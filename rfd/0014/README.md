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
exams the platform already grades. This RFD is the problem statement
for closing that gap, sized as a discussion document rather than a
proposal: the design space is broad and most decisions are not
self-evident.

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
mechanically derivable from question metadata alone — see
[Challenges](#challenges) below.

Implicit corollary: an examination that **does** contain coding
questions can have its non-coding parts mechanically generated, but the
coding parts will require some authoring step the platform cannot
fully automate. The RFD has to address both halves cleanly, not just
the easy one.

## Background

The legacy v2 system had a "Generate from document" button (the
deleted `examination pipeline generate` endpoint) that produced a
pipeline config tied to the current document. It existed because the
v2 config language was verbose enough that hand-authoring was a
non-starter for non-engineer instructors — but the design had three
recurring failure modes:

1. **Regeneration was destructive.** Clicking the regenerate button
   clobbered any manual edits the instructor had made. The UI
   acknowledged this with a warning ("any manual edits will be lost")
   that pushed the decision onto the user.
2. **The document was the source of truth in name only.** Once
   generated, the HCL was the artifact that actually ran. If the
   document changed (new question added, mark reweighted), the
   generated config drifted from the document silently. There was no
   sync, only a regenerate-and-pray loop.
3. **The generator owned every modality-mapping decision.** Whether MC
   questions batched into one pipeline or sprawled into N, what
   stdin/stdout paths each scenario expected, where assets were
   resolved from — all of this was buried in generator code, opaque to
   the instructor, and only discoverable by reading the produced HCL.

v3 (RFD 0013) reshuffled this by making the HCL itself smaller, more
inspectable, and more readily authored — but it deferred the *bridge*
between the document and the HCL entirely. The frontend plan for RFD
0013 sketched a "Generate from document" option as a one-shot template
in the empty-state picker, but stopped short of specifying it.
Meanwhile the Documents tab still carries a vestigial "Save Scores"
control whose v2 semantics are gone; it now does nothing meaningful.

The question this RFD has to answer is **what relationship between
document and configs the platform commits to going forward**, given
that:

- The v3 HCL is human-readable enough that the instructor *can* edit
  it. Whether they *should* have to is the open question.
- Most ZINC instructors are CS faculty who can read HCL but resent
  needing to. A small subset are non-CS faculty (humanities,
  language departments running MC tests) who cannot read HCL at all
  and for whom the premise above is non-negotiable.
- The platform has a fairly mature examination authoring UI on the
  Documents tab — questions, modalities, marking schemes, assets are
  all editable through forms. Asking instructors to drop into an HCL
  editor mid-flow is a meaningful break in the authoring experience.

## The four positions on the design axis

There is one fundamental axis along which any design lands. Outlining
the endpoints (not endorsing any of them) so the rest of the document
can refer back:

- **Position A — manual HCL only.** The document is decoupled from
  configs. The platform offers templates and an editor; the
  instructor types HCL to grade their exam. This is what RFD 0013
  shipped. Violates the premise.
- **Position B — one-shot generation, no sync.** The platform can
  generate a starter config from the document. After generation the
  HCL becomes the source of truth; subsequent document changes do not
  propagate. Re-running the generator is opt-in and destructive.
  Partially satisfies the premise.
- **Position C — generated artifact, document is the source of
  truth.** The HCL is *always* a derived artifact. Editing the HCL
  directly is either disallowed or limited to specific scoped
  overrides. Document changes propagate automatically. Strongly
  satisfies the premise but constrains what the HCL is for.
- **Position D — live binding via `document.examination` references.**
  The HCL contains references like `document.examination.questions`
  that the runtime resolves at grading time. The document remains
  authoritative for question metadata; the HCL describes the *shape*
  of grading. RFD 0013's `document` block was designed with this in
  mind, but the runtime resolution is not built yet.

Most plausible designs are hybrids — e.g., scaffold via B, sync via D,
fall back to A for unsupported cases — but the trade-offs differ
sharply at the edges. Subsequent sections of any concrete proposal
need to pin down a position; this background just notes the axis.

## Challenges

### C1. Coding questions are not mechanically generatable

A coding question carries a `CodingModalityInfo` blob in its answer
modality. That blob currently tells the editor what language the
student writes in, but it does not declare:

- The build command (compiler choice, flags, output filename).
- The test contract — what stdin/stdout each test case expects, how
  many cases there are, where the expected outputs live, how to diff
  them.
- The marking criteria — full marks on all-pass, partial credit per
  case, weighted cases, penalty for timeouts, etc.
- Resource limits beyond the existing global defaults.

Without that information, the generator either has to (a) ask the
instructor for it at generation time (which is HCL authoring with a
form GUI, just with a different form), (b) emit a placeholder pipeline
the instructor must edit, or (c) declare coding questions
out-of-scope for the generator. All three have downstream
implications.

Whether the platform should extend the coding modality to carry this
authoring data is itself a debatable design choice: it widens the
modality contract, couples question authoring to grading-pipeline
authoring, and conflates "this is a coding question" with "this is how
to grade a coding question." A counterargument is that the alternative
is fragmentation — every coding question becomes a snowflake in HCL.

### C2. Marks are not yet contractually placed

RFD 0013 decision M2 says per-question marks live "inside the
marking-scheme blob content," but the marking-scheme blob is currently
a `SolutionData []byte` opaque field, and no schema is defined. A
config generator can produce a structurally complete formula but
cannot populate `max_score` per component until this is settled.
Whatever the generator emits has to be either:

- A formula with placeholder marks that the instructor must edit,
  which violates the premise for non-coding exams (the instructor must
  touch HCL to set the actual point values).
- A formula keyed to a marks source somewhere else (a separate column,
  a structured marking scheme schema, a flat document attribute), in
  which case the marks source has to be designed before the generator
  can ship.
- A formula that reads marks via `document.examination.questions[x].marks`
  at runtime, which depends on Position D being available, which
  depends on the runtime-RFD parse-phase resolution that hasn't been
  built yet.

The premise cannot be fully satisfied without resolving this. There
is no design path that defers C2.

### C3. Source-of-truth ambiguity

If the platform supports both "generate from document" and "edit HCL,"
the question "which one wins on conflict?" must be answered. v2
implicitly said *neither wins, the latest write wins*, and that's
exactly why regeneration was destructive. v3 has not committed to an
answer.

Three sub-questions sit underneath this:

- **Do manual HCL edits survive a document change?** If the document
  adds a question and the HCL doesn't mention it, is that an error,
  a silent skip, or a regeneration prompt?
- **Do document changes propagate without instructor action?** A
  marking-scheme version bump that changes marks for q3 — does that
  flow into the formula automatically, or wait for re-generation?
- **Can the HCL declare things the document doesn't?** A custom
  pre-processing stage, a weighted scoring expression, a partial-credit
  rule on top of an MC question. These don't exist in document metadata.
  If the HCL is allowed to add them, it ceases to be a pure
  function of the document.

The answer is not obvious. Different instructors will want different
trade-offs, and the system probably can't optimise for all of them
simultaneously.

### C4. Modality-to-pipeline-shape mapping is not free choice

Each non-coding modality has *multiple* defensible pipeline shapes:

- **MC questions**: one batched pipeline grading all of them (compact,
  RFD 0013's example shape) vs. one pipeline per question (uniform with
  coding, easier to inspect per-question, more verbose).
- **TF questions**: identical to MC structurally; batch with MC or
  separate?
- **SA questions**: a literal diff is brittle (whitespace, case,
  punctuation). Pipeline shape depends on whether matching is exact,
  case-insensitive, regex, or fuzzy — and whether the marking scheme
  for each question carries a per-question rule. Generators that pick
  "exact diff" silently produce wrong grades on plausibly-correct
  student answers.
- **Essay questions**: not auto-gradable. The generator either emits a
  placeholder stage, omits them, or fails. Each choice has different
  downstream consequences for the formula (omitted essays leave a
  marks gap; placeholder stages have to score zero, deferring grading
  to a human).

The platform has to commit to a default shape for each modality. The
defaults are debatable, the configurability of defaults is debatable,
and the surface for *changing* the default per-question (instructor
overrides the generator's choice) is debatable.

### C5. Versioning and re-grading

The marking scheme is already versioned (`marking_scheme_meta.active_version_id`).
Pipeline configs and formulas are *not* versioned today; an `UpdateConfig`
overwrites the row. If the document/marks change after grades have
been issued:

- Are past grades retained as historical artifacts, or recomputed
  against the new configs?
- Does the system support running a re-grade with the new configs
  against past submissions? (Pipeline execution is deferred, but the
  question still affects the *config* design.)
- Does generating a new config from a changed document produce a new
  config row, or mutate the existing one? The former preserves
  history at the cost of attachment churn; the latter is simpler but
  loses provenance.

This isn't pure UX — the answer has data-model implications.

### C6. Authoring UX surface area

The premise requires the instructor to never see HCL for non-coding
exams. That means *every* knob the configs expose for non-coding
modalities must have a form-based authoring surface somewhere — likely
on the Documents tab or in the Grading tab once configs are no longer
opaque files. Open questions:

- Where does mark editing live? Per-question on Documents tab, or in
  a dedicated grading-rules editor on the Grading tab? Or both?
- How are SA matching rules (exact / case-insensitive / regex / fuzzy)
  authored? A dropdown per question? A bulk setting per modality? A
  marking-scheme-level setting?
- How are activity-wide grading parameters (max total, partial-credit
  policy, time-cap behaviour) surfaced? Today the formula's `scoring
  { ... }` block carries them; if the premise holds, there has to be
  a form for them.

Building each of these surfaces is non-trivial. Pulling them all into
the Documents tab risks overloading a UI already responsible for
question authoring; splitting them across multiple tabs risks
fragmenting the instructor's mental model of "what makes my exam grade
right."

### C7. Mixed-format examinations

The most common real exam shape is a mix: 30 MC + 10 SA + 2 coding.
Under the premise, the MC+SA parts must be HCL-free; the coding part
inevitably is not. This forces the system to support two authoring
flows for the *same* activity simultaneously:

- A form-based flow for the generatable parts.
- An HCL-based flow (or a more elaborate per-question authoring
  surface) for the coding parts.

How these two flows interact is the central design question for the
mixed case. It is not enough to make each flow work in isolation; the
generated artifacts have to *compose* into a single valid pipeline +
formula pair that the runtime grades end-to-end.

### C8. The `document.examination` runtime contract is not built

RFD 0013's `document "examination" { id = 1 }` block parses today but
does not resolve anything. Position D and any hybrid that uses live
binding depends on the parse-phase resolver landing first. If the
runtime RFD slips, the only viable positions are A or B — neither of
which fully satisfies the premise without C2 also being resolved.

This creates a dependency ordering problem: the natural way to
satisfy the premise is to commit to Position D, but D has the longest
critical path. Positions B and C with a placeholder-marks fallback
are buildable sooner but produce worse instructor experiences.

### C9. The "configs are reusable across activities" affordance

Pipeline configs and formulas have their own IDs and can be attached
to multiple activities — this was true in v2 and survives in v3. A
generator that produces a config tightly bound to a specific document
makes the config un-reusable. Conversely, a generator that produces a
generic template instructors customise per-activity falls back toward
Position A.

It's plausible that "configs that grade a specific document" and
"configs that grade a class of similar documents" are two distinct
concepts and the platform should treat them differently — but no part
of the system currently does. The bridge design has to decide whether
to introduce that distinction.

## Out of scope for this RFD

- The runtime architecture (continued from RFD 0013's deferred list).
- The marking-scheme blob schema (continues as a precondition; this
  RFD does not propose it).
- The pipeline-execution / batch-grading surfaces. They are downstream
  of configs and do not affect the document → config bridge.
- Multi-language coding-question authoring (the coding-modality
  authoring contract is its own RFD if anyone proposes extending
  `CodingModalityInfo`).
- Migration of legacy v2 generator artifacts. RFD 0013 is a full
  replacement; v3 does not carry v2 generator output forward.

## Open questions to pin down before any proposal

In rough order of "must be answered before code is opened":

1. Which position on the axis (A / B / C / D / hybrid) does the
   platform commit to for the non-coding premise?
2. Where do marks live, and who authors them? (Blocks C2; almost
   blocks everything else.)
3. What is the source of truth on conflict — document or HCL — and
   does that answer differ by modality?
4. What is the default pipeline shape for each non-coding modality,
   and how is it overridden per-question?
5. Are configs versioned, and what does "re-grade with new configs"
   mean operationally?
6. Where in the UI does mark editing live, and where do grading-rule
   knobs live? (This is the surface-area question for the premise.)
7. How do mixed-format exams resolve the form-flow vs HCL-flow
   tension?
8. Does the platform introduce a distinction between "this config
   grades this document" and "this config grades a class of documents",
   or treat all configs uniformly?

This RFD will be considered ready to advance to a concrete proposal
once questions 1–4 are settled at the team level.
