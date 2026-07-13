---
authors: Thomas Li
state: prediscussion
discussion:
labels: platform, security, interop, ux
---

# [RFD] Proctored Exam Client Orchestration

This RFD adds the orchestration layer around the `proctoring` extension introduced in [RFD 0011](../0011/README.md): a single bidirectional WebSocket between the exam client and the extension for audited control messages (announcements, private clarifications, force-submit), a first-class extension-owned admission state, and a **unified per-activity proctoring policy** with three independent knobs — `device_proof` (`on`/`off`), `live_media` (`on`/`off`), and `identity_verification` (`enforced`/`disabled`). The default `{on, on, enforced}` reproduces today's behaviour: a platform-authenticator passkey device binding, the RFD 0011 live-video/screen plane, and webcam identity verification reviewed asynchronously by invigilators. Each knob may be turned off independently, so the design must hold for all **eight cells** of the matrix — including the near-bare `{off, off, disabled}` session (no passkey, no media, no captures) and every mixed cell — without impossible states. Media transport, room lifecycle, and LiveKit token issuance remain owned by RFD 0011 and are exercised **only when `live_media=on`**, where the media plane is byte-for-byte compatible after the new admission/room-ready preconditions are satisfied; this RFD requires a small set of normative RFD 0011 edits (enumerated under Authorization Model and Known Limitations) that must be ratified with the RFD 0011 owner, and a core-side content-gate contract (a synchronous `IsAdmitted` pull on core's existing exam-start path) that must be ratified with the core/RFD 0009 owner.

The scope is the coordination between the proctoring extension, the student's exam client, and the `examination` extension ([RFD 0009](../0009/README.md)) during the window from sign-in to exam stop. Automatic room lifecycle tied to `submission_collection.start_at`/`stop_at` (per [RFD 0010](../0010/README.md)) remains deferred — room creation and destruction are still staff-triggered as in RFD 0011.

## Background

RFD 0011 delivers the minimum usable proctoring pipe: a LiveKit SFU, per-room OpenFGA membership, short-lived tokens, and a staff-driven exam-start-to-exam-stop lifecycle. It is deliberately silent on three adjacent concerns that real exam delivery cannot ignore:

1. **Who is on the other end of the camera.** RFD 0011 accepts any authenticated user listed in a room's `student` relation. There is no moment at which a human verifies that the live face matches the enrolled student, nor any binding between the session and a specific device. A shared account, a replayed credential, or a student sitting a second exam on the same enrolled account all pass the RFD 0011 controls. This RFD layers two **independently selectable** identity controls on top: an optional platform-authenticator passkey **device binding** (`device_proof`) and optional webcam **identity verification** (`identity_verification`). When `device_proof=off` there is no device binding **at all** — by deliberate choice, not by substituting a weaker mechanism — and the resulting (strictly weaker, bounded) threat model rests on the authenticated session, closed-intranet isolation, and physical invigilation. The online-onsite premise — a supervised lab on a closed intranet — is what makes that bound acceptable; closed-intranet isolation is the only network-layer control, and there is no application-level source-IP allowlist.
2. **Session continuity when the browser goes away.** A two-to-three-hour exam is long enough that tab closures, browser crashes, and machine reboots are not hypothetical. RFD 0011 treats every connection as a fresh authenticated session; re-entering the exam requires no proof of continuity with the earlier session. We establish continuity through a **session bearer** carried over the reused WS + HTTP framing, decoupled from any passkey. The bearer is issued at session create, rotated over the control WS, and re-established on reconnect — by a passkey assertion when `device_proof=on`, and by an extension-issued single-active re-entry token when `device_proof=off`. With `device_proof=off` there is no proof-of-possession on any request; continuity is a single-active-session convenience bounded by the bearer's 10-minute TTL, the intranet, and invigilation, not a cryptographic guarantee.
3. **Invigilator-to-client communication.** RFD 0011 has no path for an invigilator to say "you have thirty minutes remaining" to the room, to answer a student's clarification, or to force a student's exam client to submit. Everything an invigilator does is passive (watching tracks) or destructive (ending the exam for everyone).

This RFD covers all three without disturbing RFD 0011's media plane. The motivating constraint is that ZINC exams are **online-onsite** — students sit in supervised labs on a closed intranet, physically present with an invigilator — so the threat model is not "preventing sophisticated remote impersonation" but "catching the obvious and making the audit trail defensible." That context shapes every decision below: we prefer human judgement over ML, audited server-mediated paths over peer-to-peer convenience, and hard failure on precondition gaps over silent software fallbacks.

## Scope

### In scope

- A **unified per-activity proctoring policy** (`proctoring_policy`) with three independent knobs, resolved behind one `ProctoringPolicy` interface and **frozen as a per-session `policy_snapshot`** at session create:
  - `device_proof: on | off` — optional platform-authenticator **passkey** (WebAuthn) device binding. `on` reproduces today's behaviour (registration on entry, assertion on reconnect). `off` means **no device binding at all**: session create is authorized by the normal authenticated session cookie, an `enrolled` OpenFGA tuple, and `locked_at IS NULL`; reconnect is authorized by an extension-issued single-active re-entry token; `credential_id` is permanently NULL. No alternative device-binding mechanism is introduced under `off`, and closed-intranet isolation is the only network control.
  - `live_media: on | off` — optional LiveKit camera/screen publishing + live invigilation (the RFD 0011 plane). Controlled entirely through this extension's own policy state and control WS/HTTP, never by hacking LiveKit grants. `off` means no LiveKit room is ever created for the activity.
  - `identity_verification: enforced | disabled` — webcam ID-photo + face-snapshot captures with asynchronous invigilator review, no ML face matching, no pre-enrolled portrait. Open enum (future `optional`). Subsumes the former standalone `verification_policy`.
- **Session bearer** decoupled from passkey registration: issued at session create in every cell, rotated over the control WebSocket, re-established on reconnect.
- A **first-class, extension-owned admission state** (`admission_state`) surfaced over WS/HTTP as the single fact every consumer keys off — never "the client obtained a LiveKit token."
- Under `identity_verification=enforced`, capture submission gates admission; the invigilator's **verdict is asynchronous**. Invigilators can flag an entry **suspicious** (non-destructive) or disqualify, and can **manually admit** a student who cannot capture.
- A **single bidirectional WebSocket** on the proctoring extension carrying announcements, private clarifications, force-submit (also used for rejection-on-verification), and bearer refresh frames; all messages audited by virtue of flowing through the extension.
- **Object-storage design and cleanup policy** for captured ID photos and face snapshots.
- Coordination contract with the `examination` extension for the force-submit command.

### Deferred

- **Automatic room lifecycle** (Temporal workflow per RFD 0010, tied to `submission_collection.start_at`/`stop_at`). Still out of scope here; a future RFD closes this.
- **ML-assisted face match.** The invigilator makes the admission call; automated face matching is not included.
- **Hardware attestation of passkeys** (`attestation: 'direct'` with a vendor trust list). Practical only after a fleet survey establishes that real hardware attestation is available across lab machines.
- **Pre-enrolled portrait reference** sourced from student records. The captured ID photo is the only reference for R2; sourcing a canonical portrait from `core` belongs to a follow-up.
- **Device allowlisting at the OS / network layer** (per-machine certificates, MAC-address pinning, lab-network enrollment). This RFD binds at the browser-session level; lab-ops-level controls are complementary and out of scope.
- **Any alternative device-binding mechanism for `device_proof=off`.** `off` means no device binding at all. A non-extractable WebCrypto keypair, a per-machine certificate, an application-level source-IP allowlist, or MAC pinning are explicitly **not** introduced as a fallback; the no-device-proof cell is a deliberate, bounded weaker threat model (see Known Limitations) resting on the authenticated session + closed intranet + invigilation, not a degraded form of R1.
- **Cross-RFD ratifications (preconditions, not assumptions).** Two reach-throughs into adjacent RFDs are required for this design and are deferred pending owner sign-off; neither is silently assumed:
  - **Core-driven `IsAdmitted` pull (core / RFD 0009 owner).** Core's `examination` activity path must, before serving questions for a proctored activity, synchronously query the proctoring extension's `IsAdmitted(user_id, activity_id)` and **fail closed** when not admitted (re-checked on a heartbeat). This preserves RFD 0009's core-as-orchestrator direction (a read-dependency, not a push-gate or durable subscriber), but the `IsAdmitted` NATS request-reply subject name, its timeout, and the fail-closed semantics require the core/RFD 0009 owner's sign-off. Until ratified, no proctored activity whose content must be gated should be published.
  - **RFD 0011 normative edits (RFD 0011 owner).** Rooms derive per-room `student@proctoring_room` tuples from the new `enrolled` set (amending RFD 0011's single-source-of-truth statement to a two-plane membership model), and the token route gains student-branch preconditions (admission + `room_ready` + device-proof-complete; invigilator branch unchanged). These are **new** machinery vs RFD 0011 (which has no admission gate today) and require the RFD 0011 owner's sign-off.

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

- `POST /v1/proctoring/sessions` — **the universal session-create + first-bearer endpoint, in all eight cells.** Cookie-authorized; additionally requires the `enrolled` relation on `proctoring_session:<activity>` (authorization, media-independent) and `locked_at IS NULL`. Freezes `policy_snapshot`, mints a `session_id` ULID, issues the first bearer, and mints the off-mode re-entry token. Carries a client `idempotency_key`. On an existing non-locked row with **no attached socket**, treats the call as a first attach (re-mints after a crash). With an attached socket and the **same** `idempotency_key`, returns the same already-issued bearer (true network retry). With an attached socket and a **differing** `idempotency_key`, returns `409 session_active` with a minimal body `{reason, hint: "use /resume to take over"}` — no bearer, no `policy_snapshot`, no `session_id`. Returns `next: register` (`device_proof=on`) or `next: ready` (`device_proof=off`).
- `POST /v1/proctoring/sessions/resume` — **`device_proof=off` reconnect.** Authorized by the proctoring re-entry token (not the raw cookie) + `enrolled` + `locked_at IS NULL`. Rotates `session_id` (after WS attach completes) — which invalidates the prior bearer — issues a fresh bearer, and re-mints the re-entry token. Admission, verification, and `policy_snapshot` persist.
- `GET /v1/proctoring/sessions/me` — **bearer-only**; returns only the caller's own row `{admission_state, verification summary, policy_snapshot, room_ready, content_released_at?}`. No target `user_id`.
- `GET /v1/proctoring/sessions/challenges` — **`device_proof=on` only.** Single-use, short-lived (≤ 60 s) WebAuthn challenge bound to `(user_id, activity_id)`. Authorized by the **pending bearer** (which already exists by this point); called before `/register` and before `/authenticate`. Reuse returns `410 Gone`. `409 device_proof_disabled` under `off`.
- `POST /v1/proctoring/sessions/register` — **`device_proof=on` only.** Authorized by the pending bearer under the capability gate. Consumes a registration challenge, binds `credential_id`, clears `device_proof_pending`, and rotates a fresh bearer carrying `cnf == credential_id` on the same `session_id`. `409 device_proof_disabled` under `off`.
- `POST /v1/proctoring/sessions/authenticate` — **`device_proof=on` only.** Consumes an assertion challenge, verifies the assertion against the stored `credential_id`, rotates `session_id`, and issues a fresh bearer. `409 device_proof_disabled` under `off`.
- `POST /v1/proctoring/sessions/captures` — **`identity_verification=enforced` only.** Mutating; requires the socket be bearer-attached (`409 needs_attach` otherwise). Uploads ID photo and face snapshot; streamed to object storage. `409 verification_disabled` under `disabled`.
- `WSS /v1/proctoring/sessions/stream` — the bidirectional control channel. First connect is **cookie-authorized (pre-bearer)** in both modes; the client then sends an `attach` hello carrying the freshly-minted bearer, the extension runs the **full validation invariant** against it, and only on success binds the socket to the `session_id`.
- `GET /v1/proctoring/sessions/:user_id/captures/:kind` — **`identity_verification=enforced` only.** Extension-streamed plaintext capture for invigilators with `can_proctor`. Decryption inside the extension (see R2 Encryption); signed URLs are not used.
- `IsAdmitted(user_id, activity_id) -> {admitted, admission_epoch, basis, policy_snapshot}` — **internal** NATS request-reply (+ equivalent internal HTTP), answered from the durable session row. The core-driven content-release pull (see Coordinating with the examination extension); **requires core/RFD 0009-owner ratification** of the subject, timeout, and fail-closed semantics. Not a public client endpoint.

LiveKit room and token routes from RFD 0011 are exercised **only when `live_media=on`**. `POST /v1/proctoring/rooms/:name/tokens` keeps RFD 0011's relation dispatch and grants table; on the **student branch only** it gains three extension-owned, non-authorization preconditions: `policy_snapshot.live_media == on` (frozen snapshot, else `409 media_disabled`), `admission_state in {admitted, physically_verified}` (else `403`), and `room_ready == true` (else `409 media_not_ready`). The invigilator (`can_proctor`) branch is unchanged from RFD 0011 — invigilators have no session row and are never gated on admission. `POST /v1/proctoring/rooms` gains a policy precondition: it rejects with `409 media_disabled` when the activity's **live** resolved policy has `live_media=off`, so no LiveKit object can exist on a media-off activity. These token-route and room-create changes are **normative RFD 0011 edits requiring the RFD 0011 owner's ratification**. Admission and content **never** depend on a LiveKit token in any cell.

LiveKit room and token routes from RFD 0011 are otherwise unchanged, but under an `enforced` verification policy the token route gains one precondition: the caller's session must be `admitted` or `physically_verified` (see R2 and the Authorization Model). Under a `disabled` policy the token route behaves exactly as in RFD 0011.

## Device Binding (R1)

Device binding is governed by the `device_proof` knob. The two paths share the same session/bearer/WS/HTTP machinery; only the create-authorizer, the reconnect-authorizer, and the presence of `credential_id` differ.

### `device_proof=off` — no device binding

When `device_proof=off` there is **no device proof at all**, and no alternative binding mechanism is substituted (see Deferred). Session **creation** is authorized by the student's normal authenticated session cookie — the same authorizer the current design already trusts for the pre-bearer WS connect and the challenge endpoint, here promoted from "authorizes the connect" to "authorizes the first bearer" — together with the `enrolled` relation on `proctoring_session:<activity>` (authorization) and `locked_at IS NULL`. There is no application-level source-IP allowlist; **closed-intranet isolation is the only network control**. `POST /v1/proctoring/sessions` returns `next: ready`; there is no capability probe, no challenge, no passkey, and `credential_id` is permanently NULL. **Reconnect** is authorized by a proctoring-issued **re-entry token** (extension-signed, lifetime `== collection.stop_at + margin`, single-active, revocable via `locked_at`, stored `httpOnly`+`SameSite`) via `POST /v1/proctoring/sessions/resume` — not the raw IdP cookie, whose absolute TTL the extension cannot reliably read. A new `/resume` rotates `session_id` and thereby invalidates the prior bearer, so only one active session exists at a time. The bearer's identity binding is `(user_id, activity_id, session_id)`; there is no `cnf` claim and no proof-of-possession on any request — bearer secrecy is the only control, bounded by the 10-minute TTL, the intranet, and physical invigilation (see Known Limitations).

### `device_proof=on` — platform-authenticator passkey

When `device_proof=on`, the device credential is a **platform-authenticator passkey** created via WebAuthn:

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

Under `device_proof=on`, `POST /v1/proctoring/sessions` still issues the first bearer (machinery byte-identical to the off path) but creates the row in `admission_state = pending_device_proof` and returns `next: register`. The **pending bearer** carries the claim `device_proof_pending=true` and no `cnf`; it is capability-gated to exactly WS attach/heartbeat and the register-upgrade calls (`GET /challenges`, `POST /register`). The client runs the capability probe (below), obtains a challenge, and POSTs the registration to `/v1/proctoring/sessions/register`, which **upgrades** the row: it stores `credential_id`, clears `device_proof_pending`, and rotates a fresh bearer carrying `cnf == credential_id` on the same `session_id`. `admitted` is unreachable while `credential_id IS NULL` (enforced in the validation helper, not prose). Subsequent assertions against the same `(user, activity)` must present this credential id. Cancelling registration leaves the session `pending_device_proof`; the only escape is an audited staff **re-enroll** (still `device_proof=on`) or an audited activity-policy loosen to `device_proof=off` followed by re-enroll — never a silent per-student downgrade. Identity verification (R2) follows satisfaction of the device-proof precondition and does not itself depend on `credential_id`.

### Lab-environment prerequisite (hard blocker, `device_proof=on` only)

This prerequisite applies **only when `device_proof=on`**. Platform-authenticator passkeys require a functioning platform authenticator on the exam machine; machines without one **cannot be used to take a `device_proof=on` exam**. There is no software fallback in the shipped product.

Under `device_proof=on`, pre-exam onboarding performs a capability probe (`PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()`) and hard-fails before the student reaches passkey registration if no platform authenticator is available. Lab-ops is responsible for guaranteeing coverage across the fleet; a survey of platform-authenticator availability across the target labs is a prerequisite before any `device_proof=on` activity moves to `published`. Under `device_proof=off` there is no probe and no platform-authenticator requirement; the corresponding deployment precondition is instead trustworthy closed-intranet isolation (see Known Limitations).

### Session bearer and rotation

The bearer substrate is identical across all eight cells: an extension-signed JWT, ≤ 10 min TTL, rotated ~8 min via the `bearer_refresh` WS frame, presented as the WS attach bearer and on any extension HTTP call. The **subject** is `(user_id, activity_id, session_id)` in both modes, where `session_id` is a server-assigned ULID on the row. `credential_id` appears as an **optional `cnf` claim**, present iff `device_proof=on`. When `device_proof=on`, the passkey is not used to sign per-request or per-frame traffic and assertions are invoked only for reconnect, so user-verification prompts are rare by construction. When `device_proof=off`, there is **no proof-of-possession on any request**; the `session_id` pin is single-active-session hygiene only, never a continuity or replay control.

**Bearer validation invariant.** One shared helper runs on every bearer-authenticated request (WS frame, HTTP call, the student-branch token-route gate), reading the row for `(user_id, activity_id)` and evaluating clauses in this fixed order:

- **(a) Lock.** `locked_at IS NULL`, else `401` regardless of bearer freshness. Policy-independent; holds with `credential_id` NULL. This closes the up-to-10-minute window where a force-submitted student's existing bearer would otherwise remain valid.
- **(b) Session pin.** `bearer.session_id == row.current_session_id`, else `401` (single-active-session). A `/resume` that rotates `session_id` thereby invalidates the prior bearer.
- **(d) Pending-device-proof gate, evaluated before (c).** If `admission_state == pending_device_proof`, the bearer must carry `device_proof_pending=true` and is accepted only for WS attach/heartbeat and the register-upgrade calls; all other scopes `401`.
- **(c) cnf-per-frozen-policy, only when not pending.** If `policy_snapshot.device_proof == on` AND `admission_state != pending_device_proof`, require `cnf` present and `cnf == row.credential_id` (absent/mismatch → `401`). If `== off`, require `cnf` **absent** (present → `401`). The pending bearer (no `cnf`) is therefore never rejected by (c); (d) admits it, and (c) engages only after `/register` binds `credential_id`. A token cannot self-select the weaker validation path.
- **(e) Authz freshness — fail-open, never locks.** A short-TTL cached `enrolled` check (≤ 30 s) read alongside the row. This clause **never** rejects the request and never mutates state: if the authz read errors, times out, or returns a definitive `enrolled` absence, the request still passes and the extension writes an audit entry. Mid-exam `enrolled` revocation is therefore **not acted on in-band** — the existing bearer (and any LiveKit token) remains valid until TTL expiry; this is the accepted RFD 0011 TTL-window limitation (see Known Limitations), deliberately not closed here.

Rotation is a pure server re-sign under the row lock (compare-and-set on `session_id`, re-reading `locked_at IS NULL` at the same lock) so it can never emit a stale-`session_id` or born-dead bearer even under a concurrent `/resume`. Co-currency is **not** claimed as a bearer-theft bound: a mutating call is correlated with the attached socket for audit/eviction coherence only. The enumerated mutating set is `{captures}`; `/sessions`, `/resume`, `/challenges`, `/register` are bootstrap (exempt); the token route is non-mutating (exempt). A reconnecting client that must mutate before attach gets `409 needs_attach`. The real bearer-theft bound is TTL + intranet + invigilation + audit.

### Re-establishment on reconnect

Session loss events — browser close, tab crash, machine reboot, network flap long enough to kill the TCP connection — are handled without invigilator involvement. The reconnect authorizer differs by mode; both paths enforce `RequireUnlockedSession` (`locked_at IS NULL`) FIRST under the row lock (a `401`'d client cannot re-mint past a terminal lock), and both rotate `session_id` only **after** WS attach completes (a fast reconnect cannot evict a still-live socket) and re-read `locked_at` at the rotation compare-and-set.

- **`device_proof=on`:** cookie-authorized WS reconnect, then `GET /sessions/challenges` + `POST /sessions/authenticate` consuming an assertion verified against the stored `credential_id`; on success a fresh bearer issues and `session_id` rotates. The passkey assertion is the reconnect authorizer.
- **`device_proof=off`:** `POST /v1/proctoring/sessions/resume`, authorized by the proctoring re-entry token (not the raw IdP cookie) + `enrolled` + `locked_at IS NULL`; rotates `session_id`, issues a fresh bearer, and re-mints the re-entry token.

Admission, verification, and `policy_snapshot` persist across the reconnect. Because both paths rotate `session_id`, the single-active-session pin is universal: a new `/resume` (or `/authenticate`) **invalidates the prior bearer**, so at most one bearer is live at a time. The pin is **hygiene, not a replay control**: it makes a cookie/re-entry-token replayer's takeover visible — the displaced socket is dropped and the eviction is written to the audit log — but it does not detect a co-current stolen **bearer**. Read-only takeover is closed at the source: `POST /sessions` refuses to hand a second client a co-current bearer on a live attached socket (`409 session_active`, minimal body), so the only way to ride a victim's session is `/resume`, which invalidates the incumbent bearer and is recorded in the normal audit log. There is no alerting or escalation machinery beyond that audit record.

The only way the student loses access mid-exam is an invigilator-issued `force_submit` (terminal, via `locked_at`).

### Cross-device sync (`device_proof=on` only)

This concern exists **only when `device_proof=on`**. iCloud Keychain and Google Password Manager sync passkeys across a user's devices by default. This is not exploitable in our threat model because the exam origin is reachable only from the closed lab intranet — a synced passkey on a student's phone on mobile or home Wi-Fi cannot reach the exam host. The intranet isolation established in RFD 0011 is what makes the cross-device sync property tolerable; without it, this would be a hole. Under `device_proof=off` there is no passkey to sync; the analogous secret is the session cookie (at create) and the re-entry token (for the window), whose replay is bounded by the same closed-intranet isolation plus the single-active re-entry token (a new `/resume` invalidates the prior bearer) and physical invigilation (see Known Limitations).

## Identity Verification (R2)

Identity verification has two independently-set properties: **whether it runs** — a per-activity policy, so it can be turned off entirely — and **when the verdict lands**, which is asynchronously, during the exam. Under the default `enforced` policy, completing the webcam captures is a **precondition for entering the exam**; the asynchrony is in the invigilator's *verdict* — reached at any point in the exam window — not in the *capture*, which happens up front. A deployment that verifies students by other means (a physical ID check at the lab door) sets the policy to `disabled`, and the capture step disappears.

Gating entry on capture submission removes the "just never upload" loophole without reintroducing a synchronous review bottleneck: the capture step is **automated by the client** (live preview → freeze → upload) and needs no invigilator in the loop, so entry is gated on an automatic upload completing, not on a human decision. The invigilator's judgement is still applied asynchronously — against the captured stills plus the live camera — and a failed verification leads to disqualification regardless of when it is noticed. There is thus no authorization decision to pre-compute, only an evidence-gathering and audit obligation.

### The `identity_verification` knob

Identity verification is the `identity_verification` knob of the unified `proctoring_policy`, carried per activity (equivalently per `submission_collection`) and resolved behind the one `ProctoringPolicy` interface that supersedes the former `VerificationPolicy`. Its value is read from the **frozen** `policy_snapshot` on the session row at every per-session gate:

- **`enforced`** — the student must upload both captures, or be manually admitted (below), to reach `admitted`/`physically_verified`. Captures are reviewed asynchronously.
- **`disabled`** — no captures are requested, no review queue is populated, and admission is reached as soon as the device-proof precondition (if any) is satisfied. For deployments that verify identity physically.

The enum is deliberately open to extension (a future `optional` mode that captures but does not gate). This knob scopes only the verification layer; `device_proof` and `live_media` are orthogonal. Crucially, admission is gated on the **admitted state**, not on "the client obtained a LiveKit token" — content releases via the core `IsAdmitted` pull (see Coordinating with the examination extension) in every cell, and the LiveKit token is a pure media-plane artifact consumed only when `live_media=on`. The former wording "entry is gated on passkey registration (R1) alone" is replaced: under `device_proof=off + identity_verification=disabled` the gate is the admitted state reached at session create and released to a **live attached session** (see Lifecycle). Under `disabled`, none of the capture endpoints, object-storage paths, or review frames in this section are exercised.

### Capture flow (policy `enforced`)

Once the device-proof precondition is satisfied (immediately when `device_proof=off`; after `/register` when `device_proof=on`) and before the session reaches `admitted`, the client auto-prompts the student for two captures:

1. **ID photo.** The client prompts the student to hold their physical student / national ID up to the webcam. Live preview, student clicks *Capture* to freeze a still frame. Client-side downsized and JPEG-encoded at ~85% quality; target payload ~150 KB.
2. **Face snapshot.** Same preview, no ID. A separate still frame of the student's face.

Both images are POSTed to `POST /v1/proctoring/sessions/captures` (which requires the socket be bearer-attached, returning `409 needs_attach` otherwise). The extension streams each upload straight to the object store, records pointers in its session state (`(user, activity) → (id_photo_key, face_key, uploaded_at)`), advances `admission_state` to `admitted` (with `basis = captures`), and emits a `capture_uploaded` frame to invigilator sessions for the activity so their review queue refreshes. `admitted` (or `physically_verified`) is the **single first-class fact** every consumer keys off: it makes the core `IsAdmitted` pull return true (content release, all cells) and, when `live_media=on` AND `room_ready`, satisfies the student-branch token precondition (media). Under `identity_verification=enforced` a student still `awaiting_capture` is not admitted, so `IsAdmitted` returns false and — when `live_media=on` — `POST /v1/proctoring/rooms/:name/tokens` rejects the student branch.

Upload failure is surfaced to the student as a retryable error. Because capture gates entry, a student who genuinely cannot capture — no working webcam, ID left at home, persistent upload failure — is not left stuck behind a software wall: the invigilator admits them through the manual gate below. There is no capture deadline and no automatic "uploads missing" timer; a human makes the call when capture does not happen.

### Manual admission gate

The capture requirement has a human override. An invigilator with `can_proctor` on the room admits a specific student who has not captured — checked physically at the lab, or webcam broken. The invigilator issues a `manual_admit` frame over the control WS with a **required** free-text reason; the extension records the decision (invigilator identity, reason, timestamp) in the audit log, sets the student's admission state to `physically_verified`, and the student may then obtain a LiveKit token exactly as an `admitted` student would.

A `physically_verified` student is **exempt from capture and from the review queue** — there is nothing to review, and the audited manual-admit record is the verification artefact. This is the only escape hatch from the capture gate: there is no automatic admission and no deadline-based fallback, so admitting a student without a capture is always an accountable human decision.

### Invigilator review

Invigilators see a review queue keyed on the **stable** `(user_id, activity_id)` (never `session_id`, so a reconnect's `session_id` rotation never detaches an open review entry), alongside the per-student spot-check surface from RFD 0011. The review surface degrades cleanly with the `live_media` knob, which the client reads from `policy_snapshot.live_media` carried in `session_state`:

- **`live_media=on`:** opening a queue entry auto-subscribes to the student's LiveKit camera publication via `setSubscribed(true) + setVideoQuality(HIGH)`, rendering a three-up layout — **captured ID photo | captured face snapshot | live camera** — so the decision is informed by the person currently at the machine. The surface auto-unsubscribes on close to honor RFD 0011's idle-is-signalling-only Dynacast property. If the student's camera is not currently published (not yet joined LiveKit, reconnecting), the live tile shows a placeholder and the invigilator may defer or decide on the stills alone.
- **`live_media=off`:** there is no LiveKit publication; the client never calls `setSubscribed` and renders a **stills-only two-up** layout — **captured ID photo | captured face snapshot**. Because a substituted still cannot be cross-checked against a live face, a **terminal disqualify requires an invigilator in-person confirmation** reason; `mark_suspicious` remains freely available.

Outcomes:

- **Mark verified.** Records the decision in the audit log and clears the student from the queue. No effect on the student's exam state.
- **Flag suspicious.** The non-destructive escalation, and the expected first response to a doubtful match. It does **not** end the student's exam: the extension records the flag (invigilator identity, reason), holds the student's captures (moving them to the `held/` prefix so they outlive the normal lifecycle), and surfaces the entry as `suspicious` for a second reviewer or a post-exam decision. It is **silent to the student** — no client frame — so a possibly-innocent student is neither tipped off nor disrupted. A suspicious flag is reversible (back to `verified` or `unreviewed`, releasing the hold); disqualification is not. This is the guard against false positives: doubt is recorded and the evidence preserved without irreversibly ending an exam.
- **Disqualify.** The deliberate terminal action. Issues a `force_submit` with reason `identity_verification_failed` (plus optional free-text note); the examination extension locks the student's exam (see R4). Because it is irreversible, the invigilator UI requires an explicit confirmation, and the recommended workflow is to flag suspicious first and disqualify only on a confirmed second look. Audited as usual.
- **Request re-capture.** Issues a `reverify_required` frame: the student's client surfaces the capture flow again, overwriting the previous captures. Used when a capture is obscured, wrong ID, etc. The original captures are retained in object storage for audit (never mutated) under a `superseded/` prefix.
- **Defer.** Leaves the queue entry open. Intended as a "come back to this" — the entry remains visible until exam stop.

There is no ML face matching and no automatic disqualification: every terminal decision is a human one. The photos and live camera are evidence; the invigilator's judgement — expressed conservatively through the suspicious-then-disqualify path — is the decision.

### Object storage

Captured images are stored in a dedicated object-store bucket, separate from academic artefacts:

- **Bucket**: `proctoring-captures` (or equivalent per deployment). Public access blocked at the bucket-policy level. Bucket-level encryption (SSE-S3 / SSE-KMS) is permitted as defense in depth but **is not load-bearing** — confidentiality is provided by application-level envelope encryption (see Encryption below). The design must be portable across object stores that do not offer equivalent server-side features.
- **Key layout**:
  ```
  {activity_id}/{user_id}/{capture_kind}-{capture_id}.jpg
  {activity_id}/{user_id}/superseded/{capture_kind}-{capture_id}.jpg   (after re-capture)
  {activity_id}/{user_id}/held/{capture_kind}-{capture_id}.jpg          (suspicious-flag or hold-for-dispute)
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
| `{activity_id}/{user_id}/held/*.jpg`       | **No lifecycle rule**                   | Suspicious-flag evidence or explicit investigative hold; deleted by manual process / on resolution |

A "hold" action — triggered either by an explicit investigative hold or by a **flag-suspicious** review outcome — operates at the **`(activity_id, user_id)` prefix level**, not per-object: on hold, the extension enumerates all captures under the user's prefix — including current, `superseded/`, and any other descendants — and moves each into `held/`. This ensures that evidence of a re-captured-and-replaced first submission (the common misconduct shape) is preserved, not silently deleted by the default lifecycle rule. Holds expire on explicit release (which moves objects back to their prior prefix, re-applying lifecycle) — there is no automatic expiry on holds, because investigations run on their own timelines. Each hold and release is audited with reason and owning case id.

**Why 30 days, not 90**: the original 90-day window was sized for institutional appeals. With async verification, the appeal window isn't blocked on review completion — reviews are finished during the exam itself, and post-exam disputes are against the *decision*, not the captures. 30 days is sufficient to cover the common review-and-dispute cycle; longer investigations use the explicit hold.

**Why object-store lifecycle, not an extension sweep**: lifecycle rules are declarative, provider-enforced, and survive extension outages. An extension-managed sweep would duplicate the guarantee less reliably. The extension's role is limited to (a) uploading under the right prefix, (b) moving to `held/` on hold-action, (c) moving back to the default prefix on release — all synchronous, no background jobs. Deletion is entirely the object store's responsibility.

**Access logging**: every capture read (caller, subject, capture kind, `kek_version`, decrypt outcome) and every hold/release action is written to the extension's audit stream.

**Logging discipline**: the extension must never log image bytes, plaintext DEKs, KEK material, or bucket keys to any standard log sink. The audit stream is the only record.

**Deletion on student request** during the retention window is not supported — retention is bounded by exam administration policy, not student preference. Documented as a trade-off.

## Control Channel (R4)

### Transport

A single WebSocket per client session, mounted at `WSS /v1/proctoring/sessions/stream`. The **first connect is cookie-authorized (pre-bearer)** in both `device_proof` modes — before any bearer exists, the same way the current design's pre-registration connect is cookie-authorized — and the extension binds `(socket_conn_id → (user, activity))` on cookie auth. The client then mints its first bearer via `POST /v1/proctoring/sessions` (or `/resume` on reconnect) and sends an `attach` hello carrying that bearer; the extension runs the **full validation invariant** (clauses (a)–(e), including `bearer.session_id == row.current_session_id`) against it and only on success binds `(socket_conn_id → session_id)` and marks the socket bearer-attached. A cookie-authorized socket with no successful attach within N seconds is reaped. Steady-state authentication thereafter uses the session bearer; the socket is bidirectional — clients send, the extension sends, both over the same framing. When both a cookie and a bearer are presented, the bearer is authoritative and `cookie-subject == bearer-subject` is required (mismatch → `401` + audit).

**LiveKit data channels are not used for control.** RFD 0011's `CanPublishData: false` grant on both students and invigilators is preserved to reinforce the invariant that every control message is audited by passing through the extension. Using the LiveKit data plane would either bypass the audit trail or require the extension to double-record events already delivered by the SFU.

### Frame schema

Every frame is a JSON object with a `type` discriminator and a `seq` for ordering. Server-originated frames carry `server_seq`; client-originated frames carry `client_seq`. The extension echoes applied frames with a `server_seq` to allow idempotent reconnect.

Every frame carries an `applies when` constraint so no frame can be emitted in a cell where it has no meaning (constraint D). Frames in scope for this RFD:

| Direction           | Type                   | Applies when      | Purpose                                                                      |
|---------------------|------------------------|-------------------|------------------------------------------------------------------------------|
| client → extension  | `attach`               | all cells         | WS hello carrying the freshly-minted bearer; binds socket→`session_id` only after the full validation invariant passes |
| extension → client  | `bearer_refresh`       | all cells         | Push a new session bearer before the current one expires                     |
| extension → student | `session_status`       | all cells         | Caller's `admission_state` / `policy_snapshot` / `room_ready`, so the client never infers entry from a token |
| extension → student | `announcement`         | all cells         | Text broadcast from invigilator; `scope: room`, `room_id`                    |
| extension → student | `private_message`      | all cells         | Invigilator reply to this student's raise-hand                               |
| extension → student | `force_submit`         | all cells         | Instruct the exam client to submit and lock (carries a `reason`)             |
| student → extension | `raise_hand`           | all cells         | Student requests clarification; body carries a short text                    |
| student → extension | `ack`                  | all cells         | Acknowledge a server frame by `server_seq` (delivery confirmation)           |
| extension → invig.  | `session_state`        | all cells         | Per-student admission state / verification status / presence / raise-hand state for the review queue|
| extension → invig.  | `session_snapshot`     | all cells         | Reconciliation frame on invigilator reconnect: last-applied `decision_id` per student |
| invig. → extension  | `announce`             | all cells         | Compose-and-send an announcement to a room                                   |
| invig. → extension  | `private_reply`        | all cells         | Reply to a specific student's raise-hand                                     |
| invig. → extension  | `force_submit`         | all cells         | Trigger force-submit for a specific student (with `reason`, incl. `identity_verification_failed`) |
| extension → student | `reverify_required`    | `identity_verification=enforced` | Request a fresh ID + face capture; client re-opens the capture flow |
| extension → invig.  | `capture_uploaded`     | `identity_verification=enforced` | A new capture pair is available for review                  |
| invig. → extension  | `mark_verified`        | `identity_verification=enforced` | Record a successful verification (no client-visible effect) |
| invig. → extension  | `mark_suspicious`      | `identity_verification=enforced` | Flag an entry as suspicious (non-terminal); holds captures, no client frame |
| invig. → extension  | `manual_admit`         | `identity_verification=enforced` | Admit a student who has not captured (physical verification); requires a reason |
| invig. → extension  | `force_reverify`       | `identity_verification=enforced` | Request a fresh capture from the student                    |
| invig. → extension  | `capture_hold`         | `identity_verification=enforced` | Move a specific capture to the `held/` prefix for ongoing investigation |
| invig. → extension  | `capture_hold_release` | `identity_verification=enforced` | Release a hold and restore normal lifecycle retention       |

The live-camera three-up subscription in invigilator review is a **`live_media=on`-only** behaviour; under `live_media=off` the review surface degrades to stills-only (the client reads `policy_snapshot.live_media` from `session_state` and never calls `setSubscribed`). `attach`, `bearer_refresh`, `force_submit`, `announcement`/`announce`, `private_message`/`private_reply`, `raise_hand`, `ack`, `session_state`, `session_snapshot`, `session_status`, and `session_ended` are universal across all eight cells. Single-active-session eviction is not its own frame: a displaced socket is simply dropped and the eviction is recorded in the audit log.

Disqualification is not its own frame type — it is a `force_submit` with `reason: identity_verification_failed`. This keeps lock-and-terminate semantics in one place and reuses the audit + coordination path with the examination extension. `mark_suspicious` is the non-terminal alternative — it records doubt and holds the evidence without ending the exam, and is the expected first action before any disqualification. `force_reverify` is retained for the "capture is unclear, please redo" case where the invigilator wants a cleaner capture rather than a disqualification.

### Auditing

The extension persists every invigilator-authored frame and every admission decision to a durable audit log before emitting the corresponding client frame. This includes the full text of announcements and private replies, the subject and reason of force-submit / force-reverify, and the invigilator identity. The audit record is the canonical record, not any frame the client saw; discrepancies between what the client received and what was audited are discarded in favour of the audit.

Student-authored frames (`raise_hand`, `ack`) are also audited. Acknowledgements are not stored verbatim; the highest acknowledged `server_seq` per session is retained.

### Coordinating with the examination extension

`examination` is an **activity type in core** (per RFD 0009), not a sibling extension, and RFD 0009 keeps core as the orchestrator: core publishes `activity.started` upstream and proctoring follows. Two coordination contracts live here, both consistent with that direction; both reach into core and **require the core/RFD 0009 owner's ratification** (subject names, timeout, fail-closed semantics).

**Content release — core-driven pull (requires core-owner sign-off).** Proctoring exposes the admitted fact as an extension-owned, queryable resource: a synchronous request-reply `IsAdmitted(user_id, activity_id) → {admitted, admission_epoch, basis, policy_snapshot}` over NATS (and an equivalent internal HTTP), answered from the durable session row (LEVEL, not edge; idempotent on re-query). Core, on its **own** exam-content path for a proctored activity, calls `IsAdmitted` as a precondition before serving questions and **fails closed** when not admitted, re-checking on a heartbeat. This is a small read-dependency core adds, **not** a control-flow inversion and **not** a durable subscriber: core stays the orchestrator, proctoring owns the gated fact. This makes the entry gate extension-owned (constraint C) in **every** cell — the LiveKit token has no content-gating role in any cell. Core latches on the stable `(user_id, activity_id)`, never the rotating `session_id`; a monotonic `admission_epoch` orders re-admits, and a `basis` change within an already-admitted row does not bump `admission_epoch`. An advisory `proctoring.session.admitted {user_id, activity_id, exam_id, admission_epoch, basis, policy_snapshot, ts}` is also published as telemetry so core can pull promptly, but correctness rests on the pull, so a lost/duplicated advisory cannot leak or wrongly gate content.

**Terminal signal — one subject, structured action.** A single NATS subject `proctoring.session.revoked {user_id, activity_id, exam_id, action, reason, terminal_seq, ts}` replaces the former `proctoring.force_submit`, where `action` is a **closed set** `{submit_and_lock | content_pull_only}` and `reason` is human-readable audit metadata (`invigilator_force_submit`, `identity_verification_failed`, `session_terminated`, `idle_expiry`, …). Core switches on `action`: `submit_and_lock` runs submit-and-lock (preserving saved answers — submit-and-lock, not discard-and-lock) AND content-pull; `content_pull_only` runs content-pull only. An unknown/missing `action` defaults to `content_pull_only` + alert; `terminal_seq` dedups. Force-submit therefore proceeds as: (1) invigilator sends `force_submit` over their WS; (2) extension audits, sets `locked_at` locally (so the bearer `401`s immediately), then publishes `proctoring.session.revoked` with `action: submit_and_lock`; (3) core submit-and-locks and (its content path) stops serving; (4) proctoring sends `force_submit` to the student's WS so the client UI reflects the lock. Delivery is at-least-once; a revoke that cannot be delivered still locks locally via `locked_at` and is caught by core's next `IsAdmitted` heartbeat returning not-admitted, so the row is source of truth and a redelivery cannot split disqualify vs benign-revoke semantics. Defining the exact semantics of "submit" remains the examination activity's responsibility; this RFD guarantees delivery, the audit trail, and the fail-closed pull gate.

## Authorization Model

RFD 0011 introduced `proctoring_room` with `parent: activity`, `student: user`, and `can_proctor = can_edit from parent`, and deliberately did **not** anchor membership on `examinee` ("can read the questions, not is in this exam session"). This RFD adds **one** new first-class OpenFGA type, symmetric with how RFD 0011 introduced `proctoring_room`, to anchor session creation in a media-independent way:

```
type proctoring_session
  relations
    define parent: [activity]
    define enrolled: [user]            # "is registered to sit this proctored activity" — distinct from examination#examinee
    define can_proctor: can_edit from parent
```

`enrolled@proctoring_session:<activity>#user:<pid>` is written at an explicit, **media-independent** "Enroll for proctoring" staff action (or transactionally from the `submission_collection` participant set when proctoring is configured on the activity), kept in sync on roster mutation via the same write path, and read at OpenFGA default consistency. It exists in **every** cell, including `live_media=off` where no room is ever created. The RFD 0011 `student@proctoring_room` tuple is **demoted to media-plane membership** consumed only by the `live_media=on` token route; when a room is created, RFD 0011 derives its per-room `student` tuples from this same `enrolled` set. Amending RFD 0011's "`student` is the single source of truth for room membership" to this two-plane model (`enrolled` = session/content, `student` = media), and deriving `student` from `enrolled` at room creation, are **normative RFD 0011 edits requiring the RFD 0011 owner's ratification**. `enrolled` is **authorization**; `credential_id` was always **continuity**, deliberately forgone under `device_proof=off`.

The unified `proctoring_policy` (`device_proof`, `live_media`, `identity_verification`) lives per `submission_collection` in the proctoring extension's Postgres, resolved behind the `ProctoringPolicy` interface that supersedes `VerificationPolicy`. There are exactly **two** resolution points and they never cross: (1) the **live** activity policy is read only at room-creation / "Enroll" time (gating whether a LiveKit room may be created and writing the enrollment relation); (2) a **frozen `policy_snapshot`** resolved once at session create drives **every** per-session gate (token precondition, `IsAdmitted` answer, frame applicability, validation). Freezing prevents a mid-exam policy edit from moving a live session between cells; the only sanctioned per-session transition is an audited, loosen-only, reason-required staff re-enroll.

The extension maintains the session table alongside the RFD 0011 cache sidecar, keyed on `(user_id, activity_id)`:

- `session_id` — server-assigned ULID; the bearer's third subject component and the single-active-session pin.
- `credential_id` — the passkey credential id; non-null **iff** `device_proof=on`, NULL otherwise.
- `policy_snapshot` — the three knobs frozen at create (jsonb).
- `admission_state` — `pending_device_proof` (`device_proof=on`, credential not yet bound) → `awaiting_capture` (`identity_verification=enforced`) → `admitted` | `physically_verified`; `locked` (terminal). `admitted` is unreachable while `device_proof=on` AND `credential_id IS NULL`.
- `basis` — `auto | captures | manual`, disambiguating the three in-edges of `admitted` for audit; capture-presence is never a proxy for policy/basis.
- `admission_epoch` — monotonic; orders re-admits, bumped on `awaiting → admitted/physically_verified`, not on `basis` refinement.
- `captures` — per-kind pointers (`id`, `face`), each with `uploaded_at` and a verification outcome (`unreviewed` / `verified` / `suspicious` / `superseded` / `held`). Absent (not empty) under `identity_verification=disabled` and for `physically_verified` students.
- `locked_at` — set on force-submit / staff-terminate, with reason. Terminal. The kill-switch enforced by validation clause (a), policy-independent, holding with `credential_id` NULL.

The entry gate targets the **admission_state**, not a LiveKit token. `IsAdmitted` returns true iff `admission_state in {admitted, physically_verified}`, in every cell. The token route (`POST /v1/proctoring/rooms/:name/tokens`) retains RFD 0011's relation dispatch and grants; on the **student branch only** it gains, under `live_media=on`, the preconditions `policy_snapshot.live_media == on` (frozen) + `admission_state in {admitted, physically_verified}` + `room_ready == true`. The invigilator (`can_proctor`) branch is unchanged from RFD 0011 — invigilators have no session row and are never gated on admission. These student-branch token-route preconditions are **new** machinery vs RFD 0011 (which has no admission gate today) and **require the RFD 0011 owner's ratification**. Existing `can_proctor`/`can_edit` inheritance, invigilator-WS per-call authorization, and extension-mediated capture reads are unchanged.

Existing authorization checks are unchanged. `can_proctor` continues to inherit from `can_edit` on the parent activity. Invigilator WS actions are authorized per-call against `can_proctor` on the target room. Capture reads (`GET /v1/proctoring/sessions/:user_id/captures/:kind`) are authorized per-call against `can_proctor` on the room containing the capture's subject user; reads are extension-mediated and decrypted in-process, not served via signed URLs.

## End-to-End Lifecycle

1. **Sign-in.** Student signs in to `ui-v2` as usual. Client navigates to `/activities/:id/proctored`.
2. **Capability probe (`device_proof=on` only).** Client calls `PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()`. No → hard fail screen, exam not takeable on this machine. Yes → proceed. **Skipped entirely when `device_proof=off`.**
3. **Establish session (pre-bearer).** Client opens `WSS /v1/proctoring/sessions/stream` with the user's normal session cookie; the extension binds the socket to `(user, activity)` on cookie auth.
4. **Create session + first bearer (all cells).** Client calls `POST /v1/proctoring/sessions` (cookie + `enrolled` + `locked_at IS NULL`). Extension freezes `policy_snapshot`, mints `session_id`, issues the first bearer, mints the off-mode re-entry token, and returns `next`. Client sends the `attach` hello; the extension runs the full validation invariant before binding the socket to `session_id`.
   - `device_proof=on` → `next: register`; row is `pending_device_proof`. Client runs the capability probe, obtains a challenge, and POSTs to `/v1/proctoring/sessions/register`, which binds `credential_id`, clears `device_proof_pending`, and rotates a fresh `cnf`-bearing bearer. Then proceeds by `identity_verification`.
   - `device_proof=off` → `next: ready`; `credential_id` stays NULL.
   - `identity_verification=disabled` → resolves to `admitted` (`basis = auto`). In `{off, off, disabled}` the admit is set as **admitted-intent** at mint and `IsAdmitted` returns true only **after** the `attach` completes, so content never releases to a never-attached session.
   - `identity_verification=enforced` → `awaiting_capture`.
5. **Identity captures (`identity_verification=enforced`).** Client auto-prompts for ID photo and face snapshot. Student completes both; client POSTs to `/v1/proctoring/sessions/captures` (socket must be attached). Extension streams each to object storage, advances the session to `admitted` (`basis = captures`), and emits `capture_uploaded`. A student who cannot capture is instead admitted by an invigilator via `manual_admit` → `physically_verified` (`basis = manual`; see step 11).
6. **Content release + optional media.** Core, on its own exam-content path, calls `IsAdmitted` (a contract requiring core-owner ratification) and serves questions once the session is `admitted`/`physically_verified` — in **every** cell. When `live_media=on` AND `room_ready`, the client additionally requests a LiveKit token via RFD 0011's `POST /v1/proctoring/rooms/:name/tokens` (student branch; rejected while still `awaiting_capture` or `pending_device_proof`, or with `409 media_not_ready` until a room exists) and publishes camera / microphone / screen as RFD 0011 specifies. When `live_media=off` no token is requested and no media UI is rendered; content release is unaffected.
7. **In-exam control.** Invigilator broadcasts announcements, handles raise-hands, and spot-checks media per RFD 0011. All non-media interaction flows over the WS.
8. **Async verification review.** At any point during the exam, invigilators work through the review queue. Outcomes: `mark_verified` (queue clears, no student-visible effect), `mark_suspicious` (non-terminal flag; captures held, student undisturbed), `force_reverify` (student re-captures), `force_submit` with `reason: identity_verification_failed` (student disqualified — confirmation-gated), or deferred.
9. **Bearer rotation.** Extension pushes `bearer_refresh` every ~8 min; client replaces its bearer. No user interaction.
10. **Browser crash / reconnect.** Student reopens `/activities/:id/proctored` and the WS reconnects cookie-authorized. Then, by mode: `device_proof=on` — the extension prompts a passkey assertion, the client calls `/v1/proctoring/sessions/authenticate`, the extension validates against the stored credential id, rotates `session_id`, and issues a new bearer; `device_proof=off` — the client calls `/v1/proctoring/sessions/resume` with the re-entry token, the extension rotates `session_id` (invalidating the prior bearer), issues a new bearer, and re-mints the re-entry token. Admission, captures, verification, and `policy_snapshot` persist. A reconnect that displaces a still-live socket drops the incumbent and is recorded in the audit log; there is no involuntary loss of access short of an invigilator `force_submit`. No invigilator involvement otherwise.
11. **Manual admission.** A student whose capture cannot complete (broken webcam, persistent upload failure, ID left at home) is verified in person; an invigilator issues `manual_admit` with a reason, the extension audits it and sets the session `physically_verified`, and the student proceeds to step 6. There is no automatic deadline or `captures_missing` timer — admitting without a capture is always a human call.
12. **Raise hand.** Student sends `raise_hand`. Invigilator WS receives it, invigilator authors a `private_reply`. Both audited.
13. **Force submit.** Invigilator sends `force_submit` for a specific student. Extension audits, sets `locked_at` (so the bearer `401`s at once), then publishes the single terminal subject `proctoring.session.revoked` with `action: submit_and_lock` on NATS; core (whose `examination` activity owns submit semantics) submit-and-locks and stops serving content, and the extension sends `force_submit` to the student's WS so the client UI reflects the lock.
14. **Exam stop.** Staff clicks *Stop proctoring* per RFD 0011. Extension closes all WS sessions for the exam with a `session_ended` frame, marks any unreviewed captures accordingly in the audit log, and runs RFD 0011's room-deletion path. Captured images remain in the object store under the 30-day lifecycle rule (or indefinitely if under a `held/` hold).

## Lock Recovery: Suspend vs Revoke, and the Reconciler (R5)

The lifecycle above locks a session in two shapes the shipped implementation added but this
RFD never gave a recovery path: the **collection force-submit** (a timer at
`submission_collection.stop_at` emits `collection.closed`; the proctoring consumer locks the
closed cohort) and **room end** (an invigilator ends a room; its seated sessions lock). Both
land in the same terminal `locked` state as an invigilator `force_submit`. The problem: those
two causes are **reversible** — a `stop_at` extension reopens the window and reschedules the
timer; an ended room can be reopened — but the sessions they locked stay dead forever, because
`locked` is universally terminal (no `locked → *` edge). An instructor who sets the wrong
`stop_at` and then extends it to "give five more minutes" reopens the submission plane while
every proctoring session remains locked, recoverable today only by a direct database write.

The fix distinguishes two categories of lock, and gives the reversible one a real state.

### R5.1 — Suspend (reversible) vs revoke (terminal)

- **Revoke** is terminal, per-student, disciplinary: `force_submit` (identity failure, cheating).
  It keeps the `locked` state and the `proctoring.session.revoked` semantics unchanged. There is
  no undo (see Open Items for whether mis-click recovery is ever wanted).
- **Suspend** is reversible and cause-scoped: `collection_closed` (window force-submit) and
  `room_ended` (room closed). Room-end **must** carry a `room_ended` reason distinct from the
  per-student `invigilator` revoke, so a room reopen can reinstate its cohort without disturbing
  a student who was individually revoked while seated there.

A new non-terminal admission state **`suspended`** holds a reversible lock. A suspended and a
revoked student are both *blocked* — all deny-gates key off `locked_at != nil`, which stays set
on suspended rows, so no gate changes — but only `suspended` is recoverable, and the
student-facing copy differs off the reason ("the exam window closed, please wait" vs "you have
been removed"). Reversibility that drives copy, rendering, escalation, and eligibility **is** a
state, not metadata; `locked` stays *truly* terminal. Edges: `* → suspended` (any suspend
cause), `suspended → locked` (an invigilator escalates a suspended student to a disciplinary
revoke), `suspended → resume_state` (reinstate).

`resume_state` is a nullable column snapshotting the pre-suspend admission state, written
**atomically inside the suspend UPDATE** (`SET resume_state = state, state = 'suspended' WHERE
state NOT IN ('suspended','locked')`), cleared on reinstate/escalation. It is necessary for
robustness-to-evolution, not for today: every currently-*reachable* state is reconstructable
from markers (`policy_snapshot`, captures, `content_released_at`) **only because
`physically_verified` has no writer yet** — the day a physical-verify endpoint ships, marker
re-derivation silently regresses a verified student to `admitted` and destroys the invigilator's
attestation. The snapshot has zero staleness hazard (it is one write with the lock) and composes
correctly under double-suspend: a session suspended by a collection close and then by a room end
takes the second suspend as a no-op (its row is already `suspended`), preserving the first
snapshot.

### R5.2 — One predicate, level-triggered; events are nudges

Recovery is **not** event-driven. An edge-triggered reopen with a timestamp guard is unsound:
during the force-submit fire window, an extend can emit "reopen" before the in-flight
`ForceSubmitCollection` publishes "closed", and any `locked_at`-vs-event monotonicity check then
either rejects the valid reopen (deadlock) or, under clock skew, reinstates after a newer close.
Both directions of the lock flow instead through a single **level-triggered reconciler** (an
extension of the existing per-activity terminal sweep) computing one predicate:

> A session is **admission-eligible** iff the student is a member of **at least one currently
> open collection window** on the activity **and** their room is **not ended**. It is
> **suspend-eligible** iff neither holds. Revoked (`locked`) sessions are never touched.

The reconciler locks what should be locked and reinstates any `suspended` session for which the
predicate now holds (restoring `state := resume_state`, clearing the lock fields, bumping
`server_seq`, inserting a durable `session_reinstated` frame). The stored `locked_reason` is
advisory (copy + audit) only — reinstate is gated on live truth, which is what lets a session
suspended by *two* causes wait until *both* clear, something a reason-gated predicate cannot
express. `collection.closed`, `collection.reopened`, room-end, and room-reopen all degrade to a
pure `ScheduleLockReconcile(activity_id)` nudge with the periodic sweep as the durability
backstop; no event carries authority, and every failure mode is bounded at one sweep interval.

This is affordable precisely because **proctoring is a downstream control plane**: submission has
zero reads of proctoring state, and the authoritative answer-integrity fence is the submission
force-submit at `stop_at`. The proctoring lock only tears down the invigilation session (WS /
media / capture), never a delivery. So the lock's **latency** is free — a session lingering a few
seconds past close cannot be exploited (submission is already frozen), which is why the original
consumer was async. What must be correct is the lock's **authority**: a *wrong* lock (re-suspending
a validly-extended student) kicks them to the locked screen mid-exam, so the reconciler — not a
stale event — is the sole writer of session-blocked state.

Two consequences of the "one predicate" resolution, decided:

- **Multi-collection membership: any-open-wins.** The session is one-per-activity but cohorts are
  per-collection; a student in a closed main collection and an open accommodation collection is
  reinstated (their live window is open). Holding until *every* collection reopens would deadlock
  the extra-time student — the flagship case. The residual risk (a student erroneously in an extra
  open collection may sit during it) is a collection-membership problem already true of the
  submission plane, not one proctoring should second-guess. This requires extending the
  `activity_state` contract to answer **per-user open-collection membership** (today it answers only
  "every collection closed" over the whole-activity union).
- **Room un-ending is window-bounded.** A room is reopenable only while the activity has a live
  open window — the same predicate. This makes reopen meaningful only during an active sitting and
  avoids both an arbitrary grace timer and resurrecting a room long after the exam.

### R5.3 — The two corrections

- **Extend the exam window.** For `kind='exam'` the decided invariant is `stop_at == due_at`; the
  extend operation moves both together atomically (the code today enforces only the weaker
  `due_at >= stop_at`, so a naive "push `stop_at`" PATCH 400s on the due-at guard while students sit
  suspended). It reschedules the force-submit timer and, post-commit, calls the reconcile scheduler
  **in-process** — not via the `collection.updated` event, which publishes per collection *group*
  and so emits nothing for a user-audience (accommodation) collection.
- **Reopen an ended room.** A new `ended → open` transition (the existing status CAS cannot express
  it) that clears `ended_at` and nudges the reconcile. Un-ending is safe: room-end is a pure status
  CAS plus the session-lock loop — it seals no evidence and tears down no LiveKit (rooms are lazily
  re-provisioned on token issuance). The successor-room alternative is dead: re-seating a
  mid-exam student with an existing session is deferred by design, i.e. the whole cohort. The
  reconciler's lock direction and its `liveActivityIDs` scope must widen to cover all-ended-room
  activities, or a room whose rooms are all ended is excluded from the very sweep meant to reinstate
  it, and a reinstate that races a re-end escapes permanently — so reinstate must be one transaction
  taking the sweep's advisory lock and re-reading `room.status FOR SHARE` before its CAS.

### R5.4 — Authorization

Following the existing split (routine per-room invigilation = `can_proctor(room)`; structural
correction = `can_edit(proctoring_activity)`), scaled by blast radius:

| operation | relation | rationale |
| --- | --- | --- |
| extend exam window | `can_edit(activity)` (submission) | an academic-schedule change; not an invigilator's to make unilaterally |
| reopen ended room | `can_proctor(room)` | **symmetric with `end`** (also `can_proctor`) — the invigilator who mis-ended undoes it; ending already mass-locks the cohort, so reopening mass-reinstating it is the same power |
| per-student reinstate | `can_edit(proctoring_activity)` | mass-readmit; structural |
| escalate `suspended → locked` | `can_proctor(room)` | routine discipline; mirrors `force_submit` |

`can_edit(activity)` inherits `can_edit(proctoring_activity)` (via the activity parent), and
`chief` is *inside* `can_edit(proctoring_activity)` — so a course editor drives every correction,
and a **chief** drives room recovery fully but **not** the window extend (they lack
`can_edit(activity)`). That split is deliberate separation of duties: room lifecycle is the chief's
domain; moving an academic deadline is the coordinator's. We do **not** carve `chief` out of the
grant — doing so would need a new relation and strip chiefs of rooms/roster/assignments too. A full
authz pass may revisit personas; this is the provisional model.

### R5.5 — Freeze-race semantics and a latent bug

During the extend-vs-fire race, the student's staged work is force-committed at the *old* `stop_at`;
after reinstate they re-stage and are force-committed again at the new one. This is **accepted**: no
un-commit exists, exam collections are `score_selection=latest` so the phantom commit never wins,
and the cost of rolling back a committed Temporal force-submit is not worth a rare, harmless record
artifact — the phantom is logged for forensic clarity. Separately, the reconciler's lock direction
must re-verify live closed-state before suspending (or be a pure nudge), or the same race produces a
≤5-minute cohort-wide mid-exam suspension flicker.

This design also surfaces a **live bug independent of it**: the bulk-lock query guards
`AND state <> 'locked'` and the invigilator-lock / room-end paths discard the returned row count and
return success unconditionally — so an invigilator lock on an already-suspended student is a silent
no-op, leaving the row tagged `collection_closed` for a later reopen to resurrect. Under R5 that path
*is* the `suspended → locked` escalation edge; the fix (a zero-row lock is an error/escalation, not a
false success) needs three distinct SQL primitives — suspend, escalate, revoke — because the F13
consumer and the sweep require zero-rows-is-success (idempotent re-lock) while the interactive lock
requires zero-rows-is-error.

### R5.6 — Open Items

- **Client recovery channel (requirement, not nicety).** A student who reloaded on the locked screen
  cannot receive the `session_reinstated` frame (its delivery channels sit behind the same
  `locked_at` deny-gates). The locked/suspended screen **must** poll or retry `session create` on a
  timer — it is the only recovery path for the common "closed the laptop" case.
- **`physically_verified` writer** — when it ships, it needs a persisted attestation independent of
  FSM state (this is what makes `resume_state` load-bearing).
- **Attendance finalization** (`assignment.status = no_show`, currently unwritten) must be
  un-finalized by reinstate if/when a writer exists.
- **Invigilator-lock undo** — deliberately terminal here; a future `locked → suspended` demotion
  should be banned on purpose, not left ambiguous.

## Alternatives Considered

### Alternative A: non-extractable WebCrypto keypair as a device-binding fallback (rejected)

An `ECDSA P-256` keypair generated via `crypto.subtle.generateKey({extractable: false})`, stored as a `CryptoKey` handle in IndexedDB, would provide origin-partitioned device binding without a platform authenticator. It is **rejected as a contingency**, and this is now a firm decision rather than a standing fallback: under the unified policy, the answer to "no platform authenticator" is to set `device_proof=off`, which means **no device binding at all** — not a weaker cryptographic stand-in. Introducing a WebCrypto keypair (or a per-machine certificate, or MAC pinning) as a substitute would contradict that choice and reintroduce a mechanism whose continuity property we have deliberately declined to claim. The `device_proof=off` cell is a deliberate, bounded weaker threat model (authenticated session + closed intranet + physical invigilation + audit; see Known Limitations), not a degraded R1. Alternative A is recorded only to mark the road not taken.

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
- **Idempotency on invigilator decisions.** Invigilator-authored frames (`mark_verified`, `mark_suspicious`, `manual_admit`, `force_submit`, `force_reverify`, `capture_hold`, `capture_hold_release`) carry a client-generated `decision_id`; the extension dedupes on this id so that a double-click during a slow round-trip does not produce two audit entries.
- **Force-submit delivery guarantees.** A force-submit publishes `proctoring.session.revoked` with `action: submit_and_lock`, at-least-once to core (the extension retries until core acknowledges or a staff-level timeout elapses). It does not block on that delivery: the extension writes `locked_at` locally first, so the bearer `401`s immediately and core's next `IsAdmitted` query returns not-admitted regardless of whether the revoke was delivered — the session row is the source of truth. The client-side `force_submit` frame is advisory UI; the authoritative lock is the `locked_at` write plus core's submit-and-lock.
- **Re-capture is pointer-first, move-after.** When `force_reverify` is issued and a new capture is uploaded, the commit point is the session-state pointer update: the new capture lands at a fresh key first, then the pointer is advanced in a single transactional write, then the old object is `CopyObject`-ed to `superseded/` and the original deleted. If the extension crashes between the pointer update and the move, the old object simply remains at its original path — it is still covered by the default-prefix 30-day lifecycle rule, and a reconciliation sweep (run on extension start) moves any orphaned objects whose session pointer has advanced past them. No session state can observe a half-moved capture.
- **Capture upload failure handling.** If the client cannot upload despite retrying, it surfaces a retryable error and the session stays `awaiting_capture` — so under an `enforced` policy the student cannot yet obtain a LiveKit token. The resolution is the manual admission gate, not a timer: an invigilator verifies the student in person and issues `manual_admit`. No automatic disqualification on upload failure — network problems should not lose a student their exam silently.
- **Capture size bounds.** Client-side JPEG at 1280×720, ~85% quality, typical ~150 KB; reject uploads > 1 MB at the extension.
- **Passkey registration is necessary for any session; capture or manual admit gates entry under `enforced`.** If WebAuthn creation is cancelled, the session has no device binding and the client surfaces a retry prompt — the student cannot proceed. Under an `enforced` policy, completing registration still leaves the student `awaiting_capture` until both captures upload or an invigilator issues `manual_admit`; under `disabled`, registration alone admits. Cancelling registration repeatedly consumes no resource except the open WS.
- **Origin and RP ID.** `rp.id` must match the exam origin exactly; passkeys scoped to `zinc.example.com` cannot be used at `exam.zinc.example.com` and vice versa. Deployment choice pending.
- **Object-store lifecycle rule verification.** Lifecycle rules are easy to mis-configure at deployment. A post-deploy check asserts the rules are present and correctly scoped; a daily probe asserts no objects older than 31 days exist outside `held/`. Lifecycle rules run asynchronously; the probe is the actual deletion guarantee.
- **Orphaned wrapped-DEK rows.** A reconciliation sweep removes `session_captures` rows whose object-store object no longer exists (post-lifecycle deletion). A 30-day-after-`uploaded_at` TTL matches the default lifecycle rule; rows for `held/` captures are exempt.

## Known Limitations and Accepted Trade-offs

- **`device_proof=off` is a deliberate, bounded weaker threat model (the load-bearing concession).** Disabling `device_proof` removes all device binding with no compensating mechanism. There is **no proof-of-possession on any request**: the OIDC session cookie (at create) and the proctoring re-entry token (for the window) become the highest-value secrets, exfiltratable by the same XSS / malicious-extension / heap-dump vectors as the bearer. The bound is exactly TTL (10 min) + closed-intranet isolation (even more load-bearing than under `on`, and the only network control — there is no application-level source-IP allowlist) + physical invigilation + full audit. Cookie/re-entry-token replay lets a thief take over only via `/resume`, which rotates `session_id`, invalidates the incumbent bearer, and is recorded in the audit log; the re-entry token is single-active and `locked_at`-revocable. Read-only takeover is closed: `POST /sessions` refuses a co-current bearer (`409 session_active`). Bearer theft within the 10-min TTL from a live-socket context is an **accepted, audited-after-the-fact residual**; co-currency is not claimed to bound it, and there is no alerting/escalation beyond the audit log. Under `identity_verification=enforced` this is partly recovered by captures + review; under `disabled` (cells 6, 8) identity rests entirely on the physical door-check + invigilation.
- **Platform-authenticator availability is a hard deployment precondition only under `device_proof=on`.** Fleets without full coverage cannot run `device_proof=on` activities; the fleet survey is a prerequisite to `published` for those activities. There is no WebCrypto contingency (see Alternative A); the answer for a fleet without authenticators is `device_proof=off` with its stated weaker model.
- **Cross-device passkey sync is a concern only under `device_proof=on`.** Synced passkeys (iCloud Keychain, Google Password Manager) become valid re-login credentials only if the exam origin becomes reachable off the lab intranet (misconfigured VLANs, NAT hairpinning, maintenance-window routing). The application has no network-layer enforcement of the intranet boundary; runbooks must treat closed-intranet isolation as a first-class security control (change review, monitoring, incident response). Under `device_proof=off` the analogous secret is the cookie/re-entry-token, bounded by the same intranet isolation plus the single-active, `locked_at`-revocable re-entry token.
- **`live_media=off` removes the live visual signal.** No live camera/audio, no spot-check grid; invigilator review (if `identity_verification=enforced`) is stills-only, and a substituted still cannot be cross-checked against a live face, so terminal disqualify requires an invigilator in-person confirmation. Whether stills-only is acceptable as sole identity evidence is an explicit deployment policy call.
- **The near-bare `{off, off, disabled}` cell is the weakest electronic model.** Its electronic security is the authenticated session + physical invigilation + closed intranet + audit, with no device binding, no media, and no captures. Appropriate only where physical controls carry the load.
- **Invigilator visual match is the only identity signal.** False negatives (a lookalike, a very old ID photo) are not caught by the system and must be caught by physical invigilation. This is the same trade-off any non-biometric exam has historically accepted.
- **Captured-but-unreviewed students see exam content before the verdict.** Capture submission gates entry, but the invigilator's verdict is asynchronous, so a student who would fail review still sees question material between entry and the verdict. In-scope risk because (a) the consequence of a failed verification is the same regardless of timing (disqualification), and (b) live camera + physical invigilation already provide a parallel signal. Synchronous pre-entry review was rejected because it would require review capacity sized to the cohort's entry burst.
- **Manual admission is an audited human bypass.** The `physically_verified` path trades the webcam evidence for an invigilator's in-person check; its integrity rests on invigilator diligence and is only as strong as the audit trail. Over-use — manually admitting students wholesale under an `enforced` policy — silently degrades to no verification. This is surfaced in the audit stream (every `manual_admit` carries an actor and reason), not prevented in software.
- **Unreviewed-at-exam-stop captures exist.** If invigilators fall behind, some captures will still be `unreviewed` at exam stop. These are retained under the normal 30-day lifecycle and can be reviewed post-hoc; decisions made after exam stop have whatever standing institutional policy allows them. Not the system's problem to close.
- **Passkey binds to the OS account, not the machine (`device_proof=on` only).** A student who logs into a different OS account on the same lab machine fails to re-bind automatically; invigilator intervention (re-enroll or re-entry) is the escape hatch, and lab-ops policies (one OS session per student per exam) are assumed. Not applicable under `device_proof=off`.
- **`session_id` rotation widens RFD 0011's live-webcam stale-track limitation (`live_media=on` only).** Every reconnect rotates `session_id`; under `live_media=on` an invigilator who opened a review entry before a reconnect must re-resolve the live track. RFD 0011's stable-track-identity follow-up is a **prerequisite** for live three-up review in the `identity_verification=enforced` + `live_media=on` cells (1, 5), not closed here. All invigilator-facing per-student state keys on the stable `(user_id, activity_id)`, never `session_id`, so review-queue entries themselves do not detach on rotation.
- **Mid-exam de-authorization still has the RFD 0011 TTL window (accepted).** If a student's `enrolled` (or `student@proctoring_room`) tuple is removed during an exam, their existing extension bearer and any LiveKit token remain valid until TTL expiry; the revocation is **not acted on in-band**. The bearer hot path carries a short-TTL (≤ 30 s) cached `enrolled` re-check, but that check **fails open** — it never locks a live exam, and a flaky or definitive authz read at most writes an audit entry — so a single read can never irreversibly force-submit a student. This RFD does not close the window; closing it (acting on revocation in-band) is left to the follow-up that introduces the broader `proctoring.*` NATS event surface deferred from RFD 0011.

  Required normative RFD 0011 edits also land here and **require the RFD 0011 owner's ratification**: (1) introduce the `proctoring_session`/`enrolled` type and its media-independent writer, amending RFD 0011's "`student` is the single source of truth for room membership" to a two-plane model (`enrolled` = session/content, `student` = media), with room creation deriving `student` tuples from `enrolled`; (2) `POST /rooms` rejects with `409 media_disabled` when live `live_media=off`; (3) the token-route student-branch gains the admission + `room_ready` + device-proof preconditions (the invigilator branch is unchanged) — stated as **new** machinery, since RFD 0011 has no admission gate today.
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
| **Session bearer** | The short-lived JWT issued by the proctoring extension at session create (decoupled from passkey registration), rotated over the WS, used to authenticate extension API calls and WS frames. Subject `(user_id, activity_id, session_id)`; an optional `cnf == credential_id` claim is present iff `device_proof=on`. |
| **Proctoring policy** | The unified per-activity object `{device_proof: on\|off, live_media: on\|off, identity_verification: enforced\|disabled}`, resolved behind the `ProctoringPolicy` interface (superseding `VerificationPolicy`) and frozen as a per-session `policy_snapshot` at create. |
| **device_proof** | The knob selecting the optional passkey device binding. `on` = platform-authenticator passkey (R1). `off` = no device binding at all; create authorized by cookie + `enrolled` + `locked_at IS NULL`, reconnect by the single-active re-entry token; `credential_id` NULL; closed intranet is the only network control. |
| **live_media** | The knob selecting the optional LiveKit camera/screen plane (RFD 0011). `off` = no room is ever created; the entry gate targets the extension-owned admitted state, not a LiveKit token. |
| **identity_verification** | The knob selecting webcam ID-photo + face-snapshot captures with async review. `enforced` = captures gate admission; `disabled` = skipped. Open enum (future `optional`). Subsumes the former standalone `verification_policy`. |
| **enrolled** | The relation on the new first-class `proctoring_session` OpenFGA type meaning "is registered to sit this proctored activity." Distinct from `examination#examinee` ("can read the questions"). The media-independent session-create authorizer in all eight cells. |
| **Admission state** | The first-class, extension-owned session state (`pending_device_proof` / `awaiting_capture` / `admitted` / `physically_verified` / `locked`) that every consumer keys off, surfaced over WS (`session_state`/`session_status`) and HTTP (`GET /sessions/me`). Never "the client obtained a LiveKit token." |
| **IsAdmitted** | The internal NATS request-reply (+ internal HTTP) by which core pulls the admitted fact from the durable session row as a content-release precondition (a contract requiring core/RFD 0009-owner ratification), preserving RFD 0009's core-as-orchestrator direction. |
| **Re-entry token** | The extension-signed, single-active, `locked_at`-revocable credential (lifetime `== stop_at + margin`) minted at create under `device_proof=off` and used as the reconnect authorizer instead of the raw IdP cookie. |
| **Device binding** | The stored `credential_id` of the passkey registered on entry, present only under `device_proof=on`. Under `device_proof=off` there is no device binding. |
| **Review queue** | The invigilator's surface (keyed on stable `(user_id, activity_id)`) listing per-student verification status (`awaiting_capture` / `unreviewed` / `verified` / `suspicious` / `superseded` / `held`). Populated only under `identity_verification=enforced`; reviewed asynchronously during the exam, stills-only under `live_media=off`. |
| **Manual admission** | An invigilator admitting a student without a capture after an in-person check; sets the session `physically_verified` and exempts it from the review queue. The single override of the capture-to-enter gate. |
| **Suspicious flag** | A non-terminal review outcome marking an entry as doubtful: it holds the captures and surfaces them for a second review or post-exam decision, without ending the student's exam. The conservative alternative to disqualification. |
| **Capture hold** | An admin action — explicit investigative hold or a suspicious-flag outcome — moving a student's captures to a retention-exempt prefix in the object store, beyond the default 30-day window. |
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
