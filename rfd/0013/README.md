---
authors: Thomas Li
state: prediscussion
discussion: "[#12](https://github.com/zinc-sig/affairs/pull/12)"
labels: direction, infrastructure
---

# [RFD] Pipeline v3 and Formula Redesign

This RFD replaces the current pipeline configuration language (pipeline config v1 and v2 — both written in HCL but using different parser strategies — atop a Concourse-shaped runtime) and the JSONB-backed evaluation formula with a unified pipeline config v3 design. The new model decouples scoring from execution, drops the toolkit-template indirection in favour of a direct `exec` primitive, and makes examination-style grading (one config grading many exam questions) a first-class case rather than a workaround.

Throughout this RFD, "v1", "v2", "v3" refer to pipeline config versions, not to HashiCorp Configuration Language (HCL) syntax versions. All three pipeline config versions use HCL2 as the underlying syntax; what differs between them is the parser strategy, the block grammar, and the runtime contract.

Scope is the **config language**, the **scenario result-emission contract**, and the **formula data model**. Runtime concerns (the engine that actually runs `exec` blocks, container isolation, workflow orchestration) are deferred to a follow-up runtime RFD. Toolkit reusability and richer per-stage result emission via plugin/framework blocks are also deferred. Because the project is still pre-production, v3 is a full replacement: no v1/v2 compatibility is retained.

Two standalone reference configs accompany this RFD:

- [`example-pipeline.hcl`](example-pipeline.hcl) — a full pipeline config for a mixed-format examination (two coding questions plus a batched MC pipeline).
- [`example-formula.hcl`](example-formula.hcl) — the corresponding formula that aggregates the pipelines' results into a final score.

## Background

The current pipeline system has accumulated three layered problems that no incremental fix addresses cleanly:

**Scoring is welded into the pipeline.** v1 and v2 pipelines declare `group { scoring { mode = "sum"; ... } }` blocks per-stage, and reference `formula.<name>.<group>.max_score` from option strings. The pipeline therefore knows the rubric's component names, max scores, and aggregation modes. This means changing the rubric (e.g., redistributing marks between correctness and style) requires editing every pipeline that references it; it also forces a 1:1 mapping between pipeline groups and formula components, which is fine for assignments but fights the examination case where one pipeline grades many questions.

**The config language is shaped around Concourse.** Stages use `use "toolkit/compilation/gcc"` to reference task templates in a separate git repository; each toolkit task is a Concourse YAML template parameterised through Concourse's `((var))` substitution. Options are typed `map[string]string` (everything is a string), variables interpolate through two different mechanisms in v1 vs v2, and the indirection through toolkit templates means a one-line `diff` invocation involves a Git repo, a Concourse task YAML, schema fetching, and option enrichment. The complexity is justified when toolkit tasks abstract real reuse; for the many trivial cases (compile one file, diff two files, run one binary), it is overhead the instructor pays without benefit.

**The examination case is awkward.** A typical exam has 10 coding questions plus 30 MC/TF/short questions. Today, one pipeline config grades one activity; mapping the exam onto pipeline groups conflates "grading aspects" (correctness, style) with "exam questions" (q1, q2, q3). Workarounds exist — generating per-question groups via v2's `dynamic` blocks — but the resulting pipeline has unclear semantics for partial failures (if q3 fails to compile, what happens to q1's score?) and forces the formula to walk a group structure that wasn't designed for it.

[RFD 0008](../0008/README.md) and [RFD 0009](../0009/README.md) move ZINC toward an event-driven, observable, extension-based architecture. A separate forthcoming runtime RFD will replace the Concourse-based execution layer. v3 of the pipeline language is the user-facing surface that needs to be in place before that runtime change lands — both to give instructors a stable syntax to author against, and to give the new runtime a clean contract to implement.

## Scope

### In scope

- **Pipeline configuration language (v3).** HCL syntax, blocks, expressions, validation rules.
- **Formula configuration language (v3).** HCL syntax for components, scoring, dynamic component generation.
- **Result emission contract.** The schema of `exec_result` records produced by stage executions and consumed by the formula.
- **Examination integration.** A `document "examination" {}` block usable by both pipeline and formula.
- **Parse-time validation rules** for both languages.

### Out of scope (deferred to follow-up RFDs)

- **Runtime architecture.** How `exec` blocks are dispatched, what isolation environment runs them, workflow orchestration (Temporal vs alternatives), worker lifecycle, container management. Covered by a forthcoming runtime RFD.
- **Toolkit reusability.** A v3 pipeline can inline `exec` blocks directly. A future "toolkit" mechanism — reusable HCL macros that expand to `exec` blocks with parameter holes — is a separate RFD.
- **Plugin / framework blocks.** Richer per-stage result emission (e.g., parsing pytest output into structured test results, a JSON-emitter plugin) is deferred. The v3 contract emits only `exit_code`, timing, and object-storage URIs for stdio.
- **Storage column shape changes.** v3 commits only to the data contracts (HCL source for pipeline and formula, the `exec_result` schema, the `pipeline.<name>.scenarios` reshape). The precise ALTER TABLE statements — what tables hold the records, what columns get added or reshaped, what existing tables retire — are the runtime RFD's concern.

### Not retained from v1/v2 (full replacement)

- The `version = 1` and `version = 2` parsers. Existing configs do not migrate automatically; they are rewritten for v3.
- The `group { ... }` block (between stage and scenario).
- The `source { uri, ref } ` block (returns with toolkit).
- The `assets { type = ... }` block (replaced by implicit mounting + the `document` block).
- `formula "..." {}` references inside the pipeline.
- `group.scoring { mode = "sum" | "deduction" | ... }` blocks.
- The `weighted_sum` and `deduction` formula modes as first-class enums (recoverable as plain HCL expressions in `scoring.total`).

## Terminology

Anchoring the terms used throughout this RFD:

- **Config** — the HCL document stored in `pipeline.config` (or its formula counterpart in `evaluation.formula`). One row per config.
- **Pipeline** — each `pipeline "<name>" { ... }` block inside a config. A pipeline is a DAG of stages over a single conceptual grading unit (one exam question, one assignment aspect, one batched MC set).
- **Stage** — a step within a pipeline. Contains exactly one `exec` block.
- **Scenario** — a parameter set within a stage. Each scenario produces exactly one `exec_result` when the stage runs.
- **Pipeline Run** — one execution of one pipeline against one submission. A config with N pipeline blocks produces N runs per submission. (Data-model detail belongs to the runtime RFD; see [Persistence](#persistence).)
- **Submission Grading** — the umbrella concept that bundles all pipeline runs for one (config, submission) pair. Not a separate table; just a query view over `pipeline_run` grouped by `(config_id, delivery_id)`.

Within a pipeline, the relationship between blocks:

```
config
  └── pipeline "name"
        └── stage "name"
              └── exec
                    ├── scenario "code-1"
                    ├── scenario "code-2"
                    └── ...
```

A pipeline can have many stages; a stage has exactly one `exec`; an `exec` can have many scenarios (or none, in which case a single implicit `scenario "default"` is assumed).

## Proposal

The v3 design rests on five organising decisions:

1. **The pipeline is score-blind.** No `scoring {}` blocks, no `formula "..."` references, no `max_score` lookups in the pipeline. The pipeline emits raw scenario results; the formula consumes them.
2. **`exec` is the canonical primitive.** Every stage contains exactly one `exec` block that runs a command. Toolkit-style reuse becomes a separate (future) sugar layer that expands to `exec`.
3. **Stdio lives in object storage, not in the database.** Captured stdin/stdout/stderr are stored as object-storage blobs; the result record contains only URIs.
4. **Execution and testing are separate stages.** There is no assertion DSL in the pipeline. A "test" is just another `exec` (typically `diff`, or a custom comparator) whose exit code feeds the formula.
5. **The formula is full HCL.** Components are declared as HCL blocks with aggregation expressions; the top-level scoring policy is a native HCL expression rather than a mode enum. Examination-aware dynamic component generation falls out of the same `dynamic` block mechanism the pipeline uses.

A worked example illustrates the shape. For a coding exam question:

```hcl
version = 3

document "examination" { id = 1 }

pipeline "programming-q1" {
  description = "Question 1"

  stage "compile" {
    exec {
      command = "gcc"
      args    = ["-o", "q1.out", "q1.c"]
      timeout = "5s"
    }
  }

  stage "execute" {
    exec {
      command = "./q1.out"
      scenario "test1" { args = ["20"];  stdout_path = "test1_out.txt" }
      scenario "test2" { args = ["50"];  stdout_path = "test2_out.txt" }
      scenario "test3" { args = ["100"]; stdout_path = "test3_out.txt" }
    }
  }

  stage "test" {
    exec {
      command = "diff"
      scenario "test1" { args = ["test1_out.txt", "test1_expected.txt"] }
      scenario "test2" { args = ["test2_out.txt", "test2_expected.txt"] }
      scenario "test3" { args = ["test3_out.txt", "test3_expected.txt"] }
    }
    visibility {
      filter { effect = "hide" until = "collection_stop" }
    }
  }
}
```

And the corresponding formula:

```hcl
version = 3

document "examination" { id = 1 }

locals {
  test_codes = ["test1", "test2", "test3"]
}

pipeline "programming-q1" {}

component "q1" {
  max_score = document.examination.questions["q1"].marks
  score     = sum([for code in local.test_codes :
                   document.examination.questions["q1"].marks / length(local.test_codes)
                   if succeeded(pipeline["programming-q1"].scenarios[code].test)])
}

scoring {
  max_score = 100
}
```

The rest of this RFD details each piece.

## Pipeline language

### Top-level structure

A pipeline config is one HCL file containing:

- **`version = 3`** — required, top-level attribute. Configs without this (or with a different value) are rejected at parse time.
- **`locals { ... }`** — optional, at most one. Declares named values usable as `local.<name>` in any expression in the file. (See [Locals](#locals) below for the declaration-order rule.)
- **`document "<type>" { id = <int> }`** — optional, at most one block per type. Resolves to a fixed snapshot of the named document at parse time. Only `"examination"` is defined in v3.
- **`pipeline "<name>" { ... }`** — one or more. Each is an independent DAG.

There are no other top-level blocks. `source` and `assets` are dropped (see [Abandoned ideas](#abandoned-ideas)). Cross-file `import`/`include` is not supported.

### Pipeline block

```hcl
pipeline "name" {
  description = "human-readable text"   # optional, UI-only
  stage "..." { ... }
  stage "..." { ... }
  # ...
}
```

- The label (here, `"name"`) is the pipeline's identifier. Labels must match `[a-zA-Z0-9_-]+` — the same character class as scenario codes — to keep names safe across HCL syntax (dotted vs bracketed access) and downstream paths. Formulas reference the pipeline's results via the reserved top-level namespace `pipeline.<name>` (or `pipeline["<name>"]` when the label isn't a bare HCL identifier — e.g., contains dashes).
- Multiple pipelines in one config are allowed and are the norm for examination cases.
- Pipelines are independent: no shared state, no inter-pipeline `depends_on`, no cross-pipeline references in HCL. They execute in parallel at runtime.
- A pipeline must contain at least one `stage` block (after dynamic expansion).

### Stage block

```hcl
stage "name" {
  depends_on = ["other_stage"]   # optional; default = previous stage in declaration order
  exec { ... }                    # required, exactly one
  visibility { ... }               # optional
}
```

- The label is the stage identifier. Must be unique within the pipeline. (Stage labels are not required to be HCL identifiers in v3 since they are referenced only as map keys under `pipeline.<name>.scenarios[<code>]`, never as bare names in expressions.)
- `depends_on` lists other stage names that must complete successfully before this stage runs. The default (when omitted) is the previous stage in declaration order — making the common linear case (`compile → execute → test`) implicit. **For the first stage in declaration order**, the implicit default is `depends_on = []` (no dependencies). Set `depends_on = []` explicitly to opt a non-first stage out of the implicit chain (useful for stages that should run in parallel with the first stage).
- Stages run in topological order from the `depends_on` graph. Cycles are rejected at parse time.
- **Success-gating semantics:** if any dependency stage ends in the `failed`, `error`, or `skipped` state, this stage's scenarios all receive `skipped: true` in their results and the stage's own state becomes `skipped`. (See [Result emission contract](#result-emission-contract).)

A stage's overall state is derived from its scenarios' results:

| Stage state | Condition |
|---|---|
| `success` | All scenarios ran and have `exit_code == 0`, `!timed_out`, `error == null`, `!skipped`. |
| `failed`  | At least one scenario has `exit_code != 0` (and is not `timed_out`/`error`); no `timed_out`/`error` scenarios. |
| `error`   | Any scenario has `timed_out == true` or `error != null`. |
| `skipped` | Stage was gated out by a `depends_on` dependency (every scenario has `skipped: true`). |

`error` outranks `failed` (an infrastructure-level failure on any scenario dominates a normal test failure on another). `failed` outranks `success`. `skipped` is exclusive — a skipped stage has no other state.
- Scenarios *within* a single stage run in parallel; they are independent.

### Exec block

The `exec` block is the heart of v3: every stage contains exactly one, and every command the runtime issues is the resolution of one `exec` block for one scenario.

```hcl
exec {
  command       = "diff"
  args          = ["a.txt", "b.txt"]
  stdin_content = "raw input string"        # mutually exclusive with stdin_path at the same level
  stdin_path    = "fixtures/input.txt"
  stdout_path   = "output.txt"
  stderr_path   = "error.txt"
  timeout       = "5s"
  env           = { LANG = "C", DEBUG = "1" }
  workdir       = "./subdir"

  scenario "test1" {
    args        = ["20"]
    stdout_path = "test1_output.txt"
  }

  dynamic "scenario" {
    for_each = ...
    labels   = [...]
    content { ... }
  }
}
```

#### Attribute placement

| Attribute       | At exec level | At scenario level |
|-----------------|---------------|-------------------|
| `command`       | **required**  | **forbidden** (parse error) |
| `args`          | optional      | optional |
| `stdin_content` | optional, mutually exclusive with `stdin_path` at this level | same |
| `stdin_path`    | optional, mutually exclusive with `stdin_content` at this level | same |
| `stdout_path`   | optional      | optional |
| `stderr_path`   | optional      | optional |
| `timeout`       | optional      | optional |
| `env`           | optional      | optional |
| `workdir`       | optional      | optional |

`command` is exec-level only because the point of scenarios is "same command, different parameters." Differing commands belong in different stages.

#### Inheritance and merging

When the runtime resolves a scenario for execution:

- `command` — always taken from `exec.command`.
- `args` — scenario's `args` if set, else exec's `args`, else `[]`. **Replace, not append.**
- `stdin_*` — if the scenario sets either `stdin_content` or `stdin_path`, that value wins (and shadows whichever the exec set). If the scenario sets neither, fall back to whichever the exec set. If neither anywhere, no stdin is provided.
- `stdout_path` / `stderr_path` — scenario's if set, else exec's, else null (no file write; stdio is still captured to object storage unconditionally).

**Path resolution for `stdin_path`, `stdout_path`, `stderr_path`.** A path without a leading `/` is resolved relative to the exec's effective `workdir` (which is itself relative to the stage's root workdir; see [`workdir` constraints](#workdir-constraints) below). An absolute path (leading `/`) is resolved as-is against the container filesystem. Absolute paths are allowed for these attributes — `stdin_path = "/dev/null"` is a common and valid pattern — because the container's filesystem is itself the sandbox boundary; HCL does not need to enforce path constraints the runtime already enforces. The `..` segment is still rejected to prevent unintentional traversal-via-relative-path.
- `timeout` — scenario's if set, else exec's, else runtime default.
- `env` — **merged** key-by-key: exec's env, then scenario's env overlaid; scenario wins on conflict.
- `workdir` — scenario's if set, else exec's, else `.` (the stage's root workdir).

`args` replaces because list-append is hard to reason about across multiple inheritance layers; `env` merges because that's the natural semantics for maps and the common case (shared base env + per-scenario additions) is what authors expect.

**Idiomatic pattern for shared-prefix args.** Because `args` replaces (not appends), the canonical pattern for "shared command flags plus per-scenario tail" uses `locals` and `concat`:

```hcl
locals {
  diff_base = ["--ignore-case", "--strip-trailing-cr"]
}

exec {
  command = "diff"
  scenario "test1" { args = concat(local.diff_base, ["out1.txt", "exp1.txt"]) }
  scenario "test2" { args = concat(local.diff_base, ["out2.txt", "exp2.txt"]) }
}
```

<a id="workdir-constraints"></a>
**`workdir` constraints.** The base directory is the stage's root workdir, set by the runtime. The `exec.workdir` attribute is interpreted relative to that root. Absolute paths (leading `/`), empty strings, and any path with a `..` segment are all rejected at the validate phase. The literal value `"."` is allowed (it's the default).

#### Scenarios

A stage's scenarios are declared either statically (`scenario "code" { ... }`) or dynamically (`dynamic "scenario" { for_each = ... }`); they can be mixed.

- Scenario codes must be unique within a stage. Codes must match `[a-zA-Z0-9_-]+` — letters, digits, hyphen, underscore. Dynamic-block-generated labels that don't match this pattern are validate-phase errors. (This is stricter than the HCL syntax for block labels and prevents brittle codes from URL-encoding, shell escaping, or path quirks downstream.)
- The same code across different stages of the same pipeline refers to the same logical scenario — the formula's `pipeline.<pipeline-name>.scenarios[<code>]` will have entries for each stage that declared it. (See [Result emission contract](#result-emission-contract).)
- The code `"default"` is reserved for the implicit single-scenario case. Explicitly declaring `scenario "default" {}` is a parse error.
- A stage with no `scenario` or `dynamic "scenario"` blocks at all gets one implicit scenario with code `"default"`.

#### Dynamic scenarios

```hcl
dynamic "scenario" {
  for_each = [for q in document.examination.questions : q if q.type == "mc"]
  labels   = [scenario.value.id]
  content {
    args = ["--ignore-case", "${scenario.value.id}.txt", "${scenario.value.id}.expected.txt"]
  }
}
```

Standard HCL2 `dynblock` extension semantics:
- `for_each` takes any iterable (list, map, set, object).
- `labels` provides the labels for the generated blocks (the scenario code in this case).
- `content` is the body template, with the iterator variable in scope.

All `dynamic` expansion happens at the **parse phase** (not at runtime; see [Validation](#validation) for the parse-vs-validate phase distinction). The resolved pipeline structure — concrete list of stages, scenarios, evaluated attributes — is fixed once the parse phase completes.

#### Constraints on `command`

- No implicit shell — `command` is the program name; `args` is the argument list. Shell features (`&&`, `|`, `>`, glob) require explicit `command = "/bin/sh"; args = ["-c", "..."]`. This is a deliberate constraint to keep stage semantics inspectable.
- No `script` heredoc attribute. If shell-style multi-line work is needed, use `command = "/bin/sh"; args = ["-c", "<script>"]`. (Reconsidered in a follow-up if absence becomes consistently painful.)

### Visibility block

```hcl
stage "execute" {
  exec { ... }
  visibility {
    # Default: hide everything.
    filter { effect = "hide" }
    # Reveal stdout/stderr only when the binary exited cleanly.
    # Failure stdio might contain sensitive test inputs or system info.
    filter {
      effect   = "none"
      selector = ["stdout", "stderr"]
      when     = "exit_on_zero"
    }
    # Always show metadata so students can see their binary ran, what it
    # was invoked with, and how long it took. Safe here because this is
    # an execution stage — `exit_code` reflects whether the program itself
    # ran, not whether the output was correct. (Don't do this on a test
    # stage that runs `diff`: there, `exit_code == 0` literally reveals
    # whether the student passed the case, which defeats deadline-gating.)
    filter {
      effect   = "none"
      selector = ["metadata"]
    }
    # Re-hide non-metadata artifacts until the deadline. Selector
    # explicitly omits "metadata" so the prior reveal stands; a
    # selector-less hide here would override metadata visibility too.
    filter {
      effect   = "hide"
      selector = ["stdin", "stdout", "stderr"]
      until    = "collection_stop"
    }
  }
}
```

Visibility is stage-level (no per-scenario override) and is evaluated at result-display time, not at exec time. The pipeline always captures everything; the API filters at read time.

**Filter attributes:**

| Attribute  | Values                                                | Semantics |
|------------|-------------------------------------------------------|-----------|
| `effect`   | `"hide"` or `"none"`                                  | `"hide"` marks the selected artifacts hidden; `"none"` clears a previous `"hide"`. |
| `selector` | subset of `["stdin", "stdout", "stderr", "metadata"]` | Which artifacts the filter applies to. Empty (or omitted) = all. `"metadata"` covers `command`, `args`, `exit_code`, `timed_out`, `skipped`, `error`, `duration_ms`, timestamps. |
| `when`     | `"exit_on_zero"` (only value defined in v3)           | State condition. The filter only applies when the scenario's exit_code is 0. |
| `until`    | `"collection_stop"` (only value defined in v3)        | Time condition. The filter only applies while the current time is before the collection's `stop_at`. If the activity has no associated collection or the collection has no `stop_at`, the filter is treated as **always applying** (the deadline-gate never relaxes). |

**Semantics:**

- Filters are evaluated in declaration order, against each (scenario, artifact) pair independently.
- Default state for every artifact is `visible`.
- Later filters override earlier ones for the same artifact.
- `when` and `until` are AND-style gates on the filter — if either condition fails, the filter is skipped entirely. When both are set, both must hold for the filter to apply.
- `when = "exit_on_zero"` reads the scenario's `exit_code` from the metadata regardless of whether `metadata` is currently hidden by an earlier filter. Filter conditions always have access to the underlying data; only the *exposure* to students is affected by `effect`.
- `score` and `expected` selectors (from v1/v2) are dropped: scoring lives in the formula, and there is no expected-output artifact in v3.

A stage without a `visibility {}` block has all artifacts visible.

**Note on selector stability.** The `"metadata"` selector is a named group whose members are fixed to the v3 `exec_result` fields listed above. The plugin/framework follow-up RFD (which adds richer per-stage output channels) will introduce **new selector values** rather than expanding the membership of `"metadata"`. This keeps `"metadata"` as a stable bag of "what every exec produces" for visibility rules that survive plugin adoption.

### Locals

```hcl
locals {
  compiler        = "g++"
  cflags          = ["-std=c++17", "-O2", "-Wall"]
  scenario_marks  = { test1 = 3, test2 = 5, test3 = 12 }
  passing_marks   = sum([for k, v in local.scenario_marks : v]) / 2
}
```

- A single optional `locals {}` block, declared at the top level of the config.
- Each entry is `<name> = <expression>`. Names must be valid HCL identifiers.
- Values are arbitrary HCL expressions: literals, lists, maps, function calls, references to `document.*`, references to earlier-declared locals.
- **Declaration order matters.** A local can reference earlier locals in the same block, but not later ones. Forward references are validate-phase errors. (Cycles are therefore structurally impossible.) This diverges from Terraform, where `locals` are resolved topologically across the whole block — v3 picks declaration order to keep the parser simpler and to surface forward-reference typos as errors rather than silently working.
- Locals are referenced as `local.<name>` (singular) anywhere in the config — pipeline blocks, scenario attributes, dynamic block `for_each`, etc.

The pipeline file's locals and the formula file's locals are independent namespaces.

### Document block

```hcl
document "examination" {
  id = 1
}
```

- The label is the document type. Only `"examination"` is defined in v3.
- `id` (required, integer) references the row in the corresponding domain table.
- The block is optional. Configs that don't need examination data simply omit it.
- At most one block per type per file. Two `document "examination" {}` blocks are a parse error.
- **Resolved at the parse phase** — the runtime fetches the document once when grading begins and injects it as a static HCL variable. Subsequent changes to the document do not affect already-parsed runs.

When declared, `document.examination` is in scope throughout the file and exposes a contract that **differs slightly between pipeline and formula** — the formula additionally sees per-question `marks`. Both scopes see the rest of the marking scheme.

**In the pipeline** (`document.examination`):

```hcl
{
  id        = 1
  questions = {
    "q1" = {
      id      = "q1"
      type    = "coding"
      # Coding questions carry no auto-grading rubric here — the
      # instructor's authored pipeline + formula component IS the rubric.
    }
    "q2" = {
      id      = "q2"
      type    = "mc"
      marking = {
        # Modality-specific rubric data (defined by the marking-scheme
        # schema in the integration RFD). Per-modality fields exposed to
        # the pipeline include the expected-answer file path the test
        # stage diffs against, and any per-question matching rules.
        expected_file = "<runtime-chosen path>"
      }
    }
    "q4" = {
      id      = "q4"
      type    = "sa"
      marking = {
        expected_file = "<runtime-chosen path>"
        diff_flags    = ["--ignore-case"]
      }
    }
    ...
  }
}
```

Committed fields (must be present, types stable):
- `id` (int)
- `questions` (map keyed by question id)
- Each question:
  - `id` (string)
  - `type` (string — values from the answer-modality registry: `"mc"`, `"tf"`, `"sa"`, `"essay"`, `"coding"`)
  - `marking` (object, per-modality shape) — present for any modality whose marking scheme carries data the pipeline needs to run tests; absent for `"coding"` (the instructor-authored fragment is the rubric) and `"essay"` (not auto-graded). The exact per-modality shape is defined by the marking-scheme schema in the integration RFD; the language RFD commits only to "this field is exposed when the modality has rubric data."

**In the formula** (`document.examination`):

```hcl
{
  id        = 1
  questions = {
    "q1" = { id = "q1", type = "coding", marks = 30 }
    "q2" = { id = "q2", type = "mc",     marks = 5,  marking = { ... } }
    ...
  }
}
```

Same as the pipeline view, plus:
- `marks` (number) on each question

**Why the split.** "The pipeline is score-blind" (per [Proposal](#proposal) decision 1) means the pipeline doesn't compute scores, doesn't know mark weights, and doesn't reference `formula.*` — *not* that the pipeline can't see the rubric. The pipeline needs marking data to actually run tests (knowing which choice is correct for MC, what diff flags to use for SA, what file holds the expected answer). The contract carve-out is exactly `marks`: that field is what would let the pipeline make scoring decisions. Everything else the marking scheme carries — expected answers, match rules, file paths — is available to both scopes. The parser enforces the carve-out at the namespace level; nothing else relies on convention.

**Domain-extensible fields** (the examination service may add without bumping this RFD): `title`, `description`, `parts`, etc. Pipeline/formula authors use them at their own risk; existence is not guaranteed by this RFD.

**Resolution.** The runtime resolves the examination document at the parse phase by joining the `examination.question`, `examination.answer_modality_meta`, and the active marking-scheme version pointed to by `marking_scheme_meta.active_version_id`. The flat `questions` map exposed to HCL is therefore a synthetic view assembled from multiple sources, not a 1:1 reflection of any single table. This resolution involves a cross-extension fetch (typically NATS), not a filesystem access — the "no `file()` function" restriction is about preventing arbitrary disk reads from HCL expressions, not about avoiding all external data resolution. The `marks` field on each question is sourced from the marking-scheme blob and is filtered out of the pipeline's view of the synthetic record before injection; everything else flows through to both scopes.

**Cross-file ID match.** The pipeline and formula configs are loaded together at the parse phase. The four declaration cases:

- **Both declare with matching `id`** — OK. Both files see the same resolved document.
- **Both declare with mismatched `id`** — parse-phase error. Rejected before grading starts.
- **Only one declares** — OK. The declaring file sees the document; the other has no `document.*` in scope (any reference would be a parse-phase error from the other file).
- **Neither declares** — OK. The activity is not exam-bound; neither file has `document.*` in scope.

### HCL functions

The supported function set is small and side-effect-free:

| Function | Signature | Purpose |
|----------|-----------|---------|
| `range(end)` / `range(start, end)` / `range(start, end, step)` | → `list(number)` | Python-style numeric range. |
| `setproduct(a, b, ...)` | → `list(tuple(...))` | Cartesian product over 2+ iterables. |
| `replace(str, substr, repl)` | → `string` | Literal replace; or regex if `substr` is `/pattern/`. |
| `try(expr, fallback, ...)` | → any | Returns the first argument that evaluates without error; the last argument is the final fallback. Catches HCL evaluation errors (missing keys, type mismatches, division-by-zero). Does **not** catch `null` values — `null` is a valid value in HCL comparisons, not an error. |
| `concat(list, list, ...)` | → `list` | List concatenation. |
| `merge(map, map, ...)` | → `map` | Map merge (later keys win). |
| `length(coll)` | → `number` | Element count of a list, map, set, or string. |
| `sum(list)` | → `number` | Sum of a list of numbers. Empty list yields 0. |
| `alltrue(list)` | → `bool` | True iff every element is `true`. Empty list yields `true`. Null elements are treated as `false`. |
| `anytrue(list)` | → `bool` | True iff at least one element is `true`. Empty list yields `false`. Null elements are treated as `false`. |
| `succeeded(result)` | → `bool` | True iff the given `exec_result` represents a successful execution (`exit_code == 0 && !timed_out && !skipped && error == null`). **Null-permissive**: returns `false` if the argument is null or a missing field path (so `succeeded(s.test)` works even when `s.test` is absent). |
| `failed(result)` | → `bool` | Symmetric: true iff the execution ran but exited non-zero, timed out, or errored. Skipped scenarios yield `false`. Null/missing argument yields `false`. |

All functions are pure: no filesystem access, no network, no external state. Functions that read from disk (e.g., `file()`, `fileset()`) or compile regex patterns (`regex()`) are deliberately *not* included — they couple parse-time to runtime state and undermine the parse-time-frozen guarantee.

The `succeeded`/`failed` pair is the formula's canonical predicate for "did this exec block complete cleanly?" — neutral language since the same predicate is meaningful for a `compile` exec (compilation succeeded), an `execute` exec (binary ran cleanly), or a `test` exec (e.g., diff exited zero, meaning outputs matched). The author interprets the meaning per-stage; the predicate is uniform.

Typical formula patterns without `try()`:

```hcl
# Count scenarios that passed the test stage of pipeline "main"
score = length([for _, s in pipeline.main.scenarios : 1 if succeeded(s.test)]) * 10

# Per-question marks from the exam, awarded only on success — over the "mc" pipeline
score = sum([for code, s in pipeline.mc.scenarios :
             document.examination.questions[code].marks
             if succeeded(s.test)])

# All-or-nothing for a question with multiple test cases — pipeline name has a dash
score = alltrue([for _, s in pipeline["programming-q1"].scenarios : succeeded(s.test)]) ? 30 : 0
```

## Result emission contract

Each scenario execution produces one `exec_result` record. The schema below is the contract between the pipeline runtime (which produces records) and the formula (which consumes them via the [reshape](#reshape-for-formula-consumption)). Concrete storage shape — whether records live in a JSONB column, a separate row table, an object-store file, etc. — is the runtime RFD's concern; this section commits only to fields and types.

A pipeline run's emission is an array of these records, one per (stage, scenario) pair that ran (or was gated out):

```json
[
  {
    "stage": "compile",
    "scenario_code": "default",
    "result": {
      "command": "gcc",
      "args": ["-o", "q1.out", "q1.c"],
      "exit_code": 0,
      "timed_out": false,
      "skipped": false,
      "error": null,
      "started_at": "2026-05-18T10:23:45.001Z",
      "ended_at":   "2026-05-18T10:23:45.412Z",
      "duration_ms": 411,
      "stdin_uri":  null,
      "stdout_uri": "s3://<bucket>/<prefix>/compile/default/stdout.txt",
      "stderr_uri": "s3://<bucket>/<prefix>/compile/default/stderr.txt"
    }
  },
  {
    "stage": "execute",
    "scenario_code": "test1",
    "result": {
      "command": "./q1.out",
      "args": ["20"],
      "exit_code": 0,
      "timed_out": false,
      "skipped": false,
      "error": null,
      "started_at": "...",
      "ended_at":   "...",
      "duration_ms": 142,
      "stdin_uri":  null,
      "stdout_uri": "s3://<bucket>/<prefix>/execute/test1/stdout.txt",
      "stderr_uri": "s3://<bucket>/<prefix>/execute/test1/stderr.txt"
    }
  },
  ...
]
```

### Field definitions

| Field | Type | Meaning |
|-------|------|---------|
| `command` | string | Resolved command name (after locals, scenario overrides, dynamic expansion). |
| `args` | list(string) | Resolved argument list. |
| `exit_code` | int \| null | Process exit code. `null` only if the scenario was `skipped`. |
| `timed_out` | bool | True if the runtime killed the process for exceeding `timeout`. |
| `skipped` | bool | True if the scenario was gated out by upstream stage failure. When true, `exit_code` is null and all `*_uri` fields are null. |
| `error` | string \| null | Human-readable explanation for infra-level failures (process spawn error, object-storage upload failure, etc.). Null otherwise. |
| `started_at` / `ended_at` | RFC 3339 timestamp | UTC. Null when `skipped`. |
| `duration_ms` | int | Wall-clock execution time. 0 when `skipped`. |
| `stdin_uri` | string \| null | Object-storage URI of the actual stdin passed to the process. Always populated when stdin was provided (whether via `stdin_content` inline literal or `stdin_path` file reference — inline content is materialized by the runtime to an object-storage blob and its URI is what appears here). Null only when no stdin was provided or the scenario was skipped. |
| `stdout_uri` | string \| null | Object-storage URI of captured stdout. Always present unless skipped (zero-byte object if process produced no output). |
| `stderr_uri` | string \| null | Symmetric to `stdout_uri`. |

URIs are opaque to the formula — it never parses them. The runtime RFD picks the bucket/path scheme; v3 commits only to "these are dereferenceable URIs to the actual stdio bytes."

### Invariants

- **All stdio is captured.** Empty output produces a zero-byte object with a valid URI. `stdout_uri = null` only when `skipped = true`.
- **Field set is fixed.** No user-defined fields, no plugin-emitted custom keys. Plugin/framework blocks (deferred) will introduce a separate structured-output channel without changing this contract.
- **`command`/`args` are resolved values**, not templates. Anything the runtime actually invoked.
- **Per-scenario parameters are not stored.** The pipeline's scenario block may carry attributes (`args`, `timeout`, etc.); these drive execution and are captured in `command`/`args`/etc. — not as a separate metadata dict. Scoring-relevant per-scenario metadata belongs in the formula, not the pipeline.

### The `pipeline` namespace

Formulas access pipeline-run data through a reserved top-level namespace `pipeline`. The namespace is grounded by `pipeline "<name>" {}` declaration blocks at the top level of the formula file (see [Pipeline declaration block](#pipeline-declaration-block)); for each declared name, the runtime injects an entry `pipeline.<name>` (or `pipeline["<name>"]` for non-identifier names) whose `scenarios` attribute is a scenario-keyed map.

```hcl
pipeline = {
  "main" = {
    scenarios = {
      "default" = {
        "compile" = { command, args, exit_code, ..., stdin_uri, stdout_uri, stderr_uri }
      }
      "test1" = {
        "execute" = { ... },
        "test"    = { ... }
      }
      "test2" = { "execute" = { ... }, "test" = { ... } }
      "test3" = { "execute" = { ... }, "test" = { ... } }
    }
  }
  "programming-q2" = {
    scenarios = { ... }
  }
}
```

The namespace is **reserved** (instructors can't redefine `pipeline` via `locals`) and **runtime-injected** (resolved once the pipeline runs complete, before formula evaluation begins). It sits alongside the other reserved namespaces in formula scope, each grounded in its own block declaration: `local.<name>` from `locals {}` (parse-phase-resolved), `document.<type>` from `document "<type>" {}` (parse-phase-resolved), `pipeline.<name>` from `pipeline "<name>" {}` (runtime-resolved).

**Where `pipeline.<name>` is in scope.** Only inside expressions that evaluate against runtime data:

- `component.score`
- `scoring.total`

`pipeline.<name>` is **not** in scope in expressions that resolve at parse phase: `locals { ... }`, `component.max_score`, `dynamic` block `for_each`, etc. Referencing it from those contexts is a validate-phase error — independent of whether the pipeline is declared.

<a id="pipelinenamescenarios-schema"></a>
#### `pipeline.<name>.scenarios` schema

This is the formula's contract with the pipeline. The runtime generates each entry from the corresponding `pipeline_run.results` JSONB and exposes it as an HCL value to runtime-evaluated expressions.

| Type | Description |
|------|-------------|
| `pipeline.<name>` | Type `object` with at minimum a `scenarios` attribute. Future v3 versions may add metadata fields (e.g., `pipeline.<name>.run_id`, `pipeline.<name>.started_at`); the v3 surface commits only to `scenarios`. |
| `pipeline.<name>.scenarios` | Type `map(string, object)`. Outer map keyed by scenario codes; values are nested per-stage maps. |
| `pipeline.<name>.scenarios[<code>]` | Type `map(string, object)`. Keys are stage names; values are the **exec_result fields** (`command`, `args`, `exit_code`, `timed_out`, `skipped`, `error`, `started_at`, `ended_at`, `duration_ms`, `stdin_uri`, `stdout_uri`, `stderr_uri`). |
| `pipeline.<name>.scenarios[<code>][<stage>]` | The flattened `result` object from the `exec_result` JSONB entry. Field types match the [Field definitions](#field-definitions) table verbatim. |

**Missing-key semantics.** `pipeline.<name>.scenarios[<code>]` is absent if no stage of that pipeline produced a scenario with that code. `pipeline.<name>.scenarios[<code>][<stage>]` is absent if that scenario was not declared in that stage (the asymmetric case described below). Accessing an absent key in HCL is a parse-time evaluation error, caught by `try()` — or by the null-permissive `succeeded()` / `failed()` predicates which return `false` on absent arguments.

**Heterogeneous keys.** Stages with different scenario sets produce heterogeneous outer keys. In the example above, `"default"` only has `"compile"` (because `compile` has no explicit scenarios, getting the implicit `"default"`), while `"test1"`/`"test2"`/`"test3"` have `"execute"` and `"test"` but not `"compile"`. **A formula iterating `for code, sc in pipeline.main.scenarios` will visit the `"default"` key too** — the canonical pattern uses `succeeded(sc.<stage>)` (null-permissive) so the iteration silently skips scenarios that lack the stage the formula cares about.

**Two safe iteration patterns.** Use whichever fits the pipeline shape:

- **Iterate `pipeline.<name>.scenarios` directly** when every scenario in the pipeline has the stage you're checking. This is the natural shape for batched pipelines (e.g., `pipeline.mc.scenarios` whose single `test` stage produces one scenario per question — every key is a question id with a `test` entry).
- **Iterate an explicit code list** (`for code in local.test_codes : ... pipeline.<name>.scenarios[code].<stage>...`) when only a subset of the pipeline's scenarios are relevant — e.g., a coding pipeline where `compile` adds a `"default"` key the scoring should ignore. The explicit list filters out unwanted keys without `try()` boilerplate.

**Empty pipelines.** If a pipeline produced zero results (e.g., the runtime failed to start the worker container at all), `pipeline.<name>.scenarios` is an empty map (`{}`). Expressions like `length(pipeline.<name>.scenarios) == 0` evaluate as expected; the formula author is expected to defend against this case with `try()` or explicit conditionals.

**Runtime-error pipelines.** A pipeline whose worker crashed mid-execution (some scenarios completed, others didn't get a result emitted) produces a `pipeline.<name>.scenarios` containing only the scenarios that *did* complete. The formula's evaluation proceeds against the partial map; defensive `try()` wrapping (or null-permissive `succeeded()` / `failed()`) ensures missing scenarios produce predictable fallback values rather than uncaught evaluation errors. How the runtime distinguishes "partial because crash" from "partial because skipped" — and whether that distinction is surfaced to the formula beyond the per-scenario `skipped` flag — is the runtime RFD's call.

**Cross-pipeline composition.** Because `pipeline.<name>` is a top-level reserved namespace (not scoped per component), a single `component.score` expression may reference multiple pipelines — for instance, a bonus component that awards extra marks only when *both* coding-question pipelines pass all tests. Components remain independent of *each other* (one component's score cannot read another's), but they are not artificially scoped to a single source pipeline.

## Formula language

### Top-level structure

A formula config is one HCL file containing:

- **`version = 3`** — required.
- **`locals { ... }`** — optional, at most one. Same semantics as pipeline locals.
- **`document "<type>" { id = ... }`** — optional. Same semantics as pipeline document.
- **`pipeline "<name>" { ... }`** — zero or more (static, dynamic, or mixed). Declares that this formula consumes the named pipeline from the paired pipeline config. The block introduces `pipeline.<name>` into the runtime-evaluated expression scope. See [Pipeline declaration block](#pipeline-declaration-block).
- **`component "<name>" { ... }`** — one or more (static, dynamic, or mixed).
- **`scoring { ... }`** — required, exactly one.

The formula and pipeline files declare `locals` and `document` independently — they are separate HCL documents stored in separate database rows.

Three reserved namespaces are available inside the file's expressions, each with distinct resolution semantics, and each grounded in a block declaration:

| Namespace | Declared via | When resolved | Available in |
|---|---|---|---|
| `local.<name>` | `locals { foo = ... }` block | Parse phase | Everywhere |
| `document.<type>` | `document "<type>" { id = ... }` block; fetched from the examination service | Parse phase | Everywhere |
| `pipeline.<name>` | `pipeline "<name>" { ... }` block; populated by the runtime from the paired pipeline config | Runtime (after pipeline runs complete) | Only inside `component.score` and `scoring.total` |

A `pipeline.<name>` reference is a validate-phase error if no matching `pipeline "<name>" {}` declaration is present in the same formula file. References from parse-phase contexts (`max_score`, `dynamic` block `for_each`, etc.) are validate-phase errors regardless of declaration. See [Pipeline declaration block](#pipeline-declaration-block) and [The `pipeline` namespace](#the-pipeline-namespace).

### Pipeline declaration block

```hcl
pipeline "main" {}
pipeline "programming-q1" {}
pipeline "mc" {}
```

Each `pipeline "<name>" {}` block declares that the formula consumes the named pipeline from the paired pipeline config. The block label is the pipeline name (matching the `pipeline "<name>" { ... }` label in the pipeline file); the block body is empty in v3.

**Why declare.** Declaration grounds the `pipeline.<name>` reserved namespace, parallel to how `locals { ... }` grounds `local.<name>` and `document "<type>" {}` grounds `document.<type>`. Without a declaration, `pipeline.<name>` references are validate-phase errors — a local check that the editor can run as the author types, without needing to read the paired pipeline config.

**Constraints:**

- The block label must be a valid scenario-code pattern (`[a-zA-Z0-9_-]+`) — same constraint pipeline labels carry in the pipeline file.
- Duplicate `pipeline` labels in one formula are a validate-phase error.
- The v3 block body is empty; setting attributes is a validate-phase error. (Future RFDs may introduce attributes — e.g., `required = true`, an alias, or a result-filter projection — without breaking the v3 contract.)
- A declared but unreferenced pipeline raises a validate-phase warning (typo guard); the formula still validates.
- An undeclared `pipeline.<name>` reference in `component.score` or `scoring.total` is a validate-phase error.
- Parse-phase: the declared pipeline name must match a `pipeline "<name>" { ... }` block in the paired pipeline config. Mismatched declarations fail the parse phase before grading dispatches.

**Dynamic declarations.** Formulas whose set of consumed pipelines depends on the examination document (e.g., one pipeline per coding question) use a `dynamic "pipeline"` block at the top level:

```hcl
dynamic "pipeline" {
  for_each = [for q in document.examination.questions : q if q.type == "coding"]
  labels   = ["programming-${each.value.id}"]
  content {}
}
```

The block expands at the parse phase, after `document` resolution, into one `pipeline "..." {}` declaration per iteration. This matches the existing `dynamic "component"` and `dynamic "scenario"` patterns.

### Component block

```hcl
component "correctness" {
  max_score = 70
  weight    = 0.7
  score     = sum([for code, sc in pipeline.main.scenarios :
                   10 if succeeded(sc.test)])
}
```

**Required attributes:**
- `max_score` — number, **must be positive**. Both the UI's "out of X" denominator and a hard cap on `score`.
- `score` — HCL expression yielding a number. Has `pipeline.<name>`, `document.*`, `local.*`, and all supported functions in scope.

**Optional attributes:**
- `weight` — number, **must be positive**, default 1. Free-form metadata accessible in `scoring.total` as `<component_name>.weight`. UI may surface it in rubric displays.
- `min_score` — number, default 0. Floor on the resolved `score`. Set to a negative number to allow a deduction-style component (e.g., a "style penalty" component whose `score` expression yields negative values for accumulated issues).

**No `from` attribute.** Components do not declare a source pipeline. Pipeline dependencies are declared at the *file* level via top-level `pipeline "<name>" {}` blocks (see [Pipeline declaration block](#pipeline-declaration-block)); a component's `score` expression then references the declared namespaces directly. This is symmetric with `document.examination.questions[...]` references — the `document "examination" {}` declaration grounds the namespace, and components reference it without re-declaring.

**Scenario codes can collide across pipelines without conflict.** Because the namespace is `pipeline.<name>.scenarios[<code>]`, two pipelines can each have a scenario `"test1"` — `pipeline.q1.scenarios["test1"]` and `pipeline.q2.scenarios["test1"]` are distinct values.

**Cross-pipeline composition is allowed.** A single component's `score` expression may reference multiple pipelines:

```hcl
# Bonus component awarded only if both coding-question pipelines pass all tests
component "coding_bonus" {
  max_score = 10
  score     = (
    alltrue([for _, s in pipeline["programming-q1"].scenarios : succeeded(s.test)]) &&
    alltrue([for _, s in pipeline["programming-q2"].scenarios : succeeded(s.test)])
  ) ? 10 : 0
}
```

**Component cross-references.** Components are **not** in scope inside other components' `score` expressions — each component evaluates independently against `pipeline.*` data. Cross-component arithmetic (e.g., "this component depends on whether the style component passed") must happen in `scoring.total`, where every component's score is in scope by name. This keeps component evaluation order irrelevant and makes the dependency surface explicit.

**Clamping:** the resolved `score` is clamped to `[min_score, max_score]` (default `[0, max_score]`). Overshooting in either direction (e.g., the expression yields 80 against `max_score = 70`) is recorded in the breakdown as a warning so the instructor can spot expression bugs.

**`max_score` is a cap, not a scale factor.** If the `score` expression yields a value greater than `max_score`, the result is clamped at `max_score` (with a breakdown warning). There is no automatic proportional scaling — authors who want "earn 60% of marks" semantics encode that in the expression directly. This is a deliberate departure from the `weighted_sum` mode in v1/v2 which normalized to a ratio.

### Dynamic components

```hcl
dynamic "component" {
  for_each = [for q in document.examination.questions : q if q.type == "coding"]
  labels   = ["q-${component.value.id}"]
  content {
    max_score = component.value.marks
    score     = sum([for code, sc in pipeline["programming-${component.value.id}"].scenarios :
                     component.value.marks / length(pipeline["programming-${component.value.id}"].scenarios)
                     if succeeded(sc.test)])
  }
}
```

Standard HCL2 dynamic block. Expanded at the parse phase. The generated component names from `labels` must be unique with respect to all other (static and dynamic) component names. The pipeline reference inside the expanded `score` expression — `pipeline["programming-${component.value.id}"]` — interpolates per-iteration; each generated component depends on the pipeline name derived from its iterator value, and parse-phase validation runs against each expanded reference.

### Scoring block

```hcl
scoring {
  total     = correctness.score + style.score                # optional
  max_score = 100                                             # required
  min_score = 0                                               # optional, default 0
}
```

**Attributes:**
- `total` — optional HCL expression. Default = sum of all component scores. The expression has every component in scope by name (as an object with `.score`, `.max_score`, `.weight`), plus a `component` map of type `map(string, object)` for programmatic iteration: `sum([for name, c in component : c.score * c.weight])`. The `component` map always contains every declared component — if any component's evaluation failed, the formula has already aborted before `scoring.total` runs (see [Evaluation failures](#evaluation-failures-are-hard-failures) below).
- `max_score` — required, number, **must be positive**. UI denominator and hard cap on `total`.
- `min_score` — optional, default 0. Floor on `total` (set to a negative number to allow negative final scores).

<a id="evaluation-failures-are-hard-failures"></a>
**Evaluation failures are hard failures.** If any component's `score` expression fails to produce a finite number — type error, division by zero producing `NaN`/`Infinity`, missing-key access not wrapped in `try()`, runtime data corruption — the formula evaluation aborts and the run is marked **ungraded** with a structured diagnostic. There is no "silently treat as 0" mode. Authors are expected to write defensive expressions using `try(<access>, <numeric fallback>)` for any data access that might fail; the design intent is that uncaught failures should surface as bugs to be fixed, not absorbed into student grades.

**Clamping order.** The resolved `total` is first floored at `min_score`, then capped at `max_score`. (Equivalently: `clamped = min(max_score, max(min_score, total))`.) Order matters when `min_score > max_score` (a config bug that the parse phase rejects, but the formal order is committed here to remove ambiguity).

### Component eval examples

**Assignment style (one pipeline, multiple aspects):**

```hcl
version = 3

locals {
  scenario_marks = { test1 = 3, test2 = 5, test3 = 12 }
}

pipeline "main" {}

component "correctness" {
  max_score = sum([for k, v in local.scenario_marks : v])
  score     = sum([for code, sc in pipeline.main.scenarios :
                   local.scenario_marks[code]
                   if succeeded(sc.test)])
}

component "style" {
  max_score = 20
  weight    = 0.3
  score     = succeeded(pipeline.main.scenarios["default"].lint) ? 20 : 0
}

scoring {
  total     = correctness.score + style.score
  max_score = 100
}
```

**Examination style (many pipelines, one per question):**

```hcl
version = 3

document "examination" { id = 1 }

# Declare all consumed pipelines: one per coding question (dynamic) plus
# the batched mc pipeline (static). Declarations expand at parse phase
# after document resolution.
dynamic "pipeline" {
  for_each = [for q in document.examination.questions : q if q.type == "coding"]
  labels   = ["programming-${each.value.id}"]
  content {}
}

pipeline "mc" {}

# One component per coding question
dynamic "component" {
  for_each = [for q in document.examination.questions : q if q.type == "coding"]
  labels   = ["q-${component.value.id}"]
  content {
    max_score = component.value.marks
    score     = sum([for code, sc in pipeline["programming-${component.value.id}"].scenarios :
                     component.value.marks / length(pipeline["programming-${component.value.id}"].scenarios)
                     if succeeded(sc.test)])
  }
}

# One component covering all MC questions in the batched mc pipeline
component "mc_batch" {
  max_score = sum([for q in document.examination.questions : q.marks if q.type == "mc"])
  score     = sum([for code, sc in pipeline.mc.scenarios :
                   document.examination.questions[code].marks
                   if succeeded(sc.test)])
}

scoring {
  max_score = sum([for q in document.examination.questions : q.marks])
}
```

## Validation

Validation runs in two phases, modeled loosely on `terraform validate` vs `terraform plan`:

- **Validate phase** — single-file, schema-only. No external data fetches; no cross-file references resolved. This is what the apps/console HCL editor performs as the author types, and what a pre-publish lint step performs before storing the config. A config that passes `validate` is structurally well-formed but may still fail at runtime if it references things that turn out not to exist.
- **Parse phase** — runs at the start of the grading workflow. Loads the paired pipeline + formula configs together, fetches the referenced `document` blocks from the examination service, and resolves all cross-references. Errors here fail the run before any worker is dispatched. The parse phase also produces the final expanded structure (dynamic blocks resolved against real document data) used for execution.

The split matters because some errors are only knowable with external data (does a referenced examination question exist? does the marking scheme actually have marks for `q5`?), and we want the editor to catch what it can without round-tripping to the examination service for every keystroke.

### Validate phase (schema-only)

Caught with HCL diagnostics including source line/column. Single-file checks, no external dependencies:

- `version` attribute missing, not an integer, or not equal to 3.
- Duplicate `pipeline` labels in a config (pipeline file: duplicate top-level `pipeline "name" { ... }` blocks; formula file: duplicate top-level `pipeline "name" {}` declaration blocks).
- Duplicate `component` labels in a formula.
- Duplicate `stage` labels within a pipeline.
- Duplicate `scenario` codes within a stage.
- A scenario explicitly named `"default"`.
- `depends_on` referencing a non-existent stage in the same pipeline, or forming a cycle.
- `command` attribute set on a scenario block.
- `command` missing or empty at exec level.
- `stdin_content` and `stdin_path` both set at the same level (exec or scenario).
- `workdir` containing a `..` segment, absolute path (leading `/`), or empty string.
- `timeout` value not parseable by Go's `time.ParseDuration`.
- Two `document` blocks of the same type.
- Two `locals` blocks.
- Forward reference within a `locals` block.
- Visibility filter with `effect` other than `"hide"`/`"none"`, `selector` containing an undefined value, `when`/`until` containing an undefined condition.
- `total` expression in scoring referencing an undefined component name.
- Required attribute missing on `component` (`max_score`, `score`) or `scoring` (`max_score`).
- A `pipeline.<name>` or `pipeline["<name>"]` reference in `component.score` or `scoring.total` without a matching `pipeline "<name>" {}` declaration block in the same formula. (Local, single-file check.)
- A `pipeline.<name>` or `pipeline["<name>"]` reference appearing inside a parse-phase context (`locals { ... }`, `component.max_score`, `dynamic` block `for_each`, etc.) where only parse-resolved values are available — regardless of whether the pipeline is declared.
- A `pipeline "<name>" {}` declaration block with a non-empty body in v3 (no attributes are defined yet; reserved for future RFDs).
- A `pipeline "<name>" {}` declaration label not matching `[a-zA-Z0-9_-]+`.
- A scenario code (static label or dynamic `labels` result) not matching `[a-zA-Z0-9_-]+`.
- A `dynamic` block missing both `for_each` and `content`.
- Function calls to functions outside the supported set.
- `weight` set to a non-positive number (`<= 0`).
- `max_score` set to `0` or a negative number on either `component` or `scoring`.
- A pipeline block containing no `stage` block at the static-syntax level.
- An empty `dynamic` block (no `for_each`, no `content`).

A `dynamic` block with `for_each = []` is permitted at validate time (it expands to zero blocks at parse phase, which is treated as valid — a stage with no scenarios after expansion still gets the implicit `"default"` scenario).

#### Validate-phase warnings (non-fatal)

These produce parser warnings rather than errors. The config still validates, but the author is alerted:

- Scenario codes that appear in one stage of a pipeline but not in symmetric form across all "downstream" stages that consume them. Catches `test1` vs `Test1` typos that would otherwise silently produce `score = 0`.
- `args` re-declared at scenario level when exec level also sets `args` without using `concat(local.base, ...)` — suggests the idiomatic shared-prefix pattern.
- `pipeline "<name>" {}` declared in a formula but no reference to `pipeline.<name>` (or `pipeline["<name>"]`) appears in any score or scoring expression. The declaration validates but the warning flags likely unused-import-style typos before parse phase.

### Parse phase (cross-file + external resolution)

Caught at grading workflow start, before any dispatch. Failures here fail the run with a structured error that surfaces to the instructor:

- A `pipeline "<name>" {}` declaration block in the formula whose label has no matching `pipeline "<name>" { ... }` block in the paired pipeline config. (The validate-phase check ensures references match declarations within the formula; this parse-phase check ensures declarations match the pipeline file across the pair. Dynamic `pipeline` declarations are validated post-expansion against the resolved examination document.)
- `document "examination" { id = X }` declared in both pipeline and formula configs with different `id` values.
- A `document` block reference (`document.examination.questions["q1"]`) to a question id that does not exist in the resolved examination.
- A `document` block reference to a field not in the committed contract for that document type — most commonly `document.examination.questions[<id>].marks` from a *pipeline* (marks is the one field carved out of pipeline scope; every other marking field is available to both).
- Dynamic expansion produces zero stages or zero components after resolving `for_each` (the pipeline / formula would have nothing to execute or score).
- A `pipeline_run.results` from a prior run reshaped into `pipeline.<name>.scenarios` whose shape doesn't match the contract (defensive — should never happen but flagged for observability).

### Runtime evaluation errors (during formula evaluation)

These are not "validation" — they fire while computing scores from a fully-parsed config against actual run data. All of them are **hard failures**: the formula evaluation aborts and the run is marked ungraded with a structured diagnostic. There is no graceful-degradation mode.

- A component's `score` expression raises an HCL evaluation error (divide-by-zero, type mismatch, out-of-range index, etc.).
- A component's `score` expression evaluates to a non-numeric value, `NaN`, or `±Infinity`.
- `scoring.total` expression raises an evaluation error or produces a non-finite result.

The rationale for hard-failing: silently substituting 0 for a broken score expression means students lose points to grader bugs that no one notices. Forcing the run into an ungraded state surfaces the problem for staff to fix. Authors who anticipate specific failure modes (a scenario being skipped, a pipeline never running) handle them explicitly inside the expression via `try(<access>, <numeric fallback>)`.

## Persistence

v3 commits to two things about where its inputs live; everything else about persistence (result storage shape, table drops, column additions, FK shape changes, code removal) is the runtime RFD's concern.

- **Pipeline HCL source persists as bytes** in the existing `pipeline.config` row. Parsed on read; the parsed form may be cached but is not authoritative.
- **Formula HCL source persists as bytes** in the existing `evaluation.formula` row, analogously. The previous `components` and `scoring` JSONB columns are replaced by an HCL source column; the exact column-shape change is the runtime RFD's responsibility.

The runtime RFD additionally owns: how `exec_result` records get from worker to database, what tables hold them, what existing tables (`pipeline.result`, `evaluation.score.items`, etc.) get retired by the new flow, how multiple pipeline runs per submission get joined for formula evaluation, and what columns get added or reshaped. v3 commits only to the data contracts described in [Result emission contract](#result-emission-contract) and the [`pipeline.<name>.scenarios` schema](#pipelinenamescenarios-schema); the runtime RFD picks the storage shape that serves them.

## Abandoned ideas

A few alternatives surfaced during design that we chose not to pursue. Recording them so the same paths aren't re-walked.

### Keep `source` and `assets` blocks in v3

Tempting for continuity with v1/v2, but both blocks exist purely to serve patterns v3 removes. `source` declared git repos for toolkit task templates; with toolkit deferred and `exec` direct, source has no consumer. `assets` declared external resources for fetch; in v3, config-level assets are implicitly mounted by the runtime at a known workdir path, and examination assets follow from the `document` block. Adding either back later is a one-block addition; carrying them now is dead syntax.

### Keep `mode = "weighted_sum" | "deduction"` as first-class formula scoring modes

v1/v2 had four formula modes (`sum`, `weighted_sum`, `expression`, `deduction`). With native HCL in `scoring.total`, all of these are recoverable as plain expressions:

- `sum` → omit `total`; default is sum of component scores.
- `weighted_sum` → `total = sum([for n, c in component : c.score * c.weight]) / sum([for n, c in component : c.weight]) * max_score`
- `expression` → just write the expression in `total`.
- `deduction` → `total = initial - sum([for n, c in component : c.score])`

Keeping the modes as enums would mean two ways to express the same thing (`mode = "weighted_sum"` vs writing the expression), inviting drift and adding code paths to maintain. The modes are recoverable as patterns; the enum is not worth carrying.

### Expose per-scenario `parameters` map in the result

An earlier draft of the result schema included `scenario.parameters` — the merged parameter map for the scenario, so the formula could read per-scenario metadata. Discarded because:

- Pipeline parameters drive execution (they become `command`/`args`/`timeout`/`env`), which the result already captures.
- The temptation to use `parameters.marks = "5"` for scoring metadata leaks scoring back into the pipeline, violating the core decoupling principle. Removing the field removes the temptation.
- Scoring metadata belongs in the formula: as constants, as `local.<map>`, or from `document.examination.questions[code]`.

### Filesystem-touching HCL functions (`file()`, `fileset()`, `regex()`)

Some HCL-based grading systems provide these to read test fixtures from disk at parse time. Discarded for v3 because they would re-couple HCL parsing to runtime workdir state and break the parse-time-frozen guarantee — a config that uses `fileset("testcases", "*.in")` produces different results depending on which workdir state happens to exist at parse time. The v3 model puts fixture files under the runtime's purview (mounted into the stage workdir for `exec` to read), not under the parser's.

### Single global scenario-code uniqueness

Considered requiring scenario codes to be unique *across all stages and pipelines* in a config. Rejected because the natural form for a coding-question pipeline reuses the same code (`test1`, `test2`, `test3`) across `execute` and `test` stages to represent "the same scenario at different stages." Scoping uniqueness to the stage and allowing repetition within and across pipelines preserves this idiom.

### Inline assertion DSL on `exec`

A common alternative — particularly in unified-exec HCL designs elsewhere — is to support `assert { exit_code = 0 }` on exec blocks and inline `test { stdin = "..." assert { stdout = "..." } }` blocks for scored test cases. v3 explicitly rejects these because they mix execution and testing in one stage. Instead, v3 forces testing into its own stage: a `diff` exec (or any other comparator) whose exit code feeds the formula. This is more verbose for trivial cases but keeps the semantics crisp: the pipeline never expresses a "pass/fail" judgement, only "what ran and what it produced."

### `from = "..."` attribute on `component`

An earlier draft of the formula language gave each `component` block a `from = "<pipeline-name>"` attribute that declared which pipeline the component aggregated, and exposed the bound results via a bare `pipeline_results` variable. Discarded for three reasons:

- The bare `pipeline_results` had no syntactic affordance for "this is runtime-injected" — instructors couldn't tell from the name alone that it wasn't a local they'd forgotten to declare. The other reserved namespaces in v3 (`local.<name>`, `document.<type>`) all use a dotted prefix; `pipeline_results` was the outlier.
- The `from = "..."` attribute duplicated information that the `score` expression already encoded. A reader (or a static analyzer) could derive the dependency by scanning the expression; declaring it separately invited drift.
- Per-component scoping of pipeline data — a property the `from` attribute enabled — turned out not to be load-bearing. It avoided scenario-code collisions across pipelines, but a top-level `pipeline.<name>.scenarios[<code>]` namespace avoids collisions equally well by namespacing under the pipeline name. And it forbade cross-pipeline composition inside a single component (e.g., bonus marks awarded only when *both* coding questions pass), which has legitimate uses.

The top-level `pipeline.<name>` namespace replaces both the attribute and the bare variable. The attribute is gone; the variable is gone; the dependency is implicit in the expression and validated at parse phase.

### `pipeline "<name>" {}` sub-block on `component`

Considered making the source declaration a sub-block (`pipeline "<name>" {}` inside `component`) instead of an attribute, with a `pipeline.<...>` namespace introduced by that block. This was the cleanest path to symmetry with `document "examination" { id = 1 }` → `document.examination.<...>`. Rejected because the block-introduces-namespace pattern, applied to a sub-block of `component`, would still scope `pipeline.<...>` to that component's declared source — preserving the per-component scoping limitation that the top-level namespace approach drops. A top-level reserved namespace (no declaration block at all) is both more symmetric (matches `local.<name>` and `document.<type>`, neither of which are declared inside `component`) and more flexible (cross-pipeline composition is natural).

### Naming variants: `result.scenarios`, `source.scenarios`, etc.

Considered keeping the `from` attribute but renaming the runtime variable to `result.scenarios` or `source.scenarios` (matching a renamed attribute). Rejected because both options keep the `from`/data redundancy and don't match the `<reserved-namespace>.<name>.<...>` shape of `document.<type>.<...>`. `pipeline.<name>.scenarios[<code>]` is parallel to `document.examination.questions["q1"]` — the same dotted "namespace dot name dot member" shape — which is the strongest mental-model anchor v3 has.

### Implicit `pipeline.<name>` namespace without declaration

An earlier draft made `pipeline.<name>` a top-level reserved namespace populated implicitly from the paired pipeline config — no `pipeline "<name>" {}` declaration in the formula was required. Rejected for three reasons:

- **Asymmetry with the other reserved namespaces.** `local.<name>` is grounded by `locals { ... }`; `document.<type>` is grounded by `document "<type>" {}`. Leaving `pipeline.<name>` un-grounded made it the outlier — the same shape complaint that retired the original `pipeline_results` variable, just moved up a level.
- **Validation locality.** Without declarations, checking that a `pipeline.<name>` reference resolves required reading the paired pipeline config — a cross-file step. The validate-phase contract for the editor says single-file, schema-only; declarations let the editor catch typos as the author types, without round-tripping to the pipeline file.
- **No home for future per-pipeline options.** A formula may eventually want to express per-pipeline metadata (e.g., `required = false`, an alias, a result-filter projection). Without declaration blocks there's no obvious place to put those attributes. The block syntax reserves the space even though v3 ships with empty bodies.

The declaration block is empty in v3 and feels like boilerplate for the simple case, but the consistency and validation wins outweigh the one-line cost per consumed pipeline.

## Out of scope

Listed explicitly to mark the boundary for follow-up RFDs:

- **Runtime architecture.** How `exec` blocks are dispatched to workers, what isolation environment runs them, how Temporal (or whatever orchestrator) coordinates the parent grading workflow and per-pipeline child workflows, container lifecycle, scoped credentials, the eventual replacement of Concourse. The next runtime RFD covers this.
- **Toolkit reusability.** A future RFD will define a syntax for declaring reusable HCL macros that expand to `exec` blocks with parameter holes — restoring DRY for common patterns (gcc compile, java compile, pytest invocation) without re-introducing Concourse coupling.
- **Plugin/framework blocks for structured result emission.** A future RFD will define how a stage can emit richer result data than the v3 `exec_result` contract — e.g., a `plugin "junit"` block that parses test framework output into a list of test-level results consumable by the formula. v3 deliberately ships with a minimal fixed result schema; richer emission is additive on top.
- **External variable inputs.** Terraform-style `variable "foo" {}` blocks for `-var foo=...` overrides at runtime. The pipeline/formula are not parameterised externally; they are parsed against a fixed examination snapshot at grading time.
- **Cross-file `import` / `include`.** A pipeline config and a formula config are each one self-contained HCL file. Sharing fragments across configs is not supported in v3.
- **Stdout/stderr size caps and per-stage output limits.** The runtime imposes its own caps; per-stage configurable output limits are a runtime RFD's concern.
- **UI changes for the new HCL editor.** The `apps/console` editor consumes a schema produced by reflecting on the v3 Go structs (`schemagen`); the schema is updated as part of v3 implementation. The visual design of the editor is a separate UI track.
