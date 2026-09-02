---
authors: Thomas Li
state: prediscussion
discussion:
labels: platform, security, interop, ux
---

# [RFD] Proctored Exam Client Orchestration

This RFD adds the orchestration layer around the `proctoring` extension introduced in [RFD 0011](../0011/README.md): a single bidirectional WebSocket between the exam client and the extension for audited control messages (announcements, private clarifications, force-submit), a first-class extension-owned admission state, and a **unified per-activity proctoring policy** with three independent knobs: `device_proof` (`on`/`off`), `live_media` (`on`/`off`), and `identity_verification` (`enforced`/`disabled`). The default `{on, on, enforced}` reproduces today's behaviour: a platform-authenticator passkey device binding, the RFD 0011 live-video/screen plane, and webcam identity verification reviewed asynchronously by invigilators. Each knob may be turned off independently, so the design must hold for all **eight cells** of the matrix, including the near-bare `{off, off, disabled}` session (no passkey, no media, no captures) and every mixed cell, without impossible states. Media transport, room lifecycle, and LiveKit token issuance remain owned by RFD 0011 and are exercised **only when `live_media=on`**, where the media plane is byte-for-byte compatible after the new admission/room-ready preconditions are satisfied; this RFD requires a small set of normative RFD 0011 edits (enumerated under Authorization Model and Known Limitations) that must be ratified with the RFD 0011 owner, and a core-side content-gate contract (a synchronous `IsAdmitted` pull on core's existing exam-start path) that must be ratified with the core/RFD 0009 owner.

The scope is the coordination between the proctoring extension, the student's exam client, and the `examination` extension ([RFD 0009](../0009/README.md)) during the window from sign-in to exam stop. Automatic room lifecycle tied to `submission_collection.start_at`/`stop_at` (per [RFD 0010](../0010/README.md)) remains deferred; room creation and destruction are still staff-triggered as in RFD 0011.

## Background

RFD 0011 delivers the minimum usable proctoring pipe: a LiveKit SFU, per-room OpenFGA membership, short-lived tokens, and a staff-driven exam-start-to-exam-stop lifecycle. It does not cover three adjacent concerns that exam delivery must address:

1. **Who is on the other end of the camera.** RFD 0011 accepted any authenticated user listed in a room's `student` relation. There is no moment at which a human verifies that the live face matches the enrolled student, nor any binding between the session and a specific device. A shared account, a replayed credential, or a student sitting a second exam on the same enrolled account all pass the RFD 0011 controls. This RFD layers two **independently selectable** identity controls on top: an optional platform-authenticator passkey **device binding** (`device_proof`) and optional webcam **identity verification** (`identity_verification`). When `device_proof=off` there is no device binding **at all**, and no weaker mechanism is substituted; the resulting (weaker, bounded) threat model rests on the authenticated session, closed-intranet isolation, and physical invigilation. The online-onsite premise (a supervised lab on a closed intranet) is what makes that bound acceptable; closed-intranet isolation is the only network-layer control, and there is no application-level source-IP allowlist.
2. **Session continuity when the browser goes away.** A two-to-three-hour exam is long enough that tab closures, browser crashes, and machine reboots are not hypothetical. RFD 0011 treats every connection as a fresh authenticated session; re-entering the exam requires no proof of continuity with the earlier session. We establish continuity through a **session bearer** carried over the reused WS + HTTP framing, decoupled from any passkey. The bearer is issued at session create, rotated over the control WS, and re-established on reconnect: by a passkey assertion when `device_proof=on`, and by a cookie-authed session-create recovery when `device_proof=off`. With `device_proof=off` there is no proof-of-possession on any request; continuity is a single-active-session convenience bounded by the bearer's 10-minute TTL, the intranet, and invigilation. It is not a cryptographic guarantee.
3. **Invigilator-to-client communication.** RFD 0011 has no path for an invigilator to say "you have thirty minutes remaining" to the room, to answer a student's clarification, or to force a student's exam client to submit. Everything an invigilator does is passive (watching tracks) or destructive (ending the exam for everyone).

This RFD covers all three without disturbing RFD 0011's media plane. The motivating constraint is that ZINC exams are **online-onsite**: students sit in supervised labs on a closed intranet, physically present with an invigilator. The threat model is therefore not "preventing sophisticated remote impersonation" but "catching the obvious and making the audit trail defensible." That context shapes the decisions below: we prefer human judgement over ML, audited server-mediated paths over peer-to-peer convenience, and hard failure on precondition gaps over silent software fallbacks.

## Scope

### In scope

- A **unified per-activity proctoring policy** (`proctoring_policy`) with three independent knobs, resolved behind one `PolicyProvider` interface and **frozen as a per-session `policy_snapshot`** at session create:
  - `device_proof: on | off`. Optional platform-authenticator **passkey** (WebAuthn) device binding. `on` reproduces today's behaviour (registration on entry, assertion on reconnect). `off` means **no device binding at all**: session create is authorized by the normal authenticated session cookie plus a non-withdrawn proctoring-assignment enrollment check (a DB existence check, not an OpenFGA tuple), and an existing locked or dismissed row is recovered rather than strictly requiring `locked_at IS NULL`; reconnect re-authorizes through the same cookie-authed create-recovery, which rotates `session_id` at WS attach; no device credential is stored. No alternative device-binding mechanism is introduced under `off`, and closed-intranet isolation is the only network control.
  - `live_media: on | off`. Optional LiveKit camera/screen publishing plus live invigilation (the RFD 0011 plane). Controlled through this extension's own policy state and control WS/HTTP, not by manipulating LiveKit grants directly. `off` means no LiveKit room is created for the activity.
  - `identity_verification: enforced | disabled`. Webcam ID-photo + face-snapshot captures with asynchronous invigilator review, no ML face matching, no pre-enrolled portrait. Open enum (future `optional`). Subsumes the former standalone `verification_policy`.
- **Session bearer** decoupled from passkey registration: issued at session create in every cell, rotated over the control WebSocket, re-established on reconnect.
- A **first-class, extension-owned admission state** (`admission_state`) surfaced over WS/HTTP as the fact every consumer keys off, not "the client obtained a LiveKit token."
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
- **Any alternative device-binding mechanism for `device_proof=off`.** `off` means no device binding at all. A non-extractable WebCrypto keypair, a per-machine certificate, an application-level source-IP allowlist, or MAC pinning are **not** introduced as a fallback; the no-device-proof cell is a bounded, weaker threat model (see Known Limitations) resting on the authenticated session, closed intranet, and invigilation. It is not a degraded form of R1.
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

- `POST /v1/proctoring/sessions`: **the universal session-create + first-bearer + reconnect endpoint, in all eight cells.** Cookie-authorized; additionally requires a non-withdrawn proctoring-assignment enrollment (a DB existence check, authorization, media-independent). Freezes `policy_snapshot`, mints a `session_id` ULID, and issues the first bearer; the request body carries only `activity_id`. On an existing **active** (non-locked) row it re-issues the same session with the **same** `session_id` and a fresh bearer and returns `200` with `existing=true`, so a network retry (and a reconnect under `device_proof=off`) is an idempotent recovery; a **locked** or **dismissed** row likewise recovers with `200` (a control-plane bearer only, so the client parks on its terminal/dismissed screen) while its room is live; a **suspended** row is refused `403` until the reconciler reinstates it. There is no `idempotency_key` field and no `409 session_active` takeover response. The response carries the session `state` (`pending_device_proof` under `device_proof=on`, else `awaiting_capture`/`awaiting_attach`), not a `next` field.
- `GET /v1/proctoring/sessions/me`: **cookie-authorized** (registered on the cookie-auth route group, not bearer-only); returns the caller's own session row `{session_id, bearer, state, locked_reason, policy_snapshot}` (the `bearer` field is empty here). No target `user_id`.
- WebAuthn **challenge**: **`device_proof=on` only.** There is no `/sessions/challenges` route; the single-use challenge is minted by the begin legs `/sessions/webauthn/register/begin` and `/sessions/webauthn/authenticate/begin`, keyed `(user_id, activity_id, purpose)`, with the server challenge TTL defaulting to 5 minutes. Gated by the **bootstrap (pending) bearer** (which already exists by this point). A reused or expired challenge returns `401` (`AccessInvalidCredential`). Under `off` the WebAuthn routes are not exercised (there is no `device_proof_disabled` fault).
- WebAuthn **registration**: **`device_proof=on` only.** A two-leg `/sessions/webauthn/register/begin` + `/sessions/webauthn/register/finish` (not a single `POST /sessions/register`), gated by the bootstrap/pending bearer. Finish consumes the registration challenge and binds the credential (stored in a separate `webauthn_credential` table keyed `(user_id, activity_id)`); it does **not** itself mint a bearer or advance the FSM. A `cnf == credential_id` bearer is minted on a later re-mint once the session is admitted.
- WebAuthn **authentication**: **`device_proof=on` only.** A two-leg `/sessions/webauthn/authenticate/begin` + `/sessions/webauthn/authenticate`; the finish leg verifies the assertion against the stored credential, advances the FSM out of `pending_device_proof`, and re-mints a bearer on the **same** `session_id` (the `session_id` rotation happens at the subsequent WS attach). There is no `device_proof_disabled` fault under `off`.
- `POST /v1/proctoring/sessions/captures`: **`identity_verification=enforced` only.** Mutating; requires the socket be bearer-attached (`409 needs_attach` otherwise). Uploads ID photo and face snapshot; streamed to object storage. Under `disabled` it refuses with `503` (reason `proctoring.identity_verification_disabled`).
- `WSS /v1/proctoring/ws`: the bidirectional control channel. The student's first connect authenticates via the **session bearer** carried in the first `attach` hello frame (there is no pre-bearer cookie connect for students); the extension runs the **full validation invariant** and, on success, binds the socket to the (rotated) `session_id`. The invigilator socket is **cookie-authorized**.
- `GET /v1/proctoring/activities/:activity_id/sessions/:user_id/captures/:kind`: **`identity_verification=enforced` only.** Extension-streamed plaintext capture for invigilators with `can_view` on the `proctoring_activity`. Decryption inside the extension (see R2 Encryption); signed URLs are not used.
- `IsAdmitted(user_id, activity_id) -> {admitted, error}`: **internal** NATS request-reply (no HTTP equivalent), answered from the durable session row. The core-driven content-release pull (see Coordinating with the examination extension); **requires core/RFD 0009-owner ratification** of the subject, timeout, and fail-closed semantics. Not a public client endpoint.

LiveKit room and token routes from RFD 0011 are exercised **only when `live_media=on`**. `POST /v1/proctoring/rooms/:room_id/tokens` keeps RFD 0011's relation dispatch and grants table; on the **student branch only** it gains three extension-owned, non-authorization preconditions: `policy_snapshot.live_media == on` (frozen snapshot, else `409 media_disabled`), `admission_state in {admitted, physically_verified}` (else `403`), and `room_ready == true` (else `409 media_not_ready`). The invigilator (`can_proctor`) branch is unchanged from RFD 0011: invigilators have no session row and are not gated on admission. `POST /v1/proctoring/rooms` gains a policy precondition: it rejects with `409 media_disabled` when the activity's **live** resolved policy has `live_media=off`, so no LiveKit object can exist on a media-off activity. These token-route and room-create changes are **normative RFD 0011 edits requiring the RFD 0011 owner's ratification**. Admission and content do **not** depend on a LiveKit token in any cell.

LiveKit room and token routes from RFD 0011 are otherwise unchanged, but whenever `live_media=on` the student branch of the token route gains one precondition: the caller's session must be `admitted` or `physically_verified` (see R2 and the Authorization Model). Even under `identity_verification=disabled` the student branch is still admission-gated whenever `live_media=on`; only the invigilator branch is unchanged from RFD 0011.

## Device Binding (R1)

Device binding is governed by the `device_proof` knob. The two paths share the same session/bearer/WS/HTTP machinery; only the create-authorizer, the reconnect-authorizer, and the presence of `credential_id` differ.

### `device_proof=off`: no device binding

When `device_proof=off` there is **no device proof at all**, and no alternative binding mechanism is substituted (see Deferred). Session **creation** is authorized by the student's normal authenticated session cookie (the same authorizer the design trusts for the student's first bearer) together with a non-withdrawn proctoring-assignment enrollment (a DB existence check, not an OpenFGA `enrolled` relation; there is no `proctoring_session` OpenFGA type). A brand-new or suspended row additionally requires `locked_at IS NULL`; an existing locked or dismissed row is instead recovered with a control-plane bearer while its room is live. There is no application-level source-IP allowlist; **closed-intranet isolation is the only network control**. `POST /v1/proctoring/sessions` returns the session `state` (there is no `next` field); there is no capability probe, no challenge, no passkey, and no device credential is stored. **Reconnect** re-authorizes through the same cookie-authed `POST /v1/proctoring/sessions` create-recovery, which recovers the existing session with a fresh bearer; `session_id` rotates on each control-WS attach, so only one active session exists at a time. (The as-built here replaces this RFD's proposed single-active re-entry token and `/resume` route; the design rationale for the token (that the extension cannot reliably read the raw IdP cookie's absolute TTL) is retained for ratification.) The bearer's identity binding is `(user_id, activity_id, session_id)`; there is no `cnf` claim and no proof-of-possession on any request; bearer secrecy is the only control, bounded by the 10-minute TTL, the intranet, and physical invigilation (see Known Limitations).

### `device_proof=on`: platform-authenticator passkey

When `device_proof=on`, the device credential is a **platform-authenticator passkey** created via WebAuthn. The `create()` options are **issued by the server** (`/sessions/webauthn/register/begin`, built by go-webauthn) and passed through by the client, which hard-codes none of them:

```js
await navigator.credentials.create({
  publicKey: {
    // rp comes from the server options; rp.id is the required config knob
    // proctoring_security.webauthn_rp_id (validated non-empty at startup).
    rp: { id: webauthnRpId, name: 'ZINC Proctoring' },
    user: { id: userIdBytes, name, displayName },
    challenge: serverChallenge,
    // go-webauthn's default credential parameters (no server override):
    pubKeyCredParams: [
      { type: 'public-key', alg: -7   }, // ES256
      { type: 'public-key', alg: -35  }, // ES384
      { type: 'public-key', alg: -36  }, // ES512
      { type: 'public-key', alg: -257 }, // RS256
      { type: 'public-key', alg: -258 }, // RS384
      { type: 'public-key', alg: -259 }, // RS512
      { type: 'public-key', alg: -37  }, // PS256
      { type: 'public-key', alg: -38  }, // PS384
      { type: 'public-key', alg: -39  }, // PS512
      { type: 'public-key', alg: -8   }, // EdDSA
    ],
    // Client-side preference only: the server sets no AuthenticatorSelection,
    // so it verifies neither the UV flag nor the attachment on register/login.
    authenticatorSelection: {
      authenticatorAttachment: 'platform',
      residentKey: 'preferred',
      userVerification: 'required',
    },
    timeout: 300_000, // go-webauthn default (5 min); not server-configured
  },
});
```

The resulting credential is discoverable (passkey), bound to the user's OS account on the exam machine, protected by Windows Hello / Touch ID / Android biometric / ChromeOS equivalent, and hardware-backed on devices with a Secure Enclave / TPM / StrongBox.

Under `device_proof=on`, `POST /v1/proctoring/sessions` still issues the first bearer (machinery byte-identical to the off path) but creates the row in state `pending_device_proof`; the response carries that `state` (there is no `next` field), and the client keys off it. The **pending bearer** carries no `cnf`; the capability gate keys off the session's `pending_device_proof` **state** (not a bearer claim), admitting the bearer only to WS attach/heartbeat and the WebAuthn begin/finish calls. The client runs the capability probe (below), then registers via `/sessions/webauthn/register/begin` + `/register/finish`, which stores the credential in the `webauthn_credential` table but neither advances the FSM nor mints a bearer. The session leaves `pending_device_proof` only on a **passkey assertion** (`/sessions/webauthn/authenticate`), which advances the state to `awaiting_attach` (or `awaiting_capture` under `identity_verification=enforced`) and re-mints a bearer on the same `session_id`; a `cnf == credential_id` claim first appears on a later re-mint, once the session is `admitted`/`physically_verified`. `admitted` is therefore unreachable until a passkey is bound; the enforcement is in code (the FSM edge table and the assertion path, which refuses with no stored credential, plus the admit CAS, which fires only from `awaiting_attach`), not prose. Subsequent assertions against the same `(user, activity)` must present the registered credential. Cancelling registration leaves the session `pending_device_proof`; the only escape is an audited staff **re-enroll** (still `device_proof=on`) or an audited activity-policy loosen to `device_proof=off` followed by re-enroll, not a silent per-student downgrade. Identity verification (R2) follows satisfaction of the device-proof precondition and does not itself depend on a stored credential.

### Lab-environment prerequisite (hard blocker, `device_proof=on` only)

This prerequisite applies **only when `device_proof=on`**. Platform-authenticator passkeys require a functioning platform authenticator on the exam machine; machines without one **cannot be used to take a `device_proof=on` exam**. There is no software fallback in the shipped product.

Under `device_proof=on`, pre-exam onboarding performs a capability probe (`PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()`) and hard-fails before the student reaches passkey registration if no platform authenticator is available. Lab-ops is responsible for guaranteeing coverage across the fleet; a survey of platform-authenticator availability across the target labs is a prerequisite before any `device_proof=on` activity moves to `published`. Under `device_proof=off` there is no probe and no platform-authenticator requirement; the corresponding deployment precondition is instead trustworthy closed-intranet isolation (see Known Limitations).

### Session bearer and rotation

The bearer substrate is identical across all eight cells: an extension-signed JWT, ≤ 10 min TTL. There is no `bearer_refresh` WS frame and no proactive ~8 min push: bearers are re-minted at **every WS attach** (carried on `attach_ack`) and on demand by the cookie-authed `POST /sessions/bearer/refresh`, which the client calls to self-heal on a `401`/`403`/`4001` and once at admission; there is no pre-expiry timer. The bearer is presented as the WS attach bearer and on any extension HTTP call. The bearer's identity binding is `(user_id, activity_id, session_id)` in both modes, where `session_id` is a server-assigned ULID on the row (in the JWT the `sub` is `user_id:activity_id` and `session_id` is a separate claim). The registered credential id appears as an **optional `cnf` claim**, present iff `device_proof=on` **and** the session is `admitted`/`physically_verified`. When `device_proof=on`, the passkey is not used to sign per-request or per-frame traffic and assertions are invoked only for reconnect, so user-verification prompts are rare. When `device_proof=off`, there is **no proof-of-possession on any request**; the `session_id` pin enforces single-active-session only; it is not a continuity or replay control.

**Bearer validation invariant.** One shared helper (`RequireProctoringBearer.Validate`) runs on the bearer-authenticated HTTP routes and on the **WS first `attach` frame**; later WS frames are not re-validated, and the LiveKit token route is not gated by this helper (it is cookie-authed with an in-handler admitted check). It reads the row for `(user_id, activity_id)` and evaluates clauses in this fixed order:

- **(a) Lock.** `locked_at IS NULL`, else `401` regardless of bearer freshness. Policy-independent; holds with `credential_id` NULL. This closes the up-to-10-minute window where a force-submitted student's existing bearer would otherwise remain valid.
- **(b) Session pin.** `bearer.session_id == row.current_session_id`, else `401` (single-active-session). A WS attach that rotates `session_id` thereby invalidates the prior bearer.
- **(d) Pending-device-proof gate, evaluated before (c).** If the row's `state == pending_device_proof`, the bearer is accepted only by the **bootstrap** middleware variant (the WS attach validator and the `/sessions/webauthn/*` routes); the standard variant (e.g. `/sessions/captures`) rejects it with `403`. There is no `device_proof_pending` bearer claim; the gate keys off the row state.
- **(c) cnf-per-frozen-policy, only when not pending.** If `policy_snapshot.device_proof == on` AND the session is `admitted`/`physically_verified`, require `cnf` present and matching the registered passkey credential id (absent or mismatch gives `401`); in any other state (including `pending_device_proof`) a `cnf` must be **absent** (present gives `401`). If `policy_snapshot.device_proof == off`, require `cnf` **absent**. The pending bearer (no `cnf`) is therefore never rejected by (c); (d) admits it, and (c) engages only once a passkey assertion has bound the credential and the session is admitted. A token cannot self-select the weaker validation path.
- **(e) Authz freshness, does not lock.** A short-TTL cached `enrolled` re-check (≤ 30 s) read alongside the row. As built it **fails closed**: a checker error, timeout, or definitive `enrolled` absence returns `403` on that request (review fix C1/F12), but it does **not** lock the row, force-submit, or mutate state. So a single authz read cannot irreversibly end an exam; mid-exam `enrolled` revocation is not acted on as a lock, and the existing bearer (and any LiveKit token) is bounded only by TTL, the accepted RFD 0011 TTL-window limitation (see Known Limitations), which this RFD does not close.

The WS-attach `session_id` rotation is a compare-and-set that re-reads `locked_at IS NULL` at the same lock, so it cannot emit a bearer that is already invalid under a concurrent reconnect; the on-demand `POST /sessions/bearer/refresh` re-sign, however, is a read-then-sign on the current `session_id` with no CAS, so a refresh racing an attach can mint a stale-`session_id` bearer; the client self-heals on the resulting `401`. Co-currency is **not** claimed as a bearer-theft bound: a mutating call is correlated with the attached socket for audit/eviction coherence only. The one attach-requiring mutating route is `{captures}` (`first_attached_at IS NULL` returns `409 needs_attach`); `/sessions` and the `/sessions/webauthn/{register,authenticate}/{begin,finish}` calls are bootstrap (exempt). The LiveKit token route is cookie-authed (not gated by this helper) and itself requires `admitted`, which requires a prior attach, so it is not attach-exempt. The bearer-theft bound is TTL + intranet + invigilation + audit.

### Re-establishment on reconnect

Session loss events (browser close, tab crash, machine reboot, or a network flap long enough to kill the TCP connection) are handled without invigilator involvement. The reconnect authorizer differs by mode; both paths enforce the lock (`locked_at IS NULL`) first: clause (a) on the attach bearer, and again inside the rotation CAS (there is no separate `RequireUnlockedSession` helper). A `401`'d client cannot re-mint past a terminal lock, and `session_id` rotates **during** the WS attach (in the CAS, before `attach_ack` is written), re-reading `locked_at` at that compare-and-set.

- **`device_proof=on`:** the student reconnects, then runs `/sessions/webauthn/authenticate/begin` + `/sessions/webauthn/authenticate`, consuming an assertion verified against the stored credential; on success a fresh bearer is minted on the same `session_id` (the `session_id` rotation happens at the WS attach, not in the assertion path). The passkey assertion is the reconnect authorizer.
- **`device_proof=off`:** the client re-calls the cookie-authed `POST /v1/proctoring/sessions`, which recovers the existing session with a fresh bearer on the same `session_id`; the `session_id` rotation happens at the subsequent WS attach.

Admission, verification, and `policy_snapshot` persist across the reconnect. Because the WS attach rotates `session_id`, the single-active-session pin is universal: the first client to attach rotates `session_id` and thereby **invalidates any other live bearer**, so at most one attached session exists at a time. The pin enforces single-active-session, not replay protection: it makes a cookie replayer's takeover visible (the displaced socket is dropped and the eviction is written to the audit log), but it does not detect a co-current stolen **bearer**. Note the as-built `POST /sessions` recovery re-issues a bearer on the **same** `session_id` and returns `200` (there is no `409 session_active` refusal), so a second cookie-holder can obtain a co-current bearer until one of them attaches and rotates `session_id`; the RFD's original "read-only takeover is closed at the source" guarantee (a `POST /sessions` refusal, takeover only via `/resume`) is **not** as-built and is listed for ratification. There is no alerting or escalation machinery beyond that audit record.

The student loses access mid-exam through an invigilator-issued `force_submit` (terminal, via `locked_at`), and also through the reversible suspend causes (`collection_closed`, `room_ended`) and a staff **dismissal**; all are covered in the Lock Recovery section (R5).

### Cross-device sync (`device_proof=on` only)

This concern exists **only when `device_proof=on`**. iCloud Keychain and Google Password Manager sync passkeys across a user's devices by default. This is not exploitable in our threat model because the exam origin is reachable only from the closed lab intranet: a synced passkey on a student's phone on mobile or home Wi-Fi cannot reach the exam host. The intranet isolation established in RFD 0011 is what makes the cross-device sync property tolerable; without it, this would be a hole. Under `device_proof=off` there is no passkey to sync; the analogous secret is the session cookie, whose replay is bounded by the same closed-intranet isolation plus the attach-time `session_id` rotation (the first client to attach invalidates any other live bearer) and physical invigilation (see Known Limitations).

## Identity Verification (R2)

Identity verification has two independently-set properties: **whether it runs** (a per-activity policy, so it can be turned off) and **when the verdict lands**, which is asynchronously, during the exam. Under the default `enforced` policy, completing the webcam captures is a **precondition for entering the exam**; the asynchrony is in the invigilator's *verdict* (reached at any point in the exam window), not in the *capture*, which happens up front. A deployment that verifies students by other means (a physical ID check at the lab door) sets the policy to `disabled`, and the capture step disappears.

Gating entry on capture submission removes the "just never upload" loophole without reintroducing a synchronous review bottleneck: the capture step is **automated by the client** (live preview, freeze, upload) and needs no invigilator in the loop, so entry is gated on an automatic upload completing, not on a human decision. The invigilator's judgement is still applied asynchronously (against the captured stills plus the live camera), and a failed verification leads to disqualification regardless of when it is noticed. There is thus no authorization decision to pre-compute, only an evidence-gathering and audit obligation.

### The `identity_verification` knob

Identity verification is the `identity_verification` knob of the unified `proctoring_policy`, carried per activity and resolved behind the one `PolicyProvider` interface (`PolicyForActivity`), which returns the frozen `PolicySnapshot` (there is no `ProctoringPolicy` or `VerificationPolicy` interface). Its value is read from the **frozen** `policy_snapshot` on the session row at every per-session gate:

- **`enforced`**: the student must upload both captures, or be manually admitted (below), to reach `admitted`/`physically_verified`. Captures are reviewed asynchronously.
- **`disabled`**: no captures are requested, no review queue is populated, and admission is reached as soon as the device-proof precondition (if any) is satisfied. For deployments that verify identity physically.

The enum is open to extension (a future `optional` mode that captures but does not gate). This knob scopes only the verification layer; `device_proof` and `live_media` are orthogonal. Admission is gated on the **admitted state**, not on "the client obtained a LiveKit token". Content releases via the core `IsAdmitted` pull (see Coordinating with the examination extension) in every cell, and the LiveKit token is a media-plane artifact consumed only when `live_media=on`. The former wording "entry is gated on passkey registration (R1) alone" is replaced: under `device_proof=off + identity_verification=disabled` the row is created `awaiting_attach` and the gate is the admitted state reached only after the WS attach, released to a **live attached session** (see Lifecycle). Under `disabled`, none of the capture endpoints, object-storage paths, or review frames in this section are exercised.

### Capture flow (policy `enforced`)

Once the device-proof precondition is satisfied (immediately when `device_proof=off`; after `/register` when `device_proof=on`) and before the session reaches `admitted`, the client auto-prompts the student for two captures:

1. **ID photo.** The client prompts the student to hold their physical student / national ID up to the webcam. Live preview, student clicks *Capture* to freeze a still frame. Client-side downsized and JPEG-encoded at ~85% quality; target payload ~150 KB.
2. **Face snapshot.** Same preview, no ID. A separate still frame of the student's face.

Both images are POSTed to `POST /v1/proctoring/sessions/captures` (which requires the socket be bearer-attached, returning `409 needs_attach` otherwise). The extension streams each upload straight to the object store, records a per-kind capture row (`id`, `face`) with its object key and `captured_at`, and advances the session to `awaiting_attach` (it becomes `admitted` only after the WS attach); the `capture_uploaded` frame is reserved but not yet emitted, so invigilators refresh their review queue via a roster re-poll. `admitted` (or `physically_verified`) is the **first-class fact** every consumer keys off: it makes the core `IsAdmitted` pull return true (content release, all cells) and, when `live_media=on` and `room_ready`, satisfies the student-branch token precondition (media). Under `identity_verification=enforced` a student still `awaiting_capture` is not admitted, so `IsAdmitted` returns false and, when `live_media=on`, `POST /v1/proctoring/rooms/:room_id/tokens` rejects the student branch.

Upload failure is surfaced to the student as a retryable error. Because capture gates entry, a student who cannot capture (no working webcam, ID left at home, or persistent upload failure) is admitted through the manual gate below rather than blocked. There is no capture deadline and no automatic "uploads missing" timer; a human makes the call when capture does not happen.

### Manual admission gate

The capture requirement has a human override. An invigilator with `can_proctor` on the room admits a specific student who has not captured (checked physically at the lab, or webcam broken). The invigilator calls the manual-admit route (`POST /rooms/:room_id/sessions/:user_id/manual-admit`) with a **required** free-text reason; the extension records the decision (invigilator identity, reason, timestamp) in the audit log, sets the student's admission state to `physically_verified`, and the student may then obtain a LiveKit token exactly as an `admitted` student would.

A `physically_verified` student is **exempt from capture and from the review queue**: there is nothing to review, and the audited manual-admit record is the verification artefact. This is the only override of the capture gate: there is no automatic admission and no deadline-based fallback, so admitting a student without a capture is an accountable human decision.

### Invigilator review

Invigilators see a review queue keyed on the **stable** `(user_id, activity_id)` (never `session_id`, so a reconnect's `session_id` rotation never detaches an open review entry), alongside the per-student spot-check surface from RFD 0011. The review surface degrades cleanly with the `live_media` knob, which the client reads from `policy_snapshot.live_media` carried in `session_state`:

- **`live_media=on`:** opening a queue entry auto-subscribes to the student's LiveKit camera publication via `setSubscribed(true) + setVideoQuality(MEDIUM)`, rendering a three-up layout (**captured ID photo | captured face snapshot | live camera**), so the decision is informed by the person currently at the machine. The surface auto-unsubscribes on close to honor RFD 0011's idle-is-signalling-only Dynacast property. If the student's camera is not currently published (not yet joined LiveKit, reconnecting), the live tile shows a placeholder and the invigilator may defer or decide on the stills alone.
- **`live_media=off`:** there is no LiveKit publication; the client never calls `setSubscribed` and renders a **stills-only two-up** layout (**captured ID photo | captured face snapshot**). Because a substituted still cannot be cross-checked against a live face, the invigilator must lean on the physical door-check for a terminal decision; in the console, disqualify ("Lock session") is a generic destructive confirmation carrying no reason and is **not** conditioned on `live_media`, and `mark_suspicious` remains freely available.

Outcomes:

- **Mark verified.** Records the decision in the audit log and clears the student from the queue. No effect on the student's exam state.
- **Flag suspicious.** The non-destructive escalation, and the expected first response to a doubtful match. It does **not** end the student's exam: the extension records the flag (invigilator identity, reason), holds the student's captures via a `held` boolean toggle on the active capture rows (it does not relocate an object), and surfaces the entry as `suspicious` for a second reviewer or a post-exam decision. It is **silent to the student** (no client frame), so a possibly-innocent student is neither tipped off nor disrupted. A suspicious flag is reversible (back to `verified` or `unreviewed`, releasing the hold); disqualification is not. This is the guard against false positives: doubt is recorded and the evidence preserved without irreversibly ending an exam.
- **Disqualify.** The deliberate terminal action. Sets `locked_at` on the student's session (the revoke reason is `invigilator`; there is no distinct `identity_verification_failed` reason value or separate disqualify action); once `locked_at` is set, core's fail-closed `IsAdmitted` gate stops serving content (see R4). Because it is irreversible, the invigilator UI requires an explicit confirmation, and the recommended workflow is to flag suspicious first and disqualify only on a confirmed second look. Audited as usual.
- **Request re-capture.** *(Not implemented as built.)* The design would issue a `reverify_required` frame so the student re-captures; that frame and channel were dropped and are not on the wire. Captures are retained immutably for audit; a re-capture does not mutate a prior object, and the prior capture row is marked with a `superseded_at` column (there is no `superseded/` object prefix).
- **Defer.** Leaves the queue entry open. Intended as a "come back to this"; the entry remains visible until exam stop.

There is no ML face matching and no automatic disqualification: every terminal decision is a human one. The photos and live camera are evidence; the invigilator's judgement, expressed through the suspicious-then-disqualify path, is the decision.

### Object storage

Captured images are stored in a dedicated object-store bucket, separate from academic artefacts:

- **Bucket**: `proctoring-captures` (or equivalent per deployment). Public access blocked at the bucket-policy level. Bucket-level encryption (SSE-S3 / SSE-KMS) is permitted as defense in depth but is **not** relied on for confidentiality; confidentiality is provided by application-level envelope encryption (see Encryption below). The design must be portable across object stores that do not offer equivalent server-side features.
- **Key layout** (flat and immutable; a capture's blob is written once at its key and not relocated):
  ```
  captures/{activity_id}/{session_db_id}/{capture_kind}/{capture_id}.bin
  ```
  Keyed by the `proctoring.session` row id (`session_db_id`), not `user_id`, with a `.bin` body (not `.jpg`). There are **no** `superseded/` or `held/` object prefixes; supersede and hold are DB-only (`superseded_at` and `held` columns on `proctoring.capture`). `capture_kind` is `id` or `face`. `capture_id` is the server-assigned `proctoring.capture` integer primary key (`BIGSERIAL`, globally unique), not a ULID.
- **Upload path**: client to extension to object store, not a direct client-to-object-store upload. The extension acts as a broker so that (a) caller identity is authoritative via the session bearer, not bucket IAM, (b) size and content-type validation happens before the object lands, and (c) a single audit entry covers the upload. Payloads are small enough (~150 KB × 2) that the extra hop is immaterial.
- **Read path**: extension-mediated. The invigilator client hits `GET /v1/proctoring/sessions/:user_id/captures/:kind`; the extension authorizes (`can_proctor`), fetches the wrapped DEK from the session table, unwraps via the KMS interface, fetches the ciphertext object, decrypts in-memory, and streams plaintext with `Cache-Control: no-store` and `Pragma: no-cache`. The invigilator page must set a Content-Security-Policy restricting `img-src` to `'self'` so captures cannot be sourced from third-party origins, and the client should render captures via short-lived blob URLs rather than leaving the response URL in the DOM. No direct bucket access is granted to end users; signed URLs are not used.
- **No export surface**: no bulk download, no admin-console "view all" path. Images are viewable only in the context of a specific student's review entry.

#### Encryption

The captures are PII; we don't want them readable from object-store credentials alone, and we don't want to depend on a specific object store's encryption-at-rest feature. The proctoring extension therefore encrypts captures before upload and decrypts on read. The object store sees opaque bytes; the same design works on S3, MinIO, R2, GCS, Azure Blob, etc.

**Envelope shape.** Each capture has its own 256-bit DEK that encrypts the JPEG; a long-lived KEK wraps the DEK. The wrapped DEK lives in the extension's Postgres row alongside the capture pointer; the object body holds only ciphertext + a small format header. Compromising the object store alone does not yield plaintext; Postgres access is also required. This split assumes the two systems have **distinct credential planes**; deployments that share credentials between them should not rely on it.

**Cipher.** XChaCha20-Poly1305 (RFC 8439-extended) for new captures, an AEAD whose 192-bit nonce tolerates random generation at any practical volume. AES-256-GCM is supported as a compliance fallback (FIPS-required deployments) and selected via the format's `cipher_id` byte.

**Identity binding.** The AEAD's authenticated-data input commits each ciphertext to its `(activity_id, user_id, capture_kind, capture_id, kek_version)`. A ciphertext copied to another student's slot, or read under a downgraded KEK version, fails the auth tag at decrypt. The identifiers are fixed-width integers and the `capture_kind` is length-prefixed, so the concatenated AAD is unambiguous without a separator.

**On-disk format.** Custom binary, not JOSE/JWE: there is no interop boundary, and JWE compact serialization would inflate blobs by ~33% from base64url for no benefit in a single-application pipeline.

```
magic ("ZPC1", 4) | format_version (1) | cipher_id (1) | nonce (N) | ciphertext + 16-byte tag
```

**KEK.** Pluggable behind a `KeyManagementService` interface. Default implementation keeps the KEK as a 256-bit secret in the deployment's secret manager (Vault static, K8s Secret, env var) and wraps in-process, with no external KMS dependency, which matters for portable / small deployments. Recommended for production: HashiCorp Vault Transit (KEK never enters extension memory). AWS KMS, GCP KMS, Azure Key Vault are also pluggable; none are required.

**Rotation.** `kek_version` is monotonic; new uploads use the current version, old versions stay loadable for legacy reads. Re-wrapping historical rows touches Postgres only, not object bodies; this is cheap relative to re-encrypting JPEGs but still a long-running batch in any sizeable cohort. A version may be retired only after no row references it; retiring early is a data-loss event.

**Read path.** Extension-mediated, replacing the earlier signed-URL design. `GET /v1/proctoring/sessions/:user_id/captures/:kind` authorizes via `can_proctor`, fetches the wrapped DEK from the row, unwraps via the KMS interface, fetches the ciphertext, decrypts in-memory, and streams plaintext with `Cache-Control: no-store`. A single audited path keeps the access trail clean and lets the read inherit existing CSP / blob-URL discipline on the invigilator client.

### Cleanup strategy

Two-tier retention, implemented primarily by **object-store lifecycle rules** rather than an extension-managed sweep job. This keeps the extension stateless with respect to long-term PII retention and delegates the deletion guarantee to the storage layer:

| Object set                        | Lifecycle rule                          | Rationale                                                                       |
|-----------------------------------|-----------------------------------------|---------------------------------------------------------------------------------|
| all capture objects (`captures/{activity_id}/{session_db_id}/**/*.bin`) | Delete **30 days** after object creation | Active-review + short post-exam appeal window                                   |
| superseded captures | flagged in the DB (`superseded_at`); **no separate object prefix**, so they share the flat key above | Retained for audit of the re-capture decision                   |
| held captures       | flagged in the DB (`held`); **no separate object prefix**                   | Suspicious-flag evidence or explicit investigative hold |

Because supersede and hold are DB flags and no capture object is relocated, the prefix-scoped retention scheme this section proposed (a `held/` prefix held exempt from the delete rule) is **not instantiated** as built; no in-repo code deletes capture objects either; retention is a deployment-layer concern. Reconciling the hold-evidence exemption with the flat immutable keyspace is listed for ratification. A "hold" (triggered either by an explicit investigative hold or by a **flag-suspicious** review outcome) sets the `held` boolean on the session's **active** capture rows (`superseded_at IS NULL`); it does not enumerate a user prefix or relocate any object, and it does not newly hold already-superseded captures. A hold is released by clearing the flag; there is no automatic expiry, because investigations run on their own timelines. Each hold and release is audited with reason and owning case id.

**Why 30 days, not 90**: the original 90-day window was sized for institutional appeals. With async verification, the appeal window isn't blocked on review completion; reviews are finished during the exam itself, and post-exam disputes are against the *decision*, not the captures. 30 days is sufficient to cover the common review-and-dispute cycle; longer investigations use the explicit hold.

**Why object-store lifecycle, not an extension sweep**: lifecycle rules are declarative, provider-enforced, and survive extension outages. An extension-managed sweep would duplicate the guarantee less reliably. The extension's role is limited to (a) uploading each capture at its immutable key and (b) toggling the DB `held` / `superseded_at` flags; all are synchronous, with no background jobs and no object moves. Deletion is entirely the object store's responsibility.

**Access logging**: every capture read (caller, subject, capture kind, `kek_version`, decrypt outcome) and every hold/release action is written to the extension's audit stream.

**Logging discipline**: the extension must never log image bytes, plaintext DEKs, KEK material, or bucket keys to any standard log sink. The audit stream is the only record.

**Deletion on student request** during the retention window is not supported; retention is bounded by exam administration policy, not student preference. Documented as a trade-off.

## Control Channel (R4)

### Transport

A single WebSocket per client session, mounted at `WSS /v1/proctoring/ws`. The **student socket is bearer-first**: there is no pre-bearer cookie connect for students; the student's first frame must be an `attach` carrying the freshly-minted bearer, which the extension validates with the **full validation invariant** (clauses (a)–(e), including `bearer.session_id == row.current_session_id`) and, on success, binds to the (rotated) `session_id` via the `session_id` rotation CAS. Only the **invigilator socket is cookie-authorized**; the extension reads the cookie only for the invigilator role. A socket with no successful attach within the pre-registration timeout is reaped. Steady-state authentication uses the session bearer; the socket is bidirectional: clients send, the extension sends, both over the same framing.

**LiveKit data channels are not used for control.** RFD 0011's `CanPublishData: false` grant on both students and invigilators is preserved to reinforce the invariant that every control message is audited by passing through the extension. Using the LiveKit data plane would either bypass the audit trail or require the extension to double-record events already delivered by the SFU.

### Frame schema

Every frame is a JSON object with a `type` discriminator and a `seq` for ordering. Server-originated frames carry `server_seq`; client-originated frames carry `client_seq`. The extension echoes applied frames with a `server_seq` to allow idempotent reconnect.

Every frame carries an `applies when` constraint so no frame can be emitted in a cell where it has no meaning (constraint D). Frames in scope for this RFD:

| Direction              | Type                    | Applies when      | Purpose                                                                      |
|------------------------|-------------------------|-------------------|------------------------------------------------------------------------------|
| client → extension     | `attach`                | all cells         | WS hello carrying the freshly-minted bearer; binds the socket to `session_id` only after the full validation invariant passes |
| extension → student    | `attach_ack`            | all cells         | Attach accepted; carries the rotated `session_id` and re-minted bearer       |
| extension → student    | `admitted`              | all cells         | Admission granted / content released                                         |
| extension → student    | `session_locked`        | all cells         | The **sole** terminal/blocked frame; `{reason}` ∈ `invigilator` \| `collection_closed` \| `room_ended` \| `dismissed` (the client keys its copy off `reason`) |
| extension → student    | `session_reinstated`    | all cells         | The reconciler restored a suspended session; `{state}` = the restored admission state |
| extension → student    | `policy_update`         | all cells         | The activity policy was re-applied to this live session (opt-in `apply_to_active`); durable |
| extension → student    | `session_expiring_soon` | all cells         | The session bearer/window is nearing expiry                                  |
| student → extension     | `heartbeat`            | all cells         | Liveness ping                                                                |
| extension → student    | `heartbeat_ack`         | all cells         | Liveness pong                                                                |
| student → extension     | `raise_hand`           | all cells         | Student requests clarification; body carries a short text                    |
| student → extension     | `lower_hand`           | all cells         | Student withdraws a raised hand                                              |
| extension → student    | `hand_ack`              | all cells         | Server-confirmed hand state `{state, origin}`                                |
| extension → student    | `hand_rate_limited`     | all cells         | An inbound hand action was dropped by the per-user budget                    |
| extension → student    | `announcement`          | all cells         | Staff broadcast; durable                                                     |
| extension → student    | `private_message`       | all cells         | Invigilator DM reply to this student; durable                               |
| student → extension     | `ack`                  | all cells         | Acknowledge a server frame by `server_seq` (advances the replay watermark)   |
| extension → invig.     | `session_state`         | all cells         | Per-student admission/verification/presence/hand state for the review queue  |
| extension → invig.     | `session_locked_echo`   | all cells         | Staff-visible echo of a student `session_locked`                            |
| extension → invig.     | `student_flagged`       | all cells         | An attention flag was raised                                                 |
| extension → invig.     | `assignment_changed`    | all cells         | Invigilator-dashboard roster advisory                                        |
| extension → invig.     | `hand_resolved`         | all cells         | A hand was resolved (cross-console clear)                                     |
| extension → invig.     | `student_message`       | all cells         | A student's durable chat message (two-way chat)                             |
| extension → invig.     | `messages_seen`         | all cells         | An invigilator marked a student's chat thread seen                          |
| extension → invig.     | `announcement_read`     | all cells         | A student acknowledged an announcement (read receipt)                       |
| extension → invig.     | `capture_uploaded`      | `identity_verification=enforced` | **Reserved** wire type; a capture landed, not yet emitted (invigilators re-poll the roster) |
| internal (control bus) | `admission_eligible`    | all cells         | Server-internal nudge: an HTTP gate-clear advanced a session toward admission; the replica holding the live socket re-runs the admission decision |

Invigilator-authored actions are **HTTP routes**, not WS frames. The extension audits each and fans the resulting student/invigilator frame: compose-an-announcement is `POST /activities/:activity_id/announcements`; a private reply is `POST /rooms/:room_id/sessions/:user_id/messages`; an invigilator force-submit is `POST /rooms/:room_id/sessions/:user_id/lock`; a verification verdict (`verified` / `suspicious`) is `PUT /rooms/:room_id/sessions/:user_id/verification`; a manual admit is `POST /rooms/:room_id/sessions/:user_id/manual-admit`. The `bearer_refresh`, `session_status`, `session_snapshot`, extension-to-student `force_submit`, `reverify_required`, `force_reverify`, `capture_hold`, `capture_hold_release`, and `session_ended` frames of earlier drafts do **not** exist as built: bearer refresh is the HTTP `POST /sessions/bearer/refresh`; admission and content release are signalled by `admitted` (plus `policy_update`); the terminal signal to the student is `session_locked`; and the reverify and capture-hold channels were dropped.

The live-camera three-up subscription in invigilator review is a **`live_media=on`-only** behaviour; under `live_media=off` the review surface degrades to stills-only (the client reads `policy_snapshot.live_media` from `session_state` and never calls `setSubscribed`). Single-active-session eviction is not its own frame: a displaced socket is dropped and the eviction is recorded in the audit log.

Disqualification is not its own frame type; the terminal signal to the student is `session_locked` with `reason: invigilator`. There is no `force_submit` frame and no `identity_verification_failed` reason value. `mark_suspicious`, the reversible `suspicious` verification verdict (the `PUT .../verification` route), is the non-terminal alternative that records doubt and holds the evidence without ending the exam, and is the expected first action before any disqualification.

### Auditing

The extension persists every invigilator-authored frame and every admission decision to a durable audit log before emitting the corresponding client frame. This includes the full text of announcements and private replies, the subject and reason of force-submit / force-reverify, and the invigilator identity. The audit record is the canonical record, not any frame the client saw; discrepancies between what the client received and what was audited are discarded in favour of the audit.

Student-authored frames (`raise_hand`, `ack`) are also audited. Acknowledgements are not stored verbatim; the highest acknowledged `server_seq` per session is retained.

### Coordinating with the examination extension

`examination` is a sibling extension (per RFD 0009); the proctored `kind=exam` activity row itself lives in core. RFD 0009 keeps core as the orchestrator, but there is no `activity.started` subject; proctoring anchors on submission-owned events (`submission.events.collection.closed`) and resolves the roster via `submission.requests.activity_roster` / `activity_state`. Two coordination contracts live here, both consistent with that direction; both reach into core and **require the core/RFD 0009 owner's ratification** (subject names, timeout, fail-closed semantics).

**Content release: core-driven pull (requires core-owner sign-off).** Proctoring exposes the admitted fact as an extension-owned, queryable resource: a synchronous request-reply `IsAdmitted(user_id, activity_id) -> {admitted, error}` over NATS (no HTTP equivalent), answered from the durable session row (level-triggered, not edge-triggered; idempotent on re-query). Core, on its **own** exam-content path for a proctored activity, calls `IsAdmitted` as a precondition before serving questions and **fails closed** when not admitted, re-checking on a heartbeat. This is a small read-dependency core adds, **not** a control-flow inversion and **not** a durable subscriber: core stays the orchestrator, proctoring owns the gated fact. This makes the entry gate extension-owned (constraint C) in **every** cell; the LiveKit token has no content-gating role in any cell. Core latches on the stable `(user_id, activity_id)`, not the rotating `session_id`. An advisory `proctoring.events.session.admitted {user_id, activity_id, session_id, ts}` is also published as telemetry so core can pull promptly, but correctness rests on the pull, so a lost/duplicated advisory cannot leak or wrongly gate content.

**Terminal signal: one subject, observability-only.** The terminal NATS subject is `proctoring.events.session.revoked {user_id, activity_id, session_id, reason, ts}` (replacing the former `proctoring.force_submit`), where `reason` is `invigilator` | `collection_closed`. As built it is **observability-only**: it carries no `action` or `terminal_seq` field and no longer gates submission; the lock's authority is the `locked_at` row read by core's `IsAdmitted` request-reply. Force-submit therefore proceeds as: (1) an invigilator issues a force-submit (the HTTP lock route); (2) the extension audits, sets `locked_at` locally (so the bearer `401`s immediately) and writes a durable `session_locked` frame, then publishes `proctoring.events.session.revoked`; (3) the extension fans `session_locked` to the student's WS so the client UI reflects the lock; (4) core's next `IsAdmitted` heartbeat returns not-admitted and its content path stops serving. Delivery is best-effort; because the `locked_at` row is the source of truth, a lost or duplicated event cannot split disqualify vs benign-revoke semantics. The proctoring lock stops content release; committing the student's staged delivery ("submit") remains the examination activity's responsibility, and this RFD guarantees the audit trail and the fail-closed pull gate.

## Authorization Model

RFD 0011 introduced `proctoring_room`; as built it is re-parented under a new `proctoring_activity` type, and membership is not anchored on `examinee` ("can read the questions, not is in this exam session"). This RFD's media-independent session anchor is **not** a new OpenFGA type: enrollment is a DB `proctoring.assignment` existence check, and the proposed `proctoring_session`/`enrolled` OpenFGA type was retired. The OpenFGA proctoring types as built:

```
type proctoring_activity
  relations
    define parent: [activity]
    define chief: [user]
    define can_edit: [user] or chief or can_edit from parent
    define can_view: [user] or chief or can_read from parent

type proctoring_room
  relations
    define parent: [proctoring_activity]
    define student: [user]
    define can_proctor: [user] or chief from parent or can_edit from parent
```

Enrollment is a `proctoring.assignment` row read as a fail-closed DB existence check (`CheckProctoringAssignmentEnrolled`), **not** an OpenFGA tuple. It is written by the staff assignment routes (`can_edit`) or projected from the `submission_collection` participant set (`ReconcileAssignmentsForActivity`), kept in sync on every `collection.*` nudge plus a periodic sweep, and read at the session-create gate. It exists in **every** cell, including `live_media=off` where no room is created. The RFD 0011 `student@proctoring_room` tuple is **media-plane membership** consumed only by the `live_media=on` token route; when a room is created, RFD 0011 derives its per-room `student` tuples from this same enrollment set. Amending RFD 0011's "`student` is the single source of truth for room membership" to this two-plane model (enrollment = session/content, `student` = media), and deriving `student` from enrollment at room creation, are **normative RFD 0011 edits requiring the RFD 0011 owner's ratification**. Enrollment is **authorization**; the passkey device binding provides **continuity**, forgone under `device_proof=off`.

The unified `proctoring_policy` (`device_proof`, `live_media`, `identity_verification`) lives per **activity** (`activity_config.policy`, keyed `activity_id`) in the proctoring extension's Postgres, resolved via the `PolicyProvider.PolicyForActivity` interface (there is no `ProctoringPolicy` or `VerificationPolicy` interface). There are exactly **two** resolution points and they never cross: (1) the **live** activity policy is read only at room-creation / enroll time (gating whether a LiveKit room may be created and writing the enrollment row); (2) a **frozen `policy_snapshot`** resolved once at session create drives **every** per-session gate (token precondition, `IsAdmitted` answer, frame applicability, validation). Freezing prevents a mid-exam policy edit from moving a live session between cells; the only sanctioned per-session transition is an audited, loosen-only, reason-required staff re-enroll.

The extension maintains the session table alongside the RFD 0011 cache sidecar, keyed on `(user_id, activity_id)`:

- `session_id`: server-assigned ULID (`UNIQUE`); the single-active-session pin, carried as a separate `session_id` bearer claim (the JWT `sub` is `user_id:activity_id`).
- passkey credential: **not** a column on the session row: passkeys live in `proctoring.webauthn_credential` keyed `(user_id, activity_id)` (`credential_id BYTEA UNIQUE`). The device-proof phase is expressed by the `pending_device_proof` state instead.
- `policy_snapshot`: the three knobs frozen at create (jsonb).
- `state`: the ordered onboarding states are `pending_device_proof` (`device_proof=on`), `awaiting_capture` (`identity_verification=enforced`), `awaiting_attach`, then `admitted` or `physically_verified`; the reversible blocks `suspended` and `dismissed`; and `locked` (terminal). The explicit `awaiting_attach` gate precedes `admitted`/`physically_verified`. While `device_proof=on` the state advances out of `pending_device_proof` only on a passkey assertion, so `admitted` is unreachable until the passkey is bound.
- (no `basis` column): the manual in-edge is recorded by the `manually_admitted_by` / `manually_admitted_at` markers, and the admit CAS lands `physically_verified` (manual) vs `admitted` by a `CASE` on that marker; the auto-vs-captures distinction is implied by the policy snapshot and the capture rows.
- (no `admission_epoch` column): the only monotonic per-session counter is `server_seq_counter`, which orders WS frames for replay.
- `verification_status`: the per-session review outcome `unreviewed` / `verified` / `suspicious`. Captures themselves are rows in `proctoring.capture` (`capture_kind` ∈ `id`/`face`, `captured_at`, `superseded_at`, `held` boolean; one active row per kind); `superseded`/`held` are capture columns, not review-outcome values.
- `locked_at`: set with a reason on the revoke (force-submit / staff-terminate) and on the reversible suspend/dismiss; a `suspended`/`dismissed` row keeps it set but is recoverable, while `locked` is terminal. It is enforced by validation clause (a) and is policy-independent.

The entry gate targets the **admission state**, not a LiveKit token. `IsAdmitted` returns true iff `state in {admitted, physically_verified}` AND `first_attached_at IS NOT NULL` AND `locked_at IS NULL` (fail-closed on any read error), in every cell. The token route (`POST /v1/proctoring/rooms/:room_id/tokens`) retains RFD 0011's relation dispatch and grants; on the **student branch only** it gains, under `live_media=on`, the preconditions `policy_snapshot.live_media == on` (frozen) + `state in {admitted, physically_verified}` + `room_ready == true`. The invigilator (`can_proctor`) branch is unchanged from RFD 0011: invigilators have no session row and are not gated on admission. These student-branch token-route preconditions are **new** machinery vs RFD 0011 (which has no admission gate today) and **require the RFD 0011 owner's ratification**. Existing `can_proctor`/`can_edit` inheritance, invigilator-WS per-call authorization, and extension-mediated capture reads are unchanged.

`can_proctor` inherits `can_edit` via the `proctoring_activity` parent (plus direct `[user]` and `chief` arms). The invigilator WS is receive-only (heartbeat); invigilator **actions are REST routes** (lock, manual-admit, messages, verification, incidents, door-close/end/open/reopen), each authorized per-call against `can_proctor` on the target `:room_id`. Capture reads (`GET /v1/proctoring/activities/:activity_id/sessions/:user_id/captures/:kind`) are authorized per-call against `can_view` on the `proctoring_activity`; reads are extension-mediated and decrypted in-process, not served via signed URLs.

## End-to-End Lifecycle

1. **Sign-in.** Student signs in to `ui-v2` as usual and opens the exam (the client app's index route), which resolves proctored-ness via `GET /proctoring/activities/:id/proctoring-status` and dispatches to the proctored flow in-page. There is no student `/activities/:id/proctored` route; that path exists only in the staff console.
2. **Capability probe (`device_proof=on` only).** Client calls `PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()`. No: hard fail screen, exam not takeable on this machine. Yes: proceed. **Skipped when `device_proof=off`.**
3. **Create session + first bearer (all cells).** Client calls the cookie-authed `POST /v1/proctoring/sessions` (enrollment DB check). Extension freezes `policy_snapshot`, mints `session_id`, and issues the first bearer, and returns the session `state`.
4. **Attach the control WS.** The student socket is **bearer-first**: there is no pre-bearer cookie connect. Client opens `WSS /v1/proctoring/ws` and sends the `attach` hello carrying that bearer; the extension runs the full validation invariant and, on success, binds the socket to the (rotated) `session_id`. By policy:
   - `device_proof=on`: row is `pending_device_proof`. The client registers a passkey (`/sessions/webauthn/register/begin` + `/register/finish`) then asserts (`/sessions/webauthn/authenticate`), which advances the FSM out of `pending_device_proof` and re-mints the bearer. Then proceeds by `identity_verification`.
   - `device_proof=off`: no passkey; the row starts at `awaiting_capture` or `awaiting_attach`.
   - `identity_verification=disabled`: the row is created `awaiting_attach`; `IsAdmitted` returns true only **after** the `attach` completes, so content is not released to a session that has not attached.
   - `identity_verification=enforced`: `awaiting_capture`.
5. **Identity captures (`identity_verification=enforced`).** Client auto-prompts for ID photo and face snapshot. Student completes both; client POSTs to `/v1/proctoring/sessions/captures` (socket must be attached). Extension streams each to object storage and advances the session to `awaiting_attach` (it becomes `admitted` after the WS attach); the `capture_uploaded` frame is reserved but not emitted, so invigilators re-poll the roster. A student who cannot capture is instead admitted by an invigilator via the manual-admit route, reaching `physically_verified` (see step 11).
6. **Content release + optional media.** Core, on its own exam-content path, calls `IsAdmitted` (a contract requiring core-owner ratification) and serves questions once the session is `admitted`/`physically_verified`, in **every** cell. When `live_media=on` and `room_ready`, the client additionally requests a LiveKit token via RFD 0011's `POST /v1/proctoring/rooms/:room_id/tokens` (student branch; rejected while still `awaiting_capture` or `pending_device_proof`, or with `409 media_not_ready` until a room exists) and publishes camera / microphone / screen as RFD 0011 specifies. When `live_media=off` no token is requested and no media UI is rendered; content release is unaffected.
7. **In-exam control.** Invigilator broadcasts announcements, handles raise-hands, and spot-checks media per RFD 0011. All non-media interaction flows over the WS.
8. **Async verification review.** At any point during the exam, invigilators work through the review queue (HTTP verdict / lock routes). Outcomes: a `verified` verdict (queue clears, no student-visible effect), a `suspicious` verdict (non-terminal flag; captures held, student undisturbed), a lock / disqualify (sets `locked_at`, reason `invigilator`; confirmation-gated), or deferred. There is no `force_reverify` re-capture channel as built.
9. **Bearer rotation.** There is no server-pushed `bearer_refresh` and no fixed cadence: the bearer TTL is 10 min, and the client re-mints on demand via the cookie-authed `POST /v1/proctoring/sessions/bearer/refresh` (on a `401` self-heal, after a `policy_update`, and once at admission); the bearer is also re-minted at every WS attach. No user interaction.
10. **Browser crash / reconnect.** Student reopens the exam. By mode. `device_proof=on`: the client runs a passkey assertion (`/sessions/webauthn/authenticate`), which the extension validates against the stored credential, advances the FSM if needed, and re-mints a bearer. `device_proof=off`: the client re-calls the cookie-authed `POST /v1/proctoring/sessions`, which recovers the session with a fresh bearer. Either way the WS `attach` rotates `session_id` (invalidating any other live bearer). Admission, captures, verification, and `policy_snapshot` persist. A reconnect that displaces a still-live socket drops the incumbent and is recorded in the audit log; short of an invigilator lock or a suspend / dismiss cause there is no involuntary loss of access. No invigilator involvement otherwise.
11. **Manual admission.** A student whose capture cannot complete (broken webcam, persistent upload failure, ID left at home) is verified in person; an invigilator issues a manual admit (via `POST /rooms/:room_id/sessions/:user_id/manual-admit`) with a reason, the extension audits it and sets the session `physically_verified`, and the student proceeds to step 6. There is no automatic deadline or `captures_missing` timer; admitting without a capture is a human call.
12. **Raise hand.** Student sends `raise_hand`. Invigilator WS receives it, invigilator authors a private reply (the `POST .../messages` route). Both audited.
13. **Force submit.** An invigilator issues a force-submit (the HTTP lock route). Extension audits, sets `locked_at` (so the bearer `401`s at once) and writes a durable `session_locked` frame, fans it to the student's WS, and publishes the observability event `proctoring.events.session.revoked`; core's next `IsAdmitted` heartbeat returns not-admitted and its content path stops serving. Committing the student's staged delivery remains the examination activity's job.
14. **Exam stop.** Staff clicks *Stop proctoring* per RFD 0011. Extension closes all WS sessions for the exam, marks any unreviewed captures accordingly in the audit log, and runs RFD 0011's room path. Captured images remain in the object store under the deployment retention policy (or indefinitely while `held`).

## Lock Recovery: Suspend vs Revoke, and the Reconciler (R5)

The lifecycle above locks a session in two shapes the shipped implementation added but this
RFD did not give a recovery path: the **collection force-submit** (a timer at
`submission_collection.stop_at` emits `collection.closed`; the proctoring consumer locked the
closed cohort) and **room end** (an invigilator ends a room; its seated sessions locked). Both
landed in the same terminal `locked` state as an invigilator `force_submit`. The problem: those
two causes are **reversible**: a `stop_at` extension reopens the window and reschedules the
timer, and an ended room can be reopened. But the sessions they locked remain locked, because
`locked` is terminal (no edge leaves `locked`). An instructor who sets the wrong
`stop_at` and then extends it to "give five more minutes" reopens the submission plane while
every proctoring session remains locked, recoverable today only by a direct database write.

The fix distinguishes two categories of lock, and gives the reversible one a real state.

### R5.1: Suspend (reversible) vs revoke (terminal)

- **Revoke** is terminal, per-student, disciplinary: an invigilator force-submit (identity failure, cheating).
  It keeps the `locked` state and the `proctoring.events.session.revoked` observability semantics unchanged. There is
  no undo (see Open Items for whether mis-click recovery is ever wanted).
- **Suspend** is reversible and cause-scoped. As drafted there were two suspend causes:
  `collection_closed` (window force-submit) and `room_ended` (room closed). **As built (the
  phase-4 supervision-dismissal model) a window close suspends nobody: `room_ended` is the only
  suspend cause, and an invigilator's clean release is a separate reversible `dismissed` state.**
  This as-built model differs from the two-cause design described in the rest of R5 and is listed
  for ratification. Room-end **must** carry a `room_ended` reason distinct from the per-student
  `invigilator` revoke, so a room reopen can reinstate its cohort without disturbing a student who
  was individually revoked while seated there.

A new non-terminal admission state **`suspended`** holds a reversible lock. A suspended and a
revoked student are both *blocked* (all deny-gates key off `locked_at != nil`, which stays set
on suspended rows, so no gate changes), but only `suspended` is recoverable, and the
student-facing copy differs off the reason ("the exam window closed, please wait" vs "you have
been removed"). Reversibility that drives copy, rendering, escalation, and eligibility **is** a
state, not metadata; `locked` stays terminal. The edges are: any suspend cause moves a session to
`suspended`; an invigilator escalates a suspended student to `locked` (a disciplinary revoke); and a
reinstate returns a suspended session to its `resume_state`.

`resume_state` is a nullable column snapshotting the pre-suspend admission state, written
**atomically inside the suspend UPDATE** (`SET resume_state = state, state = 'suspended' WHERE
state NOT IN ('suspended','locked')`), cleared on reinstate/escalation. It is necessary
**today**: `physically_verified` now has a writer, the manual-admit route
(`POST /rooms/:room_id/sessions/:user_id/manual-admit`) stamps `manually_admitted_by`/`at` and
the admit CAS lands `physically_verified`, so marker re-derivation from
(`policy_snapshot`, captures, `content_released_at`) would silently regress a verified student to
`admitted` and destroy the invigilator's attestation; the `resume_state` snapshot prevents exactly
that. The snapshot has zero staleness hazard (it is one write with the lock) and composes
correctly under double-suspend: a session suspended by a collection close and then by a room end
takes the second suspend as a no-op (its row is already `suspended`), preserving the first
snapshot.

### R5.2: One predicate, level-triggered; events are nudges

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
advisory (copy + audit) only; reinstate is gated on live truth, which is what lets a session
suspended by *two* causes wait until *both* clear, something a reason-gated predicate cannot
express. `collection.closed`, `collection.reopened`, and room-reopen degrade to a
pure `ScheduleLockReconcile(activity_id)` nudge with the periodic sweep as the durability
backstop; **room-end is the exception: `End()` suspends the room's sessions inline in the same
transaction as the ended-CAS (M2), the reconciler's room arm serving only as a level-triggered
backstop.** No event carries authority, and every failure mode is bounded at one sweep interval.

This is affordable precisely because **proctoring is a downstream control plane**: submission has
zero reads of proctoring state, and the authoritative answer-integrity fence is the submission
force-submit at `stop_at`. The proctoring lock only tears down the invigilation session (WS /
media / capture), not a delivery. So the lock's **latency** does not matter: a session lingering a few
seconds past close cannot be exploited (submission is already frozen), which is why the original
consumer was async. What must be correct is the lock's **authority**: a *wrong* lock (re-suspending
a validly-extended student) sends them to the locked screen mid-exam, so the reconciler, not a
stale event, is the sole writer of session-blocked state.

Two consequences of the "one predicate" resolution, decided:

- **Multi-collection membership: any-open-wins.** The session is one-per-activity but cohorts are
  per-collection; a student in a closed main collection and an open accommodation collection is
  reinstated (their live window is open). Holding until *every* collection reopens would deadlock
  the extra-time student, the flagship case. The residual risk (a student erroneously in an extra
  open collection may sit during it) is a collection-membership problem already true of the
  submission plane, not one proctoring should second-guess. This is already built: the
  `activity_state` contract now carries `is_exam`, `open_user_ids`, and `closed_user_ids`, so it
  answers per-user window membership, though with **effective-collection** semantics (a user is in
  at most one of open/closed, per the auto-dismiss-snipe fix), not the any-open-wins union described
  here.
- **Room un-ending is window-bounded.** A room is reopenable only while the activity has a live
  open window, the same predicate. This makes reopen meaningful only during an active sitting and
  avoids both an arbitrary grace timer and resurrecting a room long after the exam.

### R5.3: The two corrections

- **Extend the exam window.** For `kind='exam'` the decided invariant is `stop_at == due_at`; the
  extend operation moves both together atomically (the generic create/PUT paths still guard only the
  weaker `due_at >= stop_at`, but the dedicated `POST /collections/:id/extend-window` route now moves
  `stop_at` and `due_at` together, so that 400 no longer applies to an extension). It reschedules the
  force-submit timer, and **fails the request if that reschedule
  fails** (a 200 with the timer still armed at the old `stop_at` would fire the old force-submit
  mid-extension; the 5xx demands the operator retry, which is safe: the extend is re-appliable and
  the schedule is terminate-and-replace). Post-commit it emits a dedicated
  `collection.reopened` **NATS nudge unconditionally** (extend lives in the submission extension and
  the reconciler in proctoring, so "in-process" is impossible; the dedicated emission also routes
  around the `collection.updated` per-collection-*group* publish, which emits nothing for a
  user-audience (accommodation) collection). The nudge carries no authority; the periodic sweep is
  the durability backstop for a lost emission.
- **Reopen an ended room.** A new transition from `ended` to `open` (the existing status CAS cannot express
  it) that clears `ended_at` and nudges the reconcile. Un-ending is safe: room-end is the ended-CAS
  plus the session-**suspend** loop in one transaction; it seals no evidence and does **not** delete
  the LiveKit room (rooms are lazily re-provisioned on token issuance). It does evict the room's live
  media (`EvictRoomMedia` removes the LiveKit participants), and the suspended sessions drop out of
  recording eligibility so the RFD 0016 sweep stops their egresses. The successor-room alternative is dead: re-seating a
  mid-exam student with an existing session is deferred by design, i.e. the whole cohort. The
  reconciler's lock direction and its `liveActivityIDs` scope must widen to cover all-ended-room
  activities, or a room whose rooms are all ended is excluded from the very sweep meant to reinstate
  it, and a reinstate that races a re-end escapes permanently, so reinstate must be one transaction
  taking the sweep's advisory lock and re-reading `room.status FOR SHARE` before its CAS.

### R5.4: Authorization

Following the existing split (routine per-room invigilation = `can_proctor(room)`; structural
correction = `can_edit(proctoring_activity)`), scaled by blast radius:

| operation | relation | rationale |
| --- | --- | --- |
| extend exam window | `can_edit(activity)` (submission) | an academic-schedule change; not an invigilator's to make unilaterally |
| reopen ended room | `can_proctor(room)` | **symmetric with `end`** (also `can_proctor`): the invigilator who mis-ended undoes it; ending already mass-locks the cohort, so reopening mass-reinstating it is the same power |
| per-student reinstate | `can_edit(proctoring_activity)` | mass-readmit; structural. **Deferred** (not in the initial implementation): the reconciler is the sole writer of session-blocked state, and both shipped corrections recover whole cohorts through it; a per-student override endpoint would bypass the live-truth predicate and immediately be re-suspended by the sweep unless the underlying cause cleared, so it only becomes meaningful alongside a per-student cause exemption. Revisit with the full authz pass. |
| escalate `suspended` to `locked` | `can_proctor(room)` | routine discipline; mirrors `force_submit` |

`can_edit(activity)` inherits `can_edit(proctoring_activity)` (via the activity parent), and
`chief` is *inside* `can_edit(proctoring_activity)`, so a course editor drives every correction,
and a **chief** drives room recovery fully but **not** the window extend (they lack
`can_edit(activity)`). That split is a separation of duties: room lifecycle is the chief's
domain; moving an academic deadline is the coordinator's. We do **not** carve `chief` out of the
grant; doing so would need a new relation and strip chiefs of rooms/roster/assignments too. A full
authz pass may revisit personas; this is the provisional model.

### R5.5: Freeze-race semantics and a latent bug

During the extend-vs-fire race, the student's staged work is force-committed at the *old* `stop_at`;
after reinstate they re-stage and are force-committed again at the new one. This is **accepted**: no
un-commit exists, exam collections are `score_selection=latest` so the phantom commit does not win,
and the cost of rolling back a committed Temporal force-submit is not worth a rare, harmless record
artifact; the phantom is logged for forensic clarity. Separately, the reconciler's lock direction
must re-verify live closed-state before suspending (or be a pure nudge), or the same race produces a
≤5-minute cohort-wide mid-exam suspension flicker.

This design also surfaced a **live bug** (now fixed): the original bulk-lock query guarded
`AND state <> 'locked'` and the invigilator-lock / room-end paths discarded the returned row count and
returned success unconditionally, so an invigilator lock on an already-suspended student was a silent
no-op. As built, `RevokeSessionWithFrame` is a `:one` query, so a zero-row lock surfaces as
`pgx.ErrNoRows`; `LockUserInRoom` escalates a suspended student and errors when there is no lockable
session (idempotent only on an already-locked row). Under R5 that path *is* the escalation edge from `suspended` to `locked`. The fix (a zero-row lock is an error/escalation, not a false success) is **two**
distinct SQL primitives, not three: `SuspendSessionsFor{Users,Room}WithFrame` (`:many`,
zero-rows-is-success) and `RevokeSessionWithFrame` (`:one`, the revoke/escalate primitive guarding
`state <> 'locked'`, zero-rows-is-error). The `collection.closed` consumer no longer suspends at all
(phase 4), so only the sweep's room arm and `End()` remain zero-rows-ok suspend callers.

**Implementation refinements (found building it, now normative):** (1) The suspend predicate is
`∈ closed-cohort ∧ ∉ open-cohort`, not merely `∉ open`; the naive form suspends every
pre-registering student during the `before` window (rooms open early for
device-proof/capture), so the `activity_state` contract carries `closed_user_ids` alongside
`open_user_ids`, plus an explicit `is_exam` gate (the countdown-derived `state` string is
best-effort and conflates "read failed" with "not an exam"). (2) The suspend direction has a
**room arm** in the same reconcile txn: a lockable session seated in an ended room is suspended
`room_ended`, making room-end level-triggered too (an interactive `End()` whose suspend leg fails
is healed by the sweep; `End()` itself is one transaction). (3) Lock ordering is **room-then-session
in every transaction** (the reconcile pins non-ended rooms FOR SHARE before any session write;
`End()` takes the room CAS before its suspend loop); the opposite interleaving deadlocks at
exam-end timing. (4) The interactive lock is idempotent on an already-**locked** target (returns
the existing lock time) and errors only when there is no lockable session, preserving the
pre-R5 double-click contract while still escalating a suspended target.

### R5.6: Open Items

- **Client recovery channel (requirement, not nicety).** A student who reloaded on the locked screen
  cannot receive the `session_reinstated` frame (its delivery channels sit behind the same
  `locked_at` deny-gates). The locked/suspended screen **must** poll or retry `session create` on a
  timer; it is the only recovery path for the common "closed the laptop" case.
- **Mid-exam unenrollment.** A student removed from all of an activity's collections mid-exam leaves
  both membership sets, so the collection arm no longer suspends them (the roster soft-withdraw skips
  seats with live sessions); their session stays live until room-end. A rare admin action; the
  eventual answer is probably a roster-reconcile-driven suspend cause, decided with the authz pass.
- **`physically_verified` writer**: when it ships, it needs a persisted attestation independent of
  FSM state (this is what makes `resume_state` necessary).
- **Attendance finalization** (`assignment.status = no_show`, currently unwritten) must be
  un-finalized by reinstate if/when a writer exists.
- **Invigilator-lock undo**: terminal here by design; a future demotion from `locked` to `suspended`
  should be explicitly disallowed, not left ambiguous.

## Alternatives Considered

### Alternative A: non-extractable WebCrypto keypair as a device-binding fallback (rejected)

An `ECDSA P-256` keypair generated via `crypto.subtle.generateKey({extractable: false})`, stored as a `CryptoKey` handle in IndexedDB, would provide origin-partitioned device binding without a platform authenticator. It is **rejected as a contingency**, and this is now a firm decision rather than a standing fallback: under the unified policy, the answer to "no platform authenticator" is to set `device_proof=off`, which means **no device binding at all**, not a weaker cryptographic stand-in. Introducing a WebCrypto keypair (or a per-machine certificate, or MAC pinning) as a substitute would contradict that choice and reintroduce a mechanism whose continuity property we have declined to claim. The `device_proof=off` cell is a bounded, weaker threat model (authenticated session + closed intranet + physical invigilation + audit; see Known Limitations), not a degraded R1. Alternative A is recorded to note the option not taken.

### Alternative B: LiveKit data channel for control

Reusing the LiveKit room's data channel (`CanPublishData: true`) for invigilator ↔ student control would avoid a second long-lived connection. Rejected because (a) pre-room windows (device registration, identity check) require a channel before the student has a LiveKit token, forcing a WebSocket anyway, (b) every control message must be audited by the extension per the R4 requirement, which routes traffic server-side regardless, and (c) reusing the media-plane connection weakens the clean separation between media (SFU-governed) and control (extension-governed).

### Alternative C: automated face matching

An in-extension face-matching model (OpenCV or a cloud API) could auto-admit high-confidence matches and reduce invigilator load. Rejected for this RFD because (a) the invigilator is physically present and auto-admission saves only seconds, (b) training-data licensing and evaluation across the institution's student demographics is substantial work for a small gain, and (c) false positives on auto-admission are harder to defend in an appeal than a documented invigilator judgement. A future RFD may revisit if invigilator load becomes a bottleneck.

### Alternative D: LiveKit data channel plus extension audit mirror

A hybrid where control frames travel over the LiveKit data channel for low-latency delivery, with the extension subscribed to mirror them into the audit log. Rejected because the extension does not reliably see every data-channel frame (depends on having an admin client in every room) and because frames authored client-side bypass server authorization on their primary path. The extension-WS path makes the extension the authoritative router, not an observer.

## Implementation Notes

- **Bearer TTL and rotation cadence.** The bearer TTL is the `proctoring_security.bearer_ttl` config, defaulting to 10 min. There is no fixed 8-minute rotation timer: the bearer is re-minted at every WS attach (the attach CAS-rotates `session_id` and `attach_ack` carries the re-minted bearer) plus reactively via the cookie-authed `POST /sessions/bearer/refresh`. Tune the TTL after load testing per RFD 0011's pre-`published` load test.
- **Session table durability.** The `(user_id, activity_id)` session table (`credential_id`, `captures`, `locked_at`) lives in the proctoring extension's durable store (Postgres, co-located with the RFD 0011 cache sidecar). In-memory-only storage is not acceptable: a locked student must remain locked across extension restarts, and the session restore on reconnect depends on the stored `credential_id`.
- **WS frame replay on reconnect.** The `attach` frame carries only the bearer, not a last-ack. The extension replays every durable `ws_frame_replay` row with `acked_at IS NULL` in `server_seq` order before transitioning to normal operation; the watermark is advanced by client `ack` frames (`{acked_server_seq}`, applied by `AckProctoringFramesUpTo`). Client-originated frames are not replayed, and `attach_ack` itself is unsequenced.
- **Invigilator decision reconciliation on reconnect.** *(Not implemented as built.)* There is no `session_snapshot` frame and no `decision_id`: the invigilator WS is fan-out only with no replay backlog, and invigilator decisions are HTTP POSTs whose authority is the response plus a roster re-read.
- **Pre-registration WS timeout.** The WS opened before passkey registration is closed by the extension after 5 minutes (`preRegistrationTimeout`); the close uses WS code `4001` with reason `bearer_missing`, and an audit row with action `pre_registration_timeout` is written (there is no `registration_timeout` close reason). This prevents dangling unbound sessions from accumulating on abandoned tabs.
- **Reconnect rate limit.** The client's back-off is the WS reconnect loop: exponential, base 2, starting at 1 s (`RECONNECT_BASE_MS`), cap 30 s (`RECONNECT_MAX_MS`). This caps user-visible WebAuthn prompts on unstable Wi-Fi.
- **Idempotency on invigilator decisions.** There is no `decision_id`. The invigilator actions are HTTP routes made idempotent by state (a re-lock of a locked session echoes its `locked_at`, a re-POST of manual-admit returns `200`), and only chat DMs carry a client idempotency key (`client_msg_id`).
- **Force-submit delivery guarantees.** A force-submit publishes `proctoring.events.session.revoked {user_id, activity_id, session_id, reason, ts}` to the `PROCTORING_EVENTS` stream as a **best-effort observability** event: no `action` field, no retry-until-ack, and no core consumer. The extension writes `locked_at` locally first, so the bearer `401`s immediately and core's next `IsAdmitted` query returns not-admitted regardless of the event; the session row is the source of truth. The client-side `session_locked` frame is advisory UI; the authoritative lock is the `locked_at` write plus core's fail-closed content gate. The proctoring lock does not commit the student's staged delivery; only the collection `stop_at` timer does.
- **Re-capture is pointer-first, no move.** A re-capture never relocates a blob: the new object lands at its own immutable per-id key, and one transaction marks the prior row `superseded_at` then inserts the new active row (a partial `UNIQUE` index on `(session_id, capture_kind) WHERE superseded_at IS NULL` keeps one active row per kind). There is no `CopyObject` and no `superseded/` prefix, and no start-time orphan sweep is needed: because blobs are never relocated, the only half-state after a crash is an unreferenced object, still covered by the deployment retention policy. No session state can observe a half-moved capture.
- **Capture upload failure handling.** If the client cannot upload despite retrying, it surfaces a retryable error and the session stays `awaiting_capture`; so under an `enforced` policy the student cannot yet obtain a LiveKit token. The resolution is the manual admission gate, not a timer: an invigilator verifies the student in person and issues `manual_admit`. No automatic disqualification on upload failure: network problems should not lose a student their exam silently.
- **Capture size bounds.** Client-side JPEG at 1280×720, ~85% quality, typical ~150 KB; reject uploads > 1 MB at the extension.
- **Passkey registration is necessary for any session; capture or manual admit gates entry under `enforced`.** If WebAuthn creation is cancelled, the session has no device binding and the client surfaces a retry prompt; the student cannot proceed. Under an `enforced` policy, completing registration still leaves the student `awaiting_capture` until both captures upload or an invigilator issues `manual_admit`; under `disabled`, registration alone admits. Cancelling registration repeatedly consumes no resource except the open WS.
- **Origin and RP ID.** `rp.id` must match the exam origin exactly; passkeys scoped to `zinc.example.com` cannot be used at `exam.zinc.example.com` and vice versa. Deployment choice pending.
- **Object-store lifecycle rule verification.** Lifecycle rules are easy to mis-configure at deployment. A post-deploy check asserts the rules are present and correctly scoped; a daily probe asserts no objects older than 31 days exist outside `held/`. Lifecycle rules run asynchronously; the probe is the actual deletion guarantee.
- **Orphaned wrapped-DEK rows.** A reconciliation sweep removes `session_captures` rows whose object-store object no longer exists (post-lifecycle deletion). A 30-day-after-`uploaded_at` TTL matches the default lifecycle rule; rows for `held/` captures are exempt.

## Known Limitations and Accepted Trade-offs

- **`device_proof=off` is a bounded, weaker threat model (the primary concession).** Disabling `device_proof` removes all device binding with no compensating mechanism. There is **no proof-of-possession on any request**: the OIDC session cookie becomes the highest-value secret, exfiltratable by the same XSS / malicious-extension / heap-dump vectors as the bearer. The bound is TTL (10 min) + closed-intranet isolation (even more important than under `on`, and the only network control, with no application-level source-IP allowlist) + physical invigilation + full audit. Cookie replay lets a thief take over by re-running the cookie-authed create-recovery; the first client to attach rotates `session_id` and invalidates any other live bearer, and the eviction is recorded in the audit log. The RFD's original read-only-takeover-closed guarantee (a `POST /sessions` `409 session_active` refusal of a co-current bearer) is **not** as-built (the recovery returns the same bearer, so two bearers can be live until one attaches) and is listed for ratification. Bearer theft within the 10-min TTL from a live-socket context is an **accepted, audited-after-the-fact residual**; co-currency is not claimed to bound it, and there is no alerting/escalation beyond the audit log. Under `identity_verification=enforced` this is partly recovered by captures + review; under `disabled` (cells 6, 8) identity rests on the physical door-check + invigilation.
- **Platform-authenticator availability is a hard deployment precondition only under `device_proof=on`.** Fleets without full coverage cannot run `device_proof=on` activities; the fleet survey is a prerequisite to `published` for those activities. There is no WebCrypto contingency (see Alternative A); the answer for a fleet without authenticators is `device_proof=off` with its stated weaker model.
- **Cross-device passkey sync is a concern only under `device_proof=on`.** Synced passkeys (iCloud Keychain, Google Password Manager) become valid re-login credentials only if the exam origin becomes reachable off the lab intranet (misconfigured VLANs, NAT hairpinning, maintenance-window routing). The application has no network-layer enforcement of the intranet boundary; runbooks must treat closed-intranet isolation as a first-class security control (change review, monitoring, incident response). Under `device_proof=off` the analogous secret is the cookie/re-entry-token, bounded by the same intranet isolation plus the single-active, `locked_at`-revocable re-entry token.
- **`live_media=off` removes the live visual signal.** No live camera/audio, no spot-check grid; invigilator review (if `identity_verification=enforced`) is stills-only, and a substituted still cannot be cross-checked against a live face, so a terminal decision must lean on the physical door-check. Whether stills-only is acceptable as sole identity evidence is an explicit deployment policy call.
- **The near-bare `{off, off, disabled}` cell is the weakest electronic model.** Its electronic security is the authenticated session + physical invigilation + closed intranet + audit, with no device binding, no media, and no captures. Appropriate only where physical controls carry the load.
- **Invigilator visual match is the only identity signal.** False negatives (a lookalike, a very old ID photo) are not caught by the system and must be caught by physical invigilation. This is the same trade-off any non-biometric exam has historically accepted.
- **Captured-but-unreviewed students see exam content before the verdict.** Capture submission gates entry, but the invigilator's verdict is asynchronous, so a student who would fail review still sees question material between entry and the verdict. In-scope risk because (a) the consequence of a failed verification is the same regardless of timing (disqualification), and (b) live camera + physical invigilation already provide a parallel signal. Synchronous pre-entry review was rejected because it would require review capacity sized to the cohort's entry burst.
- **Manual admission is an audited human bypass.** The `physically_verified` path trades the webcam evidence for an invigilator's in-person check; its integrity rests on invigilator diligence and is only as strong as the audit trail. Over-use (manually admitting students wholesale under an `enforced` policy) silently degrades to no verification. This is surfaced in the audit stream (every `manual_admit` carries an actor and reason), not prevented in software.
- **Unreviewed-at-exam-stop captures exist.** If invigilators fall behind, some captures will still be `unreviewed` at exam stop. These are retained under the normal 30-day lifecycle and can be reviewed post-hoc; decisions made after exam stop have whatever standing institutional policy allows them. Not the system's problem to close.
- **Passkey binds to the OS account, not the machine (`device_proof=on` only).** A student who logs into a different OS account on the same lab machine fails to re-bind automatically; invigilator intervention (re-enroll or re-entry) is the recovery path, and lab-ops policies (one OS session per student per exam) are assumed. Not applicable under `device_proof=off`.
- **`session_id` rotation and live-webcam track identity (`live_media=on` only).** Every WS attach rotates `session_id`, but the LiveKit participant identity is the **stable** `user:<id>` (`identityFor(userID)`), so a reconnect rejoins under the same identity (LiveKit drops the older participant) and an invigilator review pane keyed on identity re-binds automatically, with no manual re-resolve. RFD 0011's stable-track-identity follow-up is **implemented** (the console live pane already rides it), so it is no longer an open prerequisite. All invigilator-facing per-student state keys on the stable `(user_id, activity_id)`, not `session_id`, so review-queue entries themselves do not detach on rotation.
- **Mid-exam de-authorization still has the RFD 0011 TTL window (accepted).** If a student's `enrolled` (or `student@proctoring_room`) tuple is removed during an exam, their existing extension bearer and any LiveKit token remain valid until TTL expiry; the revocation is **not acted on in-band**. The bearer hot path carries a short-TTL (≤ 30 s) cached `enrolled` re-check, which **fails closed** (a checker error or definitive absence returns `403` on that request, review fix C1/F12), but it does not lock a live exam or force-submit, so a single read cannot irreversibly force-submit a student. This RFD does not close the window; closing it (acting on revocation in-band) is left to the follow-up that introduces the broader `proctoring.*` NATS event surface deferred from RFD 0011.

  Required normative RFD 0011 edits also land here and **require the RFD 0011 owner's ratification**: (1) anchor the media-independent enrollment (a DB `proctoring.assignment` existence check, not a new OpenFGA type), amending RFD 0011's "`student` is the single source of truth for room membership" to a two-plane model (enrollment = session/content, `student` = media), with room creation deriving `student` tuples from the enrollment set; (2) `POST /rooms` rejects with `409 media_disabled` when live `live_media=off`; (3) the token-route student-branch gains the admission + `room_ready` + device-proof preconditions (the invigilator branch is unchanged); stated as **new** machinery, since RFD 0011 has no admission gate today.
- **PII retention is enforced by object-store lifecycle rules.** Correctness of deletion depends on the deployment's lifecycle rules being present and scoped correctly. A post-deploy check validates the rules; drift or mis-config is caught there, not at scale.
- **Force-submit semantics are defined by the examination extension.** This RFD guarantees delivery and audit but not the answer-handling semantics. If the examination extension is unavailable, the lock still lands: the interactive lock writes `locked_at` plus a durable `session_locked` frame and fans it out, so the student sees the lock regardless. What degrades during an examination/submission outage is the content gate and the delivery commit, not the lock.
- **KEK loss is unrecoverable.** Captures encrypted under a lost KEK version cannot be decrypted by anyone. KEK material is treated as a backed-up root credential; loss equals data destruction.
- **Extension is the single read path for captures.** Decryption happens in the extension; each read costs two I/O round-trips and holds a ~150 KB plaintext briefly in memory. Review-queue bursts at exam-start are concurrent rather than long-lived, so capacity planning must size for review concurrency, not just connected sessions. An extension outage also means invigilators cannot view captures during the outage.
- **In-process KEK default is portable, not maximum-strength.** A KEK held in extension memory or in deployment-secret form (env var, mounted K8s Secret) is exposed by extension-process compromise, heap/core dumps, container snapshots, and CI logs that print rendered manifests. Deployments concerned with these surfaces should use Vault Transit or a cloud KMS, where the KEK never enters extension memory. The default exists so portable / small deployments work without external KMS infrastructure.
- **Live webcam unavailable when student has not yet joined LiveKit.** The review surface degrades to stills-only; the invigilator can defer or decide on stills. Common shape during the first minute of a student's session.
- **Live-webcam track identity across reconnects (now implemented).** When a student reconnects mid-exam, LiveKit does **not** issue a new participant identity: the identity is the stable `user:<id>` minted on every token, so LiveKit disconnects the older participant and the new tracks appear under the same identity; an invigilator's review pane keyed on identity re-binds automatically. This was the RFD 0011 stable-mapping follow-up; it is now implemented.

## Glossary

| Term | Definition |
|------|------------|
| **WebAuthn** | Web Authentication API, a W3C standard for public-key authentication in browsers, implemented by all major browsers. Uses authenticators (platform or roaming) to create and use credentials. |
| **Passkey** | Consumer-friendly name for a discoverable WebAuthn credential. In this RFD it means specifically a platform-authenticator resident credential protected by user verification. |
| **Platform authenticator** | An authenticator built into the device (Touch ID / Face ID / Windows Hello / Android biometric / ChromeOS). Contrasted with *roaming authenticators* like YubiKeys. |
| **User verification** | A WebAuthn property meaning the authenticator verified the user's presence *and* identity (e.g. biometric or PIN) at signing time. Stronger than user presence alone. |
| **Attestation** | A signed statement from an authenticator asserting the provenance of a credential (e.g. "this credential was created in a genuine Apple Secure Enclave"). Optional at registration; not used in this RFD. |
| **Session bearer** | The short-lived JWT issued by the proctoring extension at session create (decoupled from passkey registration), re-minted at every WS attach and by `POST /sessions/bearer/refresh`, used to authenticate extension API calls and WS frames. Identity binding `(user_id, activity_id, session_id)` (in the JWT the `sub` is `user_id:activity_id` and `session_id` is a separate claim); an optional `cnf` claim carrying the registered credential id is present iff `device_proof=on` and the session is `admitted`/`physically_verified`. |
| **Proctoring policy** | The unified per-activity object `{device_proof: on\|off, live_media: on\|off, identity_verification: enforced\|disabled}`, resolved via the `PolicyProvider.PolicyForActivity` interface (there is no `ProctoringPolicy` or `VerificationPolicy` interface) and frozen as a per-session `policy_snapshot` at create. |
| **device_proof** | The knob selecting the optional passkey device binding. `on` = platform-authenticator passkey (R1). `off` = no device binding at all; create authorized by cookie + a DB enrollment check, reconnect by the cookie-authed create-recovery (with `session_id` rotation at WS attach); no device credential stored; closed intranet is the only network control. |
| **live_media** | The knob selecting the optional LiveKit camera/screen plane (RFD 0011). `off` = no room is ever created; the entry gate targets the extension-owned admitted state, not a LiveKit token. |
| **identity_verification** | The knob selecting webcam ID-photo + face-snapshot captures with async review. `enforced` = captures gate admission; `disabled` = skipped. Open enum (future `optional`). Subsumes the former standalone `verification_policy`. |
| **enrolled** | The DB `proctoring.assignment` existence check (not an OpenFGA relation) meaning "is registered to sit this proctored activity." Distinct from `examination#examinee` ("can read the questions"). The media-independent session-create authorizer in all eight cells. |
| **Admission state** | The first-class, extension-owned session `state` (`pending_device_proof` / `awaiting_capture` / `awaiting_attach` / `admitted` / `physically_verified` / `suspended` / `dismissed` / `locked`) that every consumer keys off, surfaced to invigilators over WS (`session_state`) and to the student via `admitted`/`session_locked` frames and HTTP (`GET /sessions/me`). Never "the client obtained a LiveKit token." |
| **IsAdmitted** | The internal NATS request-reply (no HTTP equivalent) by which core pulls the admitted fact from the durable session row as a content-release precondition (a contract requiring core/RFD 0009-owner ratification), preserving RFD 0009's core-as-orchestrator direction. |
| **Re-entry token** | As drafted, an extension-signed single-active reconnect credential minted under `device_proof=off`. **Not as-built**: reconnect re-authorizes through the cookie-authed `POST /sessions` create-recovery (with `session_id` rotation at WS attach) instead; retained here for the design record. |
| **Device binding** | The registered passkey credential (stored in `proctoring.webauthn_credential`, keyed `(user_id, activity_id)`), present only under `device_proof=on`. Under `device_proof=off` there is no device binding. |
| **Review queue** | The invigilator's surface (keyed on stable `(user_id, activity_id)`) listing per-student `verification_status` (`unreviewed` / `verified` / `suspicious`). Populated only under `identity_verification=enforced`; reviewed asynchronously during the exam, stills-only under `live_media=off`. |
| **Manual admission** | An invigilator admitting a student without a capture after an in-person check; sets the session `physically_verified` and exempts it from the review queue. The single override of the capture-to-enter gate. |
| **Suspicious flag** | A non-terminal review outcome marking an entry as doubtful: it holds the captures and surfaces them for a second review or post-exam decision, without ending the student's exam. The conservative alternative to disqualification. |
| **Capture hold** | An admin action (explicit investigative hold or a suspicious-flag outcome) setting the `held` flag on a student's active capture rows (keys are immutable; no object moves), beyond the default 30-day window. |
| **Control WS** | The single bidirectional WebSocket on the proctoring extension carrying non-media orchestration traffic for the full exam lifecycle. |
| **DEK / KEK** | Data Encryption Key (per-object) and Key Encryption Key (long-lived, wraps DEKs). The two-tier structure of envelope encryption. |
| **Envelope encryption** | Pattern in which each object is encrypted with its own DEK, and the DEK itself is encrypted (wrapped) by a KEK. Allows independent rotation of the KEK without re-encrypting object bodies. |
| **AAD** | Additional Authenticated Data, the input to an AEAD cipher that is authenticated but not encrypted. Used here to bind ciphertext to its identity (`activity_id, user_id, capture_kind, capture_id, kek_version`). |
| **XChaCha20-Poly1305** | An AEAD cipher with a 256-bit key and 192-bit nonce (RFC 8439-extended). The large nonce makes random-nonce collisions negligible at any practical scale. |

## References

- [RFD 0009: ZINC Extension System](../0009/README.md)
- [RFD 0010: Temporal Workflow Orchestration](../0010/README.md)
- [RFD 0011: Real-Time Video Invigilation Using LiveKit](../0011/README.md)
- [W3C Web Authentication Level 3](https://www.w3.org/TR/webauthn-3/)
- [MDN: Web Authentication API](https://developer.mozilla.org/en-US/docs/Web/API/Web_Authentication_API)
- [passkeys.dev: platform authenticator support matrix](https://passkeys.dev/device-support/)
- [RFC 8439: ChaCha20 and Poly1305 for IETF Protocols](https://www.rfc-editor.org/rfc/rfc8439)
- [NIST SP 800-38D: AES-GCM specification](https://csrc.nist.gov/pubs/sp/800/38/d/final)
- [OWASP Cryptographic Storage Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Cryptographic_Storage_Cheat_Sheet.html)
