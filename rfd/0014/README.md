---
authors: Thomas Li
state: prediscussion
discussion:
labels: direction, ux
---

# [RFD] Examination → Config builder / sync

This RFD scopes the relationship between an **examination document** (the
question metadata authored by an instructor on the Documents tab) and
the **v3 pipeline config + formula** that grade it. [RFD
0013](../0013/README.md) ships the v3 HCL language and the lint surface
but explicitly defers the question of how those configs come into
existence — today, an instructor has to author both HCL files by hand,
even when their exam is structurally identical to a hundred other
exams the platform already grades. This RFD answers that question by
making the document the source of truth and treating the pipeline +
formula configs as derived artifacts, with one narrowly-scoped escape
hatch for coding questions.

## Premise

**For any examination that contains no coding questions, an instructor
must be able to create the exam and ship a fully-graded activity
without ever touching HCL.**

This is the load-bearing constraint of the RFD. MC, TF, SA, and
essay-style questions all have shapes that the platform can mechanically
translate into a `diff`-style pipeline + a matching formula. Coding
questions are deliberately excluded from the premise because they
require per-question authoring (build commands, test stdin/stdout
expectations, language toolchains, marking criteria) that is not
mechanically derivable from question metadata alone.

## Background

The legacy v2 system had a "Generate from document" button (the now-deleted
`examination pipeline generate` endpoint) that produced a pipeline
config tied to the current document. It existed because the v2 config
language was verbose enough that hand-authoring was a non-starter for
non-engineer instructors — but the design had three recurring failure
modes:

1. **Regeneration was destructive.** Clicking regenerate clobbered any manual edits; the UI shifted the decision onto the user with an "any manual edits will be lost" warning.
2. **The document was the source of truth in name only.** Once generated, the HCL was authoritative; document changes drifted silently and the fix was a regenerate-and-pray loop.
3. **The generator owned every modality-mapping decision.** Batching strategy, stdio paths, asset resolution — all buried in generator code, opaque to the instructor and only discoverable by reading the output.

v3 (RFD 0013) reshuffled this by making the HCL itself smaller and
more inspectable, but deferred the *bridge* between document and HCL.
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
  → assembled pipeline + formula HCL.
- **Editorial surfaces.** Documents tab and Grading tab UI changes
  required by the new model.
- **Lint contract.** How the inline HCL editor validates the coding
  fragment before save.

### Out of scope (deferred to follow-up RFDs)

- **Manual grading of essay questions.** Essays remain in the document
  and carry marks, but are not auto-graded in v3 and have no pipeline
  emitted for them. A separate RFD covers the manual-scoring surface
  — but note that adding a `component "essay"` block later is a
  **future breaking change** to existing configs (see [Open
  follow-ups](#open-follow-ups)).
- **Re-grading mechanics.** This RFD describes the data model
  implications of regeneration but not the execution flow (which is
  the runtime RFD's concern).
- **The v2 generator code path.** v2 is being replaced wholesale; this
  RFD does not propose a migration. Existing v2 configs are rewritten
  by hand against the v3 contract.
- **Multi-language coding-question authoring.** The
  `CodingModalityInfo` blob is unchanged by this RFD. Per-language
  build/test conventions live in the instructor's authored fragment.
- **Language-template library content.** RFD 0014 commits to the
  existence of a "Load language template" picker in the inline HCL
  drawer (see [Load-language-template picker](#load-language-template-picker)),
  but the actual library — which languages are supported, what each
  template contains, how templates version and update — is an
  operational concern handled outside the RFD process. Templates can
  be added, removed, or revised without bumping this RFD.
- **Class-bound (reusable across activities) configs.** v2 allowed one
  config to be attached to many activities. v3 makes this impossible
  by design (see [Cardinality](#cardinality)).
- **Modality changes after question creation.** A question's modality
  is immutable once set — confirmed by the current `UpdateQuestionDTO`
  surface, which exposes only `display_name` and `tag_ids`. This RFD
  does not propose changing that. Instructors who picked the wrong
  modality delete the question and create a new one.

### Not retained from v2

- The destructive "Regenerate" button and its "any manual edits will
  be lost" warning. There is no equivalent action.
- The "Save Scores" control on the Documents tab. The Documents tab UI
  is redesigned for the new model; reusing the v2 button would
  miscommunicate the new semantics.
- The `examination pipeline generate` endpoint as a one-shot
  destructive operation. Auto-generation now runs on save.
- One-config-many-activities attachment. See
  [Cardinality](#cardinality).

## Proposal: Position C with a coding-escape-hatch

The grading configs (pipeline + formula) are **always derived from the
document and its per-question marking schemes**. The instructor never
sees the assembled HCL as an editable artifact for non-coding
modalities. Coding questions get one narrowly scoped exception: a
per-question authored HCL fragment that owns the grading logic the
platform cannot mechanically infer, stored inside the coding question's
marking-scheme blob.

The five organising decisions:

1. **The document drives the config.** Non-coding questions (MC, TF, SA) are mechanically translated to pipeline + formula HCL by the generator. The `pipeline.config` row is derived materialized state, not authoring input. Per-question rubric data lives in the marking-scheme blob; exam-wide scoring policy lives on the document; the assembled config is a pure function of these inputs.
2. **Coding questions are the only escape hatch.** Each coding question owns one HCL fragment — both its `pipeline "<qid>" {...}` block (the grading DAG) and its `component "<qid>" {...}` block (the score expression) — stored inside the coding question's marking-scheme blob. No other modality has an HCL surface.
3. **Cardinality is strict: activity ↔ document ↔ config is 1:1:1.** No cross-activity reuse, no shared configs, no shared documents. To reuse grading logic, copy the document.
4. **Configs mutate in place.** No version history on the `pipeline.config` or `evaluation.formula` rows. Past grading runs carry their results, not a snapshot of the config that produced them. Re-grading uses the current state.

### Cardinality

A single examination document belongs to exactly one activity; the
activity carries exactly one document; one config is derived from
that document. 1:1:1, enforced as a chain.

Practical consequences:

- The `pipeline.config` and `evaluation.formula` rows are children of
  the document, not free-floating entities. They have no independent
  identity.
- The v2 affordance "attach existing config X to activity Y" is dropped.
  Two activities cannot share grading logic; if they should, copy the
  document.
- The activity's config-attachment endpoints (POST/PUT/DELETE) are
  retired. The config exists when the document exists.

This is the largest schema-level change in the RFD and the biggest
backwards-incompatible shift from v2.

## Marking-scheme schema

The marking scheme is the canonical home for *everything an instructor
authors about how a question is graded*. The current per-question
opaque `SolutionData []byte` becomes a typed JSON blob whose shape is
determined by the question's modality.

### Versioning

Per-question marking schemes already version via
`marking_scheme_meta.active_version_id`. Schema changes inherit that
versioning for free. Each save (marks change, correct-answer edit,
SA match-option toggle, coding HCL edit) bumps the version for *that
question's* marking scheme — not for the document as a whole.

This is the key win of putting coding HCL in the marking scheme:
versioning is per-question, so editing one coding question's pipeline
doesn't ripple version bumps across unrelated questions.

### Per-modality blob shape

Each per-question blob has a shape determined by the question's
answer-modality type. The blob does **not** carry a `type` field — the
question's modality (from `answer_modality_meta`) dictates the schema
applied at read time.

| Modality | Blob shape |
|---|---|
| `mc`     | `{ "correct_choice": "B", "marks": 5 }` — `correct_choice` must be a key of the question's `MultipleChoiceInfo.choices`. |
| `tf`     | `{ "answer": true, "marks": 3 }` |
| `sa`     | `{ "expected": "...", "match_options": { ... }, "marks": 5 }` |
| `essay`  | `{ "rubric_html": "<p>...</p>", "marks": 10 }` — `rubric_html` is displayed to human graders; not auto-graded in v3. |
| `coding` | `{ "marks": 30, "grading_hcl": "pipeline \"q1\" {...}\ncomponent \"q1\" {...}" }` |

**Marks are always per-question totals.** Coding questions do not carry
per-test-case marks in the marking scheme; if an instructor wants
differentiated per-case marks, those live in their authored fragment
(typically as `locals { case_marks = {...} }` in the formula component's
score expression — see [Locals across coding
fragments](#locals-across-coding-fragments)).

### Exposure through `document.examination`

Under the relaxed RFD 0013 contract, the marking-scheme blob fields
flow into the document namespace under `marking.<...>` per question.
Both pipeline-scope and formula-scope see everything except `marks` —
that field is formula-only by design (the pipeline doesn't make
scoring decisions). The mapping from blob field to namespace:

| Modality | `marking.<...>` fields exposed | Pipeline scope | Formula scope |
|---|---|---|---|
| `mc`     | `expected_file` (path string materialized by the generator from `correct_choice`) | ✓ | ✓ + `marks` |
| `tf`     | `expected_file` (path materialized from `answer`) | ✓ | ✓ + `marks` |
| `sa`     | `expected_file` (from `expected`); `diff_flags` (list of strings translated from `match_options`) | ✓ | ✓ + `marks` |
| `essay`  | none (not auto-graded) | n/a | only `marks` |
| `coding` | none (instructor-authored fragment is the rubric) | n/a | only `marks` |

The raw blob fields (`correct_choice`, `answer`, `expected`,
`match_options`) are translated by the generator into the
`marking.expected_file` path and `marking.diff_flags` list at
materialization time, so the pipeline reads ready-to-use values rather
than re-interpreting marking-scheme semantics. This keeps the pipeline
HCL agnostic to the marking-scheme schema's exact field names — only
the generator knows the translation.

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

### Storage

`SolutionData []byte` continues to be a byte column but content is
constrained to validate against the per-modality JSON schema above.
Validation runs at write time (Documents-tab save path) against a
schema chosen by the question's modality. Per-question entries are
required to exist for every question in the document at materialization
time; an absent marking scheme entry is a materialization-phase error
on the next grading run.

### Derived assets

For non-coding modalities, the generator materializes the
expected-answer content into a file the assembled pipeline's `diff`
calls compare against. The path is chosen by the generator (or
runtime — exact layout is a runtime concern) and exposed to the
pipeline through `document.examination.questions[<id>].marking.expected_file`,
per RFD 0013's contract relaxation. The marking data the pipeline
reads is the path the generator wrote — no hardcoded path convention
authors or runtime code depend on.

Per-modality content of the expected-answer file:

- MC: the `correct_choice` string (e.g., `"B"`).
- TF: the boolean rendered as the same string the student submits (per modality convention — `"true"` / `"false"`).
- SA: the `expected` string verbatim.

These files are derived: any change to the marking scheme that affects
non-coding expected answers triggers a re-materialization of the
relevant files before the next save returns. The materialization step
also re-publishes the `marking.expected_file` path into the document's
synthetic view used at parse phase. Asset-write semantics (idempotency,
ordering, atomicity across questions, exact path scheme) are the
runtime RFD's concern; this RFD commits only to the data dependency
and the contract that the pipeline reads paths from the document, not
from convention.

### Question-ID constraint

Because every non-coding question becomes a scenario in its modality's
batched pipeline, and every coding question becomes a `pipeline`
label, **question IDs must match `[a-zA-Z0-9_-]+`** — the same
constraint RFD 0013 places on scenario codes. The Documents tab
enforces this at question creation; existing v2 question IDs that
don't conform must be renamed before v3 can grade them. The generator
relies on this constraint for both scenario-code emission and pipeline
labels; no in-generator sanitization is performed.

## Scoring policy

The exam-wide scoring policy — what the assembled formula's
`scoring { ... }` block contains — lives on the examination document
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

This excludes essay marks from the denominator until manual grading
ships in a follow-up RFD — see [Open follow-ups](#open-follow-ups)
for why this is a future breaking change.

Like the assembled config itself, `scoring_policy_hcl` mutates in
place — no version history. Past runs do not retain a snapshot.

### UI: structured mode + advanced mode

Two modes, with one canonical storage (`scoring_policy_hcl`).

**Structured mode (default).** A small form:

- **Max score:** radio buttons — "Auto (sum of question marks
  excluding essays)" / "Fixed value: [____]". The "Auto" option
  **displays its current resolved value** next to the radio (e.g.,
  *"Auto (currently: 87)"*) so the instructor can sanity-check what
  the denominator actually is without opening the assembled-config
  preview.
- **Min score:** numeric input (default `0`).
- **Total scoring rule:** dropdown with **two** options —
  - *Sum of all component scores* (default; generator emits no
    `total` attribute so RFD 0013's default-sum behaviour applies).
  - *Weighted sum* (UI reveals a per-component weight input table;
    generator emits
    `total = sum([for n, c in component : c.score * c.weight])` and
    writes each component's `weight = ...` into the generated
    components).

  The weighted-sum option relies on RFD 0013's default `weight = 1`
  for any component that doesn't declare one — the generated
  non-coding components don't carry a `weight` attribute, and the
  default-1 makes the sum behave as expected.

  **There is no "Custom expression" option in the dropdown.** Custom
  scoring expressions are reachable only via the explicit
  Advanced-mode toggle below — keeping the dropdown HCL-free
  prevents a non-technical instructor from stumbling into an HCL
  editor by accident.
- **Per-component weights (weighted-sum only):** when weighted-sum
  is selected, the form reveals a table of *human-readable* component
  labels with weight inputs:
  - "Multiple choice (all questions)" — for `component "mc"`
  - "True/False (all questions)" — for `component "tf"`
  - "Short answer (all questions)" — for `component "sa"`
  - "Question N: <display_name>" — one row per coding question
    `component "<qid>"`
  The UI maps these labels back to component names internally; the
  instructor never sees raw HCL identifiers like `mc` or `q1`.

The form's outputs translate into the HCL text on save.

**Advanced mode.** A full HCL editor for the entire scoring-block
body. The user edits raw HCL; the editor's content becomes
`scoring_policy_hcl` verbatim. This is where instructors needing
penalty rules, bonus-question handling, or other custom logic land.

**Mode detection on load.** When the Scoring view opens, the stored
HCL is parsed against the form-recognizable patterns:

- If it matches one of the structured patterns → render structured
  mode editable.
- If it doesn't match → render structured mode **read-only with a
  banner**, but **also display the resolved values in plain
  language**: *"Pass mark: 60% of 100. Max score: 100 (computed from
  custom expression). Min score: 0."* The instructor who can't read
  HCL can still see what the policy resolves to, so they can verify
  it's not catastrophically wrong before exam day.

The exam overview / activity card carries a small
"Scoring: custom (Advanced)" indicator when the scoring policy is in
this state, so a non-technical instructor learns about the lockout
*before* they sit down to verify the pass mark.

Switching from Advanced back to Structured warns: "Reset to a
structured rule? Your custom expression will be lost."

**Field-level HCL toggles are not provided.** A whole-block toggle
(structured vs Advanced) is the only escape; per-field toggles
fragment the surface and confuse the "which fields can I write
expressions in" mental model.

## Coding-question authoring

### Where the HCL lives

A coding question's authored grading fragment is stored as the
`grading_hcl` field inside the coding question's **marking-scheme
blob**. There is no separate column on `examination.question`.

This placement has two properties that matter:

- **Instructor-only by API design.** Marking schemes are never delivered
  to students. The grading HCL — which contains test cases, expected
  outputs, and the full grading DAG — inherits that access posture
  automatically. No per-endpoint filtering required.
- **Versioned per question.** Editing the HCL bumps only this
  question's marking-scheme version, not the modality blob, not
  other questions' schemes.

The coding marking-scheme blob shape:

```json
{
  "marks": 30,
  "grading_hcl": "pipeline \"q1\" {\n  ...\n}\n\ncomponent \"q1\" {\n  ...\n}"
}
```

### The fragment shape

A coding question's `grading_hcl` value must contain exactly two HCL
blocks:

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

Both blocks are required. The pipeline defines what runs; the
component defines how its results turn into marks. The component is
included in the fragment (rather than auto-generated) because
per-question scoring policy varies meaningfully — all-or-nothing vs
equal partial credit vs weighted per-test-case marks vs penalty for
timeouts — and none of these can be mechanically derived from question
metadata. Putting the component in the fragment keeps the per-question
grading definition in one place, in one editor.

The fragment **does not** include the `pipeline "<qid>" {}` declaration
block that the formula file requires to ground the `pipeline.<qid>`
namespace (per RFD 0013). That declaration is auto-emitted by the
generator into the assembled formula — one per coding question, plus
one per non-coding modality the document uses. The instructor never
writes it; the lint shell injects it so live diagnostics stay
truthful (see [Linting](#linting)).

### Lifecycle

Because modality is immutable, the lifecycle is simple:

| Event | Effect on `grading_hcl` |
|---|---|
| Question created with `type = "coding"` | `grading_hcl` initialised with the no-op placeholder (see below) as part of the initial marking-scheme version. The instructor replaces this via the "Load language template" action in the inline HCL drawer. |
| Question's marking scheme edited (HCL change) | New marking-scheme version contains the new HCL. |
| Question deleted | Marking scheme cascades through `marking_scheme_meta`'s FK to the question. |

No archive column, no modality-flip handling, no soft-delete state.

### Default no-op placeholder

The default `grading_hcl` populated when a coding question is created
is a **no-op** — a pipeline that runs cleanly and a component that
scores zero. The real starting point comes from the
[Load-language-template picker](#load-language-template-picker) the
instructor uses next:

```hcl
pipeline "<qid>" {
  description = "<question's display name>"

  # Placeholder pipeline. Use the "Load language template" action in
  # the inline HCL drawer to populate a working starting point for
  # your chosen language (Python, Java, C++, Go, etc.); then
  # customize. Until then, this stage runs cleanly and the component
  # below scores 0.
  stage "placeholder" {
    exec {
      command = "true"
    }
  }
}

component "<qid>" {
  max_score = document.examination.questions["<qid>"].marks
  # Placeholder: scores 0 until the pipeline is configured. The
  # conservative default ensures an unconfigured coding question never
  # accidentally awards full marks; the instructor sees an obvious
  # "this question always scores 0" signal during testing and replaces
  # this expression when authoring real grading logic.
  score = 0
}
```

The default is chosen so the freshly created question materializes
cleanly without committing to a language: the placeholder pipeline
runs and exits 0, no references to files that don't yet exist, no
guessed compiler invocation. The instructor's first real edit comes
from the Load-language-template picker rather than from deleting a
wrong-language stub. Rationale for the scores-zero default and for
preferring the picker over a hardcoded template lives in [Abandoned
alternatives](#c-todo-template-as-the-default-coding-fragment).

### Load-language-template picker

A "Load language template" action in the [coding-question editorial
surface](#coding-question-editorial-surface) replaces the no-op
`grading_hcl` with one of a supported language template (Python,
Java, C++, Go, etc.). The set of templates and their content is an
operational artifact — versioned and updated outside this RFD; the
RFD commits only to the action's existence.

### Coding-question editorial surface

Coding-question HCL is edited inline on the Documents tab, per coding
question. (The Grading tab carries no whole-config editor; that path
is intentionally closed — see [Abandoned alternatives](#pure-hcl-escape-hatch-with-no-structural-lockdown).)

Mechanics:

- Each coding question's authoring card has a "Grading pipeline"
  section with an "Edit pipeline" button.
- Clicking it opens a drawer or modal overlay anchored to the question
  card, sized for 30–80-line HCL pipelines rather than card height.
- The drawer contains a single HCL editor (Monaco-based or equivalent)
  with live diagnostics from the lint endpoint
  ([Linting](#linting)).
- A **"Load language template"** action appears prominently in the
  drawer chrome when the current `grading_hcl` is the no-op placeholder
  (and remains available, with an overwrite warning, after the
  fragment has been customized). The picker lists the supported
  language templates (Python, Java, C++, Go, ...); selecting one
  replaces the editor content with that template. The template
  library is operational — what languages exist and what each
  template contains is not pinned in this RFD.
- Save commits the new HCL into a fresh marking-scheme version for
  the question.

There is no whole-config editor on the Grading tab. The Grading tab
exposes only:

- The scoring policy authoring UI (see [Scoring policy](#scoring-policy)).
- An **Advanced** subsection containing a "View assembled config"
  action that opens a **strictly read-only** preview of the stitched
  HCL — useful for debugging a failed grading run, not for editing.
  Demoted from a primary action because non-technical instructors who
  open it reflexively see HCL and lose trust. Any write path through
  this preview is a conflict-surface liability and is not provided.

### Locals across coding fragments

A coding fragment's HCL may declare its own top-level `locals { ... }`
block (e.g., for per-test-case marks distribution). The generator
**merges** all fragments' locals plus its own generator-emitted
locals into a single top-level `locals` block in the assembled file.

Conflict resolution: **duplicate keys across fragments (or between a
fragment and generator-emitted locals) are materialization errors.**
The error message names the colliding key and the offending fragment.
The no-op placeholder default declares no locals, sidestepping this
trap until the instructor loads a language template; templates with
locals declare them under qid-prefixed names (e.g., `local.<qid>_test_codes`)
to minimize collision likelihood.

(The initial generator emits no locals of its own, so the only conflict
surface is between coding fragments. A later revision may emit shared
locals — e.g., common diff flag lists — and the conflict-detection
mechanism is what protects fragments from silent shadowing.)

## Generation contract

The generator is a pure function:

```
generate(document, [per-question marking schemes], scoring_policy_hcl)
  → (pipeline_config_hcl, formula_config_hcl)
```

It runs **eagerly on save** of any input (document edit, marking-scheme
update including coding HCL edit, scoring-policy save). The save is
not considered complete until materialization succeeds. The result is
written to the `pipeline.config.source` and `evaluation.formula.source`
columns, **which are authoritative** — the runtime parses them as-is
at grading-run start. No re-materialization at grading-run time.

If a save is in flight when grading is requested, the grading
dispatch waits for the save's transaction to commit (mechanics deferred
to the runtime RFD). Re-materializing at grading-run start was
considered and rejected — see [Abandoned alternatives](#re-materialization-at-grading-run-time).

### Per-modality emission

**Coding questions.** For each coding question, the generator reads
`grading_hcl` from the question's marking-scheme blob and splits its
two blocks:

- The `pipeline "<qid>" { ... }` block is appended to the assembled
  pipeline config.
- The `component "<qid>" { ... }` block is appended to the assembled
  formula config.
- A `pipeline "<qid>" {}` declaration block (per RFD 0013) is
  auto-emitted into the assembled formula config to ground the
  `pipeline.<qid>` namespace the component references. The instructor
  doesn't write this declaration; it follows mechanically from the
  existence of the coding question.
- Any `locals` declared in the fragment are merged into the assembled
  file's top-level `locals` (see [Locals across coding
  fragments](#locals-across-coding-fragments)).

**MC questions.** One batched pipeline `"mc"`:

```hcl
pipeline "mc" {
  description = "Multiple-choice questions"

  stage "test" {
    visibility { filter { effect = "hide"; until = "collection_stop" } }
    exec {
      command    = "diff"
      stdin_path = "/dev/null"
      dynamic "scenario" {
        for_each = [for q in document.examination.questions : q if q.type == "mc"]
        labels   = [scenario.value.id]
        content {
          args = [
            "${scenario.value.id}.txt",
            scenario.value.marking.expected_file,
          ]
        }
      }
    }
  }
}
```

The dynamic block is uniform across MC questions — every scenario is
the same shape, differing only in the question id. Per-question
expected-answer paths come from `scenario.value.marking.expected_file`
(see [Derived assets](#derived-assets)).

A corresponding formula component, also generated. The formula file
also gets a `pipeline "mc" {}` declaration at top level to ground the
namespace this component references:

```hcl
pipeline "mc" {}

component "mc" {
  max_score = sum([for q in document.examination.questions : q.marks if q.type == "mc"])
  score     = sum([for code, s in pipeline.mc.scenarios :
                   document.examination.questions[code].marks
                   if succeeded(s.test)])
}
```

Per-question marks are awarded on `diff` success. Because every key
in `pipeline.mc.scenarios` is a question id (the dynamic block emitted
exactly one scenario per MC question, no implicit `"default"`), the
iteration is safe — no heterogeneous-key defensiveness needed for the
batched non-coding pipelines.

**TF questions.** Structurally identical to MC — one batched pipeline
`"tf"` with the same dynamic-scenario shape, one `pipeline "tf" {}`
declaration in the formula, and one component `"tf"` whose `score`
expression iterates `pipeline.tf.scenarios` with the same per-question
marks logic.

**SA questions.** One batched pipeline `"sa"`, symmetric with MC and TF.
Per-question `match_options` (translated to `diff` flags) and the
expected-answer file path both flow through `document.examination.questions[<id>].marking.<...>`
under the relaxed RFD 0013 contract, so the generator can emit a
uniform dynamic block rather than per-question static scenarios:

```hcl
pipeline "sa" {
  description = "Short-answer questions"

  stage "test" {
    visibility { filter { effect = "hide"; until = "collection_stop" } }
    exec {
      command    = "diff"
      stdin_path = "/dev/null"

      dynamic "scenario" {
        for_each = [for q in document.examination.questions : q if q.type == "sa"]
        labels   = [scenario.value.id]
        content {
          args = concat(
            scenario.value.marking.diff_flags,
            [
              "${scenario.value.id}.txt",
              scenario.value.marking.expected_file,
            ]
          )
        }
      }
    }
  }
}
```

The generator translates each SA `match_options` blob into a
`list(string)` of `diff` flags (mapping in [SA match
options](#sa-match-options)) and publishes it as
`scenario.value.marking.diff_flags`. The component is the same shape
as MC's, against `pipeline.sa.scenarios`; the formula also gets a
top-level `pipeline "sa" {}` declaration. Per-question marks awarded
on `diff` success.

**Essay questions.** Not emitted in the pipeline. The default
scoring-policy `max_score` filters them out
(`if q.type != "essay"`) — see [Scoring policy](#scoring-policy) and
[Open follow-ups](#open-follow-ups) for the future-breaking-change
implications of adding manual essay grading.

### Full assembled-config shape

```hcl
version = 3

document "examination" { id = <doc_id> }

locals {
  # Generator-emitted locals (empty in v1) merged with any per-coding-fragment locals.
}

# One generated pipeline per non-coding modality present in the
# document, in a stable order: mc, tf, sa.
pipeline "mc" { ... }
pipeline "tf" { ... }
pipeline "sa" { ... }

# Authored pipelines, one per coding question, in question
# declaration order from the document.
pipeline "q1" { ... }    # from coding question q1's grading_hcl
pipeline "q5" { ... }    # from coding question q5's grading_hcl
```

And the formula:

```hcl
version = 3

document "examination" { id = <doc_id> }

locals {
  # Same merged locals as the pipeline file.
}

# Pipeline declarations grounding the `pipeline.<name>` namespaces
# referenced below. One per non-coding modality present in the
# document, plus one per coding question. Emitted in the same stable
# order as the pipeline file's declarations.
pipeline "mc" {}
pipeline "tf" {}
pipeline "sa" {}
pipeline "q1" {}
pipeline "q5" {}

# Generated components per non-coding modality.
component "mc" { ... }
component "tf" { ... }
component "sa" { ... }

# Authored components, one per coding question.
component "q1" { ... }   # from coding question q1's grading_hcl
component "q5" { ... }   # from coding question q5's grading_hcl

# Scoring block — wraps the user's scoring_policy_hcl verbatim.
scoring {
  <scoring_policy_hcl contents>
}
```

### Determinism

Given identical inputs, the generator must emit identical HCL
byte-for-byte. **Question declaration order is part of the input
signature.** Reordering questions in the document changes
`document.examination.questions` iteration order — which the batched
modality pipelines' `dynamic "scenario"` blocks traverse, and which
also determines the order coding-question fragments are appended.
Reordering produces different output bytes; that's a real input
change, not a determinism violation.

The generator does not normalize order — sorting by question id would
break the instructor's intentional ordering on the Documents tab.

### Fragment collision handling

A `qid` collision across coding questions is structurally prevented by
`examination.question`'s primary key. If it ever surfaces, two
`pipeline "<qid>"` blocks share a label — an RFD 0013 parse-phase
error. The generator wraps the error with the offending question IDs
before surfacing it, since the raw message would otherwise point at
the assembled HCL rather than a specific editor.

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
  when the question is freshly created; a prominent
  ["Load language template"](#load-language-template-picker) action
  inside the drawer offers the picker for the instructor's first
  meaningful edit.

### Bulk marks view — the primary rubric-completion flow

A bulk view of questions × (marks, correct answer, match-options) is
the **primary surface for completing the marking scheme** after
question content is written. The card-based per-question flow is
appropriate for *authoring* a question; it is the wrong surface for
*setting the answer key* across 30 MC questions in a row.

The bulk view supports **direct in-table editing**:
- **MC**: dropdown of the question's `MultipleChoiceInfo.choices` keys
  for `correct_choice`.
- **TF**: boolean toggle for `answer`.
- **SA**: text input for `expected`, plus inline checkboxes for each
  `match_options` flag. Full expected-string visible; overflow handled
  via expandable rows or tooltip — no truncation that hides errors.
- **Marks**: numeric input per row.

Coding questions appear in the bulk view too, but only their `marks`
field is editable inline. The `grading_hcl` field is too large for a
table cell; the row links back to the question card's HCL drawer.

Essay questions appear with their `marks` editable and a "rubric
text" expand-on-click cell.

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

The vestigial "Save Scores" control is **deleted**. Auto-generation
runs on every save; there is no separate "commit scores" action to
expose. Reusing the v2 control would suggest semantics that no longer
apply.

## Persistence and linting

### Canonical state vs derived state

| Layer | Storage | Mutation trigger |
|---|---|---|
| Document, questions, modality info | Existing examination tables (unchanged) | Documents-tab content edits |
| Marking scheme (per question) | Existing `marking_scheme_meta` + version content; `SolutionData` constrained to per-modality JSON schema | Documents-tab marking-field edits; coding-question HCL drawer save |
| Scoring policy | New `examination.document.scoring_policy_hcl TEXT` | Grading-tab scoring UI |
| Assembled pipeline config | `pipeline.config.source` (existing; reshaped per RFD 0013) | Generator |
| Assembled formula config | `evaluation.formula.source` (existing; reshaped per RFD 0013) | Generator |
| Derived expected-answer files | Examination asset paths (object storage) | Generator |

Rows 1-3 are canonical; rows 4-6 are derived. Mutating a derived row
directly (outside the generator) is an unsupported operation.

**No new column on `examination.question`** — coding HCL lives in the
question's marking-scheme blob, not as a separate field. No archive
column, no `grading_hcl_archive`.

### Materialization timing

- **On any canonical-state save:** the generator runs and writes the
  assembled config + derived assets eagerly. The save is not considered
  complete until materialization succeeds (or fails with a structured
  diagnostic).
- **At grading-run start:** the runtime reads the assembled config
  columns **as-is**. No second materialization. The columns are
  authoritative.

If a save is in flight when grading is requested, the dispatch waits
for the save's transaction to commit. The mechanics of this wait
(advisory locks, queue ordering, retry semantics) are the runtime
RFD's concern; this RFD commits only to the "column-authoritative"
property.

### Linting

The inline HCL drawer lints the coding fragment live as the
instructor types. Because the fragment contains both a `pipeline`
block (which must satisfy RFD 0013's pipeline-scope `document`
contract) and a `component` block (which must satisfy the formula-scope
contract — including `marks`-field access), the lint flow synthesizes
**two shells**, one per scope:

1. The editor sends `(document_id, fragment_text)` to a lint endpoint
   (`POST /v1/documents/{id}/marking-scheme/{question_id}/lint`).
2. The server parses the fragment to extract its `pipeline` block,
   `component` block, and any `locals` block.
3. **Pipeline lint shell:** a temporary v3 *pipeline* config — `version
   = 3`, generator's would-be locals (empty in v1), the
   `document "examination" { id = N }` block (pipeline-scope contract),
   any fragment-locals merged in, and the fragment's `pipeline` block.
4. **Formula lint shell:** a temporary v3 *formula* config — same
   header but with the formula-scope `document` contract (includes
   `marks`), an injected `pipeline "<qid>" {}` declaration so the
   component's `pipeline.<qid>` reference grounds against RFD 0013's
   declaration requirement, and the fragment's `component` block. The
   injection mirrors what the generator does at materialization time;
   the lint shell is the same composition the runtime would parse,
   minus the other questions' contributions.
5. RFD 0013's **validate-phase** rules run against each shell
   independently. Diagnostics are merged, with line/column positions
   mapped back to the fragment's coordinates so error markers point
   at the instructor's typing.
6. **Parse-phase validation does not run here.** Cross-pipeline checks,
   document-resolution checks, dynamic-block expansion against the real
   document — these run at materialization time (eager on save) and
   surface as save errors, not as live editor diagnostics.

The validate-phase scope per shell is single-file: each catches its
own typos, malformed blocks, missing required attributes, unsupported
HCL functions, forward-reference errors in fragment-declared locals,
etc. The split shell ensures that `marks` references in the `pipeline`
block are caught as scope violations (pipeline-scope `document` doesn't
expose `marks`), while the same reference in the `component` block is
accepted.

### Re-grading

This RFD's data-model implications for re-grading:

- The current assembled config is always what the next grading run
  will use. There is no "use the historical config from run R" affordance.
- Re-running a past submission against the current config is supported
  in principle (the inputs survive; the runtime mechanics are the
  runtime RFD's concern).
- Re-grading against a *different* config is not supported — no other
  config exists to point at. Intentionally awkward, to keep v2's
  drift problem out of the model.

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
- For coding: `grading_hcl` is non-empty and contains exactly one
  `pipeline "<qid>"` block and one `component "<qid>"` block where
  `<qid>` matches the question's id, and the fragment passes the
  shell-based lint described in [Linting](#linting) (which is the
  same mechanism invoked live by the editor — save-time validation
  is not a stricter check, just the gate at save).
- `scoring_policy_hcl`: parses as a valid v3 `scoring` block body
  (contains a `max_score` attribute; structural fields are well-formed).

### Materialization-time validation (cross-reference + value-level)

Runs as part of generation, after save-time validation passes. Aborts
the save if any check fails, leaving the canonical-state edit
uncommitted.

- Every question in the document has a marking-scheme entry.
- Every coding question's `grading_hcl` parses cleanly when wrapped in
  the assembled config (catches issues only visible across the full
  file — e.g., colliding pipeline labels, conflicting locals keys).
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
    essays will (presumably) be included — meaning the formula's
    `max_score` denominator changes retroactively for any exam that
    has essay questions, affecting grades that may have already been
    issued.
  - The formula currently has no `component "essay"` block. Adding one
    requires either (a) re-materializing every existing config that
    has essay questions, or (b) changing the generator's behaviour
    going forward in a way that's not backwards-compatible.
  Neither option is harmless. The manual-grading RFD must own this
  migration path explicitly; this RFD is committing to the
  current-state behaviour with the explicit awareness that it will
  need to break.
- **Runtime resolver implementation.** RFD 0013 specifies
  parse-phase resolution of `document.examination` references; the
  implementation is not yet in place. This RFD's generator emits HCL
  that depends on that resolver being live. Sequencing is an
  implementation concern, not a redesign.
- **v2 deprecation.** v2 generator code and the `examination pipeline
  generate` endpoint are dropped wholesale. Any operational tooling
  that consumes them needs migration; this RFD does not enumerate
  the surface.
- **Per-modality option growth.** SA matching is constrained to
  `diff`-translatable flags by design. A future RFD can broaden the
  matcher set if there's demonstrated demand — likely by introducing
  a comparator-stage shape that runs something other than `diff`.
- **Concurrent save / grading-run ordering.** The save-blocks-grading
  property is committed to here; the mechanics (advisory locks, queue
  ordering, retry policy) are the runtime RFD's responsibility.

## Abandoned alternatives

The design space sketched in earlier drafts contained four positions
on a single axis. Recording the unchosen options so the same paths
aren't re-walked.

### Position A — manual HCL only

The document is decoupled from configs; the platform offers templates
and an editor; the instructor types HCL. This is what RFD 0013 ships
without 0014. Rejected because it violates the premise (non-coding
exams require HCL).

### Position B — one-shot generation, no sync

The platform generates a starter config from the document; after
generation, the HCL becomes the source of truth and subsequent
document changes do not propagate. Re-running the generator is opt-in
and destructive. Rejected because this is exactly v2's failure mode —
the same "regenerate-and-pray" loop and silent-drift problems.

### Position D — live binding via `document.examination` references only

The HCL contains references like
`document.examination.questions[code].marks` that the runtime resolves
at grading time, and the instructor authors a thin HCL shell that
delegates everything to the document. Rejected because the
authoring-surface problem doesn't go away — instructors still have to
write *some* HCL to declare pipelines, even if marks come from the
document. Position C (this RFD) achieves the same "document drives
grading" property without requiring any HCL for non-coding exams.

### `grading_hcl` as a top-level column on `examination.question`

An earlier draft proposed adding a `grading_hcl TEXT` column directly
to the question table. Rejected because: (a) the question table is an
identity table; per-modality grading data doesn't belong there; (b) it
required a separate `grading_hcl_archive` column to handle modality
changes, which turned out to be unnecessary because modality is
immutable; (c) marking schemes are already the canonical "how to grade
this question" surface, with versioning, access control, and an
authoring path already in place. Putting the HCL in the marking-scheme
blob inherits all of those properties.

### `grading_hcl` inside `CodingModalityInfo`

Considered putting the grading HCL inside the existing answer-modality
blob alongside `language`, `template_code`, etc. Rejected because the
modality blob is delivered to students for their editor view —
embedding test-case logic and expected outputs there would require
per-endpoint filtering and creates a leakage surface. The marking
scheme is instructor-only by API design.

### Pure HCL escape hatch with no structural lockdown

An earlier draft considered exposing a single HCL editor that showed
the whole stitched config with generated regions visually distinguished
but technically editable (the instructor could edit anywhere, accepting
that auto-regeneration would clobber their edits). Rejected because
it re-creates v2's destructive regeneration problem with extra steps;
the value of Position C is that *the generated regions are not editable
at all*.

### Field-level HCL toggles in the scoring UI

Considered giving the scoring-policy form per-field "use HCL"
buttons (e.g., `max_score` has its own HCL toggle independent of
`total`). Rejected because the resulting surface is fragmented — the
instructor has to learn that some fields support HCL and others don't,
discoverable only by clicking each. A single whole-block toggle is
one discoverable affordance for the same flexibility.

### "Custom expression" as a scoring-rule dropdown option

An earlier draft included "Custom expression" as a third option in
the Total Scoring Rule dropdown, alongside "Sum" and "Weighted sum."
Rejected because a non-technical instructor selecting it would be
dropped into an HCL editor with no warning — the dropdown label
sounds like a benign UI option, not an entry into a different
authoring mode. Custom expressions are now reachable only via the
explicit Advanced-mode toggle, which is a discoverable cross-mode
boundary rather than a hidden one inside a form control.

### Per-test-case marks in the marking scheme

Considered carrying `per_case: { test1: 3, test2: 5, ... }` on coding
marking-scheme entries. Rejected because the marking scheme would have
to know about test-case codes the HCL author defines — a tight coupling
across layers that were designed to be independent. Per-case marks
belong in the instructor's authored fragment, where the test cases are
declared, typically as a local map referenced by the component's score
expression.

### Class-bound configs (v2 reuse affordance)

Considered preserving v2's ability to attach one config to multiple
activities (or letting documents be reused across activities).
Rejected because Position C's "document drives the config" property
makes a class-bound config either (a) unable to read its activity's
document, or (b) attached to an arbitrary document that may not match
the activity's content. Both options re-introduce drift. The 1:1:1
cardinality is the disciplined choice: to reuse, copy.

### Re-materialization at grading-run time

An earlier draft had the generator run *both* eagerly on save and
again at grading-run start, on the theory that the second run would
"catch drift." Rejected because save-time materialization already
covers the canonical-state-at-save guarantee, any subsequent edit
re-triggers materialization, and the second run adds a write-race
surface against concurrent saves. The column is authoritative;
grading reads it as-is.

### Hardcoded `examination-assets/<modality>/<qid>.expected` path convention

An earlier draft committed the generator (and the assembled pipeline
HCL) to writing and reading expected-answer files at the literal
filesystem path `examination-assets/<modality>/<qid>.expected`.
Rejected after relaxing RFD 0013's pipeline-scope contract: the
pipeline now reads the path via `document.examination.questions[<id>].marking.expected_file`,
so the layout is a generator/runtime implementation detail rather than
a contract. The runtime can move files, version them, namespace them
per submission, or use object-storage URIs — none of which require an
RFD update or a regenerated pipeline.

### Static SA scenarios

An earlier draft emitted SA grading as static `scenario "qN" {...}`
blocks per question, with `diff_flags` inlined as HCL literals. This
was a workaround for the stricter pre-relaxation pipeline-scope
contract that didn't expose marking data. When RFD 0013 was relaxed
to expose `marking.expected_file` and `marking.diff_flags` to the
pipeline, the workaround dissolved — SA emits a uniform `dynamic
"scenario"` block symmetric with MC and TF.

<a id="c-todo-template-as-the-default-coding-fragment"></a>
### C++ TODO template as the default coding fragment

An earlier draft populated new coding-question `grading_hcl` with a
hardcoded C++ compile/execute/test template containing TODO comments
for the instructor to fill in. Rejected for three reasons:

- **Language guess.** The template guessed C++; instructors writing
  Python, Java, Go, or anything else had to rewrite most of it before
  it worked. The guess was no help; it was a starting line the
  instructor had to delete.
- **Broken on materialization.** The template referenced files
  (`<qid>.cpp`, `test1.expected`) that don't exist for a freshly
  created question. The assembled config materialized cleanly but
  failed at grading-time with confusing errors that traced back to
  missing fixtures, not to "you haven't configured this question."
- **No clean place for the right starting point.** Real per-language
  scaffolding (Python's compile-step-skip, Java's package management,
  Go's module setup, etc.) doesn't fit in one universal template.
  The right shape is a library of language templates with a UI
  picker — which is what we ship instead.

The no-op default + language-template picker replaces the TODO
template entirely. New coding questions get a fragment that
materializes successfully, runs cleanly, and scores zero — making it
obvious that real configuration is still needed, without producing
crash-flavored errors during testing.
