---
authors: Thomas Li
state: prediscussion
discussion:
labels: feature, infrastructure
---

# [RFD] Examination Screen & Media Recording via LiveKit Egress

This RFD adds durable recording of student media (screen share, and optionally
camera/microphone) during proctored examinations, on top of the LiveKit
integration introduced by [RFD 0012](../0012/README.md). Recordings are
captured server-side by the LiveKit Egress service as one object per published
track segment, stored in S3-compatible storage, indexed in a
`proctoring.recording` ledger table, and served post-hoc to a narrow evidence
review circle via short-lived presigned URLs.

The design deliberately targets **misconduct evidence secondary to in-person
invigilation** — not compliance-grade archival — and optimizes for storage and
egress-CPU cost via ultra-low-framerate publisher-side encoding presets rather
than server-side transcoding.

## Background

RFD 0012 gave proctored exams a live media plane: admitted students publish
camera, microphone, and screen-share tracks to a LiveKit SFU room
(`act{activity_id}-{slug}`, identity `user:{id}`), and invigilators watch a
live grid. Nothing is persisted: once a frame is rendered, it is gone. When a
suspected misconduct case arises after the exam, there is no footage to
consult — the only durable artifacts are ID/face captures, chat, flags, and
the audit log.

Our exams are **in-person proctored**: a human invigilator in the room is the
primary misconduct control. Recording is therefore a *secondary* evidence
layer — something staff consult occasionally when an incident or appeal
arises, not a stream anyone watches routinely. This shapes every trade-off
below: completeness and attributability matter more than visual smoothness,
and a recording gap is a fact to record, not an incident to page on.

An earlier design discussion converged on periodic screenshots (one every ~5
seconds) to bound storage. That evolved into ultra-low-framerate video once we
observed that inter-frame delta encoding gives the same storage profile with
strictly better properties (see [Abandoned Ideas](#abandoned-ideas)).

The recording *infrastructure* was proven ahead of this RFD (2026-07-16):

- **Staging** runs `livekit/egress:v1.13.0` alongside the SFU, coordinating
  over a dedicated media-plane Valkey (`cobe-livekit-valkey`; the psrpc job
  bus uses only PUBLISH/SUBSCRIBE/SETNX + hashes, verified Valkey-compatible).
  An end-to-end spike recorded a 100s 720p participant egress into RustFS,
  proving Valkey compatibility, in-cluster ICE, and multipart upload against
  pre-1.0 RustFS (cobe-deployment `dd78071`).
- **Simulate stack** gained an in-repo mockestra-style egress module
  (`internal/mock/livekitegress`, host-networked to reach the loopback RTC
  proxy) composed behind `mock.WithLiveKitEgress()`; a spike recorded into the
  stack MinIO (core branch `feat/simulate-livekit-egress`). CI test stacks do
  not opt in and pay zero extra containers.

The egress pod is deliberately **lean**: track / track-composite / participant
modes only — no RoomComposite, hence no Chrome, no `SYS_ADMIN`, small CPU.

## Proposal

One sentence per decision; each has its own section below.

1. **Purpose & coverage** — recordings are misconduct evidence secondary to
   in-person invigilation; whether and what to record is a per-activity
   policy (`none | screen | full`), with a quality preset.
2. **Mode** — track egress: one egress per published track, no transcoding,
   raw stream written as-is to S3. A student reconnect produces a new segment;
   segment boundaries are themselves evidence.
3. **Quality** — ultra-low-framerate publisher-side presets (floor ≈ 1080p /
   1–2 fps / 250 kbps, `contentHint: 'detail'`). Recording quality *is*
   publish quality; there is no server-side quality machinery.
4. **Lifecycle** — LiveKit webhooks (`track_published`, `egress_ended`, …)
   drive start/stop handlers on the proctoring side; a periodic ListEgress
   reconciliation sweep makes the system eventually correct. Temporal is
   explicitly deferred.
5. **Data model** — `proctoring.recording`: an append-mostly ledger, one row
   per egress segment, keyed on `session.id` like `capture`.
6. **Access** — chief invigilator + course-staff level only (strictly narrower
   than live proctoring); short-TTL presigned GET after an authz check; every
   mint is audit-logged.
7. **Failure stance** — gaps are derived and attributable, never paged
   per-student; OTel metrics + alerting cover systemic egress failure.

## Recording purpose & coverage

**Purpose: misconduct evidence.** The archive is rarely watched; when it is
watched, the questions are "what was on this student's screen at 14:03" and
"is this gap a disconnect or a system failure". This favours completeness,
attributability, and text legibility over smooth motion, and tolerates raw
per-track files (a reviewer-friendly composite can be produced on demand for
the rare incident case).

**Coverage: per-activity policy.** A `recording_mode` knob on the proctoring
policy selects `none` (default), `screen` (screen-share track only), or `full`
(screen + camera + microphone). "Recording off" is a first-class case
everywhere. The knob rides the existing policy machinery, including the
staff-opt-in `apply_to_active` propagation (see [Policy schema](#policy-schema)).

## Recording mode: track egress

LiveKit Egress offers four modes. The choice is dominated by one physical
fact: **egress CPU scales per recording, and transcoding is expensive**
(roughly 0.5–1 CPU per transcoded stream). At exam scale — say 100 students ×
screen + camera — any transcoding mode is a three-digit CPU bill per room.

**Track egress** writes the SFU-received stream as-is (H.264 → mp4 container,
Opus → ogg), no re-encode — roughly an order of magnitude cheaper, and the
recorded quality is exactly what was published, no generational loss. Its
quirk is lifecycle: a track egress ends whenever its track is unpublished, so
a student reconnect yields multiple files per source. For evidence purposes
this is a feature: each file is a **segment** with honest boundaries, and the
review timeline renders "screen feed gap 14:03–14:05, correlates with WS
disconnect" instead of papering over it.

Participant egress (transcoding, per-identity) and RoomComposite (headless
Chrome, `SYS_ADMIN`, 2–6 CPU) are rejected as the baseline — see
[Abandoned Ideas](#abandoned-ideas). Nothing prevents an operator from
running a one-off participant egress for a specific incident later; the lean
egress pod supports it.

## Quality: ultra-low-framerate publisher-side presets

With track egress there is no transcode, so **recording quality is publish
quality** — the knob lives in the student's browser at publish time, and both
egress CPU and storage shrink proportionally with it.

### Mechanics (verified against livekit-client 2.20.0)

Two levers per track, both accepted by
`setScreenShareEnabled(enabled, captureOptions, publishOptions)` /
`setCameraEnabled(...)`:

- **Capture constraint** — `ScreenShareCaptureOptions.resolution` is
  `{width, height, frameRate?}`, passed to `getDisplayMedia`.
- **Encoder cap** — `TrackPublishOptions.screenShareEncoding` takes
  `{maxBitrate, maxFramerate}`. The SDK ships presets down to
  `ScreenSharePresets.h360fps3` (3 fps / 200 kbps) and `VideoPreset` accepts
  arbitrary values (`new VideoPreset(1920, 1080, 250_000, 1)`).

Plus `contentHint: 'detail'`, which flips the browser's degradation preference
to maintain-resolution: under pressure it drops frames instead of blurring.
For evidence, a sharp 1 fps screen beats a smooth soft one.

The client plumbing point already exists: `usePublisher`
(`ui-v2/apps/client/app/lib/use-publisher.ts`) currently publishes with SDK
defaults (`h1080fps15` ≈ 2.5 Mbps ≈ 2.2 GB/student for a 2 h exam). At
1080p / 1–2 fps / 250 kbps the *ceiling* is ~225 MB/student (~22 GB per
100-student exam), and realistic mostly-static exam screens land well below
it, because a video encoder spends bits proportional to **pixel change**, not
tick rate.

### Why 1–2 fps, not lower

The storage win comes from delta encoding plus the bitrate cap, not from
pushing fps toward zero — a static screen costs near-nothing at 1 fps and at
0.2 fps alike. Staying at ≥1 fps buys:

- **Sub-interval events are captured.** An alt-tab flash or popup wakes the
  encoder *because pixels changed*; periodic sampling structurally misses
  anything shorter than its interval.
- **WebRTC machinery stays healthy.** Keyframe cadence, bandwidth estimation,
  and SFU/egress stall detection all assume a live stream; sub-1 fps is where
  fractional-frameRate constraint handling gets browser-dependent.

### Straw presets

| Preset | Screen | Camera | Intent |
|---|---|---|---|
| `evidence_low` | 1080p / 1–2 fps / 250 kbps | 360p / 5 fps / 150 kbps | default for recorded exams |
| `standard` | 720p / 5 fps / 800 kbps (`h720fps5`) | 360p / 15 fps | mixed live+evidence |
| `high` | 1080p / 15 fps / 2.5 Mbps (`h1080fps15`, current SDK default) | 720p / 30 fps | current behaviour |

Numbers are server-owned and tunable without a client release (see
[Policy schema](#policy-schema)).

### Spike results (2026-07-16)

Both pre-implementation spikes ran on the simulate stack: four ~7-minute
**track-egress** recordings of a synthetic 1080p exam screen (code editor +
per-second countdown) published from headless Chrome (livekit-client 2.20.0,
H.264, `contentHint: 'detail'`, simulcast off, 250 kbps cap, 1–2 fps).

**Storage rate** (steady state; the first minute carries the one-time
keyframe and encoder settling, ~60–70 KB):

| Variant | Measured | Per 2 h exam |
|---|---|---|
| 2 fps, static screen (cursor blink only) | 0.9 kbps ≈ 0.4 MB/h | ~0.8 MB |
| 1 fps, active typing | 1.9 kbps ≈ 0.8 MB/h | ~1.6 MB |
| 2 fps, active typing | 2.5 kbps ≈ 1.1 MB/h | ~2.2 MB |
| 2 fps, continuous scrolling (worst realistic) | 7.8 kbps ≈ 3.4 MB/h | ~6.8 MB |

Delta encoding does exactly what the design bet on: measured rates sit two
orders of magnitude below the 250 kbps cap. The cap stays the *guarantee*
(~225 MB/student/2 h); the *expectation* for a 100-student 2 h exam is well
under 1 GB total, not 22 GB. Caveat: the canvas-rendered screen is cleaner
than a real desktop capture (no images, PDFs, or anti-aliasing noise) —
treat real-world as several × the table, still nowhere near the cap.

**Keyframes & seekability:** the recorded stream carries exactly **one
keyframe, at t=0**, regardless of fps — libwebrtc emits keyframes on demand
(PLI) and egress subscribes once, so no periodic keyframes ever arrive.
Consequences, all acceptable:

- Playback is correct start-to-end; duration and stream metadata are right
  (1080p, H.264 Constrained Baseline); text is pixel-crisp at these
  bitrates — the countdown is legible to the second.
- Seeking decodes forward from t=0: measured ~0.3–0.5 s anywhere in a 7-min
  file, scaling roughly linearly with target position → single-digit seconds
  to cold-seek the tail of a 2 h file at 2 fps. Fine for evidence review; if
  scrubbing UX ever matters, the fix is a post-processing remux that injects
  keyframes (the deferred Temporal hook), not a publisher change.
- The mp4 is **not faststart** (moov atom at the tail): players must issue
  HTTP range requests against the presigned URL — browsers and MinIO/RustFS
  both do this natively.

**1 fps vs 2 fps:** both recorded flawlessly — no stall, no keyframe
starvation, exact frame cadence in the file. 1 fps saves only ~0.3 MB/h over
2 fps, so the floor preset stays **2 fps** for twice the temporal evidence
granularity. The `evidence_low` numbers are confirmed as specced.

**Track-egress mechanics confirmed:** H.264 in → `.mp4` out (egress appends
the extension to the templated object key); egress also uploads a small
`EG_*.json` manifest sidecar next to the media file — the implementation
either sets `disable_manifest` in the file output or accounts for the
sidecar when listing objects.

### Remaining caveats
- **The track is shared with live invigilation.** Whatever the student
  publishes is what the invigilator grid renders. 1–3 fps screen share is
  acceptable live; a 1 fps *camera* would feel broken — hence per-source
  presets with a higher camera floor.
- **Simulcast** (`screenShareSimulcastLayers`) is disabled for low presets —
  layered encoding at 1 fps is waste and muddies what track egress records.
- **Enforcement is client-side.** The preset caps what our exam client
  publishes; that is the same trust model as all client capture today, stated
  here for the record.

## Lifecycle: webhooks + reconciliation sweep

Something must react every time a matching track is (re)published while the
policy says "record". The LiveKit server is configured to POST signed webhooks
(`track_published`, `track_unpublished`, `egress_started`, `egress_updated`,
`egress_ended`) to a new endpoint on our side.

**Fast path (webhook handlers):**

1. `track_published` → resolve room name + identity `user:{id}` to the
   proctoring session → read the session's *effective* `policy_snapshot` → if
   the source matches `recording_mode`, insert a `starting` recording row and
   call `StartTrackEgress` with a per-request object key and S3 credentials.
   Non-student identities (invigilators, the hidden `kind=EGRESS` participant)
   never match a session and are skipped structurally.
2. `egress_started` / `egress_updated` → upsert status by `egress_id`.
3. `egress_ended` → mark `complete | failed | aborted`, store `end_reason`,
   `byte_size`, timestamps.

**Slow path (reconciliation sweep):** a periodic pass per active exam room
compares expected state (admitted sessions × policy × currently-published
tracks) against `ListEgress` and the ledger: starts missing egresses (missed
webhook, failed start, policy flipped on mid-exam), stops orphaned ones
(policy flipped off), and repairs rows for terminal events we never received.
**The sweep is load-bearing, not a nice-to-have**: LiveKit webhook delivery is
at-least-once-ish with limited retries and no ordering guarantee, so webhooks
are only the low-latency fast path; the sweep is what makes the system
eventually correct.

**Races and idempotency** (all bounded, all testable):

- Duplicate webhook → double start: serialized by the partial unique index
  (one live egress per `track_sid`, 23505 → ignore).
- Track unpublished before `StartTrackEgress` lands: the start fails; ignore.
- `egress_ended` before `egress_started` was processed: upsert by `egress_id`
  tolerates out-of-order arrival.
- StartEgress itself fails: **no row** — the ledger records only egresses that
  existed. Failures go to OTel and the sweep retries while the track lives.

**Accepted cost — the start gap:** publish → webhook → StartEgress → egress
subscribes loses the first ~1–2 s of each segment. Acceptable for evidence
behind an in-person invigilator; recorded here so nobody rediscovers it as a
bug.

### Coupling to the proctoring lifecycle

Recording has **no state machine of its own and no explicit sync** with the
RFD 0012 session FSM. The coupling is one-directional and derived: the
proctoring lifecycle drives the media plane (which tracks exist), and the
media plane drives recording (which egresses run). There is deliberately no
"exam started, begin recording" event — **publication is the trigger**. A
track can only exist for an *admitted* session (the media shell mounts
post-admission, under `live_media`), so recording inherits every
admission-side gate transitively: nothing is recorded during
`pending_device_proof` / `awaiting_capture` / `awaiting_attach` (identity
evidence there is `capture`'s job), and the `track_published` handler
resolving identity → session only ever finds admitted sessions.

Per lifecycle event:

| Proctoring event | Media-plane effect | Recording effect |
|---|---|---|
| Session admitted, shell mounts | tracks publish | webhooks → segments start (policy permitting) |
| Disconnect / reconnect (reentry) | tracks unpublish, republish (new SIDs) | segment ends (`track_unpublished`), new segment rows; reentry keeps one session row, so history accumulates under one `session_id` |
| Session locked (invigilator lock / force-submit) | client teardown → tracks unpublish | segments end naturally; the sweep is the backstop for a lingering client |
| Re-seat mid-exam | nothing (sessions are not room-keyed) | later segments carry the new `room_id` snapshot |
| `apply_to_active` policy flip | nothing immediate | sweep starts egresses for live tracks (mode on) / stops running ones (mode off); quality applies at next publish |
| Room `ended` (terminal) | all participants torn down → tracks unpublish | all segments end; the room leaves the sweep's active set |

The sweep is where the "sync" actually lives, stated as one invariant:
*expected egresses = admitted, unlocked sessions × recording policy ×
currently-published tracks*. Every transition above merely changes an input
to that equation; no proctoring code needs to know recording exists.

The reverse direction is deliberately absent: recording never gates the FSM.
Admission does not wait for an egress to start, a lock does not wait for
segments to finalize (`egress_ended` arriving after room end is just a late
terminal row update), and an egress failure never blocks or flags the
attempt (see [Failure stance](#failure-stance--observability)). The only
post-hoc join between the two worlds is the evidence timeline: recording
rows key on `session.id`, so segments and gaps line up against the same
session's WS/media events at review.

### Why not the alternatives

| Lifecycle lever | Webhooks | SFU auto-track-egress | Temporal per student |
|---|---|---|---|
| Filter by source (screen-only) | ✅ per-track | ❌ records every track | ✅ same APIs |
| Filter by participant (skip invigilators) | ✅ | ❌ | ✅ |
| Mid-exam policy change | ✅ | ❌ fixed at room create | ✅ |
| Restart after egress failure | ✅ | ❌ | ✅ |
| Per-request key template / S3 creds | ✅ | ⚠️ one template at room create | ✅ |
| Start gap | ~1–2 s | near-zero | ~same as webhooks |
| Orchestration code owned | moderate | none | most |

Auto-track-egress trades every filter and every mid-exam decision for a
near-zero start gap — a direct conflict with policy-driven coverage. Temporal
has *identical* control (it calls the same APIs) wrapped in durable state we
do not yet need; the webhook handler is exactly where a workflow would be
started, so this choice does not foreclose Temporal if recordings later grow
post-processing steps (stitching, on-demand transcode, encryption).

## Data model

One table. Append-mostly ledger; rows mutate only on egress status
transitions.

```sql
-- recording — append-mostly ledger of track-egress SEGMENTS. One row per LiveKit egress
-- (one track publish → one egress → one object). A student reconnect = new track SID =
-- new row; gaps between segments are DERIVED at review time from segment boundaries +
-- session events, never stored. Keyed like capture: session.id + (activity_id, user_id)
-- denorm guards. Objects are plaintext in the recordings bucket (SSE at rest) — no DEK
-- columns; unlike capture, egress uploads directly so there is no app-side encrypt hook.
CREATE TABLE proctoring.recording (
    id           BIGSERIAL PRIMARY KEY,
    session_id   BIGINT  NOT NULL,
    activity_id  INTEGER NOT NULL,
    user_id      INTEGER NOT NULL,
    room_id      BIGINT,                -- display/audit SNAPSHOT at segment start (chat_message R7 pattern), NOT a key
    source       TEXT    NOT NULL,      -- LiveKit track source
    track_sid    TEXT    NOT NULL,      -- TR_… ; republish ⇒ new SID ⇒ new row
    egress_id    TEXT    NOT NULL,      -- EG_… ; webhook dedup anchor
    status       TEXT    NOT NULL DEFAULT 'starting',
    end_reason   TEXT    NOT NULL DEFAULT '',  -- raw LiveKit error / 'track_unpublished' / 'limit_reached'
    object_key   TEXT    NOT NULL,      -- WE template it in the StartEgress request ⇒ known at insert, never NULL
    mime_type    TEXT    NOT NULL DEFAULT '',  -- e.g. video/h264 → picks the player at review
    quality      TEXT    NOT NULL DEFAULT '',  -- preset NAME applied at publish (policy may change mid-exam)
    byte_size    BIGINT,                -- from egress_ended; NULL until terminal
    held         BOOLEAN NOT NULL DEFAULT FALSE,  -- legal/incident hold: survives retention purge (capture parity)
    purged_at    TIMESTAMPTZ,           -- tombstone: object deleted by retention, row proves it existed
    started_at   TIMESTAMPTZ,           -- egress started_at (what's actually on disk, not publish time)
    ended_at     TIMESTAMPTZ,
    created_at   TIMESTAMPTZ DEFAULT now() NOT NULL,
    updated_at   TIMESTAMPTZ DEFAULT now() NOT NULL,
    CONSTRAINT proctoring_recording_egress_id_key UNIQUE (egress_id),
    CONSTRAINT proctoring_recording_source_check
        CHECK (source IN ('camera','microphone','screen_share','screen_share_audio')),
    CONSTRAINT proctoring_recording_status_check
        CHECK (status IN ('starting','active','complete','failed','aborted')),
    CONSTRAINT proctoring_recording_session_id_fkey
        FOREIGN KEY (session_id) REFERENCES proctoring.session(id) ON UPDATE RESTRICT ON DELETE CASCADE,
    CONSTRAINT proctoring_recording_activity_id_fkey
        FOREIGN KEY (activity_id) REFERENCES core.activity(id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT proctoring_recording_user_id_fkey
        FOREIGN KEY (user_id) REFERENCES core."user"(id) ON UPDATE RESTRICT ON DELETE RESTRICT
);
CREATE INDEX idx_proctoring_recording_session_id    ON proctoring.recording(session_id);
CREATE INDEX idx_proctoring_recording_activity_user ON proctoring.recording(activity_id, user_id);
-- ONE live egress per track: serializes the duplicate-webhook double-start race on 23505,
-- same trick as idx_proctoring_capture_active.
CREATE UNIQUE INDEX idx_proctoring_recording_live
    ON proctoring.recording(track_sid) WHERE ended_at IS NULL;
CREATE TRIGGER set_proctoring_recording_updated_at BEFORE UPDATE ON proctoring.recording
    FOR EACH ROW EXECUTE FUNCTION core.set_current_timestamp_updated_at();
```

Load-bearing choices:

- **Keyed on `session.id`, like `capture`.** The media shell mounts only
  post-admission, so a session always exists when a student track publishes.
  The `(activity_id, user_id)` denorm guards match capture, and the session
  identity FK chain already guarantees a roster reconcile can never
  cascade-delete evidence. The CASCADE deliberately echoes capture: voiding an
  attempt (explicit admin session delete) drops its recording rows — the S3
  objects need a cleanup step, owned by the retention work.
- **Row identity = egress; `egress_id` UNIQUE** makes handler idempotency a
  natural upsert. The partial unique index on `track_sid WHERE ended_at IS
  NULL` is the schema backstop against double-start.
- **`object_key` NOT NULL from birth** — we template the filepath in the
  StartEgress request, so the key is known before the first byte lands, and
  the sweep can check object existence for any row. The template uses numeric
  ids only (`recordings/act{activity_id}/u{user_id}/s{session_id}/{source}-{egress_id}.mp4`)
  because egress renders identity strings verbatim into keys — `user:999`
  would put a `:` in the object key (S3-legal, filesystem-hostile).
- **No gap rows.** A gap is derived at review time from segment boundaries
  joined against session events (`last_known_media_state`, WS disconnects)
  that already exist; storing gaps would denormalize a computation and invite
  drift.
- **`held` / `purged_at` are dormant** until retention jobs exist; adding them
  now means the evidence contract never needs a migration.

## Policy schema

Two flat keys extend the stable `PolicySnapshot` contract (persisted verbatim
in `proctoring.session.policy_snapshot` and embedded in the session-bearer
JWT):

```json
{
  "device_proof": false,
  "live_media": false,
  "identity_verification": "disabled",
  "recording_mode": "none",        // "none" | "screen" | "full"
  "recording_quality": "standard"  // "evidence_low" | "standard" | "high"
}
```

- **Flat keys, not a nested object** — matches house style and diffs cleanly
  in the propagation machinery. `WithDefaults()` normalizes empty →
  `"none"` / `"standard"`, so every previously-persisted snapshot and
  already-issued JWT reads as recording-off: fail-safe, zero migration.
- **Validation at `PUT /config`:** `recording_mode != none` requires
  `live_media = true` — tracks that are never published cannot be recorded.
- **Propagation:** both keys ride `apply_to_active` exactly like `live_media`
  (forward-only re-stamp + durable `policy_update` frame); `device_proof`
  stays the lone never-propagates field. Mid-exam semantics: *mode* flips take
  effect through the sweep (record-on starts egresses for already-live
  tracks; record-off stops running ones); *quality* applies at next publish
  only — no forced republish of a live track (a reconnect picks it up).
- **Names in the snapshot, numbers in the connection response.** The snapshot
  and JWT carry only preset *names* (stable contract stays small). The
  LiveKit token/connection response gains a `recording_params` block with
  resolved `{width, height, maxFramerate, maxBitrate, contentHint}` per
  source; the client applies whatever numbers arrive. The server owns the
  name→numbers map, so tuning a preset never needs a client release.
- **Server-side decisions** (webhook handler, sweep) read the session's
  *effective* `policy_snapshot` — consistent with the `live_media` gate,
  never the raw activity config.

## Access & evidence semantics

- **Who:** chief invigilator + course-staff-level permission on the activity.
  Room invigilators get *no* post-hoc access by default — their job is live;
  evidence review is a strictly narrower circle than invigilation. (Exact
  OpenFGA relation — reuse of the activity manage permission vs a dedicated
  `can_review_recordings` — is settled at implementation; the principle is
  "strictly narrower than live proctoring".)
- **List:** activity-scoped endpoint with a user filter returning ledger rows;
  the review UI derives the per-student timeline (segments + attributable
  gaps) by joining against session events.
- **Fetch:** short-TTL (~2 min) presigned GET minted after the authz check —
  house style for plaintext artifacts (cf. pipeline `result_read`). Range
  requests work natively against MinIO/RustFS, so video seeking is free; no
  proxy streaming. (Spike-verified: the recorded mp4 keeps its moov atom at
  the tail, so range support is load-bearing for browser playback.)
- **Every mint writes a `proctoring.audit_log` row** — accessing evidence is
  itself evidence, and this future-proofs institutional privacy-policy
  conversations.
- **Encryption stance:** recordings are plaintext objects in a dedicated
  `recordings` bucket with server-side encryption at rest. Capture-style
  envelope encryption **cannot** apply as-is — egress uploads directly to S3
  with no app-side encrypt hook. If evidence policy ever demands
  client-managed keys, that becomes a post-processing step (and the natural
  trigger to revisit Temporal); explicitly out of scope for v1.
- **Retention:** real-exam capacity/retention (cap ≈22 GB per 100-student
  exam at `evidence_low`; spike-measured expectation well under 1 GB; staging
  RustFS is 10 Gi) is a deployment decision deferred with the retention
  jobs. The schema (`held`, `purged_at`) is already shaped
  for it.

## Failure stance & observability

Recording failure is **detected and recorded, never paged per-student**. The
exam itself is protected by the in-person invigilator; the archive is
secondary evidence.

- Gaps are derived and *attributable*: segment boundaries join against session
  events to distinguish "student disconnected" from "system failure"
  (`end_reason` carries the raw LiveKit error).
- The sweep restarts failed egresses while the track lives, and repairs ledger
  rows for missed webhooks.
- OTel per OBSERVABILITY.md: spans on webhook handlers and sweep passes;
  metrics for egress starts/failures/restarts and sweep repairs; alerting
  thresholds on *systemic* failure rates (an egress pod dying fails many
  egresses at once — that is an infra alert, not N student incidents).

## Implementation surface

- **core / proctoring:** webhook receiver endpoint (LiveKit-JWT-signature
  verified; whether the HTTP route terminates on the core router and forwards
  to the proctoring extension over NATS, or the extension listens itself, is
  resolved at implementation to match existing patterns), egress service
  (StartTrackEgress/StopEgress + per-request S3 credentials, minted and
  revoked like the grading runtime's per-run creds; static creds in egress
  config are the fallback), reconciliation sweep, `PolicySnapshot` +
  validation + propagation extension, recording list/fetch endpoints + authz
  + audit, migration for `proctoring.recording`.
- **ui-v2:** `usePublisher` applies `recording_params` from the connection
  response at publish time; invigilator grid filters the hidden `kind=EGRESS`
  participant (explicit test — egress joins rooms as a hidden participant);
  post-hoc review surface (list + player) for the evidence circle.
- **Deployment:** webhook URL + signing-key knob in every LiveKit deployment
  (staging manifest, simulate stack); egress infra itself is already deployed
  in both environments.
- **Pre-implementation spikes: done** (2026-07-16, simulate stack) — see
  [Spike results](#spike-results-2026-07-16). Preset numbers confirmed; no
  open questions block implementation.

## Abandoned Ideas

**Periodic screenshots (one per ~5 s).** The predecessor design. Ultra-low-fps
video dominates it: delta encoding yields the same storage for static content
while capturing sub-interval events (screenshots structurally miss anything
shorter than the sampling period); and it reuses the entire existing pipeline
(student already publishes the screen; egress uploads server-side) instead of
needing a second client capture/upload path with its own batching, offline
buffering, and tamper story.

**RoomComposite egress.** One recording per room via headless Chrome —
requires `SYS_ADMIN`, 2–6 CPU, and produces a mixed grid useless as
per-student evidence. Rejected; the egress pod deliberately excludes it.

**Participant egress as the baseline.** Per-identity composites are
reviewer-friendly but transcode (~0.5–1 CPU per student per stream — a
three-digit CPU bill per exam room) and still end on participant disconnect,
buying no lifecycle simplicity. Retained as an on-demand tool for incident
cases, not the baseline.

**SFU auto-track-egress.** Zero orchestration code and near-zero start gap,
but fixed at room creation: no source filter (screen-only impossible), no
participant filter (records invigilator tracks), no mid-exam policy change,
and nothing re-arms after an egress failure. Conflicts directly with
policy-driven coverage.

**Temporal-first lifecycle.** Identical control to webhooks (same APIs) at
the cost of durable state that would mostly mirror what LiveKit already
keeps. Deferred, not rejected: the webhook handler is exactly where a
workflow would be started if recordings grow multi-step post-processing.

**Stored gap rows.** Gaps are a computation over segment boundaries and
session events; storing them denormalizes and drifts.

**Envelope encryption of recordings.** No app-side hook exists on the
egress→S3 path; parity with capture would require a post-processing pass.
Bucket SSE now; revisit only if evidence policy demands client-managed keys.

**Sub-1 fps capture.** Negligible storage gain over 1–2 fps (delta encoding
already zeroes static content) while risking browser fractional-frameRate
handling, stall detection, and keyframe starvation.
