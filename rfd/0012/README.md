---
authors: Thomas Li
state: prediscussion
discussion:
labels: platform, security, interop, ux
---

# [RFD] Proctored Exam Client Orchestration

This RFD adds the orchestration layer around the `proctoring` extension introduced in [RFD 0011](../0011/README.md): device binding with a platform-authenticator passkey, webcam-based identity verification gated on invigilator approval, and a single bidirectional WebSocket between the exam client and the extension for audited control messages (admission, announcements, private clarifications, force-submit). Media transport, room lifecycle, and LiveKit token issuance are unchanged and continue to be owned by RFD 0011.

The scope is the coordination between the proctoring extension, the student's exam client, and the `examination` extension ([RFD 0009](../0009/README.md)) during the window from sign-in to exam stop. Automatic room lifecycle tied to `submission_collection.start_at`/`stop_at` (per [RFD 0010](../0010/README.md)) remains deferred — room creation and destruction are still staff-triggered as in RFD 0011.

## Background

RFD 0011 delivers the minimum usable proctoring pipe: a LiveKit SFU, per-room OpenFGA membership, short-lived tokens, and a staff-driven exam-start-to-exam-stop lifecycle. It is deliberately silent on three adjacent concerns that real exam delivery cannot ignore:

1. **Who is on the other end of the camera.** RFD 0011 accepts any authenticated user listed in a room's `student` relation. There is no moment at which a human verifies that the live face matches the enrolled student, nor any binding between the session and a specific device. A shared account, a replayed credential, or a student sitting a second exam on the same enrolled account all pass the RFD 0011 controls.
2. **Session continuity when the browser goes away.** A two-to-three-hour exam is long enough that tab closures, browser crashes, and machine reboots are not hypothetical. RFD 0011 treats every connection as a fresh authenticated session; re-entering the exam requires no proof of continuity with the earlier session.
3. **Invigilator-to-client communication.** RFD 0011 has no path for an invigilator to say "you have thirty minutes remaining" to the room, to answer a student's clarification, or to force a student's exam client to submit. Everything an invigilator does is passive (watching tracks) or destructive (ending the exam for everyone).

This RFD covers all three without disturbing RFD 0011's media plane. The motivating constraint is that ZINC exams are **online-onsite** — students sit in supervised labs on a closed intranet, physically present with an invigilator — so the threat model is not "preventing sophisticated remote impersonation" but "catching the obvious and making the audit trail defensible." That context shapes every decision below: we prefer human judgement over ML, audited server-mediated paths over peer-to-peer convenience, and hard failure on precondition gaps over silent software fallbacks.

## Scope

### In scope

- Device binding via platform-authenticator **passkey** (WebAuthn), created at identity check and used to re-establish sessions after disconnection.
- **Session bearer** issued after admission and rotated over the control WebSocket.
- **Webcam identity verification** with invigilator visual confirmation — no ML face matching, no pre-enrolled portrait.
- **Persisted admission state** on `(user, exam)` so that passkey re-login resumes the exam without re-running identity verification.
- A **single bidirectional WebSocket** on the proctoring extension carrying admission, announcements, private clarifications, force-submit, and bearer refresh frames; all messages audited by virtue of flowing through the extension.
- Coordination contract with the `examination` extension for the force-submit command.

### Deferred

- **Automatic room lifecycle** (Temporal workflow per RFD 0010, tied to `submission_collection.start_at`/`stop_at`). Still out of scope here; a future RFD closes this.
- **ML-assisted face match.** The invigilator makes the admission call; automated face matching is not included.
- **Hardware attestation of passkeys** (`attestation: 'direct'` with a vendor trust list). Practical only after a fleet survey establishes that real hardware attestation is available across lab machines.
- **Pre-enrolled portrait reference** sourced from student records. The captured ID photo is the only reference for R2; sourcing a canonical portrait from `core` belongs to a follow-up.
- **Device allowlisting at the OS / network layer** (per-machine certificates, MAC-address pinning, lab-network enrollment). This RFD binds at the browser-session level; lab-ops-level controls are complementary and out of scope.

## Architecture

The `proctoring` extension gains a WebSocket endpoint alongside the HTTP routes introduced in RFD 0011. The student client establishes the WS **before** requesting a LiveKit token and keeps it open for the duration of the exam; the invigilator client establishes its own WS with an invigilator-scoped session. All orchestration traffic flows through the extension:

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

- `POST /v1/proctoring/sessions/register` — passkey registration during identity check.
- `POST /v1/proctoring/sessions/verify` — submit ID photo + face snapshot for invigilator review.
- `POST /v1/proctoring/sessions/authenticate` — passkey assertion to re-establish a session.
- `WSS /v1/proctoring/sessions/stream` — the bidirectional control channel.
- `GET /v1/proctoring/sessions/:id/captures/:kind` — signed-URL access to ID photo / face snapshot for invigilators (not exposed to students).

LiveKit room and token routes from RFD 0011 are unchanged; token issuance gains one precondition (the caller must hold an `admitted` admission state).

## Device Binding (R1)

### Passkey, not raw keypair

The device credential is a **platform-authenticator passkey** created via WebAuthn:

```js
await navigator.credentials.create({
  publicKey: {
    rp: { id: 'exam.zinc.example.com', name: 'ZINC Exam' },
    user: { id: userIdBytes, name, displayName },
    challenge: serverChallenge,
    pubKeyCredParams: [{ type: 'public-key', alg: -7 }], // ES256
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

Registration happens **during** identity verification, not before: the student proves they can create a passkey on this machine *as part of* demonstrating that they are sitting at their assigned exam station. The resulting credential id is stored by the extension as the `(user, exam)` device binding. Subsequent assertions against the same `(user, exam)` must present this credential id — any other binding requires invigilator intervention.

### Lab-environment prerequisite (hard blocker)

Platform-authenticator passkeys require a functioning platform authenticator on the exam machine. Machines without one **cannot be used to take the exam**. There is no software fallback in the shipped product.

Pre-exam onboarding performs a capability probe (`PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()`) and hard-fails before the student reaches the identity-check step if no platform authenticator is available. Lab-ops is responsible for guaranteeing coverage across the fleet; a survey of platform-authenticator availability across the target labs is a prerequisite before this RFD moves to `published`.

### Session bearer and rotation

The passkey is **not** used to sign per-request or per-frame traffic. After admission, the extension issues a session bearer (JWT, ≤ 10 min TTL, signed by the extension) tied to the `(user, exam, credential_id)` triple. The bearer rotates over the WebSocket on a schedule well inside its TTL; the client presents the current bearer as the WS bearer token and on any extension HTTP call. Passkey assertions are only invoked for session re-establishment (see below), so user-verification prompts are rare by construction.

### Re-login after disconnect

Session loss events — browser close, tab crash, machine reboot, network flap long enough to kill the TCP connection — are handled without invigilator involvement:

1. The client reaches `/v1/proctoring/sessions/authenticate` with a passkey assertion challenge.
2. The extension validates the assertion against the stored `credential_id`.
3. On success, a fresh bearer is issued and the student resumes the exam in the same admission state.

This requires admission to be a **persisted state on `(user, exam)`**, not a per-session event. Once an invigilator admits a student, the admission sticks across reconnects; only an explicit invigilator action (see R4's force re-verify command) invalidates it.

### Cross-device sync

iCloud Keychain and Google Password Manager sync passkeys across a user's devices by default. This is not exploitable in our threat model because the exam origin is reachable only from the closed lab intranet — a synced passkey on a student's phone on mobile or home Wi-Fi cannot reach the exam host. The intranet isolation established in RFD 0011 is what makes the cross-device sync property tolerable; without it, this would be a hole.

## Identity Verification (R2)

### Capture flow

The student client walks through two sequential captures after device registration and before admission:

1. **ID photo.** The client prompts the student to hold their physical student / national ID up to the webcam. The camera preview is live; the student clicks *Capture* to freeze a still frame. Minimum resolution 1280×720; downsized and JPEG-encoded at ~85% quality client-side to bound payload size.
2. **Face snapshot.** Same preview, no ID this time. A separate still frame of the student's face.

Both images are POSTed to `/v1/proctoring/sessions/verify`. The extension persists them to the object store under keys derived from the session id, records pointers in its session state, and pushes a `verification_pending` event over the WS to the invigilator session(s) on the same room.

### Invigilator review

The invigilator surface renders the two captures side-by-side with the student's name and enrolled id visible. The invigilator chooses *Admit* or *Reject*:

- **Admit** writes the persisted admission state for `(user, exam)`, makes the student eligible to request a LiveKit token, and pushes an `admitted` event to the student's WS.
- **Reject** pushes `rejected` with an invigilator-authored reason to the student's WS; the student session ends. Re-attempt requires an explicit invigilator unlock action (out of scope for this RFD to define the exact UX; defer to drafting).

There is no ML face matching. The invigilator's judgement is the decision; the photos are evidence, not a verdict.

### PII storage and retention

Both captured images are personal data under any plausible regulatory regime and must be handled as such:

- **Storage**: object store bucket separate from academic artefacts, encrypted at rest, access controlled by signed URLs issued only to callers holding `can_proctor on proctoring_room:<name>` (or an appeals-office role, if introduced).
- **Retention**: default window of **90 days post-exam**, chosen to cover the institutional appeal period. After expiry, images are deleted automatically by a scheduled sweep; deletion is non-recoverable. An exam-specific retention override is permitted (e.g. an active academic-misconduct investigation) and is itself audited.
- **Access logging**: every signed-URL issuance is written to the extension's audit stream with caller identity, subject, and purpose tag.
- **No export surface**: there is no bulk-export endpoint and no admin-console "view all" path. Individual images are viewable only in the context of a specific session review.
- **Deletion on student request**: not supported during the retention window — retention is bounded by exam administration policy, not student preference. Documented as a trade-off.

The extension must not log image bytes or signed URLs to any standard log sink.

### Waiting room

Between completing captures and receiving an invigilator decision, the student sits in a **waiting state**: the client renders a "verification in progress" view, holds the WS open, and ignores any attempt to request a LiveKit token. This state is explicitly represented in the session state machine so that WS reconnects during the wait resume correctly.

## Control Channel (R4)

### Transport

A single WebSocket per client session, mounted at `WSS /v1/proctoring/sessions/stream`. Authentication on connect uses the session bearer as a bearer token; the extension associates the socket with the session id and participant identity. The socket is bidirectional — clients send, the extension sends, both over the same framing.

**LiveKit data channels are not used for control.** RFD 0011's `CanPublishData: false` grant on both students and invigilators is preserved to reinforce the invariant that every control message is audited by passing through the extension. Using the LiveKit data plane would either bypass the audit trail or require the extension to double-record events already delivered by the SFU.

### Frame schema

Every frame is a JSON object with a `type` discriminator and a `seq` for ordering. Server-originated frames carry `server_seq`; client-originated frames carry `client_seq`. The extension echoes applied frames with a `server_seq` to allow idempotent reconnect.

Frames in scope for this RFD:

| Direction           | Type                        | Purpose                                                                      |
|---------------------|-----------------------------|------------------------------------------------------------------------------|
| extension → client  | `bearer_refresh`            | Push a new session bearer before the current one expires                     |
| extension → student | `admitted` / `rejected`     | Result of invigilator review (post-R2)                                       |
| extension → student | `announcement`              | Text broadcast from invigilator; `scope: room`, `room_id`                    |
| extension → student | `private_message`           | Invigilator reply to this student's raise-hand                               |
| extension → student | `force_submit`              | Instruct the exam client to submit and lock                                  |
| extension → student | `reverify_required`         | Invalidate admission; client returns to ID-capture flow (see R4 extension)   |
| student → extension | `raise_hand`                | Student requests clarification; body carries a short text                    |
| student → extension | `ack`                       | Acknowledge a server frame by `server_seq` (delivery confirmation)           |
| extension → invig.  | `session_state`             | Per-student admission / presence / raise-hand state for the invigilator grid |
| extension → invig.  | `verification_pending`      | A new `(student, captures)` is ready for review                              |
| invig. → extension  | `admit` / `reject`          | Decide on a pending verification                                             |
| invig. → extension  | `announce`                  | Compose-and-send an announcement to a room                                   |
| invig. → extension  | `private_reply`             | Reply to a specific student's raise-hand                                     |
| invig. → extension  | `force_submit`              | Trigger force-submit for a specific student                                  |
| invig. → extension  | `force_reverify`            | Invalidate a student's admission and send them back through R2               |

A fifth invigilator command — `force_reverify` — is included to cover the edge case where an invigilator admitted a student in error or has cause to repeat the check mid-exam. It invalidates the persisted admission state for `(user, exam)` and the client surfaces the ID-capture flow again; the student retains their passkey binding and does not re-register the device.

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

RFD 0011 introduced `proctoring_room` with `parent: activity`, `student: user`, and `can_proctor = can_edit from parent`. This RFD adds a per-`(user, exam)` admission state that is not an OpenFGA relation but extension-local state, keyed on `(user_id, activity_id)` with values:

- `unverified` (initial — captures not yet reviewed)
- `pending` (captures submitted, awaiting invigilator)
- `admitted` (invigilator accepted; LiveKit token issuance unlocked)
- `rejected` (invigilator rejected; session terminal unless invigilator unlocks)

Admission state lives in the extension's database (alongside the RFD 0011 cache sidecar) rather than in OpenFGA because it is a bounded, session-scoped state machine, not a durable access-control relation. The authoritative membership relation remains the RFD 0011 `student` tuple; `admitted` is an additional gate on top, not a replacement.

Token issuance (`POST /v1/proctoring/rooms/:name/tokens`) gains a new precondition: an `admitted` state on the caller's `(user_id, activity_id)`. Callers in `pending` receive `202 Accepted` with a hint to wait; callers in `unverified` or `rejected` receive `403`.

Existing authorization checks are unchanged. `can_proctor` continues to inherit from `can_edit` on the parent activity. Invigilator WS actions are authorized per-call against `can_proctor` on the target room.

## End-to-End Lifecycle

1. **Sign-in.** Student signs in to `ui-v2` as usual. Client navigates to `/activities/:id/proctored`.
2. **Capability probe.** Client calls `PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()`. No → hard fail screen, exam not takeable on this machine. Yes → proceed.
3. **Establish session.** Client opens `WSS /v1/proctoring/sessions/stream` with the user's normal session cookie; extension creates a session with state `unverified`.
4. **Device registration.** Client obtains a WebAuthn challenge, creates a platform-authenticator passkey with biometric prompt, POSTs the attestation to `/v1/proctoring/sessions/register`. Extension stores `(user, activity) → credential_id`.
5. **Identity captures.** Client captures ID photo, then face snapshot, POSTs both to `/v1/proctoring/sessions/verify`. Session state → `pending`. Invigilator's WS receives `verification_pending`.
6. **Invigilator review.** Invigilator opens the side-by-side review surface, clicks *Admit*. Extension writes admission state, emits `admitted` to the student's WS. Session state → `admitted`.
7. **LiveKit join.** Client requests a LiveKit token via RFD 0011's `POST /v1/proctoring/rooms/:name/tokens`; the new admission precondition passes. Client connects to the room with VP8 + simulcast + Dynacast as RFD 0011 specifies and publishes camera / microphone / screen.
8. **In-exam control.** Invigilator broadcasts announcements, handles raise-hands, and spot-checks media per RFD 0011. All non-media interaction flows over the WS.
9. **Bearer rotation.** Extension pushes `bearer_refresh` every ~8 min; client replaces its bearer. No user interaction.
10. **Browser crash.** Student reopens `/activities/:id/proctored`. Client probe succeeds, WS reconnects, extension sees no live session for this `(user, activity)` and prompts passkey assertion. Client calls `/v1/proctoring/sessions/authenticate` with an assertion; extension validates, issues a new bearer, restores the admitted state, and the student resumes. No invigilator involvement.
11. **Raise hand.** Student sends `raise_hand`. Invigilator WS receives it, invigilator authors a `private_reply`. Both audited.
12. **Force submit.** Invigilator sends `force_submit` for a specific student. Extension audits, publishes `proctoring.force_submit` on NATS, examination extension processes, student's exam client locks.
13. **Exam stop.** Staff clicks *Stop proctoring* per RFD 0011. Extension closes all WS sessions for the exam with a `session_ended` frame, deletes admission state, and runs RFD 0011's room-deletion path. Captured images remain in the object store for the retention window.

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
- **WS reconnect during verification window.** If the WS drops while the session is in `pending`, the client re-opens the WS and the extension replays the most recent `verification_pending` → `admitted`/`rejected` events up to the last acknowledged `server_seq`. Captures already uploaded are not re-uploaded; the client recognises its state by the server's hello frame.
- **Idempotency on admission.** Invigilator `admit` frames carry a client-generated `decision_id`; the extension dedupes on this id so that a double-click during a slow round-trip does not produce two audit entries.
- **Force-submit delivery guarantees.** `force_submit` is at-least-once to the examination extension over NATS (the extension retries until `examination.submitted` is observed or a staff-level timeout elapses). The client-side `force_submit` frame is advisory UI — the authoritative lock is done by the examination extension.
- **Rejection retry policy.** Out of the gate, a rejected student cannot self-retry; only an invigilator unlock action reopens the ID-capture flow. Specific UX (retry-cap, unlock endpoint) to be finalised during drafting of the staff tool.
- **Capture size bounds.** Client-side JPEG at 1280×720, ~85% quality, typical ~150 KB; reject uploads > 1 MB at the extension.
- **Passkey registration does not gate the WS open.** If WebAuthn creation is cancelled by the student, the session stays in `unverified` and the extension surfaces a retry path. Cancelling repeatedly does not consume any resource except the open WS.
- **Origin and RP ID.** `rp.id` must match the exam origin exactly; passkeys scoped to `zinc.example.com` cannot be used at `exam.zinc.example.com` and vice versa. Deployment choice pending.

## Known Limitations and Accepted Trade-offs

- **Platform-authenticator availability is a hard deployment precondition.** Fleets without full coverage cannot use this RFD's R1 mechanism; the fleet survey is a prerequisite to `published`. Alternative A is the standing contingency.
- **Invigilator visual match is the only identity signal.** False negatives (a lookalike, a very old ID photo) are not caught by the system and must be caught by physical invigilation. This is the same trade-off any non-biometric exam has historically accepted.
- **Passkey binds to the OS account, not the machine.** A student who can log into a different OS account on the same lab machine will fail to re-bind automatically. Invigilator intervention (`force_reverify`) is the escape hatch. Lab-ops policies (one OS session per student per exam) are assumed.
- **Mid-exam OpenFGA revocation still has the RFD 0011 TTL window.** If a student's `student` tuple is removed during an exam, their existing LiveKit token and extension bearer remain valid until expiry. This RFD does not close the window; the follow-up that introduces `proctoring.*` NATS events (deferred from RFD 0011) will.
- **PII retention is a policy, not a mechanism.** A 90-day retention window enforced by a scheduled sweep is only as good as the sweep. Monitoring on the sweep job and its completion metrics is part of the deployment runbook, not this RFD.
- **Force-submit semantics are defined by the examination extension.** This RFD guarantees delivery and audit but not the answer-handling semantics. If the examination extension is unavailable, force-submit degrades to an audit-only event; the client will not see a lock. Degraded behaviour during an examination-extension outage is documented, not prevented.

## Glossary

| Term | Definition |
|------|------------|
| **WebAuthn** | Web Authentication API — a W3C standard for public-key authentication in browsers, implemented by all major browsers. Uses authenticators (platform or roaming) to create and use credentials. |
| **Passkey** | Consumer-friendly name for a discoverable WebAuthn credential. In this RFD it means specifically a platform-authenticator resident credential protected by user verification. |
| **Platform authenticator** | An authenticator built into the device (Touch ID / Face ID / Windows Hello / Android biometric / ChromeOS). Contrasted with *roaming authenticators* like YubiKeys. |
| **User verification** | A WebAuthn property meaning the authenticator verified the user's presence *and* identity (e.g. biometric or PIN) at signing time. Stronger than user presence alone. |
| **Attestation** | A signed statement from an authenticator asserting the provenance of a credential (e.g. "this credential was created in a genuine Apple Secure Enclave"). Optional at registration; not used in this RFD. |
| **Session bearer** | The short-lived JWT issued by the proctoring extension after admission, rotated over the WS, and used to authenticate extension API calls and WS frames. |
| **Admission state** | An extension-local state per `(user, exam)` with values `unverified` / `pending` / `admitted` / `rejected`, gating LiveKit token issuance and surviving session reconnects. |
| **Control WS** | The single bidirectional WebSocket on the proctoring extension carrying non-media orchestration traffic for the full exam lifecycle. |

## References

- [RFD 0009 — ZINC Extension System](../0009/README.md)
- [RFD 0010 — Temporal Workflow Orchestration](../0010/README.md)
- [RFD 0011 — Real-Time Video Invigilation Using LiveKit](../0011/README.md)
- [W3C Web Authentication Level 3](https://www.w3.org/TR/webauthn-3/)
- [MDN: Web Authentication API](https://developer.mozilla.org/en-US/docs/Web/API/Web_Authentication_API)
- [passkeys.dev — platform authenticator support matrix](https://passkeys.dev/device-support/)
