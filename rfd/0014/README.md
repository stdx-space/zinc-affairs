---
authors: Thomas Li
state: published
discussion:
labels: direction, ux
---

# [RFD] Examination → Config builder / sync

This RFD scopes the relationship between an **examination document** (the
question metadata authored by an instructor on the Documents tab) and
the **v3 pipeline config + formula** that grade it. [RFD
0013](../0013/README.md) ships the v3 HCL language and the lint surface
but defers the question of how those configs come into existence. Today
an instructor has to author both HCL files by hand, even when the exam
is structurally identical to others the platform already grades. This
RFD answers that question by making the document the source of truth and
treating the pipeline + formula configs as derived artifacts, with one
narrowly scoped exception for coding questions.

## Premise

**For any examination that contains no coding questions, an instructor
must be able to create the exam and ship a fully-graded activity
without touching HCL.**

This is the primary constraint of the RFD; the rest of the design
follows from it. MC, TF, SA, and essay-style questions all have shapes
that the platform can mechanically translate into a `diff`-style
pipeline plus a matching formula. Coding questions are excluded from the
premise because they require per-question authoring (build commands,
test stdin/stdout expectations, language toolchains, marking criteria)
that is not mechanically derivable from question metadata alone.

## Decisions at a glance

The whole design in one table; each row links to its detail section.

| Area | Decision |
|---|---|
| [Position](#proposal-position-c-with-a-coding-question-exception) | Document is the source of truth; pipeline + formula configs are derived, never hand-edited for non-coding modalities. |
| [Coding exception](#coding-question-authoring) | Each coding question owns one HCL fragment (`pipeline` + `component`) stored in its marking-scheme blob. The only HCL surface. |
| [Cardinality](#cardinality) | activity, document, and config are 1:1:1. No shared/reused configs. |
| [Versioning](#materialization-timing) | Configs mutate in place; no history, no per-run config snapshot. |
| [Marking scheme](#marking-scheme-schema) | Typed per-modality blob carries marks + answer key + (coding) `grading_hcl`. `accept` stored-not-honored in v1; `reference`/`rubric_typst` are human-facing. |
| [Coding skeleton](#coding-skeleton-responsibility-model) | Backend seeds a no-op; the authoring layer (import agent / picker) writes the language skeleton from `CodingModalityInfo`. Backend never language-aware. |
| [Scoring policy](#scoring-policy) | Per-exam HCL on the document; structured-form UI with a raw-HCL advanced mode. |
| [Materialization](#materialization-timing) | Generator runs eagerly on save; the config column is authoritative (no re-materialize at grading-run). |
| [Linting](#linting) | Coding fragment lints against two synthesized shells (pipeline-scope + formula-scope). |
| [Import integration](#examination-import-integration) | The document-import path targets this schema and authors coding skeletons (design only here). |

## Background

The legacy v2 system had a "Generate from document" button (the now-deleted
`examination pipeline generate` endpoint) that produced a pipeline
config tied to the current document. It existed because the v2 config
language was verbose enough that hand-authoring was not feasible for
non-engineer instructors, but the design had three recurring failure
modes:

1. **Regeneration was destructive.** Clicking regenerate overwrote any manual edits; the UI shifted the decision onto the user with an "any manual edits will be lost" warning.
2. **The document was the source of truth in name only.** Once generated, the HCL was authoritative; document changes drifted without notice and the fix was to regenerate and re-check by hand.
3. **The generator owned every modality-mapping decision.** Batching strategy, stdio paths, and asset resolution all lived in generator code, opaque to the instructor and only discoverable by reading the output.

v3 (RFD 0013) changed this by making the HCL itself smaller and
more inspectable, but deferred the mapping between document and HCL.
This RFD picks an answer and commits to enough schema to make it
executable end-to-end for non-coding modalities.

## Scope

### In scope

- **Position commitment.** Document is the source of truth for grading
  configs; pipeline + formula configs are derived artifacts.
- **Per-modality marking-scheme blob schema.** A typed shape for the
  per-question `SolutionData` blob, replacing the current opaque bytes.
- **Coding-question grading HCL placement.** Lives inside the coding
  question's marking-scheme blob as a `grading_hcl` string field.
- **Scoring-policy storage.** A new exam-wide `scoring_policy_hcl`
  field on the examination document.
- **Generation contract.** The deterministic mapping from
  (document, per-question marking schemes, scoring policy)
  to assembled pipeline + formula HCL.
- **Editorial surfaces.** Documents tab and Grading tab UI changes
  required by the new model.
- **Lint contract.** How the inline HCL editor validates the coding
  fragment before save.

### Out of scope (deferred to follow-up RFDs)

- **Manual grading of essay questions.** Essays carry marks but aren't
  auto-graded in v3; a separate RFD covers manual scoring. Adding a
  `component "essay"` later is a **future breaking change** (see [Open
  follow-ups](#open-follow-ups)).
- **Re-grading mechanics.** Data-model implications are here; the
  execution flow is the runtime RFD's concern.
- **The v2 generator code path.** Replaced entirely; existing v2
  configs are rewritten by hand, not migrated.
- **Multi-language coding-question authoring.** `CodingModalityInfo` is
  unchanged; per-language conventions live in the authored fragment.
- **Language-template library content.** The RFD commits to the picker's
  existence and the skeleton shape; the per-language template content is
  operational (versioned outside the RFD).
- **Class-bound configs.** v2's one-config-many-activities is dropped
  (see [Cardinality](#cardinality)).
- **Modality changes after creation.** Modality is immutable (the
  current `UpdateQuestionDTO` exposes only `display_name`/`tag_ids`);
  wrong-modality means delete and recreate.

### Not retained from v2

- The destructive "Regenerate" button and its "edits will be lost"
  warning; no equivalent action.
- The "Save Scores" control: the Documents tab is redesigned, and the v2
  button would miscommunicate the new semantics.
- The one-shot `examination pipeline generate` endpoint; generation
  now runs on save.
- One-config-many-activities attachment (see [Cardinality](#cardinality)).

## Proposal: Position C with a coding-question exception

The grading configs (pipeline + formula) are **always derived from the
document and its per-question marking schemes**. The instructor never
sees the assembled HCL as an editable artifact for non-coding
modalities. Coding questions get one narrowly scoped exception: a
per-question authored HCL fragment that owns the grading logic the
platform cannot mechanically infer, stored inside the coding question's
marking-scheme blob.

The organising decisions:

1. **The document drives the config.** Non-coding questions (MC, TF, SA) are mechanically translated to pipeline + formula HCL by the generator. The `pipeline.config` row is derived materialized state, not authoring input. Per-question rubric data lives in the marking-scheme blob; exam-wide scoring policy lives on the document; the assembled config is a pure function of these inputs.
2. **Coding questions are the only HCL surface.** Each coding question owns one HCL fragment, stored inside the coding question's marking-scheme blob: one `pipeline "<qid>" {...}` block (the grading DAG) plus one or more `component "<label>" {...}` knob blocks (the score expressions), where each label is any `[a-zA-Z0-9_-]+` knob name that the generator namespaces to the global name `<qid>` (label equal to the qid) or `<qid>-<label>`. No other modality has an HCL surface.
3. **Cardinality is strict: activity, document, and config are 1:1:1.** No cross-activity reuse, no shared configs, no shared documents. To reuse grading logic, copy the document.
4. **Configs mutate in place.** No version history on the `pipeline.config` or `evaluation.formula` rows. Past grading runs carry their results; they do not store a snapshot of the config that produced them. Re-grading uses the current state.

### Cardinality

A single examination document belongs to exactly one activity; the
activity carries exactly one document; one config is derived from
that document. 1:1:1, enforced as a chain.

Practical consequences:

- The `pipeline.config` and `evaluation.formula` rows are keyed to the
  activity (via `pipeline.config_activity` / `evaluation.activity_formula`,
  upserted by activity id) and flagged `managed_by_document`, not FK'd to
  the document. They are children of the activity's document by ownership
  flag, not free-floating entities: they keep their own integer ids and
  stay readable at `GET /configs/{config_id}` and
  `GET /activities/{activity_id}/config`, but have no independent write
  surface.
- The v2 affordance "attach existing config X to activity Y" is dropped.
  Two activities cannot share grading logic; if they should, copy the
  document.
- The activity's config-attachment endpoints (POST/PUT/DELETE) are
  retired. The config exists when the document exists.

This is a significant schema-level change and a backwards-incompatible
shift from v2.

## Marking-scheme schema

The marking scheme is the canonical home for *everything an instructor
authors about how a question is graded*. The current per-question
opaque `SolutionData []byte` becomes a typed JSON blob whose shape is
determined by the question's modality.

### Versioning

Per-question marking schemes already version via
`marking_scheme_meta.active_version_id`. Schema changes inherit that
versioning. Each save (marks change, correct-answer edit,
SA match-option toggle, coding HCL edit) bumps the version for *that
question's* marking scheme, not for the document as a whole.

Putting coding HCL in the marking scheme keeps versioning per-question,
so editing one coding question's pipeline does not bump versions on
unrelated questions.

### Per-modality blob shape

Each per-question blob has a shape determined by the question's
answer-modality type. The blob does **not** carry a `type` field. The
question's modality (from `answer_modality_meta`) dictates the schema
applied at read time.

| Modality | Blob shape |
|---|---|
| `mc`     | `{ "marks": 5, "correct_choice": "B" }`; `correct_choice` must be a key of the question's `MultipleChoiceInfo.choices`. |
| `tf`     | `{ "marks": 3, "answer": true }` |
| `sa`     | `{ "marks": 5, "expected": "...", "accept": ["..."]?, "match_options": { ... }? }` |
| `essay`  | `{ "marks": 10, "rubric_typst": "..."?, "reference": "..."? }` |
| `coding` | `{ "marks": 30, "grading_hcl": "pipeline \"q1\" {...}\ncomponent \"q1\" {...}", "reference": "..."? }` |

Fields marked `?` are optional. (Amended: see Amendments, 2026-09-08. An
`msq` row belongs in this table; that entry gives the `msq` blob and its
`MultiSelectInfo` answer-modality schema.)

**`marks` always per-question total.** Coding questions do not carry
per-test-case marks; differentiated per-case marks live in the authored
fragment (typically `locals { case_marks = {...} }` in the component's
score expression; see [Locals across coding
fragments](#locals-across-coding-fragments)).

**`accept` (SA, optional)** is a list of additional acceptable answers
beyond `expected` (synonyms, equivalent forms). **Stored but not yet
honored in v1**: the v1 SA comparator matches only `expected` (see [SA
match options](#sa-match-options)). The field round-trips faithfully so
no re-authoring is needed when the multi-answer comparator ships; a
save-time warning fires when it is non-empty (see [Save-time
validation](#save-time-validation-structural)).

**`reference` (essay + coding, optional)** is a worked solution or model
answer in Typst, preserved for human graders. Never read by the
pipeline; documentation only. (The document-import flow captures it
from solution papers; see [Examination-import
integration](#examination-import-integration).)

**`rubric_typst` (essay, optional)** is grading guidance in Typst for
human graders. Essays are not auto-graded in v3.

### Exposure through `document.examination`

Under the relaxed RFD 0013 contract, blob fields flow into the document
namespace as `marking.<...>` per question. Both scopes see everything
except `marks`, which is formula-only because the pipeline does not
make scoring decisions:

| Modality | `marking.<...>` exposed | Pipeline | Formula |
|---|---|---|---|
| `mc`     | `expected_file` (from `correct_choice`) | ✓ | ✓ + `marks` |
| `tf`     | `expected_file` (from `answer`) | ✓ | ✓ + `marks` |
| `sa`     | `expected_file` (from `expected`); `diff_flags` (from `match_options`) | ✓ | ✓ + `marks` |
| `essay`  | none (not auto-graded) | n/a | `marks` |
| `coding` | `assets` (uploaded marking-scheme files, when present; the fragment is otherwise the rubric) | ✓ | ✓ + `marks` |

(Amended: see Amendments, 2026-09-08. `msq` exposes `expected_file` from
`correct_choices`, the same row as `mc`.)

The generator materializes only the expected-answer bytes; the
`expected_file` path and the `diff_flags` list are built by the snapshot
resolver (`snapshotFromInput`) when the document snapshot is resolved at
grading-run start. The emitted HCL references `marking.expected_file` /
`marking.diff_flags` symbolically, so the pipeline reads ready-to-use
values and stays agnostic to the marking-scheme's field names.

### SA match options

The `match_options` for SA questions is a flat boolean object. Each
key maps to a `diff` flag; the generator concatenates the flags into
the per-scenario `args`:

| Option | Diff flag |
|---|---|
| `ignore_case` | `--ignore-case` |
| `ignore_all_whitespace` | `--ignore-all-space` |
| `strip_trailing_cr` | `--strip-trailing-cr` |
| `ignore_blank_lines` | `--ignore-blank-lines` |

The Documents-tab marking UI surfaces these as checkboxes per SA
question. **No regex matching, no fuzzy matching, no edit-distance
threshold.** If those become necessary the question must be promoted to
a coding question or wait for a follow-up RFD.

`match_options` subsumes the earlier `case_insensitive` boolean
convention: `case_insensitive: true` is now `match_options.ignore_case`.

**Multi-answer matching (`accept`) is deferred.** The v1 SA comparator
is a single `diff` of the student answer against `expected`'s
materialized file. A non-empty `accept` list cannot be expressed by one
`diff` against one file; it requires a set-membership comparator
(match against `expected` ∪ `accept`) that v1 does not build. The
`accept` field is therefore stored and round-tripped but not honored in
v1; the comparator is follow-up work. The save-time warning keeps this
from being a silent mis-grade.

### Storage

`SolutionData []byte` continues to be a byte column but content is
constrained to validate against the per-modality JSON schema above.
Validation runs at write time (Documents-tab save path) against a
schema chosen by the question's modality. Per-question entries are
required to exist for every question in the document at materialization
time; an absent marking scheme entry is a materialization-phase error
on the next grading run. (Amended: see Amendments, Where the shipped
semantics live now (MATERIALIZATION.md). A missing or unauthored marking
scheme is an authoring-class generator diagnostic raised on every
materializing save and on the manual materialize endpoint, recorded as
`not_applied` with the previous derived config left live; nothing
re-materializes at grading-run start.)

### Derived assets

For non-coding modalities the generator materializes the expected
answer into a plain-text file the pipeline's `diff` compares against:
MC the `correct_choice` string, TF the boolean as the student submits
it (`"true"`/`"false"`), SA the `expected` string verbatim. The path is
generator/runtime-chosen and exposed via `marking.expected_file`, so
there is no hardcoded path convention to depend on (see [Abandoned
alternatives](#abandoned-alternatives)). (Amended: see Amendments,
2026-09-08. `msq` derives its file too: the correct set sorted, joined with
`\n`, with no trailing newline.)

These files are derived: a marking-scheme change re-materializes the
affected files (and re-publishes the path into the document's synthetic
view) before the save returns. (Amended: see Amendments, Where the
shipped semantics live now (MATERIALIZATION.md). Re-materialization is
synchronous in-request but only on saves that move active marking-scheme
state; it is best-effort and rewrites every expected file document-wide,
not only the affected ones, and no path is re-published, since
`marking.expected_file` is a fixed convention the snapshot resolver
derives at grading-run start.) Asset-write semantics (idempotency,
atomicity, the exact path scheme) are the runtime RFD's concern; this
RFD commits only to the data dependency.

### Question-ID constraint

Because every objective (MC / MSQ / TF / SA) question becomes a
scenario in its modality's batched pipeline and every coding question
becomes a `pipeline` label (essays emit neither a scenario nor a
pipeline), **client-supplied question IDs must match
`^[a-z0-9][a-z0-9_-]{0,63}$`** (lowercase, at most 64 characters) and
must not be a reserved name (`mc`, `msq`, `tf`, `sa`, `default`,
`component`, `document`, `local`, `manual`, `pipeline`, `scenario`),
enforced by `ValidateClientRef` in `resolveCreateID`; server-minted
UUIDs bypass it. This is stricter than RFD 0013's `[a-zA-Z0-9_-]+`
scenario-code rule, because a qid becomes a component name that
surfaces as a bare variable in `scoring.total`. The Documents tab
enforces this at question creation; existing v2 question IDs that
don't conform must be renamed before v3 can grade them. The generator
relies on this constraint for both scenario-code emission and pipeline
labels; no in-generator sanitization is performed.

## Scoring policy

The exam-wide scoring policy (what the assembled formula's
`scoring { ... }` block contains) lives on the examination document
as a single HCL text fragment.

### Storage

A new `scoring_policy_hcl TEXT` column on `examination.document`. The
value is the *body* of the `scoring { ... }` block (i.e., what goes
inside the braces). The generator wraps it verbatim in `scoring { ... }`
when assembling the formula.

A default value is populated when a document is created:

```hcl
max_score = sum([for q in document.examination.questions : q.marks if q.type != "essay"])
```

Amended: see Amendments, 2026-08-12 A. No deployed default ever
excluded essays; the initial schema default sums every question's
marks, since replaced by
`max_score = sum([for _, c in component : c.max_score])` (the sum of
every component's max).

This excludes essay marks from the denominator until manual grading
ships in a follow-up RFD; see [Open follow-ups](#open-follow-ups)
for why this is a future breaking change.

Like the assembled config itself, `scoring_policy_hcl` mutates in
place, with no version history. Past runs do not retain a snapshot.

### UI: structured mode + advanced mode

Two modes, with one canonical storage (`scoring_policy_hcl`).

**Structured mode (default).** A small form:

- **Max score:** "Auto (sum of non-essay marks)" / "Fixed value". Auto
  shows its current resolved value (e.g. *"Auto (currently: 87)"*) so
  the denominator is verifiable without opening the config preview.
- **Min score:** numeric, default `0`.
- **Total scoring rule:** a **two-option** dropdown: *Sum of component
  scores* (default; generator emits no `total`, RFD 0013's default-sum
  applies) or *Weighted sum* (reveals a per-component weight table;
  generator emits `total = sum([for n, c in component : c.score *
  c.weight])` and writes `weight` onto each component, relying on RFD
  0013's default `weight = 1`). (Amended: see Amendments, B. The
  generator has no weight input or output; the *Weighted sum* option
  ships as inline weighted terms in the scoring body itself, written by
  the console, not a generator-emitted `total` plus per-component
  `weight`.) No "Custom expression" option; custom
  logic lives behind the Advanced toggle (see [Abandoned
  alternatives](#abandoned-alternatives)).
- **Weight table** (weighted-sum only) uses human-readable labels
  ("Multiple choice (all questions)", "Question N: <display_name>"),
  mapped back to component names internally; the instructor never sees
  raw identifiers.

**Advanced mode.** A raw HCL editor for the whole scoring-block body;
content becomes `scoring_policy_hcl` verbatim. Holds penalty rules,
bonus caps, and other custom logic. (Whole-block toggle, not per-field;
see [Abandoned alternatives](#abandoned-alternatives).)

**Mode detection on load.** The stored HCL is matched against the
structured patterns: a match renders the editable form; a non-match
renders the form **read-only with a banner** that still **shows the
resolved values in plain language** (*"Pass mark: 60% of 100…"*) so a
non-HCL instructor can check it. (Amended: see Amendments, C. A
non-match falls to Advanced, the editable raw-HCL editor, with an
informational banner; there is no read-only structured rendering.) The
exam overview carries a
"Scoring: custom (Advanced)" indicator so the lockout is visible before
they open the tab. Switching from Advanced to Structured warns that the
custom expression will be lost.

## Coding-question authoring

### Where the HCL lives

A coding question's authored grading fragment is stored as the
`grading_hcl` field inside the coding question's **marking-scheme
blob**. There is no separate column on `examination.question`.

Two properties make the marking scheme the appropriate location: it is
**instructor-only in the API** (never delivered to students, so the
test cases, expected outputs, and DAG in the HCL inherit that access
posture with no per-endpoint filtering), and it is **versioned per
question** (editing the HCL bumps only this question's marking-scheme
version). The blob shape is `{ marks, grading_hcl, reference? }` (see
the [per-modality table](#per-modality-blob-shape)).

### The fragment shape

A coding question's `grading_hcl` value must contain exactly one
`pipeline "<qid>"` block and at least one `component` knob block, plus
an optional single top-level `locals` block. The single-knob shape
below labels its lone `component` with the question id:

```hcl
pipeline "<qid>" {
  # ...stages, scenarios, the full v3 pipeline DAG...
}

component "<qid>" {
  max_score = document.examination.questions["<qid>"].marks
  score     = # ...instructor-authored score expression that references
              #    pipeline["<qid>"].scenarios[<code>].<stage>...
}
```

The single `pipeline` block and at least one `component` block are
required. The pipeline defines what runs; the component knobs define
how its results turn into marks. The component is
included in the fragment (rather than auto-generated) because
per-question scoring policy varies: all-or-nothing, equal partial
credit, weighted per-test-case marks, or a penalty for timeouts, none of
which can be mechanically derived from question metadata. Putting the
component in the fragment keeps the per-question grading definition in
one place, in one editor.

The fragment **does not** include the `pipeline "<qid>" {}` declaration
block that the formula file requires to ground the `pipeline.<qid>`
namespace (per RFD 0013). That declaration is auto-emitted by the
generator into the assembled formula: one per coding question, plus
one per non-coding modality the document uses. The instructor never
writes it; the lint shell injects it so live diagnostics stay
accurate (see [Linting](#linting)).

### Lifecycle

Because modality is immutable, the lifecycle is simple:

| Event | Effect on `grading_hcl` |
|---|---|
| Question created with `type = "coding"` | `grading_hcl` initialised with the no-op placeholder (see below). The authoring layer (document-import agent, or instructor via the "Load language template" action) replaces it with a language-correct skeleton once the language is known. |
| Question's marking scheme edited (HCL change) | New marking-scheme version contains the new HCL. |
| Question deleted | The delete transaction explicitly removes the marking scheme (`DeleteMarkingSchemeMeta`); `marking_scheme_meta` has no FK to the question (only to `examination.document`), and the sole cascade FK runs the other way (deleting the meta row cascades the question row). |

No archive column, no modality-flip handling, no soft-delete state.

### Default no-op placeholder

The `grading_hcl` seeded at coding-question creation is a **no-op**: a
single `stage "placeholder" { exec { command = "true" } }` pipeline and
a `component` that scores `0`.

```hcl
pipeline "<qid>" {
  stage "placeholder" { exec { command = "true" } }
}
component "<qid>" {
  max_score = document.examination.questions["<qid>"].marks
  score     = 0
}
```

It materializes and runs cleanly without committing to a language (no
missing-file references, no guessed compiler), and scores zero rather
than full marks, so an unconfigured question fails visibly instead of
awarding credit unnoticed. The authoring layer replaces it with a
language skeleton (next); why a no-op rather than a hardcoded template
is in [Abandoned
alternatives](#c-todo-template-as-the-default-coding-fragment).

### Coding skeleton: responsibility model

The no-op default is language-agnostic because, at the moment
a coding question is created, its language is not yet known. The
language arrives later, in the answer-modality's `CodingModalityInfo`,
not at question creation. The language-correct grading skeleton is
therefore produced by the **authoring layer**, never the backend:

| Layer | Responsibility |
|---|---|
| **Backend** (`create question type=coding`) | Seeds `grading_hcl` with the no-op placeholder on every create; not language-aware. |
| **Authoring layer** (document-import agent, or instructor via the picker) | Replaces the no-op with a language-correct skeleton, keyed off the now-known `CodingModalityInfo.language` and `compilation_enabled`. Sourced from the operational template library. |
| **Instructor** | Fills the skeleton's placeholder test case with real inputs / expected outputs and adjusts scoring. |

The backend does not interpret the language; the skeleton is an
authoring-layer concern. This keeps the no-op default and the
operational template library (below) consistent: neither needs the
backend to understand languages.

**Skeleton shape.** A loaded language template is a working
compile, execute, and test pipeline plus its component:

- A **compile** stage only when `CodingModalityInfo.compilation_enabled`
  is true (e.g., `g++` for C++, `javac` for Java; omitted for Python).
- An **execute** stage invoking the language runtime or built binary.
- A **test** stage with **one placeholder scenario** (a `diff` against a
  TODO expected file) the instructor extends to the real cases.
- A `component` scoring all-or-nothing over the declared cases (the
  instructor rewrites for partial credit).

### Load-language-template picker

A "Load language template" action in the [coding-question editorial
surface](#coding-question-editorial-surface) replaces the no-op
`grading_hcl` with the skeleton for `CodingModalityInfo.language`. Since
the language is already set on the question, the picker does not ask the
instructor to choose one; it applies (or re-applies) the skeleton for
the known language. The set of templates and their content is an
operational artifact, versioned and updated outside this RFD; the RFD
commits only to the action's existence and the skeleton shape above.

### Coding-question editorial surface

Coding-question HCL is edited inline on the Documents tab, per coding
question. (The Grading tab carries no whole-config editor; that path
is closed, and the reasoning is in [Abandoned alternatives](#abandoned-alternatives).)

Mechanics:

- Each coding question's authoring card has a "Grading pipeline"
  section with an "Edit pipeline" button.
- Clicking it opens a drawer or modal overlay anchored to the question
  card, sized for 30–80-line HCL pipelines rather than card height.
- The drawer contains a single HCL editor (Monaco-based or equivalent)
  with live diagnostics from the lint endpoint ([Linting](#linting)),
  and surfaces the [Load-language-template
  picker](#load-language-template-picker) prominently while the fragment
  is still the no-op.
- Save commits the new HCL into a fresh marking-scheme version.

There is no whole-config editor on the Grading tab; it exposes only the
[scoring-policy UI](#scoring-policy) and an Advanced "View assembled
config" action, a read-only preview for debugging failed runs
(no write path; not a primary action).

### Locals across coding fragments

A coding fragment's HCL may declare its own top-level `locals { ... }`
block (e.g., for per-test-case marks distribution). The generator
**merges** all fragments' locals plus its own generator-emitted
locals into a single top-level `locals` block in the assembled file.

Conflict resolution: **duplicate keys across fragments (or between a
fragment and generator-emitted locals) are materialization errors.**
The error message names the colliding key and the offending fragment.
The no-op placeholder default declares no locals, avoiding this
conflict until the instructor loads a language template; templates with
locals declare them under qid-prefixed names (e.g., `local.<qid>_test_codes`)
to minimize collision likelihood.

(The initial generator emits no locals of its own, so the only conflict
surface is between coding fragments. A later revision may emit shared
locals, for example common diff flag lists, and the conflict-detection
mechanism prevents one fragment's locals from overriding another's
without notice.)

## Generation contract

The generator is a pure function:

```
generate(document, [per-question marking schemes], scoring_policy_hcl)
  → (pipeline_config_hcl, formula_config_hcl)
```

It runs eagerly on every save in the materializing set and its output
is column-authoritative (timing detail in [Materialization
timing](#materialization-timing)). This section is what it emits.

### Per-modality emission

**Coding questions.** For each coding question, the generator reads
`grading_hcl` from the question's marking-scheme blob and splits it into
its single `pipeline` block and its one-or-more `component` knob blocks:

- The `pipeline "<qid>" { ... }` block is appended to the assembled
  pipeline config.
- Each `component` knob block is appended to the assembled
  formula config, its label namespaced to the global component name
  `<qid>` (label equal to the qid) or `<qid>-<label>`.
- A `pipeline "<qid>" {}` declaration block (per RFD 0013) is
  auto-emitted into the assembled formula config to ground the
  `pipeline.<qid>` namespace the component references. The instructor
  doesn't write this declaration; it follows mechanically from the
  existence of the coding question.
- Any `locals` declared in the fragment are merged into the assembled
  file's top-level `locals` (see [Locals across coding
  fragments](#locals-across-coding-fragments)).

**MC / TF / SA: one batched pipeline per modality.** (Amended: see
Amendments, 2026-09-08. `msq` emits this same shape, in the same plain-`diff`
form as MC/TF.) All three emit
the same shape: one `pipeline "<modality>"` with a single `test` stage
whose `dynamic "scenario"` block produces one `diff` scenario per
question of that modality, driving the expected-answer path (and, for
SA, the diff flags) off `document.examination.questions[<id>].marking.<...>`.
SA is the superset; MC/TF are identical minus `diff_flags`:

```hcl
# pipeline config — SA shown; MC/TF drop the diff_flags concat
pipeline "sa" {
  stage "test" {
    visibility { filter { effect = "hide"; until = "collection_stop" } }
    exec {
      command = "diff"
      dynamic "scenario" {
        for_each = [for q in document.examination.questions : q if q.type == "sa"]
        labels   = [scenario.value.id]
        content {
          args = concat(scenario.value.marking.diff_flags, [   # MC/TF: no concat
            "${scenario.value.id}.txt",
            scenario.value.marking.expected_file,
          ])
        }
      }
    }
  }
}

# formula — one declaration + one component per modality
pipeline "sa" {}
component "sa" {
  max_score = sum([for q in document.examination.questions : q.marks if q.type == "sa"])
  score     = sum([for code, s in pipeline.sa.scenarios :
                   document.examination.questions[code].marks if succeeded(s.test)])
}
```

Amended: see Amendments, 2026-08-12 A. A modality no longer emits one
modality-wide `component "<modality>"` summing marks; it emits a
`dynamic "component"` expanded per question, each with
`max_score = component.value.marks` and
`score = try(manual[id], succeeded(pipeline.<modality>.scenarios[id].test) ? component.value.marks : 0)`.

`marking.diff_flags` is the generator's translation of the SA
`match_options` blob (mapping in [SA match options](#sa-match-options));
`marking.expected_file` is the materialized expected-answer path (see
[Derived assets](#derived-assets)). Per-question marks are awarded on
`diff` success. Iteration is safe without heterogeneous-key
defensiveness: every key in a batched pipeline's `scenarios` is a
question id with a `test` entry (no implicit `"default"`).

**Essay questions.** Not emitted. The default scoring-policy `max_score`
filters them out (`if q.type != "essay"`); see [Open
follow-ups](#open-follow-ups) for the future-breaking-change
implications of manual essay grading. (Amended: see Amendments,
2026-08-12 A. Essays are emitted as a manual-only `component "<qid>"`
(score = `try(manual[qid], 0)`, no pipeline block), and the default
`max_score` no longer filters essays out.)

### Full assembled-config shape

Both files carry `version = 3`, the `document "examination"` block, and
a merged top-level `locals` (generator locals, empty in v1, plus any
from coding fragments). Beyond that:

- **Pipeline config:** one generated `pipeline "<modality>"` per
  non-coding modality present (stable order `mc`, `tf`, `sa`), then the
  authored `pipeline "<qid>"` blocks spliced from each coding question's
  `grading_hcl`, in question-declaration order. (Amended: see Amendments,
  2026-09-08. The shipped order is `mc`, `msq`, `tf`, `sa`.)
- **Formula config:** a `pipeline "<name>" {}` declaration for every
  pipeline above (grounding the namespaces), the matching generated
  `component "<modality>"` blocks and authored `component "<qid>"`
  blocks, then a `scoring { ... }` wrapping `scoring_policy_hcl`
  verbatim. (Amended: see Amendments, 2026-08-12 A. The generated
  modality scoring unit is a per-question `dynamic "component"`, not a
  single `component "<modality>"`; the declaration, authored-component,
  and `scoring` parts are unchanged.)

Ordering is identical across both files. Worked end-to-end examples of
the v3 HCL live in RFD 0013's
[`example-pipeline.hcl`](../0013/example-pipeline.hcl) and
[`example-formula.hcl`](../0013/example-formula.hcl).

### Determinism

Given identical inputs, the generator must emit identical HCL
byte-for-byte. **Question declaration order is part of the input
signature.** Reordering questions in the document changes
`document.examination.questions` iteration order, which the batched
modality pipelines' `dynamic "scenario"` blocks traverse and which
also determines the order coding-question fragments are appended.
Reordering produces different output bytes; this is a legitimate input
change, not a determinism violation.

The generator does not normalize order; sorting by question id would
break the instructor's intended ordering on the Documents tab.

### Fragment collision handling

A `qid` collision across coding questions is structurally prevented by
`examination.question`'s primary key. If it ever surfaced, the
file-wide component-name uniqueness check (`declareComponent`) would
catch it before assembly and name both offending questions. The
generator does not wrap a pipeline-label parse error: a collision on the
pipeline label alone would fall to the generic Internal `selfValidate`
error carrying no question ids.

## Editorial surfaces

### Documents tab redesign

The Documents tab is the canonical authoring locus. The redesign:

- Each question card carries: question text editor, modality-specific
  authoring (choices for MC, expected for SA, etc.), and minimal
  marking-scheme fields inline (marks, correct answer / match-options
  /  `answer` per modality).
- For coding questions only, an additional "Grading pipeline" section
  with an "Edit pipeline" button that opens the inline HCL drawer. The
  drawer opens with the [no-op placeholder](#default-no-op-placeholder)
  when the question is freshly created; a
  ["Load language template"](#load-language-template-picker) action
  inside the drawer offers the picker for the instructor's first
  edit.

### Bulk marks view: the primary rubric-completion flow

A bulk view of questions × (marks, correct answer, match-options) is
the **primary surface for completing the marking scheme** after
question content is written. The card-based per-question flow suits
*authoring* a question; it is ill-suited to
*setting the answer key* across 30 MC questions in a row.

The bulk view supports **direct in-table editing**:
- **MC**: dropdown of the question's `MultipleChoiceInfo.choices` keys
  for `correct_choice`.
- **TF**: boolean toggle for `answer`.
- **SA**: text input for `expected`, plus inline checkboxes for each
  `match_options` flag. Full expected-string visible; overflow handled
  via expandable rows or tooltip, with no truncation that hides errors.
- **Marks**: numeric input per row.

Coding questions appear in the bulk view too, but only their `marks`
field is editable inline. The `grading_hcl` field is too large for a
table cell; the row links back to the question card's HCL drawer.

Essay questions appear with their `marks` editable and an
expand-on-click cell for `rubric_typst` / `reference`.

The bulk view is reachable from a "Set marking scheme" action on the
Documents tab header. The per-card fields remain available for
in-flow authoring; the bulk view is the recommended surface when the
task is rubric completion.

### Grading tab redesign

The Grading tab focuses on scoring policy and pre-flight checks:

- The scoring-policy UI (structured + Advanced modes).
- An **Advanced** subsection containing the read-only "View assembled
  config" action and (future) a pre-flight parse-phase validation
  runner.

The pipeline / formula text editors that exist today are removed. The
config is no longer a hand-authored artifact accessible from this tab.
The "View assembled config" preview lives in the Advanced subsection
because its audience is platform admins debugging failed runs, not
non-technical instructors.

### Save Scores

The "Save Scores" control is **deleted**. Auto-generation
runs on every save; there is no separate "commit scores" action to
expose. Reusing the v2 control would suggest semantics that no longer
apply.

## Examination-import integration

The platform already has a document-import path: an MCP server exposes
the examination mutation API as agent tools, and an `/import-exam`
workflow authors a full exam document from a question paper (plus
optional solution paper). It predates this RFD and wrote marking schemes
under an ad-hoc `solution_data` convention. This RFD's schema is
**authoritative**; the import path must target it. Design only here;
the concrete tool/instruction edits are follow-on.

**What the import agent must produce:** each marking scheme in the [v3
shape](#per-modality-blob-shape), with three changes from the pre-RFD
convention:

- **`marks`** is now required. The agent lifts per-question marks the
  paper states (`[5 marks]`, rubric columns) into `marks`; when absent,
  it writes a placeholder and flags low-confidence (the same
  flag-for-review pattern it uses for missing answer keys).
- **Field shapes:** `correct` becomes `correct_choice`/`answer`;
  `case_insensitive` becomes `match_options.ignore_case`; alternatives
  become `accept`; model answers become `reference` (Typst); essay
  guidance becomes `rubric_typst`.
- **Coding `grading_hcl`:** the agent already sets
  `CodingModalityInfo.language` during import, so it knows the language
  and authors the language-correct [skeleton](#coding-skeleton-responsibility-model)
  into `grading_hcl` rather than leaving the no-op. Paper-specified test
  I/O is incorporated where available; otherwise the placeholder case is
  flagged. A worked solution is preserved in `reference`.

This is the [responsibility model](#coding-skeleton-responsibility-model)
applied: the import agent is an authoring-layer actor, so it owns the
skeleton; the backend's contract is unchanged (seed no-op, validate
against the v3 schema). The reconciliation goes into the MCP server's
authoring instructions and the `/import-exam` modality-shape guidance;
exact edits are implementation work.

## Persistence and linting

### Canonical state vs derived state

| Layer | Storage | Mutation trigger |
|---|---|---|
| Document, questions, modality info | Existing examination tables (unchanged) | Documents-tab content edits |
| Marking scheme (per question) | Existing `marking_scheme_meta` + version content; `SolutionData` constrained to per-modality JSON schema | Documents-tab marking-field edits; coding-question HCL drawer save |
| Scoring policy | New `examination.document.scoring_policy_hcl TEXT` | Grading-tab scoring UI |
| Assembled pipeline config | `pipeline.config.config` (existing; reshaped per RFD 0013) | Generator |
| Assembled formula config | `evaluation.formula.source` (existing; reshaped per RFD 0013) | Generator |
| Derived expected-answer files | Examination asset paths (object storage) | Generator |

Rows 1-3 are canonical; rows 4-6 are derived. Mutating a derived row
directly (outside the generator) is unsupported. Coding HCL lives in
the marking-scheme blob, with no new column on `examination.question`.

### Materialization timing

- **On any canonical-state save:** the generator runs and writes the
  assembled config + derived assets eagerly. The save is not considered
  complete until materialization succeeds (or fails with a structured
  diagnostic). (Amended: see Amendments, Where the shipped semantics
  live now (MATERIALIZATION.md). Materialization fires only on saves in
  the materializing set (writes the compose step reads), not on any
  canonical-state save, and it is best-effort: it records a structured
  outcome and never blocks the save.)
- **At grading-run start:** the runtime reads the assembled config
  columns **as-is**. No second materialization. The columns are
  authoritative.

If a save is in flight when grading is requested, the dispatch waits
for the save's transaction to commit. The mechanics of this wait
(advisory locks, queue ordering, retry semantics) are the runtime
RFD's concern; this RFD commits only to the "column-authoritative"
property.

### Linting

The inline drawer lints the fragment live. The fragment holds both a
`pipeline` block (pipeline-scope `document` contract, no `marks`) and a
`component` block (formula-scope contract, `marks` allowed), so the
lint endpoint (`POST /v1/documents/{document_id}/marking-schemes/{marking_scheme_id}/lint`)
synthesizes **two shells** and runs RFD 0013's validate phase against
each:

- **Pipeline shell:** `version = 3` + the `document "examination"`
  block (pipeline scope) + merged fragment locals + the fragment's
  `pipeline` block.
- **Formula shell:** same header in formula scope + an injected
  `pipeline "<qid>" {}` declaration (grounds the `pipeline.<qid>`
  reference, mirroring what the generator emits) + the fragment's
  `component` block.

Diagnostics from both are merged with positions mapped back to the
fragment's coordinates. The split is what lets a `marks` reference be
rejected in the `pipeline` block but accepted in the `component` block.
Parse-phase checks (cross-pipeline, document resolution, dynamic
expansion) do **not** run here; they fire at materialization and
surface as save errors, not live diagnostics.

### Re-grading

This RFD's data-model implications for re-grading:

- The next grading run uses the current assembled config. There is no
  "use the historical config from run R" affordance.
- Re-running a past submission against the current config is supported
  in principle (the inputs survive; the runtime mechanics are the
  runtime RFD's concern).
- Re-grading against a *different* config is not supported; no other
  config exists to point at. This follows from the single-config model,
  which keeps v2's config-drift problem out of the design.

## Validation rules

Validation splits across three phases. The first two are within this
RFD's surface; the third inherits from RFD 0013.

### Save-time validation (structural)

Runs on the Documents-tab save path before any materialization.
Single-record checks; no cross-record resolution required.

- Marking-scheme blob parses as JSON.
- Blob structure matches the per-modality schema for the question's
  modality. (Wrong-shape entries, e.g., MC fields on an SA question,
  are rejected.)
- Required fields per modality are present (`marks` always;
  modality-specific fields per the [shape table](#per-modality-blob-shape)).
- `marks` is a non-negative number.
- For MC: `correct_choice` is a key of the question's
  `MultipleChoiceInfo.choices`.
- For SA: `match_options` keys are within the defined set.
- **Warning (non-fatal):** for SA, a non-empty `accept` list emits a
  save-time warning: alternatives are stored but only `expected` is
  matched in v1 (see [SA match options](#sa-match-options)). The save
  succeeds; the warning surfaces in the authoring UI so the gap is
  visible before exam day.
- For coding: `grading_hcl` is non-empty and contains exactly one
  `pipeline "<qid>"` block (labelled by the question id) and at least
  one `component` block, each labelled by a distinct author knob label
  matching `[a-zA-Z0-9_-]+` (not the qid), plus at most one `locals`
  block, and the fragment passes the
  shell-based lint described in [Linting](#linting) (which is the
  same mechanism invoked live by the editor; save-time validation
  is not a stricter check, just the gate at save).
- `scoring_policy_hcl`: parses as a valid v3 `scoring` block body
  (contains a `max_score` attribute; structural fields are well-formed).

### Materialization-time validation (cross-reference + value-level)

Runs as part of generation, after save-time validation passes. Aborts
the save if any check fails, leaving the canonical-state edit
uncommitted. (Amended: see Amendments, Where the shipped semantics live
now (MATERIALIZATION.md). Materialization is best-effort and never
aborts the save: the canonical-state edit commits first, then
materialize records an outcome (`applied` / `not_applied` / `partial`)
in the document-materialization sidecar.)

- Every question in the document has a marking-scheme entry.
- Every coding question's `grading_hcl` parses cleanly when wrapped in
  the assembled config (catches issues only visible across the full
  file, for example colliding pipeline labels or conflicting locals keys).
- The merged top-level `locals` block has no duplicate keys.
- `scoring_policy_hcl`'s `max_score` expression resolves to a positive
  number against the materialized document (this is the check the
  save-time validator cannot perform because `max_score` can reference
  runtime values like `document.examination.questions[...].marks`).
- `scoring_policy_hcl`'s `min_score` (if present) resolves to `≤
  max_score`.

### Runtime parse-phase validation

RFD 0013's parse phase still runs at grading-run start. By that
point, save-time + materialization-time validation have already passed,
so parse-phase failures should be rare and indicate either runtime-state
drift (e.g., a referenced examination asset is missing) or a v3
language bug. They are surfaced as run failures, not save failures.

## Open follow-ups

Items this RFD identifies but does not solve:

- **Manual essay grading.** Essays carry marks and are visible on the
  Documents tab, but cannot be graded by the platform until a
  manual-scoring surface is designed. This is a **future breaking
  change** for two reasons:
  - The current default `scoring_policy_hcl` filters essays out of
    `max_score` (`if q.type != "essay"`). When manual grading ships,
    essays will (presumably) be included, meaning the formula's
    `max_score` denominator changes retroactively for any exam that
    has essay questions, affecting grades that may have already been
    issued.
  - The formula currently has no `component "essay"` block. Adding one
    requires either (a) re-materializing every existing config that
    has essay questions, or (b) changing the generator's behaviour
    going forward in a way that is not backwards-compatible. (Amended:
    see Amendments, 2026-08-12 A. Every essay question now emits a real
    `component "<qid>"` (score = `try(manual[qid], 0)`) from the start,
    so this follow-up is resolved and its feared migration never
    occurred.)
  Neither option is harmless. The manual-grading RFD must own this
  migration path; this RFD commits to the
  current-state behaviour in the knowledge that it will
  need to break.
- **Runtime resolver implementation.** RFD 0013 specifies
  parse-phase resolution of `document.examination` references; the
  implementation is not yet in place. This RFD's generator emits HCL
  that depends on that resolver being live. Sequencing is an
  implementation concern, not a redesign.
- **v2 deprecation.** v2 generator code and the `examination pipeline
  generate` endpoint are dropped entirely. Any operational tooling
  that consumes them needs migration; this RFD does not enumerate
  the surface.
- **SA multi-answer comparator (`accept`).** The marking scheme stores
  an `accept` list of alternative answers, but v1's single-`diff`
  comparator honors only `expected`. A set-membership comparator
  (match against `expected` ∪ `accept`, under `match_options`) is
  deferred; it needs a comparator-stage shape that runs something
  other than a one-target `diff`. Until it ships, `accept` is stored,
  round-tripped, and flagged at save time but not graded against. Any
  broader matcher growth (regex, fuzzy) belongs to the same follow-up.
- **Concurrent save / grading-run ordering.** The save-blocks-grading
  property is committed to here; the mechanics (advisory locks, queue
  ordering, retry policy) are the runtime RFD's responsibility.

## Abandoned alternatives

Unchosen options, recorded so they are not re-explored from scratch. The
first three (A/B/D) are the axis endpoints Position C was chosen
against; the rest are narrower forks rejected during design.

**Position A: manual HCL only.** Document decoupled from configs;
instructor types HCL. What RFD 0013 ships without 0014. Violates the
premise (non-coding exams require HCL).

**Position B: one-shot generation, no sync.** Generate a starter
config, then HCL becomes the source of truth; document changes do not
propagate, regeneration is destructive. This repeats v2's failure mode
(destructive regeneration and undetected drift).

**Position D: live binding only.** Instructor authors a thin HCL shell
that delegates everything to `document.examination` references resolved
at grading time. The authoring-surface problem remains: they still
write *some* HCL per pipeline. Position C achieves "document drives
grading" with no HCL for non-coding exams.

**`grading_hcl` as a top-level `examination.question` column.** The
question table is an identity table; per-modality grading data does not
belong there, it needed a separate archive column for modality changes
(unnecessary, since modality is immutable), and the marking scheme already
provides versioning + access control + an authoring path. The blob
inherits all of that.

**`grading_hcl` inside `CodingModalityInfo`.** The modality blob is
delivered to students for their editor; embedding test logic and expected
outputs there would expose them to students and require per-endpoint
filtering. The marking scheme is instructor-only in the API.

**Editable assembled config, no locked regions.** A single editor over the whole
stitched config, with generated regions editable. Re-creates
v2's destructive-regeneration problem; Position C's value is that
generated regions are *not editable*.

**Field-level HCL toggles in the scoring UI.** Per-field "use HCL"
buttons fragment the surface: the instructor learns field-by-field
which fields support HCL. One whole-block Advanced toggle gives the same
capability through one affordance.

**"Custom expression" as a scoring dropdown option.** A non-technical
instructor could pick it and be taken to an HCL editor with no warning. Custom
expressions live behind the Advanced-mode toggle instead: a
visible cross-mode boundary, not a hidden one inside a form control.

**Per-test-case marks in the marking scheme.** `per_case: {...}` would
force the marking scheme to know test-case codes the HCL author defines,
coupling layers meant to be independent. Per-case marks live
in the fragment's `locals`, where the cases are declared.

**Class-bound configs (v2 reuse).** One config across many activities
either cannot read its activity's document or is bound to an arbitrary
mismatched one; both re-introduce drift. 1:1:1 is the chosen
model: to reuse, copy the document.

**Re-materialization at grading-run time.** Running the generator again
at run start "to catch drift" adds a write-race against concurrent saves
for no gain; save-time materialization already covers canonical state
and every edit re-triggers it. The column is authoritative.

**Hardcoded `examination-assets/<modality>/<qid>.expected` path.** Once
RFD 0013 exposes the path via `marking.expected_file`, the layout is a
runtime detail, not a contract; the runtime can move, version, or
namespace files freely without an RFD change.

**Static SA scenarios.** Emitting per-question `scenario` blocks with
inlined `diff_flags` was a workaround for the pre-relaxation contract
that hid marking data from the pipeline. With `marking.diff_flags` and
`marking.expected_file` exposed, SA uses a uniform `dynamic "scenario"`
block like MC/TF.

<a id="c-todo-template-as-the-default-coding-fragment"></a>
**C++ TODO template as the coding default.** A hardcoded C++
compile, execute, and test stub was rejected because it guessed the language
(wrong for most questions, a starting point to delete), referenced
files that do not exist yet (materializes clean but fails at grading
with confusing missing-fixture errors), and cannot hold real
per-language scaffolding in one universal template. The no-op default plus
language-template picker replaces it: it materializes cleanly, scores
zero, and signals that the question needs configuring without producing
errors that look like a crash.

## Amendments

Amendments record where the shipped implementation diverged
from the design above. **The body of this RFD is left as
written.** It is the historical design record, not a description of the
running system. Where an amendment and the body disagree, the amendment
and the durable package docs it points at are authoritative.

### 2026-08-12 — Scoring policy: the max is derived, the weights are inline

Affects [Scoring policy](#scoring-policy), [Generation
contract](#generation-contract), and the "Manual essay grading" item in
[Open follow-ups](#open-follow-ups).

Two divergences share one root cause: **two
independently-authored statements of the same fact, reconciled nowhere.**
In both cases the design put a number in one place and the thing that
number describes in another, with no mechanism reconciling the two, so
the implementation collapsed the pair into a single authored statement
and derived the other.

#### A. The default `scoring_policy_hcl`

**The RFD says** a document is created with

```hcl
max_score = sum([for q in document.examination.questions : q.marks if q.type != "essay"])
```

Essays are excluded from the denominator "until manual grading ships",
flagged in Open follow-ups as a future breaking change.

**What shipped**, in two steps.

*Essays were never excluded in a deployed default.* Manual grading did
not arrive as a separate surface; it arrived as a **per-component manual
override**, which made essays gradable without a new denominator rule.
Every essay question emits a real component scored
`try(manual["<qid>"], 0)` (core `internal/pipeline/configgen/emit.go:136`,
called from `configgen/generator.go:189`), and objective and coding
components wrap their computed score in the same guard
(`emit.go:101`, `emit.go:177`). Essays are gradable, so they belong in
the denominator: the initial schema default sums *every* question's
marks (core `database/migrations/000001_initialize_schema.up.sql:930-940`,
whose comment records the reversal), and the console's structured form
was aligned to the same expression; its remaining trace is
`LEGACY_AUTO_MAX_SCORE_EXPR` in
`apps/console/app/lib/scoring-policy/index.ts:453`, retained only to
explain the pre-derived bodies described in (C).

*That default has since been replaced entirely.* The current column
default is

```hcl
max_score = sum([for _, c in component : c.max_score])
```

(core `database/migrations/000021_scoring_policy_derived_default.up.sql`,
pinned by `database/scoring_policy_default_test.go:21`; the same string
is a named constant on both sides:
`internal/api/examination/authoring_summary_service.go:36` and console
`apps/console/app/lib/scoring-policy/index.ts:19`). The max is now
**derived from the total's own structure** (the total expression with
each component's score replaced by that component's max), and a numeric
literal is no longer "the other automatic mode" but a **cap
override** ("70 marks available, scored out of 60").

The engine was extended to support this: `scoring.max_score` and
`scoring.min_score` evaluate in a parse-phase **component-meta** scope:
`component` as `{max_score, weight}` per component, without
`score`, since a max depending on scores would be circular (core
`internal/pipeline/evaluate.go:678-700`, `scoringMetaContext` at
`evaluate.go:830-865`, lint contract in
`internal/pipeline/lint_types.go:145-205`).

**Why.** The RFD's expression and the achievable total are two different
statements of the paper's size, and they disagree in practice:

- A coding question emits **one component per knob**, with
  author-written literal `max_score`s. This RFD assumed a coding
  component's max would be the question's marks; multi-knob practice
  writes literals instead, so Σ question marks ≠ Σ component maxes. The
  derived-max work added a generator check for exactly this: when every
  knob's max is a static number literal and their sum differs from the
  question's marks, it emits a `SeverityWarning`, *"knob max_scores sum
  to N but the question carries M marks"* (core
  `internal/pipeline/configgen/generator.go:150-167`). It is a warning,
  not an error: the generator still materializes. The check is
  **skipped** when any knob max is a non-literal expression
  (`knobMaxScoreSum`, `configgen/coding.go:243-255`); that is the case
  where the divergence is not reported.
- A **fixed** max over a weighted total discards the weights, so
  no consumer can judge the declared max against what is achievable.
- A **question-marks** max over a weighted total is worse: the total
  computes Σ wᵢ·marksᵢ, so weights > 1 are truncated by the
  clamp and weights < 1 make full marks unreachable.

Deriving the max from the components deletes the second statement rather
than trying to reconcile it. The full reasoning, the canonical
expressions, and the recognition rules are in core
`docs/plans/2026-08-10-scoring-derived-max.md`.

Two consequences:

- **Existing rows are not rewritten.** Migration 000021 changes the
  column default only. Stored bodies keep evaluating unchanged (the
  `document` namespace is still in scope for `max_score`); in the editor
  they fall to Advanced until a human re-states them; see (C).
- **Open follow-ups' "Manual essay grading" item is resolved, and the
  migration it warned about never occurred.** Because the essay filter never
  reached a live default, no exam's denominator changed retroactively,
  and `component "<essay-qid>"` blocks were emitted from the start
  rather than added to configs already in flight.

*Adjacent change this item depends on:* objective modalities no longer
emit one `component "<modality>"` summing question marks, as [Per-modality
emission](#per-modality-emission) shows. They emit a `dynamic "component"`
expanded **per question**, keyed by question id, with
`covers = [id]`, `max_score = marks`, and the manual-override guard
(`emit.go:112-123`, `generator.go:208`). The pipeline stays batched; only
the scoring unit became per-question. This is what makes "the sum of
every component's max" a faithful reading of the paper. Note also that
the modality set that section enumerates is no longer complete: an
`msq` modality ships (core `internal/pipeline/configgen/input.go:20,71`)
that this RFD's body did not mention when written; documenting it is out of
this amendment's scope, and the 2026-09-08 amendment documents it.

#### B. The weighted-total form

**The RFD says** the *Weighted sum* option makes the generator emit

```hcl
total = sum([for n, c in component : c.score * c.weight])
```

and **write a `weight` attribute onto each component**, relying on RFD
0013's default `weight = 1`.

**What shipped** is inline weighted terms in the scoring body alone:

```hcl
max_score = component["mc"].max_score * 2 + component["q3"].max_score * 1
total     = component["mc"].score * 2 + component["q3"].score * 1
```

(console `apps/console/app/lib/scoring-policy/index.ts:73-110`;
the max terms mirror the total's terms exactly, in the same order.)
**The generator neither consumes nor emits a `weight`.** It has no
weight input: its `Input` is questions + marking schemes + the
policy body (core `internal/pipeline/configgen/input.go:73-85`), and a
grep of `internal/pipeline/configgen/` for `weight`, tests included,
returns zero hits.

The attribute is still in use, though: it remains part of the v3 formula
language, still defaults to `1`, and is still evaluated and linted
(core `internal/pipeline/formula_types.go:50`,
`internal/pipeline/evaluate.go:465`,
`internal/pipeline/lint_types.go:170,202`). A **coding author** can
therefore still write `weight` inside a knob's `component` block: the
fragment's body is spliced verbatim (`ParseCodingFragment` has no
attribute allowlist and `bodyTextWithoutAttr` strips only `score`; see
`configgen/coding.go:123-170`), so an author-written weight reaches the
emitted formula and takes effect. What changed is that weight is not the
channel the **weighted-total feature** uses.

**Why.** The same defect class, forced by this RFD's own model:

- Component blocks are **generated artifacts**. The document is the only
  canonical state and the config column is re-derived on every save that
  touches the materializing set (core
  `internal/api/examination/MATERIALIZATION.md`). A weight written into a
  component block would live only in derived output. To survive
  re-materialization it would have to become a *second* piece of
  canonical state (a per-component weight stored on the document)
  alongside a `total` expression that references it. Two authored
  statements of one weighting, again.
- The scoring surface the console writes is `PUT
  /documents/{document_id}/scoring-policy` (core
  `internal/api/examination/scoring_policy.go:25`), the policy body, not
  the config. The hand-authored pipeline/formula editors were removed
  when the derived-config model landed (ui commit `25487fe7`, "Remove the
  hand-authored pipeline/formula editors… no write path for the config
  remains").
- Keeping both halves in one body is what makes the derived max
  *checkable*: recognition requires the max's `(name, weight)` terms to
  match the total's exactly and in order, otherwise the policy is
  treated as custom (`index.ts:255-273`). That check could
  not be stated if half the pair lived in generated component blocks.

#### C. Mode detection on load

[UI: structured mode + advanced mode](#ui-structured-mode--advanced-mode)
describes a non-matching body as rendering **the structured form
read-only, with a banner showing the resolved values in plain
language**. That is not what shipped.

Recognition is **canonical spellings only**, and a non-match falls to
**Advanced**: the raw-HCL editor, editable, with an informational
banner. There is no read-only structured rendering (console
`apps/console/app/lib/scoring-policy/index.ts:164-273`; editor
`apps/console/app/components/grading/scoring-policy/scoring-policy-editor.tsx:313-345`).
The one plain-language reading that survives is for the legacy
pre-derived body (the state every existing document is in), which the
banner describes as "Caps the exam at the sum of question marks — the
pre-derived model. Re-save in Structured form to migrate."
(`index.ts:453-472`, editor `:324-334`).

**Why.** The legacy question-marks expression is *not*
recognized as the derived form: it resolves to Σ question marks while
the canonical form resolves to Σ component maxes, and the two diverge
exactly when coding knobs diverge from marks. Recognizing it would
either misreport the cap or rewrite it without notice on the next save.
So the body is treated as opaque until a human re-states it. This RFD's
essay-excluding variant is likewise
unrecognized (it was never a live default).

For the same reason the "Scoring: custom (Advanced)" overview indicator
this RFD describes shipped as a **two-axis classification** instead:
total: `sum` / `weighted` / `opaque`; max: `derived` / literal-with-value
/ `opaque`, where `opaque` means the summary makes no claim on that axis
(core `internal/api/examination/authoring_summary.go:43-46`,
`authoring_summary_service.go:169-273`). How the Overview renders it is a
console concern outside this amendment.

#### D. The resolved-value display

The RFD's *"Auto (currently: 87)"* survived in substance but not in
wording or in basis. The mode is labelled **"Derived from the paper"**
and the resolved value reads **"Currently: N marks."** (editor
`:506`, `:535-537`), resolved from the **materialized formula's
component maxes**, not from a sum of question marks, and degrading
to "The current value cannot be resolved right now — it appears
once the config has been materialized" when the formula read is absent
or any needed component max is unknown (`resolveDerivedMaxScore`,
`index.ts:406-444`).

**Why.** The display exists to make the denominator verifiable without
opening the config. A fallback computed on a different basis than the
stored expression would be a third statement of the same fact, wrong in
the coding-knob case that motivated (A).

#### Where the shipped semantics live now

- core `internal/api/examination/MATERIALIZATION.md`: what
  materialization derives from a document, when it runs, and how each
  attempt's outcome is recorded and repaired. Supersedes this RFD's
  [Materialization timing](#materialization-timing) as the current
  reference.
- core `docs/plans/2026-08-10-scoring-derived-max.md`: the derived-max
  design (the defect class, the canonical expressions both repos must
  agree on byte-for-byte, the recognition rules, and the core-before-
  console deploy ordering).
- core `internal/pipeline/USAGE.md` and `internal/pipeline/configgen`:
  the v3 language surface and the generator's actual emission.
- console `apps/console/app/lib/scoring-policy/index.ts`: the canonical
  spellings and the recognized structured subset; core's Go port of the
  same classification is
  `internal/api/examination/authoring_summary_service.go`.

### 2026-09-08: the `msq` modality (multi-select), documented

The generator, the marking-scheme schema, and the examination service ship
an `msq` ("Multiple Choice (select several)") modality this RFD's body does
not describe. The body was written 2026-06-01 and covers five modalities:
`mc`, `tf`, `sa`, `essay`, and `coding`. `msq` was added to core on
2026-08-11 (commit `feat(examination): add msq multi-select answer
modality`), after the body was frozen. The 2026-08-12 amendment (A) recorded
that it ships but deferred documenting it. The 2026-09-03 corrections added
`msq` to the reserved-name list and the objective-question enumeration
([Question-ID constraint](#question-id-constraint)) without describing the
modality. This entry describes it. Where it and the body's per-modality
tables disagree by omission, this entry governs.

`msq` is multiple choice where the student selects a set of choices. Grading
is all-or-nothing: the submitted set must equal the authored correct set.
`msq` is an objective modality, so it earns an auto verdict and batches with
`mc`, `tf`, and `sa` (core `internal/pipeline/evaluate.go:597`,
`configgen/input.go:71`), and it has no manual-grading surface of its own.

#### A. Blob shape and answer-modality schema

The table in [Per-modality blob shape](#per-modality-blob-shape) has no
`msq` row. The shipped blob is `MarkingSchemeMSQ` (core
`internal/api/examination/marking_scheme_types.go:49-52`):

| Modality | Blob shape |
|---|---|
| `msq` | `{ "marks": 5, "correct_choices": ["A", "C"] }`; each key must be a key of the question's `MultiSelectInfo.choices`. |

`correct_choices` is required and must be non-empty
(`validate:"required,min=1"`), including when the question's
`min_selections` is 0. A blank answer is never uploaded, because the exam
client omits empty answers, so an empty correct set produces no file for
`diff` to read and can never be scored correct. An author who wants "none of
these" adds a real choice for it (`marking_scheme_types.go:44-48`).

`msq` also carries an answer-modality `extra_info` schema the body does not
list, `MultiSelectInfo` (core `internal/api/examination/types.go:273-297`):

- `choices` is the label-to-text map, as for `mc`, but its keys are
  constrained to `^[A-Za-z0-9_-]{1,32}$` (`msqChoiceKeyPattern`,
  `answer_modality_service.go:679`). The constraint applies to `msq` alone;
  `mc` keys are unconstrained. It is what makes the serialization in (B)
  safe.
- `max_selections` is required (`gte=1`). A question with no cap is a
  pick-any-subset question, which under all-or-nothing grading is rarely the
  author's intent, and the exam client needs the cap to stop a student
  selecting every choice.
- `min_selections` is optional. An omitted value means 0, the permissive
  floor: a bare integer cannot distinguish an omitted field from an explicit
  0. Authoring surfaces should still ask for it rather than let it default
  silently.

#### B. Expected file: the two-language serialization

[Derived assets](#derived-assets) lists `mc`, `tf`, and `sa`, but not `msq`.
For `msq` the generator materializes the correct set in a canonical
encoding: the keys sorted ascending, joined with `\n`, with no trailing
newline (`SerializeMSQAnswer`, core `configgen/expected_files.go:22`).
Grading is a byte `diff` of this file against the student's uploaded answer.

The encoding is a two-language contract. The exam client writes the
student's answer file with the same rule in TypeScript, and any divergence
mis-grades. Two properties keep it safe, and both rely on the key-charset
constraint in (A). The trailing newline is omitted because `diff` reports a
trailing-newline mismatch as a difference. Over `[A-Za-z0-9_-]`, Go's byte
ordering and JavaScript's UTF-16 code-unit ordering are identical, so the
two sorts cannot diverge for any legal key set. The TypeScript half belongs
to the exam client; this RFD commits only to the Go serialization and the
shared rule.

Exposure matches `mc` ([Exposure through
`document.examination`](#exposure-through-documentexamination)):

| Modality | `marking.<...>` exposed | Pipeline | Formula |
|---|---|---|---|
| `msq` | `expected_file` (from `correct_choices`) | ✓ | ✓ + `marks` |

The published answer key carries `msq` as `AnswerKeyMSQ { correct_choices }`
(`answer_key.go:48`).

#### C. Emission

`msq` emits with the batched objective modalities, in the same shape as `mc`
and `tf`: one `pipeline "msq"` whose `dynamic "scenario"` runs one plain
`diff` per `msq` question against `marking.expected_file`, and a per-question
`dynamic "component"` (the shape in [Per-modality
emission](#per-modality-emission), as amended 2026-08-12 A). `msq` takes no
`diff_flags`; that concatenation is specific to `sa` (`configgen/emit.go:38`).

The shipped code contradicts one order the body states. [Full
assembled-config shape](#full-assembled-config-shape) gives the stable
non-coding pipeline order as `mc`, `tf`, `sa`. The shipped order is `mc`,
`msq`, `tf`, `sa`: `msq` sits next to `mc` as the same question shape with a
set-valued answer (`nonCodingBatchOrder`, `configgen/input.go:71`). Emission
is gated on `present[modality]`, so a document with no `msq` questions
produces byte-identical output whatever `msq`'s place in the list
(`input.go:68-70`). Only documents that contain `msq` questions are affected.

#### D. Validation

`msq` is validated across the same gates the body describes for the other
modalities, split across the two separately versioned resources:

- Write-time, on the modality `extra_info` (`validateMultiSelectInfo`,
  `answer_modality_service.go:693`): every choice key matches the charset,
  `min_selections` is not greater than `max_selections`, and
  `max_selections` is not greater than the number of choices. An
  unsatisfiable question cannot be saved, so it does not surface later as a
  student-side lockout.
- Save-time, on the marking-scheme blob (`ValidateMarkingSchemeData`,
  `marking_scheme_types.go:213-260`): every `correct_choices` key is one of
  the question's choices, the set has no duplicates, and its size falls
  within `[min_selections, max_selections]`. The correct set must be one a
  student could submit. This cross-check lives here, not in the modality
  validator, because the modality may be saved before its marking scheme.
- Publish-time (`publish_service.go:75,86`): rechecks the authored set
  against the modality, so a `correct_choices` set left outside its
  selection bounds is caught at publish. The modality-edit-after-scheme path
  (`marking_scheme_service.go:649`) invalidates a scheme whose set the new
  choice map or bounds no longer admit.
- Materialization-time: an unauthored or empty-set scheme is an
  authoring-class generator diagnostic, worded "Multiple Choice (select
  several) marking scheme does not say which choices are correct"
  (`configgen/expected_files.go:62`). Core
  `internal/api/examination/MATERIALIZATION.md:393` records the empty-set
  case.

#### E. Deferred, as with SA `accept`

Grading is all-or-nothing, and partial credit is not modelled. Partial
credit can be added later as optional blob fields with no migration:
`decodeStrict` rejects a newer blob only on an older server, and a newer
server reads an older blob unchanged (`marking_scheme_types.go:38-42`). This
is the `msq` counterpart of the deferred `sa` multi-answer comparator: the
schema has room for it, and v1 does not implement it.

The examination-import flow ([Examination-import
integration](#examination-import-integration)) predates `msq` and has no
`msq`-specific handling; its manifest path does not branch on modality.
Import coverage of `msq` is unspecified here and left to that flow's own
follow-up. `msq` questions are authored on the Documents tab.
