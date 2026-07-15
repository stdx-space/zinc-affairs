# [RFD] ZINC Extension System

---

authors: Thomas Li
state: implemented
discussion: [#7](https://github.com/zinc-sig/affairs/pull/7)
labels: `infrastructure`

---

## Revision note (2026-07-15)

The original RFD (below, preserved in spirit) proposed the modular, event-driven
vision that motivated the split of ZINC into a core plus pluggable extensions.
That vision shipped — but the *implemented* system diverged from the original
text on several load-bearing points, and the rules that actually govern it grew
up **outside** this document (in `core: database/queries/README.md` §3, in
`core: PACKAGES.md`, and in code comments). This revision reconciles the RFD
with reality and, more importantly, writes down the two boundary rules whose
**absence** was actively causing bugs:

1. the **three-transport model** (the original "events for everything" is no
   longer true), and
2. the **responsibility boundary** — *which* extension is allowed to perform
   *which computation* — plus the **capability-seam doctrine** (how one
   extension exposes a capability to another, and the ban on silent-nil seams).

The motivating incident is documented inline as a case study (§7): a
user-facing per-question-points feature that had **never worked in any real
deployment** because a cross-extension capability was wired as an optional,
in-process-only seam that silently degraded to nil. It passed every test,
violated no lint, and shipped dead. The rules here exist so that class of
failure becomes a red CI run instead of a silent one.

---

## 1. Overview

ZINC manages grading of programming assignments, collection of student
submissions, computer-based examinations, and student scores in university
courses. It is built as a **core** plus a set of **extensions**: independent
domains, each owning a slice of behavior and a schema, deployed as separate
processes and communicating over well-defined channels. The goal is the
original one — flexibility, independent evolution, and scalability — but the
system is a **modular monolith**, not a pure microservice mesh: the extensions
share one database and one generated ORM, and the boundary between them is
**logical**, enforced by convention and lint rather than by the network.

That "shared substrate, logical boundary" reality is the single most important
fact the original RFD omitted, and everything in §3–§6 follows from it.

## 2. Background

The pre-extension ZINC was a monolith: tightly-coupled features, all-or-nothing
scaling, and change ripple. The extension system addressed this by carving the
monolith into domains along ownership lines. What the original RFD under-specified
— and what this revision fixes — is that carving a system into domains raises two
questions the original answered for *data* but not for *computation*:

- **Data:** who may read/write whose tables, and over what transport? (Answered
  by `database/queries/README.md` §3, R1–R5 — summarized in §4.)
- **Computation:** within a multi-extension derivation, which extension is
  allowed to *perform* which step? (Answered nowhere until §5 of this document.)

The second gap is subtle and expensive: data ownership can be perfectly correct
while the *computation* is placed in the wrong extension, and no data-boundary
lint will catch it (§7).

## 3. Architecture as implemented

### 3.1 Core and extensions

- **Core** — the shared, read-only foundation. Owns courses, terms, users,
  activities, and the course↔student relationship. Every extension may read and
  hold FKs into `core.*`; only core writes it. An **activity** is the unit an
  extension attaches to (an assignment, an examination — these are *activity
  types*, not extensions; see §6).
- **Extensions** (each owns a schema, deployed as its own process):
  - **submission** — collections, deliveries, the submission window.
  - **pipeline** — the grading runtime: runs each question's configured
    execution and produces exec results.
  - **report** — the `evaluation` domain: scoring formulas and computed scores /
    per-component breakdowns / overrides.
  - **examination** — exam documents, questions, contexts, answer modalities,
    marking schemes. Owns the authored exam and the derived grading config it
    materializes from it.
  - **sandbox** — interactive single-question runs / authoring sandbox.
  - **environment** — per-activity environment/image templates.
  - **proctoring** — live invigilation, capture, chat, review flags.

> The original RFD's roster (grader / submission-collector / scoring) has been
> superseded: "grader" is **pipeline**, "scoring" is **report** (owning the
> `evaluation` schema), and examination is a first-class extension.

### 3.2 One database, logical boundaries

All extensions connect to **one Postgres** with **one generated ORM package**
(`orm`). A schema (`submission`, `pipeline`, `evaluation`, `examination`,
`sandbox`, `environment`, `proctoring`, plus `core`) is *owned* by exactly one
extension. The boundary is **logical**: it is not enforced by database
credentials — every process can technically reach every table — but by
convention and `scripts/boundary_lint.sh` (CI). The rules keep a future physical
split *possible* (R5) and, more importantly, keep each schema's invariants in
one owner's hands.

### 3.3 Transports — the three-transport model

**This supersedes the original RFD's "state changes are triggered by events, not
direct RPC calls."** The implemented system uses **three** transports, and which
one you use is **not** a free choice — it is determined by the shape of the
interaction (`database/queries/README.md` §3 R4):

| Interaction shape | Transport | Example |
|---|---|---|
| **Sync request/response** (caller needs an answer now) | **NATS request/reply** (protobuf) | report → examination: "resolve `document.*` for activity X"; examination → report: `UpsertDerivedFormula` |
| **Async fact propagation** (a thing happened; others may care) | **JetStream events** | lifecycle facts |
| **Orchestrated multi-step** (a durable workflow) | **Temporal activities** on the owner's task queue | grading fan-in: `ScoreSubmission` runs on report's queue with the snapshot pinned as workflow data |

Dead subjects are deleted, never left ambient. Two transports for the same
interaction is a bug: every reader would have to check both.

## 4. Cross-extension data boundaries (R1–R5)

These live normatively in `core: database/queries/README.md` §3 and are enforced
by `just boundary-lint`. Summarized here because they are architectural, not
merely a SQL style guide:

- **R1 — core is the shared read-only foundation.** Any extension may read/join
  `core.*` and hold FKs into it; only core writes it.
- **R2 — sibling reads go through the owner's published contract**: the views the
  owning schema designates public, **or an existing service/Temporal/NATS data
  flow** (see §5.1 — an owner's exported resolver is such a flow). New direct
  reads of a sibling's *base tables* are lint failures.
- **R3 — sibling writes are forbidden**; cross-extension mutation goes through
  the owner (NATS request/reply or a Temporal activity on the owner's queue).
  Reference case: the **derived-mode materialization** (§5.3).
- **R4 — transport selection is fixed** (the table in §3.3).
- **R5 — existing extension→extension FKs stay** and are documented inline; a
  physical DB split must first replace them.

> **Known enforcement gap (to close — see §8):** `boundary_lint.sh` is
> *SQL-file-level*. It catches a query file referencing a sibling's base tables,
> but it is **blind to a Go-level cross-read** — e.g. one extension's process
> calling another extension's exported query function against the shared DB.
> R2 forbids that in spirit; the lint does not catch it. An import-graph check
> is needed to make R2 mechanically enforceable.

## 5. Responsibility boundaries (new)

Data ownership (§4) says *who owns the bytes*. It does **not** say *who is
allowed to compute what*. This section fills that gap. It is the rule whose
absence caused §7.

### 5.1 Facts, programs, and verdicts

Model every cross-extension exchange as one of three things:

- A **fact** — an observed, owned datum. Examination's `document.*` (a question's
  id, type, marks) is a fact examination owns and may attest to.
- A **program** — a late-bound artifact to be evaluated later, against inputs not
  all present at emit time. A scoring formula's HCL is a program (its
  `max_score = document.examination.questions["q3"].marks` is an *expression*,
  bound when evaluated, not when written).
- A **verdict** — the *result* of evaluating a program against facts. The
  numeric per-question points (`components`), or a delivery's score, are
  verdicts.

**The rule:**

> **Extensions exchange facts and programs, never verdicts. The owner of an
> artifact's semantics evaluates it — at its own binding time, at the point
> where every input is visible. Data owners only attest.**

Corollaries:

- **Evaluation lives at the join point** — the extension that observes *all*
  inputs of the evaluation at evaluation time. If evaluating `f(A, B)` and
  extension X sees only `A` (and only at X's write times), X is not the join
  point, no matter who "started" the derivation.
- **Shipping a program across a boundary is fine** (it stays late-bound);
  **shipping a verdict across a boundary is a smell** — it freezes binding-time
  and rule-version in the wrong place and couples the consumer to the producer's
  evaluation moment.

### 5.2 Materialize vs. evaluate

A derived artifact is **materialized** by whichever extension can *project* it
from data it owns, and **evaluated** by whichever extension is the join point for
its inputs. These are frequently *different* extensions, and conflating them is
the trap:

- Examination **materializes** the scoring formula (a *program*) by projecting
  the document — legitimate, it owns the document.
- Report **evaluates** that formula (into *verdicts*: components, scores) —
  legitimate, report owns the formula *and* is the only party that sees both the
  formula and `document.*` at evaluation time.

Materialize-and-ship (a program) ≠ evaluate-and-ship (a verdict). The first is
the derived-mode pattern (§5.3); the second violates §5.1.

### 5.3 The derived-mode materialization pattern

The sanctioned pattern for a document-owned projection to reach another
extension's schema (R3): the source-of-truth owner **generates** the derived
*program* and **pushes** it to the owning extension via a NATS request/reply;
the owner writes its **own** schema behind a `managed_by_document` guard (so the
HTTP surface rejects manual edits to derived rows).

```
examination (document saved) --materialize--> FormulaHCL (a program, projected from the document)
   --NATS UpsertDerivedFormula--> report writes evaluation.formula (managed_by_document=true)
```

Note what is *not* shipped: the evaluated components. Those are verdicts; report
computes them at its own read time from (formula + document.*), because report is
their join point.

## 6. Cross-extension capability seams (new)

When one extension needs a **capability** from another at request time (e.g.
report needs examination to resolve `document.*` for an activity), that seam has
a mechanism *and* a binding discipline. Getting the mechanism right but the
binding wrong is exactly how §7 happened.

### 6.1 Two legitimate read-seam mechanisms

- **Co-located owner-code seam** — the owner exports a function/service
  (depending only on the shared repo + storage) that a consumer links into its
  own process graph. Precedent: sandbox links `examination.NewGradingAssets` /
  `NewMiddleware` in-process (`core: internal/app/app.go`). Doctrine: *"a free
  function is the right seam, not a service instance or a network hop"*
  (`core: internal/api/examination/snapshot.go`). Cheapest; correct while the
  monolith is deployed from one image (no version skew). Weaker isolation.
- **NATS request/reply to the owner's process** — the consumer calls the owner
  over the bus; the owner resolves in *its* process and returns the fact.
  Forward-compatible with a real physical split (separate DBs/storage/scaling);
  costs a hot-path round-trip and a **liveness dependency on the owner's pod**.

### 6.2 The tie-breaker

The codebase carried **two contradictory seam doctrines with no tie-breaker** —
R4's "sync request/response → NATS" versus snapshot.go's "a free function is the
right seam, not a network hop." A seam built to neither (§7) is what results.
The tie-breaker:

> **Default to the co-located owner-code seam for reads.** Choose the NATS
> request/reply transport when — and only when — real physical isolation
> (separate DBs, separate storage credentials, independent scaling of the two
> extensions) is an actual roadmap goal for that pair, not R5's "keep it
> possible" aspiration. The transport buys process isolation; do not pay for it
> unless you are going to use it.

Either way, the write/side-effect direction is **always** transported per R4 —
this tie-breaker governs *reads* only.

### 6.3 HARD RULE — no optional, silent-nil production capabilities

This is the rule §7 violated, and the one that matters most:

> A cross-extension capability that a **production** code path depends on **must
> be bound** (a required provider), never an `optional` dependency that
> silently falls back to nil. If a capability can *legitimately* be absent in
> some deployment, its absence must be **explicit and API-visible** (an error,
> or an empty result *with a stated reason*), **logged/metered at boot**, and
> **asserted by a deployment-graph test** (§8). A silent nil that makes
> "feature is broken" indistinguishable from "there is no data" is banned.

## 7. Case study — the per-question-points seam (why these rules exist)

**Symptom.** The exam client shows per-question max points ("· 8 pts") from
`GET /activities/:id/formula` (report), in a `components` field. In every real
deployment the field was always empty; per-component override re-scoring (essay
marking, `ApplyComponentOverride`) was also dead.

**Mechanism.** Producing `components` means evaluating the formula's `max_score`
expressions against `document.*` (a verdict). Report did this at read time via
`pipeline.DescribeComponents(formula, snapshot)`, where `snapshot` came from a
`SnapshotResolver` capability. That capability was declared `optional:"true"` and
implemented as an **in-process fx binding** meant to be satisfied by examination
— but report and examination run as **separate processes**, the binding was never
made in any real graph (it existed only in a code comment), so the capability was
**nil**, and `describeFormulaComponents` silently returned no components. Initial
grading survived only because Temporal carries the snapshot as workflow data, so
the failure was invisible where anyone was looking.

**What each rule would have caught:**

- §5.1/§5.2 — the responsibility split was actually *correct* (examination
  attests `document.*`; report evaluates). One tempting "fix" was to have
  examination compute and ship `components` at materialize time. §5.1 forbids it
  (that ships a *verdict*), and the decisive functional reason is the join-point
  corollary: `components = f(formula, document)`, and examination never sees
  instructor-authored formulas (the staff-authored `Source` path never passes
  through examination's materializer) — so examination is not the join point.
  Report is.
- §6.2 — the seam was built to neither doctrine; the tie-breaker resolves which.
  (Decision on this instance: use the NATS transport, as physical isolation is a
  desired direction — but the durable rule is §6.3, not the transport.)
- §6.3 — the actual defect. Had the capability been *required* (or its absence
  API-visible + boot-logged + graph-tested), the feature could never have shipped
  dead and silent.

## 8. Guardrails

Rules that live only in prose get violated. These make the rules mechanical.
Priority order (agents and humans obey **lints > README > RFD**, so invest
accordingly):

1. **Deployment-graph capability-assertion tests** (highest value). Each
   `NewXExtension` opts set gets an `fx.ValidateApp` + an `fx.Invoke` asserting
   every declared cross-domain capability the extension's production paths use is
   **non-nil**. Turns "documented dead seam" into a red CI run. (Extend the
   existing `TestProctoringExtensionGraph` pattern.)
2. **Ban silent-nil degradation (§6.3) in code.** A tiny `capability.Unavailable[T](reason)`
   sentinel + a rule: an `optional` cross-domain dependency is allowed only if
   absence yields an explicit, API-visible outcome **and** a boot-time
   log/metric. Reviewers reject a silent field omission on absence.
3. **Evaluation-locality lint + import-graph check.** A `boundary_lint`-style
   script: `pipeline\.(EvaluateFormula|DescribeComponents)\(` permitted only
   under `internal/pipeline/` and `internal/api/report/`. **And** close R2's Go
   blind spot (§4) with an import-graph check (`go list -deps` / go-arch-lint)
   declaring which `internal/api/*` packages may import which — mechanically
   killing cross-extension in-process base-table reads instead of trusting nobody
   tries it.
4. **One end-to-end smoke on the real split topology.** The simulate stack runs
   the true multi-process deployment; assert `GET formula` returns non-empty
   `components` for a seeded exam and that an override round-trips. This is the
   only guardrail that catches "inert in production" *as such*.
5. **Doc placement.** Normative one-liners go into `database/queries/README.md`
   §3 (the doc with teeth) as new rules — R6 (capability-seam mechanisms +
   required-binding) and R7 (evaluation locality / facts-not-verdicts). Core
   `CLAUDE.md` gets a pointer. This RFD keeps the rationale.

## 9. What is / isn't an extension (retained)

**Should be an extension:** specialized processing (grading, plagiarism
detection), external integrations (proctoring hardware, LMS), optional features
not every deployment needs, resource-intensive/independently-scaled work, and
domain-specific enhancements.

**Should NOT be an extension** (stays in core): fundamental data models
(students, courses, activities), **activity types** (examinations, assignments,
quizzes are configurations of one concept — a deadline-bound student
submission — not extensions), authentication/authorization, core data
persistence, and the primary UI/API surface.

**Example — examination vs. proctoring:** examinations are activities with
constraints (time limits, controlled access), so "examination" is an activity
type. The *authored exam content and its grading derivation* is the
**examination extension**; webcam/screen monitoring, lockdown, live dashboards,
and cheat detection are the **proctoring extension**.

## 10. Open questions

1. **Physical-split roadmap.** §6.2's tie-breaker hinges on whether a genuine
   physical split is planned for a given extension pair. This should be an
   explicit, per-pair decision recorded somewhere durable, not re-litigated per
   seam.
2. **Contract-view reach.** R2's cleanest sibling-read channel is a contract
   view, but views cannot reach object storage — data that lives in blobs (e.g.
   marking-scheme `marks`) cannot be exposed as a view without promoting it to a
   column. When is that promotion worth it vs. a resolver seam?
3. **Event vs. RPC for facts.** Some current sync RPCs could be async facts with
   consumer-side caches, and vice versa. A checklist for the R4 choice would
   reduce case-by-case debate.

## 11. Conclusion

The extension system delivered the modularity it promised, but its governing
rules outgrew the original RFD and scattered. This revision re-centers them:
three transports (not events-for-everything), a shared-database logical boundary
with R1–R5, and — new — a **responsibility boundary** (facts and programs cross
the wire, verdicts do not; evaluation lives at the join point) plus a
**capability-seam doctrine** with a required-binding rule and a tie-breaker for
in-process vs. transported reads. The §7 case study is the cautionary tale these
rules answer: correctness of *data* ownership is not sufficient; *computation*
placement and *capability binding* are first-class, and must be enforced by
lints and graph tests, not left to prose.
