---
authors: Thomas Li
state: prediscussion
discussion:
labels: direction, platform, ux
---

# [RFD] Activity Settings: Per-Extension Switches, Policy, and Readiness

An activity today carries one type, `kind`, with the values `assignment` and
`exam`. This RFD replaces that type with a settings envelope stored on the
activity row in the core schema: one key per extension, each with an on/off
switch and the activity-level policy that extension applies, resolved to
constants when no decision has been recorded. Exam and assignment become
presets over the envelope rather than a stored type. A readiness read asks
every extension whether the activity can be held as configured and reports
the answer per extension, including undecided keys and extensions that are
not running. A small set of rules bounds what the core may know about an
extension so that centralizing the settings does not centralize extension
logic.

The RFD records the decisions, their reasons, and the alternatives that were
rejected. It covers all four delivery steps at the level of decided
direction; only the first step, the intermediate, is specified to implementation detail, and
that specification lives in the core repository as a plan document that is
removed when that step is complete.

## Background

The platform is composed of a core (logistics) and seven extensions
(submission, examination, pipeline, report, sandbox, environment,
proctoring), each owning a database schema and communicating over NATS and
Temporal ([RFD 0009](../0009/README.md)). RFD 0009 states that examinations
and assignments are "different configurations of the same underlying
concept", not extensions and not types. The stored `kind` column contradicts
that principle by making the configuration a type.

Verified against the core repository at the time of writing, `kind = exam`
gates one behavioural bundle, all of it owned by the submission
extension: client mutations are refused at the collection's stop time (with
a save grace for drafts and attachments), the commit time is clamped to the
stop time, the due time must be at or after the stop time, the window must
fit the session budget, the collection lifecycle exposes a freeze state, a
force-submit workflow is scheduled per collection, the extend-window
operation is permitted, submission export is eligible after every collection
closes, and the reconciler user sets are computed. The only other reader is
proctoring, which refuses to enable unless the activity is an exam.
Examination, pipeline, report, sandbox, and environment never branch on the
value. The exam-lifecycle design that introduced the column (a sibling of
RFD 0012) defines an exam as that bundle: a hard, synchronized,
server-guaranteed cutoff.

Three further facts shaped the design:

- **Enablement is structural today.** Every extension except proctoring
  infers "on" from row existence: a document exists, a config is attached, a
  pool is mapped, a template is assigned. The staff overview work found
  that a deliberate "off" and "never decided" were byte-identical for
  proctoring and worked around it by writing a `proctored: false` row for an
  explicit off and reading no row as undecided. This RFD generalizes that
  row-existence workaround into a recorded tri-state for every extension.
- **The console already reserves the surface.** The activity navigation
  design in zinc-sig/ui models a three-state settings row per extension
  (applicable, disabled, unavailable), records that "disabled" has no
  backend source, names per-activity extension enablement as the next
  project, and inherits one constraint: a toggle is a policy flag, not a
  process kill, so records surfaces must stay reachable when a capability
  is off.
- **Changing the type today has no guards.** The activity update route
  validates the value of `kind` and nothing else: it neither re-validates
  existing collection windows nor schedules or cancels force-submit
  workflows.

The examination extension deserves one clarification, because its name
suggests exam-ness. In the backend it has none. It is the online-answering
modality: students answer a paper in the exam client, and their answers are
stored as delivery attachments through the same push the console's file
upload uses. A homework answered in the client is therefore one combination
of two independent axes, cutoff and modality, and nothing in the core
prevents it; what prevents it today lives in the clients and is listed in a
later section. That combination is designed for here and not committed to.

The design was settled with the platform owner in a design interview on
2026-09-11, then given a second read and an adversarial review whose
findings are folded in. A colleague's proposal that exam and assignment be
settings templates is compatible with this RFD and deferred until the
settings themselves are in place.

## Proposal

Replace the stored type with a settings envelope and derive everything the
type decides from it.

**Two axes replace the type.** The cutoff, a submission setting with the
values `soft` (open to the stop time, late after the due time, no
force-submit) and `hard` (freeze at the stop time, force-submit, commit
clamp), carries every behaviour the exam type carries today. The modality,
the examination switch, states whether students answer a paper in the client
or upload files. The four combinations are: hard with a paper, today's exam;
hard with uploads, a timed upload exam, which already works because an exam
activity without a document force-submits attachment deliveries; soft with
uploads, today's assignment; and soft with a paper, the online homework that
is not supported yet.

**One envelope in the core.** A JSONB column on the activity row, keyed by
extension name, holds each extension's switch and its activity-level policy.
Every key carries `enabled`. An absent key means undecided, and its resolved
value is a constant that describes the least-capable activity, so every
process computes the resolved value of any key from the envelope alone.
Bindings to rows an extension owns, authoring facts that version with a
paper, per-collection values, and deployment configuration stay where they
are; the envelope holds decisions staff make about the activity.

**Off is total for new use.** With a key disabled the owning extension
refuses every new use of the capability by anyone, staff included; what
already exists stays readable.

**Readiness reports, never gates.** One core route fans out to every
registered extension and composes a per-extension verdict with named checks,
including undecided keys and extensions that did not answer. Any status
transition stays allowed.

**Core stores bytes; extensions define meaning.** Six rules bound what the
core may know: it validates shape through validators the extensions author,
evaluates cross-key preconditions that the dependent extension declares,
never reads extension state or calls an extension on the write path, publishes
one notification that no extension is required to consume, derives nothing
but declared projections, and asks extensions only through readiness.

**Exam and assignment are presets.** The console and the command-line
client write a named envelope at creation. The backend stores no type.

### Abandoned ideas

- **One settings row per extension in each extension's schema.** The first
  draft's recommendation. Rejected by the owner in favour of centralized
  management: with one row per extension there is no single place to answer
  "what is this activity", no way to refuse an invalid pair of decisions
  across extensions at write time without an inverted dependency, and no
  uniform tri-state.
- **A core switchboard table of switches plus per-extension settings
  rows.** Two writers per decision and a remote call per flip, since the
  legality of a switch depends on the owning extension's invariants.
- **A state-dependent default for an undecided key** (examination on when a
  document exists, pipeline on when a config is attached). Known only to
  the owning extension, so any other consumer of the resolved value would
  have to ask that extension live, which ties a policy decision to its
  liveness, or read its tables, which breaks the schema boundary. The flat
  fields on student reads and every cross-key rule are such consumers.
- **A precheck call to the owning extension before persisting a write.** A
  synchronous cross-process call per write, a timeout policy for a down
  extension, and every stateful rule implemented twice.
- **A core write-time guard that reads extension state** (for example,
  refusing a cutoff change while a collection is open by reading a
  submission view). It embeds extension knowledge in the core, which is
  the thing centralization must not do.
- **A deferred proctoring off behind an enforced copy of the switch** that
  proctoring would maintain until the last live session ended. A guard must
  not split one concept into a decided value and an enforced copy; once the
  content gates read the switch from the core there is no cross-extension
  read left to protect.
- **Moving the sandbox pool limits into the envelope.** The pool config is
  the specification of a resource sandbox provisions, an artefact like an
  environment template or a pipeline config, and artefact parameters are
  not activity policy.
- **A durable event stream for settings changes in the intermediate.** No
  reactor needs a delivery guarantee that its own periodic ensure cannot
  give.
- **Keeping `kind` as a stored label beside the settings.** Two writable
  sources for one fact.
- **A single coordinated cut across core, the ui, and the command-line
  client.** The fastest and the least verifiable option; the intermediate
  step exists to be verified on the backend alone.

## The settings envelope

One column, `core.activity.settings JSONB NOT NULL DEFAULT '{}'`, keyed by
extension name as registered in the application's extension map, plus a
sibling column `core.activity.settings_meta JSONB NOT NULL DEFAULT '{}'` the
core manages.

```json
{
  "submission":  { "enabled": true, "cutoff": "hard" },
  "examination": { "enabled": true },
  "pipeline":    { "enabled": true, "trigger_run_on_submit": true },
  "report":      { "enabled": true, "score_selection": "latest",
                   "default_score_visibility": "none" },
  "sandbox":     { "enabled": true },
  "environment": { "enabled": true },
  "proctoring":  { "enabled": true,
                   "policy": { "device_proof": false, "live_media": true,
                               "identity_verification": "enforced",
                               "recording_mode": "none" } }
}
```

### Absent means undecided, resolved to a constant

The shared package defines one constant per key, and every process computes
the resolved value of any key from the envelope alone: the recorded value if
the key is present, else the constant. The constants describe the
least-capable activity: submission on with a soft cutoff; examination,
pipeline, sandbox, environment, and proctoring off; report on with the
latest selection and no default visibility. A present key is a recorded
decision. Absence and `false` are different bytes, which gives the tri-state
the console asked for without a flag.

Two values are locked on by their key's validator until an off-state has a
product meaning: `submission.enabled = false` and `report.enabled = false`
are refused. Every key still carries `enabled` so the console rail has one
uniform row per extension; locking a value is cheaper to unlock later than
adding a switch.

An activity created with an empty envelope is a soft-cutoff upload
assignment with no automated grading on the platform image, and that is a
supported creation. The creation paths are the console dialog, the
command-line client, the seed scripts and demo scenarios, and the
end-to-end scenarios; exam bundle apply and the model-context-protocol
server create no activity. The console and command-line presets write keys
at creation, and the backfill records decisions for every existing
activity.

### Off is total for new use of the capability

With a key disabled the extension refuses every new use by anyone, staff
included: pipeline dispatches no run by any path, manual and batch triggers
included; examination refuses authoring as well as serving and pauses
materialization; sandbox refuses the linter and staff test runs as well as
student attempts, and creates no pool; environment off means grading and
sandbox run on the platform default image and the template binding is
ignored; proctoring refuses sessions. An off key is not applicable to
readiness, so nothing vouches for the extension, and anything usable under
off would be unverified; a partial off also leaves the intent unclear.
Enabling is the explicit first step before authoring or running, and the
exam preset does it at creation. What exists stays readable under off
(documents, runs, attempts, recordings): the switch governs new use, never
reading records, which is the console's own rule for records surfaces.
Enforcement is one middleware per extension route group that resolves the
activity and checks the key, plus a route-coverage test, because examination
alone has about forty write routes and a missed route is a silent partial
off.

### What belongs in the envelope

A value passes into the envelope when it is a decision staff make per
activity that an extension applies as policy. Five other homes are
unchanged:

- **A binding to something an extension has built** stays in that
  extension's table with a foreign key, because JSONB cannot hold one: the
  pipeline config id, the environment template id, the examination
  document. Readiness reports whether each binding exists.
- **An extension's specification of a resource it provisions is an
  artefact.** An environment template (an image spec), a pipeline config (a
  grading run spec), an examination document (a paper), and a sandbox pool
  config (the executor pool's spec) each have their own identity and
  lifecycle; they stay in the extension's schema, the activity binds to
  them, and the envelope holds the switch and the activity-level policy,
  never the artefact's parameters. The test for a value: does it describe
  how to build or run a resource the extension provisions, or does it state
  a rule the activity imposes on students or on other extensions? The
  sandbox limits are the pool's parameters and stay with sandbox; the
  proctoring policy is the set of rules students meet at admission and is
  policy; the pipeline trigger is a rule about when grading runs and is
  policy. Artefact editors live with their extension, as the console
  already edits templates on the environment page; the settings rail holds
  switches and policy.
- **An authoring fact stays with the artefact it describes** and versions
  with it: paper visibility, shuffling, and the scoring policy on the
  document, pagination on the context, the per-question execution
  overrides.
- **A per-collection value stays on the collection**: windows, delivery
  limits, release timestamps, the per-collection score visibility. The
  envelope may hold the activity-level default a new collection starts
  from.
- **Deployment configuration stays in the server configuration file**:
  runner backends, the session maximum age, the linter, the default images.

Settings never hold secrets.

What moves into the envelope, and what stays:

| Extension | Moves into `settings` | Stays in the extension |
|---|---|---|
| submission | `cutoff` (from `core.activity.kind`) | collections and their windows, limits, release timestamps |
| examination | `enabled` | the document and all authoring facts |
| pipeline | `enabled`, `trigger_run_on_submit` (from the config attachment row) | the config attachment (the binding) |
| report | `enabled`, `score_selection` (which the of-record seam reads), `default_score_visibility` (applied to new collections) | per-collection release state; the reserved per-collection `score_selection` column becomes dead and is dropped |
| sandbox | `enabled` | the pool config and its activity mapping (artefact and binding), the per-question overrides |
| environment | `enabled` | the template mapping (the binding) |
| proctoring | `enabled` (from `proctored`), `policy` | the config row as the cascade anchor for its eight dependent tables, with its settings columns dropped |

`score_selection` sits under `report` because its readers are the gradebook,
the student score read, the roster flag, and export eligibility, all report
paths; the grading snapshot in pipeline is the one other reader.

### Typed in Go, one package, one file per key

A leaf package in the core repository holds one file per key, each authored
by that extension's maintainers by convention and compiled into one static
table. "The extension contributes" means it authors that file, not that it
registers at runtime, which keeps the package free of import cycles. The
core imports the package to validate writes and to project; each extension
imports it to decode any key it needs through typed accessors. Adding or
renaming a field is a struct edit and a validator edit, no migration.
Unknown keys and unknown fields are rejected on write, because the console
is the writer and a typo must fail loudly. There is no version field; the
envelope is validated by the deployed binary, and a breaking rename, if ever
needed, is a data-rewrite migration.

## What the core is allowed to know

Centralizing the settings must not turn the core into a place that embeds
extension knowledge, and a settings change must not become a fan-out to
extensions. Six rules bound both.

1. **Core stores bytes and validates shape; the owning extension defines
   meaning.** Each key's file holds its struct, validator, and constant.
   The core calls them without reading fields. The only field the core
   understands on every key is `enabled`, because readiness needs a
   not-applicable status. A locked value is a constraint the key's
   validator declares, not a core rule.
2. **Cross-key preconditions are declared by the dependent key and
   evaluated generically over resolved values.** Proctoring's file declares
   "requires a hard cutoff" as a predicate; the core evaluates every
   declared predicate on every write, delete and inline create included,
   against the resolved envelope, without knowing what a cutoff is. The
   dependent side owns the knowledge, which is where it sits in the current code:
   proctoring reads the activity kind, submission never reads proctoring.
3. **Core never reads extension state to decide a write, and never calls
   an extension on the write path.** A write's legality is a function of
   the envelope alone. No extension views, no precheck call, no liveness
   dependency. A transition that is unsafe because of extension state is
   guarded by the client that can see that state (the console's live guard
   and confirm, a command-line warning) and reported by readiness
   afterwards, except where the owning extension applies a guard of its own
   at effect time. That is safer than the current code, where a type change has no
   guard.
4. **Extensions pull; the core publishes one notification.** The contract
   an extension relies on is the envelope, readable in its own queries
   under the boundary rule that lets any extension read the core schema,
   plus its own periodic ensure. The notification exists to cut latency,
   not to carry meaning: one publish per key changed on a per-key subject,
   best-effort after commit, over core NATS at most once. No extension is
   required to subscribe; a restarting subscriber converges by its ensure;
   nothing in the core waits for a subscriber.
5. **Core derives nothing from the envelope except declared projections,
   and any extension may read a declared value through the shared
   package's typed accessor.** The flat `cutoff` and `paper` fields on
   student reads are projections the owning key declares; the core copies a
   value, it does not interpret one. The accessor is what lets submission
   serve the coursework read with `paper` and read the report's default
   visibility when it creates a collection, both reads of core data decoded
   by the package that defines the key.
6. **Readiness is the only place the core asks extensions anything, and it
   is read-only, bounded, and optional.** One fan-out per request with a
   timeout; an extension that does not answer degrades to unavailable.

What the core embeds per extension, in total: a schema it calls but does not
read, declared predicates, declared projections, and a readiness topic. What
it never embeds: field semantics, extension tables or views, synchronous
calls on write, a subscriber it depends on, or a write into an extension's
authorization namespace.

That last item settles who provisions proctoring's authorization tuple.
Enabling proctoring writes one tuple making the activity the parent of
its `proctoring_activity` object; every relation on that object derives from
the parent, so without the tuple course staff get a permission failure on
every proctoring route, which is the off-gate in practice for staff
proctoring surfaces. The object exists as proctoring's own authorization
namespace: it holds a per-activity role the core type must not know (the
chief invigilator), circles narrower than the activity's read circle, a
reverse-of-parent room tupleset, and a place for exceptional direct grants.
Under this RFD proctoring keeps provisioning its own tuple and its anchor
row, in reaction to the enable notification with a periodic ensure over
activities whose resolved proctoring is on as the backstop, and its
off-is-total middleware lands before any tuple change so the permission
failure stops doubling as the off-gate. The core grants nothing into that
namespace, as it grants nothing into pipeline's or report's.

## Writes and reads

Only the core writes the core schema, so every settings write is a core
route:

```
POST   /activities                                  body may carry `settings`
GET    /activities/{id}                             carries `cutoff`, `paper`
GET    /activities/{id}/settings                    `settings`, `defaults`, `meta`
PUT    /activities/{id}/settings/{extension}        replace one key
DELETE /activities/{id}/settings/{extension}        back to undecided
```

- **Create with an inline envelope** makes a preset atomic: the insert and
  the key validation run in one transaction.
- **Per-key replace runs in one transaction**: lock the activity row,
  compare the `If-Match` token with the key's recorded update time when the
  header is present, validate the new key against the locked resolved
  envelope (its own validator, then every declared predicate), then write
  the settings, the metadata, and the dual-written `kind` in one update.
  The lock is what makes cross-key rules hold under concurrency: two staff
  editing different keys cannot lose each other's write, and two concurrent
  writes cannot each pass validation against a stale envelope. There is no
  whole-envelope replace.
- **Delete** removes the key and evaluates every predicate over the
  resulting resolved envelope, so deleting the submission key while
  proctoring is enabled is refused. Locked keys may be deleted; the constant
  satisfies the lock.
- **The activity read, the activity list, and the coursework read** carry
  the two flat projections and nothing else from the envelope. The activity
  queries select whole rows and the handlers return them, so the new
  columns need explicit column lists or they reach every student; a test
  asserts the student read has no `settings` key. An audit of zinc-sig/ui
  found that neither the console's student path nor the exam client's
  student path reads `kind`; the coursework read needs both fields
  (lead time, conflict detection, and enter-versus-submit intent), the
  activity list needs both for the label on the unassigned set and the
  course directory, and the activity read needs `paper` for the client's
  staff review and export path. The collections read needs nothing, and a
  flat `proctored` would duplicate the proctoring-status read students
  already have. The "Exam" and "Assignment" labels are console copy derived
  from the two fields.
- **The envelope is served only by its own route**, gated by activity edit
  rights, which is the posture the proctoring config read has for
  staff; the invigilator's config read stays on proctoring's own route.
- **Write authorization is activity edit rights for every key.** This
  widens examination: examination's own edit relation is coordinator,
  admin, or creator, while activity edit includes instructors, so an
  instructor who cannot edit a document can switch the paper off. Document
  creation already uses activity edit rights, so the switch follows the
  same relation as the binding it governs. The widening is accepted.
- **Metadata** holds, per key, the update time (transaction time) and the
  writer's user id, written in the same update as the key, so the console
  can say who decided and when.
- **Validation faults**: unknown extension, unknown field, invalid value,
  locked value, reserved key: request invalid, with the field named; a
  declared predicate violation: resource state conflict, naming the rule; a
  stale `If-Match`: a new precondition-failed category mapped to 412, with
  the current token in the body.

### Optimistic concurrency as a platform convention

The platform has no policy for concurrent mutation; the one precedent,
`If-Match` on the attachments push, is advisory. This RFD sets the
convention, with the settings routes as first adopter:

- Every mutable resource exposes a revision token on its read: the row's
  update time for ordinary resources, the per-key update time for the
  envelope.
- Replace and patch routes accept `If-Match`. Present and equal: the write
  applies. Present and unequal: precondition failed, 412, current token in
  the body. Absent: last-write-wins, documented as the caller's choice.
- For resources without a row lock the comparison is a compare-and-set in
  the update's where clause; zero rows updated means stale.
- The attachments push keeps its advisory mode as the documented exception:
  a student's autosave is never refused for a revision race.
- The convention is written into the query conventions document as the
  third update rule. Other staff full-replace writes adopt it as they are
  touched.

Every operation is idempotent: the per-key replace is a full replace, delete
is a no-op on an absent key, the apply-to-active action re-stamps a snapshot
that already matches and changes nothing, the backfill and the staging
dry-run are re-runnable, and every ensure converges from the envelope.

### The settings-changed notification

One generic message per key changed, carrying the activity id, the extension
key, the previous and current values as opaque JSON, and the update time;
the current value is empty on delete; an inline create publishes one message
per key present. The subject carries the key as its last token so an
extension subscribes to its own token and an observer subscribes with a
wildcard. It rides core NATS, at most once, with no stream and no durable
consumer; the ensures are the guarantee, and the derived-state inventory
below shows nothing depends on the notification for correctness. A durable
stream can follow if a reactor ever needs a delivery guarantee an ensure
cannot give.

## Transitions and guards

Writes are accepted whenever they are valid against the envelope; they
record intent. The owning extension reacts to the notification or converges
by its ensure, and anything it cannot reconcile becomes a red readiness check
with a precise message, for example "collection Midterm A: due must be at or
after stop for a hard cutoff". Existing collection-write validators keep
refusing new invalid windows.

| Change | What the owning extension does or checks |
|---|---|
| cutoff soft to hard | schedule force-submit for every open collection; existing windows may violate the hard-cutoff invariants and are reported |
| cutoff hard to soft | cancel scheduled force-submit workflows |
| examination on to off | deliveries may hold answers against the paper; serving stops; recoverable by re-enabling; the console confirm quotes the delivery count |
| pipeline on to off | in-flight runs finish; objective components ungrade until re-enabled; manual-only formulas still score |
| sandbox on to off | attempts, the linter, and staff test runs are refused; an existing pool idles out |
| environment on to off | the next run uses the platform image; a live pool swaps image on its next generation |
| proctoring on to off | immediate at the content gates; the console confirm quotes the live-session count; readiness records an off written while sessions were live |
| proctoring policy change | propagated to active sessions only through the explicit action route; device proof never propagates |
| report selection change | every of-record read changes at once, since selection is a query parameter evaluated at read time; `best` is locked until the seam is repointed |

The adversarial review separated these into recoverable transitions and
three that re-enabling cannot undo. Each of the three has a guard in the
owning extension at effect time, keeping the third rule intact:

- **A hard-to-soft cutoff whose cancel is lost.** The force-submit workflow
  re-reads the resolved cutoff when its timer fires and does nothing on
  soft, and the submission ensure cancels for soft activities and lists
  collections inside a grace window past their stop time so a change made
  near the stop time is still ensured. A lost cancel stamps nothing.
- **Proctoring off during live sessions.** The examination and report
  content gates read the switch from the core (retiring their direct read
  of proctoring's table and the database grant it needs), so an off is
  immediate. The hazard, serving the paper to enrolled students the
  invigilators never admitted, is a deliberate staff action guarded by the
  console confirm and a command-line warning, and recorded by readiness. An
  enforced copy that lags intent was rejected: a guard must not split one
  concept into two values.
- **A selection change to `best` after release.** The report key's
  validator rejects `best` as a locked value until the step that repoints
  the of-record seam, so the rule is a constant until then.

Applying a policy change to active proctoring sessions is a separate action
route, "apply the current policy to active sessions", called after the
settings write. It is explicit, auditable, keeps the envelope free of
extension-specific options, and closes a gap in the Go client, whose config
type lacks the flag.

### Derived state

The question that decides the transport is whether anything a reaction
mutates is not re-derived from the envelope. Only two pieces of derived
state exist, and each has or gains an ensure: force-submit schedules
(submission's ensure exists and gains cancel and the grace window) and
proctoring's tuple and anchor row (a new ensure). Two copies are never
re-read by design: the per-session policy snapshot frozen at admission,
which changes only through the explicit action, and the per-collection
visibility copied from the default at collection creation. Everything else
is read from the envelope at use time: the freeze gate, the commit clamp,
the window validators, export eligibility, the reconciler user sets, the
examination middleware and serving, image resolution at dispatch, the
pipeline dispatch gates, session create and admission, and the content
gates. Without the notification the cost is latency: staff
proctoring routes answer with a permission failure for up to one ensure
interval after enabling, and a force-submit schedule is created up to five
minutes late, which the grace window and the as-of commit semantics make
harmless.

## Readiness

```
GET /activities/{id}/readiness
```

The core fans out one request on a single subject that every extension
subscribes to, using the broker's multi-request, and collects answers until a
two-second deadline; the multi-request drains until the deadline, so a
fan-out always costs the full timeout, and the core caches the composed
answer per activity for five seconds. Answers are keyed by extension with the
worst status winning when two instances of one extension both answer. Each
extension answers for its own key with named checks:

```json
{ "extension": "submission", "status": "red",
  "checks": [
    { "id": "window_valid", "status": "red",
      "message": "Midterm A: due must be at or after stop for a hard cutoff" },
    { "id": "force_submit_scheduled", "status": "green", "message": "2 of 2 open collections" }
  ] }
```

Statuses: green; red; undecided (the key is absent; the extension is on the
constant and staff have not recorded a choice); not applicable (the key is
present and disabled); reserved (while a key is not yet live: the key
is not yet live, the extension's own table is authoritative, and its checks
reflect that table); unavailable (the extension is enabled but did not
answer within the deadline, or is not registered). Overall status is the
worst applicable one; undecided and reserved are their own lines, never
folded into green.

An undecided answer reports the constant, so the console draws every
undecided row from the settings read and the constants table without a
fan-out; the extension may still say what it sees ("a paper exists; enable
to serve it") so staff know what a decision would change. The setup list's
count of pending decisions is the count of absent keys.

First-cut check lists, each owned by its extension: submission checks that
at least one collection exists, every window is valid for the cutoff, a
force-submit schedule exists per open collection under a hard cutoff, and
membership is not empty; examination checks that the document exists,
materialization is current, and marks are complete; pipeline checks that a
config is attached and consistent with the modality, the formula is
materialized, the image resolves, and the runner backend is healthy; report
checks that the selection is decided; sandbox checks that a pool config is
bound, the executor image is available, and every coding question has an
execution config or inherits the pool's limits; environment checks that a
template is assigned and its last build succeeded, which needs the build
outcome the console has already asked for; proctoring checks that rooms
exist, a chief invigilator is assigned, identity verification is permitted
by the server-wide flag, and the media server is reachable when live media
is on.

Readiness reports and never gates. Every status transition stays allowed,
and the readiness strip puts the verdict in front of the person pressing
activate. A gate that refuses activation on a red check is a later
follow-up. The overview page derives readiness client-side from four
per-extension summary reads under an earlier constraint that the core
aggregates nothing; this RFD centralizes the verdict, and the summary reads
stay for detail. An enabled extension that is not registered reports
unavailable, which is the rail state the console has no source for.

The console rail models three row states (applicable, disabled,
unavailable). Readiness maps onto them and adds two: applicable splits into
green and red, disabled is a present key with `enabled = false`,
unavailable is unchanged, and undecided and reserved are new row states the
rail gains in the console step.

## The modality rule and online homework

The two modalities are exclusive by rule: with the paper on, the console's
file-upload surface is off and prescreen rules are shown as not applicable;
with it off, the exam client is not offered. The console's document-presence
gates read the examination switch instead. The rule lives on the console
surface, and two server behaviours are recorded as known gaps: the exam
client pushes answers as per-question text attachments through the same
attachments route the console upload uses, and the push applies the
collection's prescreen ignore filters with no modality check, so an ignore
filter matching text files on a paper collection drops answers silently; and
export eligibility keys on the type before this RFD and on the paper axis
and "every collection past its stop", which makes a soft-cutoff paper
activity exportable once its windows end. Server-side enforcement, if ever
wanted, is a marker on the client's negotiated push and a refusal of
unmarked uploads on paper activities.

Nothing in the core prevents a soft cutoff with a paper. The gaps are in
the clients and in semantics: the exam client's entry gate compares the
session cap with the window end for every activity it opens, so a two-week
window trips the twelve-hour cap on every visit and the gate must apply
only under a hard cutoff; the student home and course cards key intent and
lead time on the type and should key intent on `paper` and lead time on
`cutoff`; late answers after the due time under a soft cutoff accrue delay
as attachments do, which needs a product decision; and force-submit does not
run, so a student who never commits stays a no-show. None of these block the
settings work; they are the checklist for the day the combination is
supported.

## Backfill contract

Two failure modes are forbidden: a silent enable, where the backfill writes
an on that is not in effect before the migration; and a silent disable, where a key is left
absent and its constant off switches off something that runs before the migration. One rule
prevents both: a key is written on only where the owning extension's own
table proves the capability is in use before the migration, never inferred from another
extension's state (a document never turns pipeline on); a key is left absent
only where the behaviour before the migration already equals the constant. Each key is
backfilled by the migration of the step in which it goes live; until then
the extension's table stays authoritative and the constant does not apply to
that key.

| Key | Goes live in | Source of the behaviour | Backfill writes | Left absent when |
|---|---|---|---|---|
| submission | the intermediate | `core.activity.kind` | every activity: on, `hard` for `exam`, else `soft` | never |
| examination | the intermediate | the document row | on where a document exists | no document |
| environment | the intermediate | the template mapping | on where a mapping exists | no mapping |
| report | the intermediate | the hardcoded selection and the collection default | every activity: on, `latest`, `none` | never |
| pipeline | the moves | the config attachment | on with the trigger copied, where a config is attached | no config |
| sandbox | the moves | the pool mapping | on where a mapping exists; the pool config itself stays | no mapping |
| proctoring | the moves | the config row | `enabled` from `proctored` and the policy copied, where a row exists; an explicit off row becomes a decided off | no row, which preserves the undecided signal |

Three further guarantees: the backfill emits no notifications, so no
extension reacts to the migration and existing force-submit schedules are
untouched; each step that backfills ships with a warm-stack migration test
that asserts, for every activity and every key going live, that the resolved
value after equals the behaviour before, derived from the source table in
the same test, and that exercises the down migration; and staging gets a
re-runnable dry-run query before deploy whose expected output is empty.
After that a key changes only by an explicit staff write or a recorded
return to undecided.

## Delivery steps

The three settings that already have a home in an extension table
(proctoring's switch and policy, pipeline's trigger, and the sandbox switch's
structural equivalent) move only after an intermediate that touches no
extension table has been verified.

**The intermediate.** Core: both columns, the backfill of the four
keys that have no existing home, the dual-written `kind`, the shared package
with all seven files (three marked reserved and rejected on write), the
settings routes, explicit column lists on the activity reads with the two
projections, and the notification; `kind` leaves the write DTOs.
Submission: readers move from `kind` to the resolved cutoff; the cutoff
reactor, the force-submit fire-time guard and cancel ensure, the coursework
projections; the report's default visibility applied on collection create.
Examination: the off-is-total middleware on its route group with the
route-coverage test. Environment and pipeline: the environment-off branch in
image resolution and in the sandbox executor. Proctoring: the enable
precondition reads the cutoff from the envelope. Console and command-line
presets write the four live keys.

`kind` stays, with its default, and is dual-written from the resolved
cutoff in every settings transaction. The reads select whole rows, a cutoff
changed through the settings route would otherwise leave the column stale,
and the down migration would then restore behaviour from a stale column and
revert staff decisions. With dual-write the compatibility field is correct
with no handler code and the down migration is lossless for the cutoff; the
column drops after the console readers move.

**Readiness.** The core route, the caching fan-out, and the
submission, examination, environment, and proctoring responders, with
reserved keys answered from the extension's own table.

The verification gate for the intermediate and readiness, mapped to test tiers: unit
tests on the shared package (decode, validators, predicates over resolved
values, projections); route-wiring tests updated for the four routes;
integration on a warm stack: two concurrent writes to different keys both
land, two to the same key with `If-Match` yield one 412, a proctoring-on
with cutoff-soft pair is refused on replace and on delete, the full
submission suite is green with no reader of `kind`, a cutoff change
schedules and cancels force-submit, a timer firing on a now-soft activity
stamps nothing, the migration test holds and exercises down and up, the
student activity read has no `settings` key; end-to-end tier, with built
binaries since registration identity exists only there: one stopped
extension reports unavailable, and undecided, reserved, not applicable, and
green are each observed.

**The moves.** One extension per change, in this order: pipeline's
trigger (one reader plus the manual and batch trigger gates, no console
surface); proctoring's switch and policy (the content gates move to the
envelope and the cross-schema grant retires, the requires-hard-cutoff
predicate goes live, the off-is-total middleware and its route-coverage test
land before any tuple change, proctoring provisions its own tuple and anchor
with an ensure); the sandbox switch (only `enabled`, the off-gate, and the
readiness responder; the pool config stays as sandbox's artefact with its
routes unchanged). Report: the of-record seam repoints to the envelope's
selection together with the unlock of `best`, then the existing follow-up
that exposes the resolved selection on a roster-reachable read. The
per-collection `score_selection` column is dropped. Presets gain the three
keys.

**The console.** The settings rail on the envelope with presets in
the create dialog, the undecided and reserved row states, the readiness
strip, the type readers rerouted, the mixed-combination presentation for the
two unsupported axis combinations, then the proctoring config and runtime
forms writing to the settings routes as each move lands. The interface needs
its own visual design round with running candidates before any choice.

### Decision status by step

| Step | Status | Still open |
|---|---|---|
| the intermediate | decided and specified in the core plan document | ordinary implementation choices |
| readiness | decided in shape | each extension's check list, which the first rule leaves to the extension; the environment build check waits on the build-outcome item |
| the moves | decided in direction | a short specification per move before it starts, including what proctoring does with its own live sessions on an off |
| the console | decided in direction | the interface itself; the mixed-combination presentation; the off-state page |

### Deferred

Exam and assignment as stored templates (contract-neutral, because create
takes an inline envelope); the online-homework checklist; a readiness gate on
activation; the console presentation of the two mixed axis combinations.

## Implementation

The intermediate's specification lives in the core repository as a plan document
and is removed when that step is complete. Its contents, in outline: the
shared package shape (an envelope type of raw JSON per key; a per-key
specification with a zero value for strict decoding, the constant, a
validator, declared predicates, and declared projections; a resolver
returning the resolved view; validate and delete helpers that run the
validator and every predicate over the resolved envelope), the route DTOs
and fault categories, the metadata column shape, the migration with its
backfill statements and down side, the notification message and subject
constant, the readiness request and response messages with the deadline and
cache, the explicit column lists and the two projections on the three reads,
the rewrite of the nine type predicates in the collection queries and the
two in the export queries, the force-submit reconcile and fire-time guard,
the examination route-group middleware, the environment-off branch, the
console and command-line preset envelopes, and the test mapping above.

The change surface, by repository: in the core, the activity type column and
DTOs, the activity queries, the swagger and Go client, the command-line
type flag, the demo and end-to-end scenarios, the coursework read, the
submission readers of the type, the proctoring precondition read, and, in
the moves, the proctoring config routes and policy provider, the
pipeline attachment DTO and dispatch gates, the sandbox execution entry
points, and the content gates' proctoring read. In zinc-sig/ui, about thirty
console readers of the type across the navigation model, the overview
derivations and rail actions, the export hooks, the student home and course
models, the admin and create forms, plus the client's staff review route;
the document-presence gates read the examination switch. The frozen base
migration's schema comments stay as they are, with the follow-up migration
carrying the superseding note; the submission and proctoring package
documents, the repository agent instructions, the query conventions
document, and the console navigation gaps document are updated as each
step lands.

## UX

Staff see one settings rail per activity with one row per extension: a
switch, the extension's policy fields, who decided and when, and the
readiness verdict with its named checks. Undecided rows say what the
constant does and what a decision would change. Extension artefacts
(templates, pool configs, papers) keep their own pages. Exam and assignment
are presets in the create dialog. Students see no settings; their surfaces
carry the cutoff and the paper flag and derive their copy from those.

The command-line client replaces its type flag with settings get, set, and
unset commands and prints a warning on the transitions the console confirms.
The model-context-protocol server's read tools read the envelope.
