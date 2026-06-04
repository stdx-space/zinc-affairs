---
authors: Kristopher Lam
state: prediscussion
discussion:
labels: direction, infrastructure
---

# [RFD] Grading Runtime

This RFD defines the **runtime** that executes a v3 pipeline config against a submission and turns the result into a score. It is the follow-up runtime RFD that [RFD 0013](../0013/README.md) and [RFD 0014](../0014/README.md) repeatedly defer to: 0013 froze the *config language* and the `exec_result` data contract but explicitly left "how `exec` blocks are dispatched, what isolation runs them, workflow orchestration, worker lifecycle, container management" out of scope; 0014 froze the *document → config generator* and left "the execution flow" and "concurrent save / grading-run ordering" to the runtime.

Scope is the **execution model** (who runs the DAG and where), the **container-runner abstraction** (how a grading job is placed on an orchestrator), the **command channel** between the orchestrator and the in-container executor, the **result/score persistence reshape** required to honour the 0013 contract, and the **trigger/lifecycle** wiring. The v3 language, the formula semantics, and the document-driven generator are inputs to this RFD, not subjects of it — where this RFD touches a 0013/0014 contract it implements it verbatim; it does not renegotiate it.

This RFD records decisions and their rationale, not an implementation plan. Concrete table DDL, Go types, activity signatures, and config keys are implementation work that follows from the decisions here.

## Background

ZINC grades a student submission by running an instructor-authored pipeline and feeding the pipeline's per-test outcomes into a formula that produces a score. Three layers were reshaped in sequence:

- **[RFD 0013](../0013/README.md)** replaced the Concourse-shaped v1/v2 pipeline languages with v3: a score-blind pipeline of `exec` blocks (each stage runs one command across one or more *scenarios*), and a separate full-HCL *formula* that consumes the pipeline's results. 0013 committed to a precise **`exec_result`** contract (per (stage, scenario): `command`, `args`, `exit_code`, `timed_out`, `skipped`, `error`, timestamps, and object-storage URIs for stdin/stdout/stderr — and crucially *no score*), and to the reshape by which the formula reads results as `pipeline.<name>.scenarios[<code>][<stage>]`. It deliberately did **not** decide where results are stored, how stdio reaches object storage, how runs are dispatched, or how the formula is evaluated.
- **[RFD 0014](../0014/README.md)** made the examination document the source of truth and the pipeline + formula configs derived artifacts, materialised by a deterministic generator on every save. It committed to a strict **activity ↔ document ↔ config 1:1:1** cardinality, configs that mutate in place (no per-run snapshot), and per-question marking schemes. It left re-grading mechanics and the save-vs-grading-run ordering to the runtime.
- The **current code state** reflects this lineage. The v3 parser + validate phase, the 0014 generator (`internal/pipeline/configgen`), and the editor schema generator (`internal/pipeline/schemagen`) all exist. The execution layer does **not**: the Concourse adapter and the ghost-webhook handler were removed when 0013 landed, the pipeline run endpoints return `501 Not Implemented`, and the JetStream delivery/collection consumers are registered but no-op (`internal/api/pipeline/event.go`). The database schema for results and scores still carries the *old* ghost-webhook/Concourse shape — a per-result `score`, a flattened `case_code`, a `{success, failed, timeout}` status enum, and an `evaluation.score.items` log appended one entry per webhook callback. None of that matches the 0013 `exec_result` contract.

So the runtime is effectively greenfield on the execution side, sitting on top of a config/language layer that is already built and a persistence layer that must be reshaped to the 0013 contract.

A **ground-truth implementation exists** and is the reference for this design: a separate Temporal-based grading runtime that dispatches one container per run through a pluggable runner abstraction (Docker / Kubernetes / Nomad), where an in-container worker fetches the submission, runs the pipeline, and reports back over a per-run Temporal task queue. This RFD ports that model into ZINC's idioms — Uber FX modules, the existing `internal/temporal` worker pattern (mirroring the `EnvironmentBuilderWorkflow`), `internal/dind` / `internal/sandbox`, `internal/registry`, the NATS extension system, and the `fault` error model — and adapts it where ZINC differs, most notably by relocating the DAG logic out of the container and into the core workflow, and by using **`ghost`** (ZINC's existing single-command executor) as the in-container agent rather than a bespoke binary.

## Terminology

Building on [RFD 0013 § Terminology](../0013/README.md#terminology):

- **Pipeline run** — one execution of one `pipeline "<name>"` block against one submission. A config with N pipeline blocks produces N runs per submission, executed in parallel. **One row per pipeline** (see [Decision 6](#decisions-at-a-glance)).
- **Submission grading** — the umbrella over all pipeline runs for one (config, delivery) pair, plus the formula evaluation that aggregates them. Realised as a parent workflow, not a table.
- **Runner** — a backend that places a grading job on an orchestrator (Docker, Kubernetes, Nomad) and manages its lifecycle. The **runner registry** holds an ordered set of runners and chooses one per dispatch.
- **Executor** — colloquially, a runner backend (a Nomad executor, a Kubernetes executor).
- **Ghost agent** — `ghost` running in its long-lived agent mode inside the grading container: it connects out to Temporal, accepts resolved exec commands, runs each in the shared container filesystem, captures stdio to object storage, and reports structured results. It contains **no pipeline logic**.
- **Resolved exec spec** — a single scenario's command after 0013 inheritance/merge (command, args, env, stdin, stdout/stderr paths, timeout, workdir) — the unit of work handed to the ghost agent.

## Proposal

The runtime is **core-orchestrated with an in-container executor agent**. The core Temporal workflow owns the pipeline DAG, the fan-out across pipelines, and the fan-in, and drives formula evaluation at fan-in (as a report-extension step; see [§ Execution flow](#execution-flow)). The container is a dumb, long-lived executor: it runs the single commands it is told to run and reports what happened. The orchestrator and the container communicate over **Temporal itself** — the container is a Temporal worker on a per-run task queue, and each exec command is an activity. No callback channel, no inbound connection to the container.

### Decisions at a glance

The whole design in one table; each row links to its rationale.

| # | Area | Decision |
|---|---|---|
| 1 | [Execution topology](#1-execution-topology-core-orchestrates-ghost-executes) | Core's Temporal workflow owns the DAG, fan-out/in, and formula. `ghost` is a long-lived, DAG-blind executor that runs one resolved exec per command and reports back. |
| 2 | [Runner registry](#2-the-runner-registry-and-executors) | One container/job per pipeline run, placed via a pluggable **runner registry** that satisfies config-declared resource/security constraints. Each backend is its own Temporal task queue; dispatch routes to the chosen queue, failover picks another. The contract is mandatory even if fewer backends ship. |
| 3 | [Command channel](#3-the-command-channel-ghost-as-a-temporal-worker) | The channel **is** Temporal: ghost is a worker on a per-run task queue, each exec is an activity, ghost dials *out* to Temporal. A readiness handshake gates the first command. |
| 4 | [Result contract](#4-result-emission-and-the-persistence-reshape) | Full reconcile with 0013's score-blind `exec_result` contract. The legacy ghost-webhook result/score shape retires. |
| 5 | [Formula evaluation](#5-formula-evaluation-and-score-materialisation) | The grading workflow evaluates the formula at fan-in, after all pipeline runs of a submission complete. Hard-fail → ungraded, per 0013. |
| 6 | [Run cardinality](#6-one-pipeline-run-per-pipeline) | One `pipeline.run` per pipeline label per delivery. "Submission grading" is the set of runs for a (config, delivery). |
| 7 | [Submission delivery](#7-submission-and-asset-delivery) | The ghost agent fetches the submission and derived assets from object storage itself, using per-run scoped credentials — matching the ground truth. |
| 8 | [Credentials & auth](#8-credentials-and-authenticating-the-agent) | A per-run credential bundle (a Temporal auth token + STS-scoped object-storage credentials), minted at dispatch, short-TTL, revoked on completion. |
| 9 | [Isolation](#9-isolation-two-independent-layers) | Two independent layers: per-exec process sandbox inside ghost, and container-level isolation chosen by the runner backend. |
| 10 | [Observability](#10-observability-and-log-handling) | Temporal carries control + structured results + progress. Final stdio lives in object storage (the contract). **Live log tail is deferred.** |
| 11 | [Triggering](#11-triggering-and-lifecycle) | Grading runs as its own extension/worker, triggered by the existing (currently no-op) JetStream delivery/collection consumers. |
| 12 | [Admission control](#12-admission-control-and-batch-fan-out) | No application-level admission gate. Bursty fan-out is absorbed by Temporal worker tuning (concurrent-execution caps, task-queue rate limits); load probing is advisory input to backend selection only. |

### 1. Execution topology: core orchestrates, ghost executes

The decisive question is *where the pipeline DAG runs*. The ground truth puts the entire DAG inside the container (the in-container worker parses the HCL and runs every stage). This RFD does **not**: the DAG, the dependency gating, the scenario fan-out, the fan-in across pipelines, and the formula all live in the **core Temporal workflow**. `ghost` runs exactly one resolved exec per command it receives and reports the outcome.

The nuance that makes this work is that **the container persists for the whole run**. A pipeline's stages share filesystem state (`compile` writes `q1.out`, `execute` reads it). Because there is one long-lived container per run and one long-lived ghost agent inside it, successive exec commands see each other's side effects — exactly as if a single in-container worker had run them. The difference is only *who decides what to run next*: the core workflow, which already holds the parsed config and therefore the dependency graph.

Why relocate the DAG into core:

- **The orchestration logic and the language live together.** The parser, the dependency graph, the scenario expansion, and (post-this-RFD) the parse phase all live in `internal/pipeline`. Putting the DAG engine in the same place as the language it executes avoids a second HCL interpreter inside ghost and avoids shipping language changes into a container image on every grammar tweak.
- **Fan-in is already a core concern.** The formula aggregates across *all* of a submission's pipeline runs ([Decision 5](#5-formula-evaluation-and-score-materialisation)). That join cannot happen inside any single container; it has to be orchestrated centrally. Having the same workflow own both the per-pipeline DAG and the cross-pipeline join keeps one mind in charge.
- **ghost stays small and reusable.** ghost is already a single-command executor with sandboxing and object-storage upload. Keeping it DAG-blind means the runtime's executor is a thin extension of what ghost already is, not a rewrite — see [Decision 13 lineage in § Abandoned ideas](#ghost-as-the-dag-orchestrator).
- **Temporal gets per-exec visibility.** Each exec is an activity, so retries, timeouts, and tracing are per-command and native, rather than buried inside an opaque in-container run.

The cost is chattiness — a stage with M scenarios is M activities, and an exam is many stages — and a hard dependency on the container being reachable as a Temporal worker for the run's duration ([Decision 3](#3-the-command-channel-ghost-as-a-temporal-worker)). Both are judged acceptable; the alternative of an in-container DAG is recorded in [Abandoned ideas](#ghost-as-the-dag-orchestrator).

Two nuances this split makes load-bearing and that the runtime must commit to:

- **Intra-stage scenario fan-in is the workflow's job, and is as real as the cross-pipeline fan-in.** A stage's scenarios run as independent parallel commands; the workflow collects their results, derives the stage's state per the [0013 stage-state table](../0013/README.md#stage-block), and only then gates downstream stages (setting `skipped` on a gated stage's scenarios). The per-stage aggregation is a first-class part of the DAG engine, not an afterthought.
- **An exec command mutates shared, non-transactional container state, so an exec is not freely retryable.** Because stages share one container filesystem, re-running a command that already half-wrote its output (a killed-mid-write artifact, a partially-consumed input) is not idempotent the way a pure activity is. The committed posture is **fail-fast**: a failed exec fails its stage (and gates downstream) rather than being silently retried into ambiguous filesystem state. Infrastructure-level retries (the agent never received the command) are distinct from re-running a command that already ran; only the former is safe, and the runtime must keep them distinct.

**Command granularity is per-exec (decided).** The agent's command contract is "one resolved exec spec in, one `exec_result` out" — one Temporal activity per `(stage, scenario)`, never a batch. The alternative — handing the agent a whole stage's scenarios in a single activity to shrink Temporal history — was weighed and rejected. Because the command channel *is* Temporal (each command is an activity), the dispatch unit and the agent's contract are the same knob; keeping it at one-exec keeps the agent maximally dumb and, more importantly, makes **every scenario a first-class Temporal activity with its own lifecycle, timeout, retry classification, and trace span**. That per-scenario visibility is the property the progress UI is built on (see [Observability](#10-observability-and-log-handling)). The cost is more history events for wide stages (an examination's batched MC/SA stage can hold dozens of scenarios); this is **accepted**. The only real ceiling is Temporal's per-workflow history limit, which a pathologically wide single stage could approach; the escape hatches if it ever bites are `continue-as-new` and capping concurrent scheduling, neither needed now (per-pipeline-run workflows already partition history, so only one enormous batched stage — not a whole exam — is the risk).

### 2. The runner registry and executors

A grading run is one container (Docker) or one job/allocation (Kubernetes Job, Nomad batch job) — **one per pipeline run**, never a shared or pre-warmed container. One-per-run is what makes the scoped-credential model ([Decision 8](#8-credentials-and-authenticating-the-agent)) and the shared-filesystem-across-stages property ([Decision 1](#1-execution-topology-core-orchestrates-ghost-executes)) clean: the container's lifetime *is* the run's lifetime, and its credentials, isolation, and object-storage prefixes are scoped to exactly one submission.

Placement goes through a **runner registry** — an ordered set of named runner backends behind a common interface. In Temporal terms **each backend is its own task queue** (a Docker executor queue, a Kubernetes executor queue, a Nomad executor queue), so dispatch reduces to *choosing a backend* and scheduling the placement activity on that backend's queue, and failover is choosing a different queue. The interface is the load-bearing artifact and is **mandatory**, even though the first cut may implement only one or two backends (with Docker-only, the set collapses to a single executor queue). It must express:

- **Dispatch** a job for a run (image, the resolved resource/security constraints, the per-run credential bundle, the per-run task-queue identity) onto the chosen backend's queue.
- **Lifecycle** — verify a job actually started (catch image-pull failures and instant crashes fast), check liveness during the run, and clean up.
- **Failover** across backends in order, with a circuit breaker so a sick backend is skipped briefly rather than retried into the ground.
- **Load-awareness** — an optional probe so the registry can prefer a less-loaded or GPU-capable backend.

Committing to the interface now, even with one executor behind it, is the decision: it forces the dispatch/lifecycle contract to be backend-agnostic from day one, so adding Kubernetes or Nomad later is an implementation, not a redesign. **Which** backends ship first is an open question ([Open questions](#open-questions)); ZINC today has only a Docker-in-Docker path (`internal/dind`) and no Kubernetes/Nomad client, so Docker is the natural first executor, with the others designed-for but not necessarily built.

**Resource limits and hardware** (CPU/memory/storage, optional GPU) and the container's **security posture** are declared in the **pipeline config**, not invented by the runtime: the registry is a *constraint-satisfying scheduler* that places a run on a backend able to honour its declared constraints. The exact config surface (granularity, defaults) is a small follow-up to [RFD 0013](../0013/README.md) — 0013 omitted it because a sensible default suffices for the common case; this RFD depends on it as the source of dispatch inputs but does not specify it. Each scarce constraint carries a **`required` vs `best-effort`** sense: a `required` GPU with no schedulable backend is a placement failure (fail fast), while `best-effort` permits the accelerator-less fallback — and because a fallback that silently runs CPU-only when a pipeline needs a GPU is a correctness trap, **whether the GPU was actually provided must be observable to the run**, not hidden inside the backend.

**The image and the agent.** The image a run dispatches is the activity's **environment image** — the instructor's built environment (the existing environment-builder output), or the default base image when no custom environment is configured. The **ghost agent is baked into that image**: the base grading image carries ghost as an invariant and the environment builder layers instructor content on top, so agent presence never depends on the instructor remembering it. The ghost binary's *source* (an object-storage key or URL, pulled at image-build time) is configuration, decoupling the agent's release from the image build. Baking-in over runtime injection is deliberate — a self-contained image runs identically across Docker/Kubernetes/Nomad, which is what keeps the runner abstraction backend-agnostic; the cost is version skew, caught by the protocol-version check at readiness ([Decision 3](#3-the-command-channel-ghost-as-a-temporal-worker)).

The portability the registry promises is real but not free, and the abstraction should acknowledge where backends genuinely differ rather than imply a clean uniformity:

- **Job identity leaks.** The opaque handle returned by dispatch is a Docker container id, a Kubernetes Job name, or a Nomad job id — and some lifecycle facts are inherently backend-shaped (a pod name, a Docker secrets mount). The interface carries an opaque identity plus the owning runner's name; that some detail is backend-specific is accepted leakage, stated rather than denied. (A consequence: failover is a *pre-dispatch* decision — once a run is placed on a backend, its identity is only meaningful to that backend.)
- **Credential delivery and lifecycle differ per backend**, and the security properties differ with them: a Kubernetes Secret is RBAC-controlled and at-rest-encryptable but not self-expiring (it outlives a finished Job unless explicitly reclaimed); a Nomad job-spec env block is visible to anyone with read access to the job and is best replaced by a secrets-manager/Variables path in production; a Docker env/file delivery is visible to host inspection. The bundle model ([Decision 8](#8-credentials-and-authenticating-the-agent)) is uniform; its *delivery* is not, and the weaker deliveries must be hardened or avoided where student code runs.
- **"Verify it started" and "is it alive" are backend-shaped.** Pod phases and image-pull-backoff (Kubernetes), allocation client-status (Nomad), and container state (Docker) carry different diagnostic richness and different asynchronous-settling behaviour. The interface expresses the *intent* (started / alive / cleaned up); the diagnostic fidelity it can surface is backend-dependent, and startup timeouts must be sized for the slowest settling chain, not just image-pull time.
- **Egress-only is an architectural property of the agent (it binds no listener), not a platform-enforced one.** On Kubernetes it must be backed by a deny-ingress network policy; on Docker/Nomad by network configuration; otherwise "no ingress" is true of the agent but not of the container. See [Decision 9](#9-isolation-two-independent-layers) and the egress note in [Observability](#10-observability-and-log-handling).

### 3. The command channel: ghost as a Temporal worker

The orchestrator and the container talk over **Temporal**, not a bespoke protocol. Concretely:

- On dispatch, the run gets a **per-run task queue** (e.g. keyed by run id). Only this run's ghost agent polls it.
- The ghost agent boots, connects **out** to the Temporal frontend, and registers a small set of activities — fetch-the-submission, and run-one-exec.
- The core workflow schedules those activities **pinned to the per-run task queue**, so Temporal routes each command to exactly this container's agent. Each exec command is one activity invocation; its return value is the structured result; its heartbeats carry progress.

**Persistent connection: yes.** The agent holds a long-lived gRPC long-poll to the Temporal frontend for the run's lifetime — that poll *is* the persistent channel, and it is why the agent must be long-lived rather than one-shot. It stays connected across all of the run's exec commands.

**Direction: outbound only, agent → Temporal.** Core never dials into the container. Both core and the agent connect *out* to the shared Temporal frontend; Temporal does the routing. This is the property that makes the model portable across executors: an inbound connection to a pod or allocation is the hard, often-impossible, always-risky case on Kubernetes and Nomad, whereas egress to Temporal (plus object storage and the telemetry collector) is something every backend can provide. The container needs no ingress.

**The startup race** is handled without an explicit signal: the workflow dispatches the container, then schedules the agent's first activity (fetch-the-submission), whose **schedule-to-start timeout is the readiness proof** — if the agent never connects to poll its queue, that timeout fires and the run fails with a diagnostic. Meanwhile the workflow polls the runner's liveness so a container that never comes up fails fast rather than waiting the timeout out. (An explicit "ready" signal from the agent is the alternative; schedule-to-start is preferred — same guarantee, one fewer moving part.) That first exchange also carries the agent's **protocol version**: because ghost is baked into the environment image ([Decision 2](#2-the-runner-registry-and-executors)), a stale agent in an old image fails fast with "agent too old, rebuild environment" rather than a confusing activity-type mismatch.

**Why not a callback or a custom stream.** Once a persistent Temporal connection exists, an HTTP callback channel (the old ghost-webhook model) adds a second transport, a second auth surface, and a second failure mode for no gain — rejected in [Abandoned ideas](#http-callback-result-channel). A custom bidirectional gRPC stream (core pushes commands, ghost streams results) was also considered and rejected there: it would require core to host an ingest service and bridge a live socket into a workflow via signals, and it would take per-exec control away from the workflow — the opposite of [Decision 1](#1-execution-topology-core-orchestrates-ghost-executes).

This makes the ghost change an **extension of its existing heartbeat/liveness behaviour into a full agent that accepts commands and reports details** — not a new orchestrator. ghost's command-execution, sandboxing, and object-storage upload already exist; the agent mode adds the Temporal worker loop and the result/stdio reporting around them.

**Liveness is monitored for the whole run, not only at startup.** The readiness handshake covers "did the agent ever connect"; it does not cover an agent that connects and then dies mid-run (container OOM, node loss, agent crash). Without ongoing monitoring, a dead agent's per-run queue simply stops being polled and the next command stalls until its timeout, cascading a slow failure across the remaining stages. The runtime therefore keeps a liveness check running for the run's duration (the runner backend's liveness probe), so container death is detected and the run failed promptly with a diagnostic rather than by timeout cascade. The corresponding nuance on the happy-startup path: a backend can report the job "running" while the agent's Temporal connection has in fact failed (bad credentials, wrong namespace). The committed behaviour is that a liveness failure during the pre-ready window fails the run immediately with a "container failed to start" diagnostic, rather than waiting out the first command's schedule-to-start timeout — the startup-timeout is only the backstop for the case where liveness still looks healthy.

### 4. Result emission and the persistence reshape

The pipeline is **score-blind**: a pipeline run emits, per (stage, scenario), exactly the [RFD 0013 `exec_result`](../0013/README.md#result-emission-contract) — `command`, `args`, `exit_code`, `timed_out`, `skipped`, `error`, `started_at`/`ended_at`/`duration_ms`, and `stdin_uri`/`stdout_uri`/`stderr_uri`. No score appears on a result. This contract is non-negotiable; the runtime implements it as written.

Two halves to the decision:

**Who emits what.** The ghost agent runs the exec, captures stdin/stdout/stderr to object storage (always — empty output is a zero-byte object with a valid URI, per 0013), and returns the structured fields. The core workflow owns the fields ghost cannot know on its own: `skipped` is set by the workflow when a dependency stage failed (dependency gating is the workflow's job, [Decision 1](#1-execution-topology-core-orchestrates-ghost-executes)), and the derived stage state (`success`/`failed`/`error`/`skipped` per the 0013 table) is computed by the workflow from its scenarios' results.

**The persistence reshape.** The existing result/score tables were built for the ghost-webhook era and contradict the contract; reconciling them is this RFD's responsibility (0013 explicitly assigned "what tables hold the records, what retires, what columns reshape" to the runtime). At the contract level, not the DDL level:

- A pipeline run's results are keyed by **(stage, scenario_code)**, not a flattened `case_code` string. The legacy `case_code = stage_name[/scenario_code]` flattening retires.
- **No `score` on a result.** Scoring moves entirely to formula evaluation ([Decision 5](#5-formula-evaluation-and-score-materialisation)). The non-null per-result score column retires.
- The result **state set is 0013's** — `success`, `failed`, `error`, `skipped` — superseding the legacy `{success, failed, timeout}` enum (`timed_out` becomes a field, and `error`/`skipped` are first-class).
- Results carry **three stdio URIs plus the structured fields**, not two file paths. The URIs are opaque dereferenceable handles; the formula never parses them.
- The **`evaluation.score.items` append-per-webhook model retires.** A score is produced once, by formula evaluation, in one transaction — not accumulated one row per callback. The legacy idempotency-for-webhook-retries concern disappears with the callback channel.
- A pipeline run's external identifier becomes its **Temporal workflow identity**, not a Concourse build id.

What this RFD does **not** decide is the physical storage shape — whether the per-run emission lives as rows, as a JSONB array on the run, or as an object-store blob. That is an implementation trade-off (queryability vs write-amplification) constrained by, but not determined by, the contract above.

### 5. Formula evaluation and score materialisation

Scoring is a **fan-in** step, not a per-result side effect. After all of a submission's pipeline runs complete, the parent workflow hands the collected results to the **report/evaluation extension**, which reshapes the `exec_result` emissions into the `pipeline.<name>.scenarios[<code>][<stage>]` view that 0013 defines, evaluates the formula's components and `scoring.total` against it, and materialises one score for the submission. Mechanically these are report-extension activities the parent schedules at fan-in — see [§ Execution flow](#execution-flow).

The placement is deliberate: the fan-out (N pipelines) and the fan-in (one formula over all N) both live in the workflow, so the workflow is the natural and only place where the complete result set exists at once. This is the join that no container can perform.

Two nuances inherited from 0013, restated as runtime commitments:

- **Hard-fail is ungraded, never zero.** If any component's `score` or the `scoring.total` raises an evaluation error or yields a non-finite number, the submission is marked **ungraded** with a structured diagnostic. There is no silently-treat-as-zero path; a grader bug must surface as a fixable problem, not as lost student marks.
- **Partial results are the formula's to handle.** A run whose container crashed mid-way produces a partial `scenarios` map; the formula's null-permissive predicates (`succeeded`/`failed`) and `try()` are how authors defend against it. The runtime's only obligation is to expose the partial map faithfully and to distinguish "skipped" from "absent."

This is **net-new** capability: core today has the formula *parser* and validate phase but no evaluator and no parse phase. Which leads to the one prerequisite this RFD surfaces — the **parse phase** — and to a refinement of how 0013 framed it. 0013 splits validation into a single-file validate phase (built) and a cross-file, document-resolving, dynamic-expanding **parse phase** (not built), framed as one combined step over the pipeline+formula pair. This RFD **splits that parse along the extension boundary**, because the two halves have no runtime dependency: the pipeline never references the formula (0013's decoupling), so resolving the pipeline needs only its own config and the document.

- **Pipeline parse runs upfront, before dispatch**, in the pipeline extension: it resolves `document.examination`, expands dynamic blocks, and produces the concrete stages/scenarios and resolved exec specs the workflow executes. Failures fail the run before any container is dispatched, exactly as 0013 specifies. This remains a **blocking prerequisite** — net-new work this RFD depends on but does not itself specify, to be tracked as such.
- **Formula resolution + evaluation runs at fan-in**, in the report/evaluation extension, against the collected results. The pipeline run is score-blind and never touches the formula, so there is no reason to parse it upfront — and a structurally-broken formula does not waste the run, since results persist and a fixed formula re-scores them with no container re-run.
- **The two cross-file checks** 0013 placed in the parse phase — the `document` id must match across the pair, and the formula's `pipeline "<name>" {}` declarations must match pipeline blocks — need only the document and the pipeline's label list, never results. They are enforced at **generation/save time**, where the generator already builds both files from one document and runs the validate phase over each (`configgen.selfValidate`); the grading path does not re-litigate them.

Two commitments make the evaluation robust:

- **The resolved document and both config sources are snapshotted once, at run start**, into the grading workflow's state — inherent to the workflow, since Temporal records the parse activity's result in history, not a separate mechanism to build. The **parent parses once and threads the snapshot to the per-pipeline children**; children never re-read config, keeping one submission on one config generation, and the formula evaluated at fan-in resolves against *that* document snapshot, not a fresh fetch — so it scores against the same exam data the pipeline ran against. Without this, [0014's mutate-in-place](../0014/README.md#materialization-timing) configs admit a silent inconsistency: a save landing *between* dispatch and fan-in could pair a *new* formula or document with results from an *old* pipeline. The residual race — a save committing in the instant between run start and the snapshot read — is **accepted, not locked against**: single-object reads are atomic, the blast radius is the few submissions dispatched in that window, and the remedy is a re-grade.
- **Formula evaluation is a recoverable step, not inline orchestration.** Because the formula is arbitrary HCL evaluated against possibly-partial runtime data, an evaluation error or non-finite result must be *caught* and turned into the structured **ungraded** outcome — it must not be allowed to crash the orchestration. This is the runtime realisation of 0013's hard-fail rule: ungraded is a first-class, recorded terminal state, distinct from "scored zero" and distinct from "infrastructure failed."

### 6. One pipeline run per pipeline

A config with N `pipeline` blocks produces **N pipeline runs per submission**, one row each, executed in parallel as N containers. This was the intent of 0013/0014 (the examination case is "one config grading many questions," each question its own pipeline) but the context was lost as out-of-scope; this RFD makes it explicit.

Consequences:

- A pipeline run is identified by (delivery, config, **pipeline label**), not just (delivery, config). The legacy one-row-per-(config, delivery) shape gains the pipeline-label dimension.
- "Submission grading" is the set of runs sharing a (config, delivery) — a query view, not a table, consistent with 0013 § Terminology.
- The grading decomposes into a **parent Submission Grading Workflow per submission and a child Pipeline Run Workflow per pipeline run** (one container each); the parent fans out to the children and hands the collected results to the report extension's formula evaluation. This parent/child shape is **committed, not optional** — it is forced by three decisions already taken: a pipeline run's external id *is* its Temporal workflow identity ([Decision 4](#4-result-emission-and-the-persistence-reshape)), per-pipeline-run workflows are what partition Temporal history ([Decision 1](#1-execution-topology-core-orchestrates-ghost-executes)), and workflow-id uniqueness is the re-grade enforcement point (below). See [§ Execution flow](#execution-flow) for the full decomposition and activity ownership.

Re-grading needs a decided **supersession rule**, because [0014](../0014/README.md#re-grading) allows re-running a delivery against the current config and that produces a *second* run for the same (delivery, config, pipeline label). The commitments:

- **The formula evaluates against the latest run per pipeline label.** Prior runs are retained for provenance/history but marked superseded; the fan-in selects the current set. There is never ambiguity about which of two runs for `pipeline "q1"` feeds the score.
- **A re-grade does not silently coexist with an in-flight run for the same target.** A re-grade triggered while a prior grade for the same (delivery, pipeline label) is still running must resolve deterministically — reject, or cancel-and-replace — rather than letting two workflows write the same run's results concurrently. (Temporal workflow-id uniqueness is the natural enforcement point; the choice between reject and cancel-and-replace is open.)

### 7. Submission and asset delivery

The **ghost agent fetches its own inputs** from object storage — the submission files, plus the derived expected-answer assets the 0014 generator materialised (and any config assets) — rather than having them streamed in by core. This matches the ground truth and keeps the bulk submission I/O on the container ↔ object-storage path rather than proxied through core.

The nuance is that this is a genuine extension to ghost: today ghost only *uploads* to object storage; *downloading* a submission prefix into the working directory is new behaviour the agent mode must add. Path-traversal defence on keys (a submission must not be able to write outside its working directory) is part of that behaviour.

Object-storage layout follows the existing ZINC convention and 0013's opaque-URI requirement: a per-run prefix under the course bucket, with stdio captured under `…/runs/<run>/<stage>/<scenario>/{stdin,stdout,stderr}`. The exact prefix scheme is a layout detail, not a contract — the formula only ever sees opaque URIs.

### 8. Credentials and authenticating the agent

The container must authenticate two things — its **command channel** (to Temporal) and its **object-storage access** — and it must do so without holding any standing, broadly-scoped secret. The decision is a **per-run credential bundle**, minted by core at dispatch, injected by the runner backend (as environment/secret material appropriate to the executor), short-TTL (the run timeout plus a buffer), and revoked on completion or failure:

- **Object storage: STS-scoped credentials.** Read-only on the submission prefix, write on the run's output prefix — the same model as the ground truth. A leaked credential is useless outside this run's prefixes and expires with the run.
- **Command channel: a per-run auth token for Temporal.** ZINC already has a cryptographic authority that issues scoped tokens (extension-registration tokens; the retired pipeline webhook JWT). The decision is to mint a per-run token from that same authority, scoped to the run's namespace/task-queue, and have Temporal validate it via its pluggable claim-mapper/authorizer. This gives the channel a cryptographic identity: knowing the (unguessable) per-run task-queue name is not, by itself, enough to impersonate the agent and steal its commands.

The threat model this must withstand is sharp: **the student submission is hostile and runs in the same container as the agent**, so it can attempt to read whatever the container holds. That reframes several points from "scoping" to "must-not-be-reachable," and the security review surfaced gaps the bundle's one-line framing glossed:

- **The channel token must be scoped to *this run's* task queue, not to the namespace.** A namespace-wide token leaked to student code would let it register as a worker on *another* run's queue and complete activities with fabricated results — direct grade tampering. Temporal's stock claim-mapper is namespace-grained; per-task-queue scoping requires a custom authorizer. The committed design is per-run-queue scoping; the namespace-only posture is explicitly insufficient.
- **The object-storage write credential must be keyed to an unguessable per-run prefix.** If the write scope is broader than this run's own prefix, student code can overwrite a sibling run's stdout/stderr blobs — and since the formula consumes those blobs by URI, that is grade tampering with no Temporal involvement. Read scope is the submission (shared across a submission's runs by nature); write scope is this run alone.
- **Credentials must not be reachable by the student command.** The agent and the student process share a container; the credential bundle must not be inheritable by spawned student processes (environment scrubbed before exec) nor readable from the agent's process via a shared UID / `/proc`. This makes the **agent a trusted execution context** that the student code must not be able to read, signal, or impersonate — a property the [isolation layers](#9-isolation-two-independent-layers) must actively enforce, not assume.
- **Isolation is multi-tenant, not just per-run.** Scoping must prevent a Course A container from reaching Course B's object-storage prefixes, queues, or data — credentials are scoped per course/activity as well as per run.
- **Revocation must survive abnormal exit.** "Revoked on completion or failure" only holds if the revoking actor is *core*, in a cleanup path that runs even when the container/workflow dies — see [cleanup below](#cleanup-and-orphans). Backend-resident credential artifacts (a Kubernetes Secret, a Nomad job-spec env block) are not self-expiring the way an STS token is, so a missed cleanup is a standing exposure, not a self-healing one.

Two posture decisions, stated as decisions rather than hedges:

- **The trusted-network fallback (Temporal auth disabled) is not acceptable for production**, because production grading containers run hostile code; an unguessable queue name embedded in that container is a shared secret, not authentication. Token validation is a hard requirement where student code runs.
- **The shared-credentials + prefix-scoping fallback (the old Concourse posture) is unsafe with hostile code in-container** and is only admissible behind a server-side storage proxy that enforces prefixes (so the container never holds the broad credential). Whether ZINC's storage layer can mint STS credentials directly is an [open question](#open-questions); if it cannot, the proxy — not the raw shared credential — is the fallback.

<a id="cleanup-and-orphans"></a>
**Cleanup and orphans.** Per-run teardown (revoke credentials, remove the job and any backend credential artifact) runs in a context that **survives workflow cancellation or worker restart** — cleanup must not be skipped because the parent was cancelled. Because per-run cleanup can still be missed (core crash at the wrong instant), a **periodic orphan sweep across every backend** is required, not optional and not Docker-only: it must reclaim leaked jobs/allocations *and* leaked credential artifacts (e.g. Kubernetes Secrets, which a Job's finished-TTL does not garbage-collect). This is a committed capability of the runner layer, with backend-specific reclamation.

### 9. Isolation: two independent layers

Isolation is decided on **two axes that do not interact**:

- **Inside the container**, ghost applies a **per-exec process sandbox** to each command it spawns — filesystem restriction and network-namespace isolation and process limits — which ghost already does today. This is the boundary around the *student's code* each time it runs.
- **Around the container**, the **runner backend** applies container/job-level isolation appropriate to the executor (e.g. a hardened container runtime / sandboxed runtime class, seccomp/AppArmor posture). This is the boundary around the *grading job* as a whole.

They are orthogonal in *what* they bound: the per-exec sandbox is the same regardless of which executor runs the job, and the container-level posture is chosen by the executor regardless of what ghost does inside. But they are **operationally coupled**, and the RFD should not pretend otherwise: process-level network-namespace creation requires the container's own seccomp/AppArmor profile to permit namespace-creation syscalls — and a container-wide relaxation of that profile also lets the *student* code create namespaces, which widens the container-escape surface precisely where the per-exec sandbox was meant to narrow it. So "decide each layer independently" does not mean "configure each layer obliviously": loosening the container profile to enable the inner sandbox is a real trade-off, and a sandboxed-runtime class (e.g. gVisor/Kata) that absorbs namespace operations without a blanket profile relaxation is the preferable container-level posture where available.

Two related commitments fall out of the [hostile-code threat model](#8-credentials-and-authenticating-the-agent): the student command runs under a **distinct, lower-privileged UID** from the agent (so it cannot read the agent's memory/descriptors), and the agent's stdio-capture staging is **agent-owned and not in a world-writable location** (so a concurrent student process cannot race or symlink-redirect what gets captured and uploaded as the result).

### 10. Observability and log handling

The split is: **Temporal carries control, structured results, and progress; object storage carries the bytes.**

- **Structured outcomes and progress** ride the command channel — exec results are activity return values, and coarse progress (which stage/scenario, its state, timings) is visible through workflow state and activity heartbeats. Temporal is "well aware" of everything except raw log bytes.
- **Final stdout/stderr/stdin** are object-storage blobs referenced by the `exec_result` URIs — this is the durable record and is part of the 0013 contract. Log bytes never transit Temporal (whose payloads are size-bounded and not a streaming transport).
- **Tracing/logging** reuse ZINC's OpenTelemetry wiring; the runtime is instrumented end-to-end (dispatch, agent connect, each exec, formula eval) consistent with the rest of core.

A security nuance ties stdio handling back to [0013's deadline-gated visibility](../0013/README.md#visibility-block): the URIs a student is eventually allowed to see should be **dereferenced through access that is itself gated** — short-lived, issued at display time after the visibility filter has been applied — rather than being durable, directly-fetchable handles. And the materialised expected-answer assets (the 0014 generator's output) must live in a prefix segregated from student-reachable result prefixes, so that gaining a result URI never implies the ability to enumerate adjacent answer keys. The egress restriction from [Decision 9](#9-isolation-two-independent-layers) is the other half of this: the grading container's egress is limited to Temporal, object storage, and the telemetry collector — not open to the cluster or the internet — so hostile code cannot exfiltrate or reach internal services.

**Per-scenario progress is in scope; only live log-byte tailing is deferred.** Because [command granularity is per-exec](#1-execution-topology-core-orchestrates-ghost-executes), every scenario is a Temporal activity, so Temporal *already* tracks each scenario's lifecycle (scheduled → started → completed/failed/retrying) — the runtime does not build a separate per-scenario state machine, it reads the one the orchestration maintains. The grading workflow is the authoritative live state-keeper (its scenario-status map is durable and replay-safe by virtue of being workflow state), and it surfaces that map two ways, mirroring the existing `EnvironmentBuilderWorkflow` pattern (a `status` query handler plus a per-attempt push-progress channel):

- **Live:** the workflow publishes a per-scenario transition to core's NATS/realtime layer on each change; the UI subscribes through the existing realtime channel. A `status` **query handler** returns the current snapshot for initial load and reconnects.
- **Durable:** the per-scenario terminal state is the `exec_result` record persisted at run completion ([Decision 4](#4-result-emission-and-the-persistence-reshape)) — what the UI reads for a finished run.

The product UI reads these projections, **not Temporal directly**: Temporal's native activity state is the internal source and an ops/debug view, but it is retention-bounded and stops answering queries once a workflow closes, so it is not a product read-model. One nuance: Temporal hands the workflow a *completion*, not a *start*, callback — so "queued vs done" is known natively, while a crisp "executing now" needs either inferring it from pending-activity state or a start-heartbeat from the exec activity; the simpler "in-flight = running" reading is usually sufficient.

**Live log-byte tailing remains deferred.** Streaming an in-progress exec's stdout/stderr to the UI before the blob is finalised is the separate concern, with its own transport question (a NATS subject vs incremental object-store chunks). It is left to a follow-up; the durable post-hoc record via the URIs is sufficient for grading correctness, and per-scenario *status* progress (above) already gives meaningful in-flight visibility without it.

### 11. Triggering and lifecycle

Grading runs across the **pipeline** and **report/evaluation** extensions (execution vs scoring), each a Temporal worker on its own task queue, with core owning credential minting and the triggers — see [§ Execution flow](#execution-flow) for the ownership map. It is triggered by the JetStream consumers that already exist but are currently no-op (`internal/api/pipeline/event.go`): delivery-finalised drives a grading run for that submission; the collection event drives scheduled/batch grading. The `501` pipeline-run endpoints become the manual/re-grade (and re-score) entry points to the same workflows.

**Re-grading** follows 0014's "configs mutate in place": a re-grade is a new pipeline run against the *current* config; there is no historical-config snapshot to grade against. **Save-vs-grading-run ordering** (0014 deferred the mechanics to here) needs no dedicated locking mechanism: the run snapshots the resolved document + configs into workflow state at parse ([Decision 5](#5-formula-evaluation-and-score-materialisation)) and is consistent from that point on. The only residual is a save committing in the instant between run start and that snapshot read; per [Decision 5](#5-formula-evaluation-and-score-materialisation) that narrow, low-blast-radius race is accepted (remedy: re-grade) rather than serialized against.

### 12. Admission control and batch fan-out

Grading dispatch is **bursty by nature** and the runtime must not treat the orchestrator as its admission controller. Two multipliers stack: one submission fans out to N pipeline runs (one per pipeline block), and one collection event (an exam closing) fans out to every submission in the collection at once. A 200-submission exam with 5 pipelines each is 1,000 containers wanting to start in the same instant.

The decision: **there is no application-level admission controller.** The burst is absorbed where it naturally belongs — in Temporal. Fan-out enqueues workflow/activity tasks, not running containers; how many execute at once is governed by **executor-worker tuning** (per-worker concurrent-execution caps) and **task-queue rate limits**, so a 1,000-task burst drains through the executor pool at whatever rate the workers are configured to accept rather than starting 1,000 containers at once. The runner registry's load probing ([Decision 2](#2-the-runner-registry-and-executors)) stays **advisory** — input to *which* backend to prefer — and is explicitly not a gate. This is a deployment/operations knob, not orchestration logic. A global or per-collection hard cap is deferred unless a real workload measures the Temporal-native backpressure to be insufficient — and because Temporal has no native global semaphore, such a cap would be a dedicated gatekeeper-workflow, not a parameter, worth building only if needed.

## Execution flow

The decisions above describe *what* the runtime does; this section fixes *how the Temporal pieces fit* — the workflow decomposition, the ordering, and which extension owns each activity. Concrete activity signatures remain implementation.

**Orchestration model.** ZINC's Temporal usage is cross-extension: an activity is owned by the extension whose domain it belongs to, each extension runs a worker on its own task queue, and a workflow orchestrates across extensions simply by scheduling activities on their queues — Temporal *is* the channel, so no separate inter-extension transport is needed. The grading runtime is an instance of that pattern, with one addition: the in-container ghost agent is an **ephemeral per-run worker** that joins a per-run task queue for the life of one run.

### Workflows

- **Submission Grading Workflow (parent)** — pipeline extension, one per (config, delivery). Owns the upfront pipeline parse, the snapshot, fan-out across pipelines, fan-in, and the hand-off to scoring. Surfaces the unified graded/ungraded terminal.
- **Pipeline Run Workflow (child)** — pipeline extension, one per (delivery, config, pipeline label). Its **workflow id is the pipeline run's external identifier** ([Decision 4](#4-result-emission-and-the-persistence-reshape)), so workflow-id uniqueness enforces run supersession and resolves concurrent re-grades ([Decision 6](#6-one-pipeline-run-per-pipeline)). Owns one container's whole lifecycle; per-pipeline-run history partitioning keeps a single run's Temporal history bounded ([Decision 1](#1-execution-topology-core-orchestrates-ghost-executes)).

Scoring is **not** a third workflow: `evaluate-formula` and `persist-score` are activities of the report/evaluation extension that the parent schedules on the report queue at fan-in. The same activities invoked against stored results are how a **re-score without re-running** works (the score-blind payoff of 0013).

### Order of operations

**Parent (Submission Grading):** parse + expand the pipeline and resolve the document into a pinned snapshot — failing the run here, before any dispatch, on a parse error → fan out one child per pipeline label, threading the snapshot down → await all children, collect their `exec_result` sets → schedule the report extension's `evaluate-formula` / `persist-score` against the latest run per label and the pinned document snapshot → surface graded or ungraded.

**Child (Pipeline Run):** mint the per-run credential bundle (core) → select a backend and dispatch the container onto that backend's queue → readiness gate (first activity's schedule-to-start, with liveness polling racing it) → `fetch-submission` on the per-run queue → DAG loop: per stage in topological order, schedule one `run-one-exec` per scenario in parallel on the per-run queue, derive stage state, gate downstream (mark `skipped`), fail-fast → `persist-run-results` → teardown (`cleanup-job` + `revoke-credentials`) in a cancellation-surviving context.

### Activity ownership

| Activity | Owner / task queue | Role |
|---|---|---|
| (trigger) start the parent | **core** event/API layer | JetStream consumers + the (formerly `501`) manual/re-grade endpoints |
| `parse-config` (pipeline parse, document resolution) | **pipeline ext** (document fetched from the examination domain) | resolve pipeline specs + pin the document snapshot before dispatch |
| `mint-credentials` / `revoke-credentials` | **core** (the cryptographic authority) | issue/revoke the per-run Temporal token + STS bundle |
| `select-runner` | **pipeline ext** (runner registry) | choose a backend (ordered list + circuit breaker; advisory load probe) |
| `dispatch-job`, `await-started`, `check-liveness`, `cleanup-job`, `orphan-sweep` | **per-backend executor queue** (Docker / K8s / Nomad), under the pipeline ext | place, monitor, and reclaim the container/job and its credential artifacts |
| `fetch-submission`, `run-one-exec` | **per-run queue** (ephemeral ghost agent) | pull inputs; run one resolved exec, capture stdio to object storage, return `exec_result` fields |
| `persist-run-results` | **pipeline ext** | durable `exec_result` writes |
| `evaluate-formula`, `persist-score` | **report/evaluation ext** | resolve + evaluate the formula against the pinned snapshot; materialise one score, or ungraded |
| `publish-progress` | each extension, for its own phase | per-scenario / per-phase transitions to the NATS realtime layer |

### Signals & queries

- **`status` query** — both workflows expose a current snapshot for UI initial-load and reconnect; live per-scenario transitions are pushed to NATS ([Decision 10](#10-observability-and-log-handling)).
- **`cancel` signal** — parent cancellation propagates to children; per-run teardown still runs via the cancellation-surviving path ([Decision 8](#cleanup-and-orphans)).
- Readiness needs no signal: the first activity's schedule-to-start is the gate ([Decision 3](#3-the-command-channel-ghost-as-a-temporal-worker)).

## Persistence summary

What this RFD commits to about persistence, at the contract level (physical shape is implementation):

| Concern | Decision |
|---|---|
| Pipeline run identity | One run per (delivery, config, pipeline label). External id = Temporal workflow identity. |
| Result keying | (stage, scenario_code) per the 0013 `exec_result` contract. No flattened `case_code`. |
| Result state | `success` / `failed` / `error` / `skipped`. `timed_out` and `error` are fields. |
| Result stdio | Three opaque object-storage URIs (`stdin`/`stdout`/`stderr`), always captured. |
| Score on results | None. Pipeline is score-blind. |
| Score production | Once, at formula fan-in, in one transaction. The per-webhook `items` append model retires. |
| Ungraded state | A first-class terminal outcome when formula evaluation hard-fails — distinct from "scored zero" and from "infrastructure failed." |
| Run supersession | Re-grade creates a new run; the latest run per pipeline label feeds the formula; prior runs retained for provenance. |
| Terminal-write idempotency | Completing / failing / cancelling a run is idempotent on run identity — a retried terminal write must not duplicate results or corrupt state. |
| Config snapshotting | No *historical* snapshot to re-grade against (0014: mutate-in-place). Within one run, the resolved document + both config sources are snapshotted once at run-start (in workflow state) and threaded parent→child, so execution and fan-in scoring share one consistent generation. |

## Out of scope / deferred

- **Live log streaming** to the UI (see [Decision 10](#10-observability-and-log-handling)).
- **Which executors ship first.** The registry interface is mandatory; the backend roster (Docker first; Kubernetes/Nomad designed-for) is an [open question](#open-questions).
- **The exec resource/security config schema** — a small follow-up to [RFD 0013](../0013/README.md) defines how a pipeline declares resource limits and security posture (with sensible defaults); this RFD consumes it as dispatch input ([Decision 2](#2-the-runner-registry-and-executors)) but does not specify it.
- **Toolkit reusability and plugin/framework result emission** — already deferred by 0013, unchanged here.
- **The 0014 generator and the v3 language** — inputs, not subjects.
- **Manual/essay grading** — a 0014 open follow-up, unaffected.

## Abandoned ideas

Recorded so the same paths are not re-walked.

### ghost as the DAG orchestrator

The ground truth runs the entire pipeline DAG inside the container via a full in-container worker. Rejected for ZINC because it puts a second HCL interpreter and the dependency-graph engine inside a container image — meaning language/grammar changes ship as image rebuilds — and because it splits the DAG logic (in-container) from the cross-pipeline fan-in for the formula (necessarily central), putting two different minds in charge of one grading. Core-orchestrated keeps the language, the DAG, and the fan-in in one place ([Decision 1](#1-execution-topology-core-orchestrates-ghost-executes)) and keeps ghost a small, reusable executor.

### In-container child workflow

A middle option — keep core orchestrating but run a Temporal *child workflow* inside the container (as the ground truth does for its eval step) — was set aside. It would still require the in-container worker to carry pipeline logic, and it complicates the parent/child story without buying anything over per-exec activities, given the DAG already lives in core.

### HTTP callback result channel

The retired ghost-webhook model had the container POST results back to a core endpoint. Rejected: once a persistent Temporal connection exists for commanding, a second HTTP channel for results is redundant transport, a second authentication surface (signed webhook tokens), and a second failure mode — with no capability the command channel lacks.

### Custom bidirectional command stream

A bespoke gRPC stream — core pushes exec commands, ghost streams results and logs over one long-lived socket — was considered because it reads literally as "maintain a channel." Rejected: a Temporal workflow cannot hold a socket, so core would need an ingest service and a long-running "session" activity to bridge the stream into the workflow via signals, and that bridge would take per-exec control away from the workflow — defeating [Decision 1](#1-execution-topology-core-orchestrates-ghost-executes). Temporal-as-channel reuses the broker, the auth, the retries, and the visibility for free. The custom stream is only worth revisiting if per-exec activity overhead is later *measured* to be a problem.

### Pre-warmed / shared container pools

ZINC has a pre-warmed sandbox pool (`internal/sandbox/executor`) used elsewhere. Rejected for grading: a shared or reused container breaks the one-run-one-lifetime property that makes scoped credentials, per-run isolation, and clean filesystem state simple. The latency win does not justify reusing a container across submissions that must not see each other's credentials or files.

### Keeping score on the pipeline result

Tempting for continuity with the existing schema, but it directly contradicts 0013's score-blind pipeline — the whole point of which is that changing the rubric never touches the pipeline. Scoring lives only in formula evaluation ([Decision 4](#4-result-emission-and-the-persistence-reshape), [Decision 5](#5-formula-evaluation-and-score-materialisation)).

## Open questions

- **Executor roster for v1.** Docker-in-Docker is the only backend ZINC has today. Do we ship Docker-only behind the registry and design Kubernetes/Nomad for later, or build a second backend immediately to prove the abstraction?
- **STS availability.** Can ZINC's object-storage deployment mint STS-scoped credentials per run? If not, do we accept shared-credential + prefix-scoping as an interim, or invest in STS first ([Decision 8](#8-credentials-and-authenticating-the-agent))?
- **Temporal auth posture.** Is the deployment's Temporal configured (or willing to be configured) with a token authorizer, or do we rely on the trusted-network fallback for the command channel ([Decision 8](#8-credentials-and-authenticating-the-agent))?
- **Physical result storage.** Rows vs JSONB-on-run vs object-store blob for the per-run `exec_result` array — a queryability/write-amplification trade-off the contract leaves open ([Decision 4](#4-result-emission-and-the-persistence-reshape)).
- **Container-crash diagnostics.** On container death mid-run, should the runtime fetch the container's own logs into the failure record (as the reference implementation does) to make "it just died" debuggable? A small but real observability decision.
