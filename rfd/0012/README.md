---
authors: Thomas Li
state: prediscussion
discussion:
labels: platform, security, interop, ux
---

# [RFD] Proctored Exam Client Orchestration

This RFD adds the orchestration layer around the `proctoring` extension introduced in [RFD 0011](../0011/README.md): device binding with a platform-authenticator passkey, webcam-based identity verification reviewed asynchronously by invigilators during the exam, and a single bidirectional WebSocket between the exam client and the extension for audited control messages (announcements, private clarifications, force-submit). Media transport, room lifecycle, and LiveKit token issuance are unchanged and continue to be owned by RFD 0011.

The scope is the coordination between the proctoring extension, the student's exam client, and the `examination` extension ([RFD 0009](../0009/README.md)) during the window from sign-in to exam stop. Automatic room lifecycle tied to `submission_collection.start_at`/`stop_at` (per [RFD 0010](../0010/README.md)) remains deferred — room creation and destruction are still staff-triggered as in RFD 0011.

## Background

RFD 0011 delivers the minimum usable proctoring pipe: a LiveKit SFU, per-room OpenFGA membership, short-lived tokens, and a staff-driven exam-start-to-exam-stop lifecycle. It is deliberately silent on three adjacent concerns that real exam delivery cannot ignore:

1. **Who is on the other end of the camera.** RFD 0011 accepts any authenticated user listed in a room's `student` relation. There is no moment at which a human verifies that the live face matches the enrolled student, nor any binding between the session and a specific device. A shared account, a replayed credential, or a student sitting a second exam on the same enrolled account all pass the RFD 0011 controls.
2. **Session continuity when the browser goes away.** A two-to-three-hour exam is long enough that tab closures, browser crashes, and machine reboots are not hypothetical. RFD 0011 treats every connection as a fresh authenticated session; re-entering the exam requires no proof of continuity with the earlier session.
3. **Invigilator-to-client communication.** RFD 0011 has no path for an invigilator to say "you have thirty minutes remaining" to the room, to answer a student's clarification, or to force a student's exam client to submit. Everything an invigilator does is passive (watching tracks) or destructive (ending the exam for everyone).

This RFD covers all three without disturbing RFD 0011's media plane. The motivating constraint is that ZINC exams are **online-onsite** — students sit in supervised labs on a closed intranet, physically present with an invigilator — so the threat model is not "preventing sophisticated remote impersonation" but "catching the obvious and making the audit trail defensible." That context shapes every decision below: we prefer human judgement over ML, audited server-mediated paths over peer-to-peer convenience, and hard failure on precondition gaps over silent software fallbacks.

## Scope

### In scope

- Device binding via platform-authenticator **passkey** (WebAuthn), created on first entry and used to re-establish sessions after disconnection.
- **Session bearer** issued on entry and rotated over the control WebSocket.
- **Webcam identity verification** with invigilator visual confirmation — no ML face matching, no pre-enrolled portrait. Verification is **asynchronous**: the student is admitted to the exam on passkey registration, captures are uploaded during the exam, and the invigilator reviews them at any point in the exam window.
- A **single bidirectional WebSocket** on the proctoring extension carrying announcements, private clarifications, force-submit (also used for rejection-on-verification), and bearer refresh frames; all messages audited by virtue of flowing through the extension.
- **Object-storage design and cleanup policy** for captured ID photos and face snapshots.
- Coordination contract with the `examination` extension for the force-submit command.

### Deferred

- **Automatic room lifecycle** (Temporal workflow per RFD 0010, tied to `submission_collection.start_at`/`stop_at`). Still out of scope here; a future RFD closes this.
- **ML-assisted face match.** The invigilator makes the admission call; automated face matching is not included.
- **Hardware attestation of passkeys** (`attestation: 'direct'` with a vendor trust list). Practical only after a fleet survey establishes that real hardware attestation is available across lab machines.
- **Pre-enrolled portrait reference** sourced from student records. The captured ID photo is the only reference for R2; sourcing a canonical portrait from `core` belongs to a follow-up.
- **Device allowlisting at the OS / network layer** (per-machine certificates, MAC-address pinning, lab-network enrollment). This RFD binds at the browser-session level; lab-ops-level controls are complementary and out of scope.

## Architecture

The `proctoring` extension gains a WebSocket endpoint alongside the HTTP routes introduced in RFD 0011. The student client establishes the WS on entry and keeps it open for the duration of the exam; the invigilator client establishes its own WS with an invigilator-scoped session. All orchestration traffic flows through the extension:

```
ui-v2 student app ─────── HTTPS ────── proctoring extension ─── NATS ─── core
       │                  WSS (control) │   │
       │                                 │   ├── examination extension  (force-submit, question state)
       │                                 │   │
       ▼                                 │   └── LiveKit SFU            (media — RFD 0011)
    passkey authenticator                │
                                         ▼
                            object store (ID photo, face snapshot)

ui-v2 staff app ──────── HTTPS ────── proctoring extension
       │                  WSS (control)
       ▼
    [invigilator review surface]
```

No changes to `core`. The proctoring extension is already a `ClientModule` per RFD 0011; this RFD adds:

- `GET /v1/proctoring/sessions/challenges` — issue a single-use, short-lived (≤ 60 s) WebAuthn challenge bound to `(user_id, activity_id)`. Unauthenticated beyond the normal session cookie; called both before `/register` and before `/authenticate`. Challenges are persisted server-side for one-time consumption; reuse returns `410 Gone`.
- `POST /v1/proctoring/sessions/register` — consume a registration challenge; passkey registration on entry; issues the first session bearer.
- `POST /v1/proctoring/sessions/captures` — upload ID photo and face snapshot; streamed to object storage.
- `POST /v1/proctoring/sessions/authenticate` — consume an assertion challenge; verifies the WebAuthn assertion's `clientDataJSON.challenge` matches the issued value; on success, issues a fresh session bearer.
- `WSS /v1/proctoring/sessions/stream` — the bidirectional control channel.
- `GET /v1/proctoring/sessions/:user_id/captures/:kind` — extension-streamed plaintext capture for invigilators with `can_proctor`. Decryption happens inside the extension (see R2 Encryption); signed URLs are not used.

LiveKit room and token routes from RFD 0011 are unchanged. Because identity verification is asynchronous and no longer blocks entry, token issuance needs no new precondition beyond what RFD 0011 already enforces.

## Device Binding (R1)

### Passkey, not raw keypair

The device credential is a **platform-authenticator passkey** created via WebAuthn:

```js
await navigator.credentials.create({
  publicKey: {
    rp: { id: 'exam.zinc.example.com', name: 'ZINC Exam' },
    user: { id: userIdBytes, name, displayName },
    challenge: serverChallenge,
    pubKeyCredParams: [
      { type: 'public-key', alg: -7   }, // ES256
      { type: 'public-key', alg: -257 }, // RS256 — Windows Hello fallback
    ],
    authenticatorSelection: {
      authenticatorAttachment: 'platform',
      residentKey: 'required',
      userVerification: 'required',
    },
    timeout: 60_000,
  },
});
```

The resulting credential is discoverable (passkey), bound to the user's OS account on the exam machine, protected by Windows Hello / Touch ID / Android biometric / ChromeOS equivalent, and hardware-backed on devices with a Secure Enclave / TPM / StrongBox.

Registration happens **on entry** — it is the one action that gates the student's transition from signed-in to in-exam. The resulting credential id is stored by the extension as the `(user, exam)` device binding. Subsequent assertions against the same `(user, exam)` must present this credential id — any other binding requires invigilator intervention. Identity verification (ID photo + face snapshot) follows registration but does not gate admission; it is captured during the exam and reviewed asynchronously (see R2).

### Lab-environment prerequisite (hard blocker)

Platform-authenticator passkeys require a functioning platform authenticator on the exam machine. Machines without one **cannot be used to take the exam**. There is no software fallback in the shipped product.

Pre-exam onboarding performs a capability probe (`PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()`) and hard-fails before the student reaches passkey registration if no platform authenticator is available. Lab-ops is responsible for guaranteeing coverage across the fleet; a survey of platform-authenticator availability across the target labs is a prerequisite before this RFD moves to `published`.

### Session bearer and rotation

The passkey is **not** used to sign per-request or per-frame traffic. After passkey registration, the extension issues a session bearer (JWT, ≤ 10 min TTL, signed by the extension) tied to the `(user, exam, credential_id)` triple. The bearer rotates over the WebSocket on a schedule well inside its TTL; the client presents the current bearer as the WS bearer token and on any extension HTTP call. Passkey assertions are only invoked for session re-establishment (see below), so user-verification prompts are rare by construction.

**Bearer validation invariant**: JWT signature + expiry are necessary but not sufficient. On every bearer-authenticated request (WS frame, HTTP call, LiveKit token issuance gate), the extension additionally checks that the session row for `(user_id, activity_id)` has `locked_at is null`. A locked session rejects the request with `401` regardless of bearer freshness. This closes the up-to-10-minute window where a force-submitted student's existing bearer would otherwise remain valid.

### Re-login after disconnect

Session loss events — browser close, tab crash, machine reboot, network flap long enough to kill the TCP connection — are handled without invigilator involvement:

1. The client reaches `/v1/proctoring/sessions/authenticate` with a passkey assertion challenge.
2. The extension validates the assertion against the stored `credential_id`.
3. On success, a fresh bearer is issued and the student resumes the exam.

The device binding itself is the persistent state — because admission is not gated on invigilator approval, re-login requires no admission-state lookup. The only way the student loses access mid-exam is an invigilator-issued `force_submit` (whether as disqualification-on-verification or for any other reason).

### Cross-device sync

iCloud Keychain and Google Password Manager sync passkeys across a user's devices by default. This is not exploitable in our threat model because the exam origin is reachable only from the closed lab intranet — a synced passkey on a student's phone on mobile or home Wi-Fi cannot reach the exam host. The intranet isolation established in RFD 0011 is what makes the cross-device sync property tolerable; without it, this would be a hole.

## Identity Verification (R2)

Identity verification is **asynchronous** and does not gate exam entry. The student is admitted to the exam on passkey registration; captures are uploaded during the exam and reviewed by invigilators at any point within the exam window. An invigilator who finds a failed verification disqualifies the student by issuing a `force_submit` with a disqualification reason (R4), terminating the student's exam in place. This trade — admit-first, verify-async — is acceptable because a failed verification leads to disqualification regardless of timing, so there is no authorization decision to pre-compute, only an evidence-gathering and audit obligation.

### Capture flow

On entry — after passkey registration, before joining the LiveKit room — the client prompts the student to complete two captures:

1. **ID photo.** The client prompts the student to hold their physical student / national ID up to the webcam. Live preview, student clicks *Capture* to freeze a still frame. Client-side downsized and JPEG-encoded at ~85% quality; target payload ~150 KB.
2. **Face snapshot.** Same preview, no ID. A separate still frame of the student's face.

Both images are POSTed to `POST /v1/proctoring/sessions/captures`. The extension streams each upload straight to the object store, records pointers in its session state (`(user, activity) → (id_photo_key, face_key, uploaded_at)`), and emits a `capture_uploaded` frame to invigilator sessions for the room so their review queue refreshes.

The student can proceed to join the LiveKit room immediately after capture upload completes — verification review is not a precondition. Upload failure is surfaced to the student as a retryable error; persistent failure escalates to the invigilator queue as "uploads missing" (see below).

### Capture deadline

The client auto-prompts for captures on entry. If a student has not uploaded both captures within **15 minutes of entering the exam**, the extension flags the student in the invigilator review queue as `captures_missing` and emits a reminder frame over the student's WS. The invigilator can then nudge the student (private message) or force-submit with a "verification-not-completed" reason. This exists specifically so that "just never upload" is not a workable strategy.

### Invigilator review

Invigilators see a review queue alongside the per-student spot-check surface from RFD 0011. Opening a queue entry auto-subscribes to the student's LiveKit camera publication via `setSubscribed(true) + setVideoQuality(HIGH)`, rendering a three-up layout — **captured ID photo | captured face snapshot | live camera** — so the invigilator's decision is informed by the person currently at the machine, not just the stills. The surface auto-unsubscribes on close to honor RFD 0011's idle-is-signalling-only Dynacast property. If the student's camera is not currently published (not yet joined LiveKit, reconnecting), the live tile shows a placeholder and the invigilator may defer or decide on the stills alone. Outcomes:

- **Mark verified.** Records the decision in the audit log and clears the student from the queue. No effect on the student's exam state — they were already in the exam.
- **Disqualify.** Issues a `force_submit` with reason `identity_verification_failed` (plus optional free-text note). Audited as usual; the examination extension locks the student's exam (see R4).
- **Request re-capture.** Issues a `reverify_required` frame: the student's client surfaces the capture flow again, overwriting the previous captures. Used when a capture is obscured, wrong ID, etc. The original captures are retained in object storage for audit (never mutated) under a `superseded/` prefix.
- **Defer.** Leaves the queue entry open. Intended as a "come back to this" — the entry remains visible until exam stop.

There is no ML face matching. The invigilator's judgement is the decision; the photos and live camera are evidence.

### Object storage

Captured images are stored in a dedicated object-store bucket, separate from academic artefacts:

- **Bucket**: `proctoring-captures` (or equivalent per deployment). Public access blocked at the bucket-policy level. Bucket-level encryption (SSE-S3 / SSE-KMS) is permitted as defense in depth but **is not load-bearing** — confidentiality is provided by application-level envelope encryption (see Encryption below). The design must be portable across object stores that do not offer equivalent server-side features.
- **Key layout**:
  ```
  {activity_id}/{user_id}/{capture_kind}-{capture_id}.jpg
  {activity_id}/{user_id}/superseded/{capture_kind}-{capture_id}.jpg   (after re-capture)
  {activity_id}/{user_id}/held/{capture_kind}-{capture_id}.jpg          (hold-for-dispute)
  ```
  `capture_kind` is `id` or `face`. `capture_id` is a server-assigned ULID that ties the object to the session-state pointer.
- **Upload path**: client → extension → object store, not direct client → object store. The extension acts as a broker so that (a) caller identity is authoritative via the session bearer, not bucket IAM, (b) size and content-type validation happens before the object lands, and (c) a single audit entry covers the upload. Payloads are small enough (~150 KB × 2) that the extra hop is immaterial.
- **Read path**: extension-mediated. The invigilator client hits `GET /v1/proctoring/sessions/:user_id/captures/:kind`; the extension authorizes (`can_proctor`), fetches the wrapped DEK from the session table, unwraps via the KMS interface, fetches the ciphertext object, decrypts in-memory, and streams plaintext with `Cache-Control: no-store` and `Pragma: no-cache`. The invigilator page must set a Content-Security-Policy restricting `img-src` to `'self'` so captures cannot be sourced from third-party origins, and the client should render captures via short-lived blob URLs rather than leaving the response URL in the DOM. No direct bucket access is granted to end users; signed URLs are not used.
- **No export surface**: no bulk download, no admin-console "view all" path. Images are viewable only in the context of a specific student's review entry.

#### Encryption

The captures are PII; we don't want them readable from object-store credentials alone, and we don't want to depend on a specific object store's encryption-at-rest feature. The proctoring extension therefore encrypts captures before upload and decrypts on read. The object store sees opaque bytes; the same design works on S3, MinIO, R2, GCS, Azure Blob, etc.

**Envelope shape.** Each capture has its own 256-bit DEK that encrypts the JPEG; a long-lived KEK wraps the DEK. The wrapped DEK lives in the extension's Postgres row alongside the capture pointer; the object body holds only ciphertext + a small format header. Compromising the object store alone does not yield plaintext — Postgres access is also required. This split assumes the two systems have **distinct credential planes**; deployments that share credentials between them should not rely on it.

**Cipher.** XChaCha20-Poly1305 (RFC 8439-extended) for new captures — an AEAD whose 192-bit nonce tolerates random generation at any practical volume. AES-256-GCM is supported as a compliance fallback (FIPS-required deployments) and selected via the format's `cipher_id` byte.

**Identity binding.** The AEAD's authenticated-data input commits each ciphertext to its `(activity_id, user_id, capture_kind, capture_id, kek_version)`. A ciphertext copied to another student's slot, or read under a downgraded KEK version, fails the auth tag at decrypt. ULIDs are 128-bit fixed-length identifiers, so the concatenated AAD is unambiguous without separators.

**On-disk format.** Custom binary, not JOSE/JWE: there is no interop boundary, and JWE compact serialization would inflate blobs by ~33% from base64url for no benefit in a single-application pipeline.

```
format_version (1) | cipher_id (1) | kek_version (4) | nonce_length (1) | nonce (N) | ciphertext + 16-byte tag
```

**KEK.** Pluggable behind a `KeyManagementService` interface. Default implementation keeps the KEK as a 256-bit secret in the deployment's secret manager (Vault static, K8s Secret, env var) and wraps in-process — no external KMS dependency, which matters for portable / small deployments. Recommended for production: HashiCorp Vault Transit (KEK never enters extension memory). AWS KMS, GCP KMS, Azure Key Vault are also pluggable; none are required.

**Rotation.** `kek_version` is monotonic; new uploads use the current version, old versions stay loadable for legacy reads. Re-wrapping historical rows touches Postgres only, not object bodies — cheap relative to re-encrypting JPEGs but still a long-running batch in any sizeable cohort. A version may be retired only after no row references it; retiring early is a data-loss event.

**Read path.** Extension-mediated, replacing the earlier signed-URL design. `GET /v1/proctoring/sessions/:user_id/captures/:kind` authorizes via `can_proctor`, fetches the wrapped DEK from the row, unwraps via the KMS interface, fetches the ciphertext, decrypts in-memory, and streams plaintext with `Cache-Control: no-store`. A single audited path keeps the access trail clean and lets the read inherit existing CSP / blob-URL discipline on the invigilator client.

### Cleanup strategy

Two-tier retention, implemented primarily by **object-store lifecycle rules** rather than an extension-managed sweep job. This keeps the extension stateless with respect to long-term PII retention and delegates the deletion guarantee to the storage layer:

| Prefix                            | Lifecycle rule                          | Rationale                                                                       |
|-----------------------------------|-----------------------------------------|---------------------------------------------------------------------------------|
| `{activity_id}/{user_id}/*.jpg`   | Delete **30 days** after object creation | Active-review + short post-exam appeal window                                   |
| `{activity_id}/{user_id}/superseded/*.jpg` | Delete **30 days** after creation        | Same as above — retained for audit of the re-capture decision                   |
| `{activity_id}/{user_id}/held/*.jpg`       | **No lifecycle rule**                   | Explicit hold for ongoing misconduct investigations; deleted by manual process  |

A "hold" action operates at the **`(activity_id, user_id)` prefix level**, not per-object: on hold, the extension enumerates all captures under the user's prefix — including current, `superseded/`, and any other descendants — and moves each into `held/`. This ensures that evidence of a re-captured-and-replaced first submission (the common misconduct shape) is preserved, not silently deleted by the default lifecycle rule. Holds expire on explicit release (which moves objects back to their prior prefix, re-applying lifecycle) — there is no automatic expiry on holds, because investigations run on their own timelines. Each hold and release is audited with reason and owning case id.

**Why 30 days, not 90**: the original 90-day window was sized for institutional appeals. With async verification, the appeal window isn't blocked on review completion — reviews are finished during the exam itself, and post-exam disputes are against the *decision*, not the captures. 30 days is sufficient to cover the common review-and-dispute cycle; longer investigations use the explicit hold.

**Why object-store lifecycle, not an extension sweep**: lifecycle rules are declarative, provider-enforced, and survive extension outages. An extension-managed sweep would duplicate the guarantee less reliably. The extension's role is limited to (a) uploading under the right prefix, (b) moving to `held/` on hold-action, (c) moving back to the default prefix on release — all synchronous, no background jobs. Deletion is entirely the object store's responsibility.

**Access logging**: every capture read (caller, subject, capture kind, `kek_version`, decrypt outcome) and every hold/release action is written to the extension's audit stream.

**Logging discipline**: the extension must never log image bytes, plaintext DEKs, KEK material, or bucket keys to any standard log sink. The audit stream is the only record.

**Deletion on student request** during the retention window is not supported — retention is bounded by exam administration policy, not student preference. Documented as a trade-off.

## Control Channel (R4)

### Transport

A single WebSocket per client session, mounted at `WSS /v1/proctoring/sessions/stream`. Authentication on connect uses the session bearer as a bearer token; the extension associates the socket with the session id and participant identity. The socket is bidirectional — clients send, the extension sends, both over the same framing.

**LiveKit data channels are not used for control.** RFD 0011's `CanPublishData: false` grant on both students and invigilators is preserved to reinforce the invariant that every control message is audited by passing through the extension. Using the LiveKit data plane would either bypass the audit trail or require the extension to double-record events already delivered by the SFU.

### Frame schema

Every frame is a JSON object with a `type` discriminator and a `seq` for ordering. Server-originated frames carry `server_seq`; client-originated frames carry `client_seq`. The extension echoes applied frames with a `server_seq` to allow idempotent reconnect.

Frames in scope for this RFD:

| Direction           | Type                   | Purpose                                                                      |
|---------------------|------------------------|------------------------------------------------------------------------------|
| extension → client  | `bearer_refresh`       | Push a new session bearer before the current one expires                     |
| extension → student | `announcement`         | Text broadcast from invigilator; `scope: room`, `room_id`                    |
| extension → student | `private_message`      | Invigilator reply to this student's raise-hand                               |
| extension → student | `force_submit`         | Instruct the exam client to submit and lock (carries a `reason`)             |
| extension → student | `reverify_required`    | Request a fresh ID + face capture; client re-opens the capture flow          |
| extension → student | `capture_reminder`     | Nudge a student who hasn't uploaded captures within the deadline window      |
| student → extension | `raise_hand`           | Student requests clarification; body carries a short text                    |
| student → extension | `ack`                  | Acknowledge a server frame by `server_seq` (delivery confirmation)           |
| extension → invig.  | `session_state`        | Per-student presence / capture-status / raise-hand state for the review queue|
| extension → invig.  | `session_snapshot`     | Reconciliation frame on invigilator reconnect: last-applied `decision_id` per student |
| extension → invig.  | `capture_uploaded`     | A new capture pair is available for review                                   |
| invig. → extension  | `mark_verified`        | Record a successful verification (no client-visible effect)                  |
| invig. → extension  | `announce`             | Compose-and-send an announcement to a room                                   |
| invig. → extension  | `private_reply`        | Reply to a specific student's raise-hand                                     |
| invig. → extension  | `force_submit`         | Trigger force-submit for a specific student (with `reason`, incl. `identity_verification_failed`) |
| invig. → extension  | `force_reverify`       | Request a fresh capture from the student                                     |
| invig. → extension  | `capture_hold`         | Move a specific capture to the `held/` prefix for ongoing investigation      |
| invig. → extension  | `capture_hold_release` | Release a hold and restore normal lifecycle retention                        |

Disqualification is not its own frame type — it is a `force_submit` with `reason: identity_verification_failed`. This keeps lock-and-terminate semantics in one place and reuses the audit + coordination path with the examination extension. `force_reverify` is retained for the "capture is unclear, please redo" case where the invigilator wants a cleaner capture rather than a disqualification.

### Auditing

The extension persists every invigilator-authored frame and every admission decision to a durable audit log before emitting the corresponding client frame. This includes the full text of announcements and private replies, the subject and reason of force-submit / force-reverify, and the invigilator identity. The audit record is the canonical record, not any frame the client saw; discrepancies between what the client received and what was audited are discarded in favour of the audit.

Student-authored frames (`raise_hand`, `ack`) are also audited. Acknowledgements are not stored verbatim; the highest acknowledged `server_seq` per session is retained.

### Coordinating with the examination extension

The `examination` extension (per RFD 0009) owns the exam UI and question delivery. `force_submit` is the one control command where coordination is load-bearing:

1. Invigilator sends `force_submit` over their WS.
2. Extension audits the command, then publishes a `proctoring.force_submit` event on NATS with `{user_id, exam_id, actor_id, reason}`.
3. `examination` subscribes, performs its normal submit-and-lock for that user on that exam (semantics defined by the examination extension's own RFD), and publishes `examination.submitted`.
4. Proctoring extension sends `force_submit` to the student's WS so the client UI can reflect the locked state immediately, without waiting for the examination extension's own client-side push.

Force-submit preserves the student's currently saved answers — it is submit-and-lock, not discard-and-lock. Defining the exact semantics of "submit" is the examination extension's responsibility; this RFD only guarantees delivery of the command and the audit trail.

## Authorization Model

RFD 0011 introduced `proctoring_room` with `parent: activity`, `student: user`, and `can_proctor = can_edit from parent`. This RFD does not add any new OpenFGA relation. Because identity verification is asynchronous, there is no pre-entry admission gate to model as a state machine — the only per-`(user, exam)` record needed is the device binding itself (a `credential_id` for the registered passkey) and a per-capture verification status used to drive the invigilator review queue.

The extension maintains a small session table alongside the RFD 0011 cache sidecar, keyed on `(user_id, activity_id)`:

- `credential_id` — the passkey credential id registered on entry. Its presence is the device binding.
- `captures` — per-kind pointers into the object store (`id`, `face`), each with an `uploaded_at` and a verification outcome (`unreviewed` / `verified` / `superseded` / `held`).
- `locked_at` — set if the student was force-submitted, with the reason. Terminal.

Token issuance (`POST /v1/proctoring/rooms/:name/tokens`) retains RFD 0011's checks unchanged. It gains no new precondition.

Existing authorization checks are unchanged. `can_proctor` continues to inherit from `can_edit` on the parent activity. Invigilator WS actions are authorized per-call against `can_proctor` on the target room. Signed-URL issuance for capture reads additionally requires `can_proctor` on the room containing the capture's subject user.

## End-to-End Lifecycle

1. **Sign-in.** Student signs in to `ui-v2` as usual. Client navigates to `/activities/:id/proctored`.
2. **Capability probe.** Client calls `PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()`. No → hard fail screen, exam not takeable on this machine. Yes → proceed.
3. **Establish session.** Client opens `WSS /v1/proctoring/sessions/stream` with the user's normal session cookie; extension creates a session record.
4. **Device registration.** Client obtains a WebAuthn challenge, creates a platform-authenticator passkey with biometric prompt, POSTs the attestation to `/v1/proctoring/sessions/register`. Extension stores `(user, activity) → credential_id` and issues the first session bearer. The student is now in the exam.
5. **Identity captures.** Client auto-prompts for ID photo and face snapshot. Student completes both; client POSTs to `/v1/proctoring/sessions/captures`. Extension streams each to object storage and emits `capture_uploaded` to invigilator sessions. The student can proceed without waiting for review.
6. **LiveKit join.** Client requests a LiveKit token via RFD 0011's `POST /v1/proctoring/rooms/:name/tokens`. Client connects to the room with VP8 + simulcast + Dynacast as RFD 0011 specifies and publishes camera / microphone / screen.
7. **In-exam control.** Invigilator broadcasts announcements, handles raise-hands, and spot-checks media per RFD 0011. All non-media interaction flows over the WS.
8. **Async verification review.** At any point during the exam, invigilators work through the review queue. Outcomes: `mark_verified` (queue clears, no student-visible effect), `force_reverify` (student re-captures), `force_submit` with `reason: identity_verification_failed` (student disqualified), or deferred.
9. **Bearer rotation.** Extension pushes `bearer_refresh` every ~8 min; client replaces its bearer. No user interaction.
10. **Browser crash.** Student reopens `/activities/:id/proctored`. Client probe succeeds, WS reconnects, extension prompts passkey assertion. Client calls `/v1/proctoring/sessions/authenticate` with an assertion; extension validates against the stored credential id, issues a new bearer, and the student resumes. Uploaded captures and verification state persist across the reconnect. No invigilator involvement.
11. **Capture deadline miss.** If 15 minutes pass since entry without both captures uploaded, the extension flags the student as `captures_missing` in the invigilator queue and emits a `capture_reminder` to the student.
12. **Raise hand.** Student sends `raise_hand`. Invigilator WS receives it, invigilator authors a `private_reply`. Both audited.
13. **Force submit.** Invigilator sends `force_submit` for a specific student. Extension audits, publishes `proctoring.force_submit` on NATS, examination extension processes, student's exam client locks.
14. **Exam stop.** Staff clicks *Stop proctoring* per RFD 0011. Extension closes all WS sessions for the exam with a `session_ended` frame, marks any unreviewed captures accordingly in the audit log, and runs RFD 0011's room-deletion path. Captured images remain in the object store under the 30-day lifecycle rule (or indefinitely if under a `held/` hold).

## Alternatives Considered

### Alternative A: non-extractable WebCrypto keypair instead of passkey

An `ECDSA P-256` keypair generated via `crypto.subtle.generateKey({extractable: false})`, stored as a `CryptoKey` handle in IndexedDB, would also provide origin-partitioned device binding without requiring a platform authenticator. Pros: universal browser support, no user-verification prompt on any action. Cons: no proof that the human at the machine is the enrolled student (just that the browser session is the same one that registered), weaker exfiltration resistance on admin-compromised machines, and no hardware attestation path.

This alternative is **not shipped as a fallback**. The product hard-fails on machines lacking a platform authenticator. It is preserved here because the lab-fleet platform-authenticator availability survey is a prerequisite to moving this RFD to `published`, and if that survey finds coverage infeasible, Alternative A becomes the contingency and this section becomes the proposed mechanism.

### Alternative B: LiveKit data channel for control

Reusing the LiveKit room's data channel (`CanPublishData: true`) for invigilator ↔ student control would avoid a second long-lived connection. Rejected because (a) pre-room windows (device registration, identity check) require a channel before the student has a LiveKit token, forcing a WebSocket anyway, (b) every control message must be audited by the extension per the R4 requirement, which routes traffic server-side regardless, and (c) reusing the media-plane connection weakens the clean separation between media (SFU-governed) and control (extension-governed).

### Alternative C: automated face matching

An in-extension face-matching model (OpenCV or a cloud API) could auto-admit high-confidence matches and reduce invigilator load. Rejected for this RFD because (a) the invigilator is physically present and auto-admission saves only seconds, (b) training-data licensing and evaluation across the institution's student demographics is substantial work for a small gain, and (c) false positives on auto-admission are harder to defend in an appeal than a documented invigilator judgement. A future RFD may revisit if invigilator load becomes a bottleneck.

### Alternative D: LiveKit data channel plus extension audit mirror

A hybrid where control frames travel over the LiveKit data channel for low-latency delivery, with the extension subscribed to mirror them into the audit log. Rejected because the extension does not reliably see every data-channel frame (depends on having an admin client in every room) and because frames authored client-side bypass server authorization on their primary path. The extension-WS path makes the extension the authoritative router, not an observer.

## Implementation Notes

- **Bearer TTL and rotation cadence.** Proposed: 10 min TTL, rotated every 8 min. The rotation cadence must be strictly inside the TTL to leave slack for in-flight retries. These values are starting points — tune after load testing per RFD 0011's pre-`published` load test.
- **Session table durability.** The `(user_id, activity_id)` session table (`credential_id`, `captures`, `locked_at`) lives in the proctoring extension's durable store (Postgres, co-located with the RFD 0011 cache sidecar). In-memory-only storage is not acceptable: a locked student must remain locked across extension restarts, and the session restore on reconnect depends on the stored `credential_id`.
- **WS frame replay on reconnect.** Clients track the highest `server_seq` they have acked. On reconnect, the client sends its last-acked `server_seq` in the hello frame; the extension replays every server-originated frame with `server_seq > client_last_ack` before transitioning to normal operation. Applied invigilator decisions are part of the replay. Client-originated frames are not replayed — the client is responsible for re-sending anything without a matching `ack`.
- **Invigilator decision reconciliation on reconnect.** When an invigilator WS reconnects, the hello response includes a `session_snapshot` frame carrying the most recent `decision_id` applied per student on this invigilator's queue. The invigilator client uses this to determine whether a pending decision made it before disconnect, so it can safely skip or re-send without guessing. `decision_id`s are persisted alongside the audit record for the retention period of the audit stream.
- **Pre-registration WS timeout.** The WS opened at step 3 (before passkey registration) accepts only challenge-related exchanges and is closed by the extension with a `registration_timeout` reason if registration does not complete within 5 minutes of connect. This prevents dangling unbound sessions from accumulating on abandoned tabs.
- **Reconnect rate limit.** A client may attempt at most 5 passkey assertions per `(user_id, activity_id)` per 5-minute window. Further attempts are rejected with `429 Too Many Requests` and a `Retry-After` header; the client must apply exponential back-off (base 2, starting at 2 s, cap 60 s) before the next retry. This caps user-visible WebAuthn prompts on unstable Wi-Fi and prevents assertion-storm resource exhaustion on the extension.
- **Idempotency on invigilator decisions.** Invigilator-authored frames (`mark_verified`, `force_submit`, `force_reverify`, `capture_hold`, `capture_hold_release`) carry a client-generated `decision_id`; the extension dedupes on this id so that a double-click during a slow round-trip does not produce two audit entries.
- **Force-submit delivery guarantees.** `force_submit` is at-least-once to the examination extension over NATS (the extension retries until `examination.submitted` is observed or a staff-level timeout elapses). The client-side `force_submit` frame is advisory UI — the authoritative lock is done by the examination extension.
- **Re-capture is pointer-first, move-after.** When `force_reverify` is issued and a new capture is uploaded, the commit point is the session-state pointer update: the new capture lands at a fresh key first, then the pointer is advanced in a single transactional write, then the old object is `CopyObject`-ed to `superseded/` and the original deleted. If the extension crashes between the pointer update and the move, the old object simply remains at its original path — it is still covered by the default-prefix 30-day lifecycle rule, and a reconciliation sweep (run on extension start) moves any orphaned objects whose session pointer has advanced past them. No session state can observe a half-moved capture.
- **Capture upload failure handling.** If the client cannot upload within the 15-minute deadline despite retrying, the client surfaces an error and the session is flagged `captures_missing` to the invigilator. The invigilator has explicit UI to either nudge (private message) or disqualify. No automatic disqualification on upload failure — network problems should not lose a student their exam silently.
- **Capture size bounds.** Client-side JPEG at 1280×720, ~85% quality, typical ~150 KB; reject uploads > 1 MB at the extension.
- **Passkey registration is the entry gate.** If WebAuthn creation is cancelled by the student, the session remains without a device binding and the client surfaces a retry prompt. The student cannot proceed to the exam without completing registration. Cancelling repeatedly does not consume any resource except the open WS.
- **Origin and RP ID.** `rp.id` must match the exam origin exactly; passkeys scoped to `zinc.example.com` cannot be used at `exam.zinc.example.com` and vice versa. Deployment choice pending.
- **Object-store lifecycle rule verification.** Lifecycle rules are easy to mis-configure at deployment. A post-deploy check asserts the rules are present and correctly scoped; a daily probe asserts no objects older than 31 days exist outside `held/`. Lifecycle rules run asynchronously; the probe is the actual deletion guarantee.
- **Orphaned wrapped-DEK rows.** A reconciliation sweep removes `session_captures` rows whose object-store object no longer exists (post-lifecycle deletion). A 30-day-after-`uploaded_at` TTL matches the default lifecycle rule; rows for `held/` captures are exempt.

## Known Limitations and Accepted Trade-offs

- **Platform-authenticator availability is a hard deployment precondition.** Fleets without full coverage cannot use this RFD's R1 mechanism; the fleet survey is a prerequisite to `published`. Alternative A is the standing contingency.
- **The intranet boundary is the only control preventing cross-device passkey sync abuse.** Synced passkeys (iCloud Keychain, Google Password Manager) on a student's personal device become valid re-login credentials if — through misconfigured VLANs, NAT hairpinning, or maintenance-window routing changes — the exam origin becomes reachable off the lab intranet. The application has no network-layer enforcement of the intranet boundary. Deployment runbooks must treat network isolation as a security control with the same operational rigor as any other control (change review, monitoring, incident response). If this control cannot be guaranteed, the device-binding model collapses and an alternative (per-machine certificate, WebAuthn with `hints: ['client-device']`, etc.) must be introduced.
- **Invigilator visual match is the only identity signal.** False negatives (a lookalike, a very old ID photo) are not caught by the system and must be caught by physical invigilation. This is the same trade-off any non-biometric exam has historically accepted.
- **Admit-first exposes unreviewed students to exam content briefly.** A student who would have been rejected on sight sees question material between entry and review. In-scope risk because (a) consequences of a failed verification are the same in either model (disqualification), and (b) live camera + physical invigilation already provide a parallel signal. Pre-exam rejection was deemed worse because it would require synchronous review capacity sized to the cohort's entry burst.
- **Unreviewed-at-exam-stop captures exist.** If invigilators fall behind, some captures will still be `unreviewed` at exam stop. These are retained under the normal 30-day lifecycle and can be reviewed post-hoc; decisions made after exam stop have whatever standing institutional policy allows them. Not the system's problem to close.
- **Passkey binds to the OS account, not the machine.** A student who can log into a different OS account on the same lab machine will fail to re-bind automatically. Invigilator intervention (`force_reverify` or re-entry) is the escape hatch. Lab-ops policies (one OS session per student per exam) are assumed.
- **Mid-exam OpenFGA revocation still has the RFD 0011 TTL window.** If a student's `student` tuple is removed during an exam, their existing LiveKit token and extension bearer remain valid until expiry. This RFD does not close the window; the follow-up that introduces `proctoring.*` NATS events (deferred from RFD 0011) will.
- **PII retention is enforced by object-store lifecycle rules.** Correctness of deletion depends on the deployment's lifecycle rules being present and scoped correctly. A post-deploy check validates the rules; drift or mis-config is caught there, not at scale.
- **Force-submit semantics are defined by the examination extension.** This RFD guarantees delivery and audit but not the answer-handling semantics. If the examination extension is unavailable, force-submit degrades to an audit-only event; the client will not see a lock. Degraded behaviour during an examination-extension outage is documented, not prevented.
- **KEK loss is unrecoverable.** Captures encrypted under a lost KEK version cannot be decrypted by anyone. KEK material is treated as a backed-up root credential; loss equals data destruction.
- **Extension is the single read path for captures.** Decryption happens in the extension; each read costs two I/O round-trips and holds a ~150 KB plaintext briefly in memory. Review-queue bursts at exam-start are concurrent rather than long-lived, so capacity planning must size for review concurrency — not just connected sessions. An extension outage also means invigilators cannot view captures during the outage.
- **In-process KEK default is portable, not maximum-strength.** A KEK held in extension memory or in deployment-secret form (env var, mounted K8s Secret) is exposed by extension-process compromise, heap/core dumps, container snapshots, and CI logs that print rendered manifests. Deployments concerned with these surfaces should use Vault Transit or a cloud KMS, where the KEK never enters extension memory. The default exists so portable / small deployments work without external KMS infrastructure.
- **Live webcam unavailable when student has not yet joined LiveKit.** The review surface degrades to stills-only; the invigilator can defer or decide on stills. Common shape during the first minute of a student's session.
- **Live-webcam track identity not contracted with RFD 0011 across reconnects.** When a student reconnects mid-exam, LiveKit issues a new participant identity; an invigilator who opened a review entry before the reconnect is subscribed to a stale track. The invigilator client must re-resolve on each open. Tightening this into a stable mapping in RFD 0011 belongs to a follow-up.

## Glossary

| Term | Definition |
|------|------------|
| **WebAuthn** | Web Authentication API — a W3C standard for public-key authentication in browsers, implemented by all major browsers. Uses authenticators (platform or roaming) to create and use credentials. |
| **Passkey** | Consumer-friendly name for a discoverable WebAuthn credential. In this RFD it means specifically a platform-authenticator resident credential protected by user verification. |
| **Platform authenticator** | An authenticator built into the device (Touch ID / Face ID / Windows Hello / Android biometric / ChromeOS). Contrasted with *roaming authenticators* like YubiKeys. |
| **User verification** | A WebAuthn property meaning the authenticator verified the user's presence *and* identity (e.g. biometric or PIN) at signing time. Stronger than user presence alone. |
| **Attestation** | A signed statement from an authenticator asserting the provenance of a credential (e.g. "this credential was created in a genuine Apple Secure Enclave"). Optional at registration; not used in this RFD. |
| **Session bearer** | The short-lived JWT issued by the proctoring extension on entry, rotated over the WS, and used to authenticate extension API calls and WS frames. |
| **Device binding** | The stored `credential_id` of the passkey registered on entry for a given `(user, exam)`. Re-login requires presenting an assertion against this id. |
| **Review queue** | The invigilator's surface listing per-student capture status (`unreviewed` / `verified` / `captures_missing` / `superseded` / `held`). Reviewed asynchronously during the exam. |
| **Capture hold** | An explicit admin action moving a capture to a retention-exempt prefix in the object store, for ongoing investigations beyond the default 30-day window. |
| **Control WS** | The single bidirectional WebSocket on the proctoring extension carrying non-media orchestration traffic for the full exam lifecycle. |
| **DEK / KEK** | Data Encryption Key (per-object) and Key Encryption Key (long-lived, wraps DEKs). The two-tier structure of envelope encryption. |
| **Envelope encryption** | Pattern in which each object is encrypted with its own DEK, and the DEK itself is encrypted (wrapped) by a KEK. Allows independent rotation of the KEK without re-encrypting object bodies. |
| **AAD** | Additional Authenticated Data — input to an AEAD cipher that is authenticated but not encrypted. Used here to bind ciphertext to its identity (`activity_id, user_id, capture_kind, capture_id, kek_version`). |
| **XChaCha20-Poly1305** | An AEAD cipher with a 256-bit key and 192-bit nonce (RFC 8439-extended). The large nonce makes random-nonce collisions negligible at any practical scale. |

## References

- [RFD 0009 — ZINC Extension System](../0009/README.md)
- [RFD 0010 — Temporal Workflow Orchestration](../0010/README.md)
- [RFD 0011 — Real-Time Video Invigilation Using LiveKit](../0011/README.md)
- [W3C Web Authentication Level 3](https://www.w3.org/TR/webauthn-3/)
- [MDN: Web Authentication API](https://developer.mozilla.org/en-US/docs/Web/API/Web_Authentication_API)
- [passkeys.dev — platform authenticator support matrix](https://passkeys.dev/device-support/)
- [RFC 8439 — ChaCha20 and Poly1305 for IETF Protocols](https://www.rfc-editor.org/rfc/rfc8439)
- [NIST SP 800-38D — AES-GCM specification](https://csrc.nist.gov/pubs/sp/800/38/d/final)
- [OWASP Cryptographic Storage Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Cryptographic_Storage_Cheat_Sheet.html)
