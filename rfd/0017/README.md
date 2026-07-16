---
authors: Thomas Li
state: prediscussion
discussion:
labels: examination, platform, ui
---

# [RFD] Question Layout: Hierarchical Numbering, Per-Context Shuffling, and Stable Question References

## Overview

Examination documents are trees of **contexts** (shared passages / sections) and
**questions**, but the platform currently renders them with flat numbering
(1, 2, 3, …) and a single global order shared by every student. This RFD
introduces a coherent **layout model** that delivers four inter-related
features:

1. **Hierarchical automatic numbering** — questions grouped under contexts
   render as `1a`, `1b`, `2a.i`, … derived at render time.
2. **Per-context (and document-root) randomized question ordering** — an
   opt-in, per-context shuffle of sibling order, unique per student, to deter
   copying in physically co-located exams — while contexts with ordering
   dependencies or length-fairness concerns stay deterministic.
3. **Completed nested-context authoring** — contexts inside contexts, already
   supported by the data model and renderer, become first-class in creation
   and validation.
4. **Stable question references in chat** — instructors and students reference
   questions in proctoring chat/announcements via mention tokens that render
   as *each viewer's own* question number.

The unifying idea: **displayed order and displayed number are per-viewer,
derived properties; identity is the question slug.** One deterministic layout
function — `layout(tree, shuffle flags, seed) → ordered tree`, with numbering
as a pure function of the ordered tree — underlies all four features.

## Background: current state

Facts verified against `core` and `ui-v2` as of this writing:

- **The tree already exists.** `examination.context_relation` is an adjacency
  list (`parent_description_id` must be a context; children may be contexts or
  questions). Depth is unbounded; only self-parenting is rejected at write
  time (deeper cycles are caught by a runtime `CYCLE` guard in the recursive
  ancestor query). The `ui-v2` student renderer and paginator are genuinely
  recursive. The gaps are peripheral: context creation is root-only (nesting
  requires a follow-up drag-drop reparent), there is no write-time cycle or
  depth validation, and the exam sidebar collapses grouping to the top-level
  ancestor.
- **Ordering is one global `sort_order`** (gap-1000 insertion) per document,
  shared by questions and contexts, identical for every student. It is also an
  input to grading materialization: the reorder endpoint deliberately
  re-materializes the activity's single pipeline config because declaration
  order is part of the generator's input signature.
- **Grading identity is the slug, not the position.** Generated components,
  pipelines, formula keys, and expected files are all keyed by `question_id`
  (the author-chosen `client_ref`). Order affects only declaration order.
  This is the load-bearing enabler: presentation-only reordering is provably
  grading-safe as long as slugs are untouched.
- **Numbering is deliberately client-side.** The server stores no positional
  number (it would go stale under gap insertion); the client computes
  `flatIndex + 1` at render time. There is no grouped-numbering concept
  anywhere.
- **There is no per-student variation anywhere today.** Students read the same
  list endpoints as staff, gated by the collection-window middleware (plus
  proctoring admission where applicable). No seed, no per-user projection.
- **Chat exists in the proctoring extension** (`proctoring.chat_message`,
  announcements) with an opaque plain-text `body`; both UIs are bare
  textareas. Question identity lives across the schema boundary in
  `examination`.

## Design

### D1. Numbering convention (fixed, v1)

Numbering is a pure function of the **ordered** tree. One convention, no
per-context numbering configuration:

- The tree is capped at **3 levels** (root children = level 1). Contexts may
  appear at levels 1–2 only; level-3 nodes are questions.
- Every node consumes a counter slot at its level — **contexts and questions
  alike**.
- Level 1: `1`, `2`, `3`, …
- Level 2: parent label + lowercase letter, no separator: `2a`, `2b`, … then
  `aa`, `ab` past `z`.
- Level 3: parent label + `.` + lowercase roman numeral: `2b.i`, `2b.ii`.
- Contexts are displayed by their `display_name`, not an auto number, but
  their (invisible) label prefixes their children's labels.
- The existing global "Question N of M" progress chrome is retained alongside
  the hierarchical label: the label is identity, N-of-M is progress.

The depth cap is enforced at write time (creation and reparenting, accounting
for the height of a moved subtree). It exists so the numbering convention is
total over every legal document; it can be raised later with a defined
extension of the convention, which is cheap — the reverse (retrofitting
undefined numbering) is not.

Numbering stays client-side, computed from the ordered tree by a shared
frontend library used by the student app, the console preview, and the
sidebar. The server never stores or serves a number. (Rationale: numbering is
per-viewer once shuffling exists, and the client already owns tree assembly.
There is currently no server-side consumer of a rendered number; if one
appears — e.g. PDF export — the function is small enough to mirror, and this
RFD's layout endpoint already fixes the order it would consume.)

### D2. Shuffle flags

New columns, both `BOOLEAN NOT NULL DEFAULT false` (shipped in a follow-up
migration):

- `examination.context.shuffle_children` — shuffle this context's **direct
  children as units** (a sub-context moves as an intact block; its interior
  order is governed by its own flag).
- `examination.document.shuffle_children` — the same, for root-level items.

Authoring surfaces: the existing per-context settings (create dialog and
context settings page, next to `pagination_mode`) and the document settings
surface. Opt-in per context is the whole point: contexts with sequential
dependencies or with length-discrepancy fairness concerns simply keep the flag
off.

Boolean columns (not an attributes JSONB) follow the `pagination_mode`
precedent: plain columns added by normal migrations, keeping the schema
self-describing.

### D3. The layout endpoint — per-student order authority

`GET /v1/documents/{document_id}/layout`

```json
{
  "order": {
    "":       ["intro", "part-a", "standalone-q9"],
    "part-a": ["q3", "q1", "part-a-sub"],
    "part-a-sub": ["q4", "q5"]
  }
}
```

A **complete per-parent order map**: key = parent context id (`""` = document
root), value = ordered child ids, questions and sub-contexts interleaved.
Every parent with children appears, shuffled or not — the response is the
whole order authority for the viewer, not a shuffle overlay.

- **Staff callers** receive canonical order (`sort_order ASC, id ASC` per
  sibling set) — authoring, preview, grading, and export always show canonical
  order.
- **Examinee callers** are gated exactly like content reads (open collection
  window, proctoring admission where applicable). Sibling sets under a
  shuffle-enabled parent are permuted per student; all others are canonical.
  The standing invariant is **gating parity**: `/layout` is readable by an
  examinee exactly wherever question content is readable, no wider. Note that
  today the server exposes *no* post-window examinee content path at all
  (verified: every content read requires an open collection), so post-window
  student review of one's own paper — in one's own seeded order — requires a
  deliberate product decision to open a review read path (natural shape:
  reuse the published-answer visibility/release keys, applied uniformly to
  content *and* layout, never layout alone). Deferred; see Open questions.

Shape rationale: the client learns tree *structure* from `context_relation`
and needs only per-sibling-set ordering, which the map provides directly — a
flat DFS array would force the client to re-derive sibling order and is
fragile to fetch skew; a full tree response would duplicate structure the
relations endpoint already owns (two sources of truth for the same edges). In
`ui-v2`, adoption is minimal: the tree builder's `sort_order` comparator
becomes an index lookup into the map.

### D4. Seed derivation — deterministic, stateless, and one trap

Per sibling set:

```
seed = HMAC(server_key, "exam-layout-v1" || document_id || user_id || parent_id)
```

The first 8 bytes seed a deterministic PRNG driving a Fisher–Yates shuffle of
the canonical sibling list. No stored state: the same student sees the same
order on every reload, reconnect, and in post-exam review, forever, with no
new table.

Two non-obvious constraints, recorded here so they are never "simplified"
away:

- **`collection_id` must NOT be a seed input.** Students are moved between
  collections mid-exam (individual time extensions via collection member
  move). A collection-bound seed would silently reshuffle a student's paper
  at the moment of the move.
- **The purpose string namespaces the stream.** Future shuffling surfaces
  (e.g. MC choice order, explicitly out of scope here) derive their own
  purpose and get independent permutations without redesign.

Because the client cannot hold the HMAC key, the server serves the
permutation (D3) rather than a seed — which is also what keeps the canonical
order unobservable to students.

### D5. Hiding canonical order from examinees

Sibling order spans two list endpoints (contexts and questions are separate
resources), so raw `sort_order` in those payloads is the merge key — and,
today, the student client's only use of it is sorting. Once the layout
endpoint exists, an examinee response revealing canonical order would defeat
the shuffle. Therefore:

- **Staff reads keep `sort_order`** (the authoring tree legitimately needs the
  cross-list merge key).
- **Examinee-path reads omit/zero `sort_order`**, role-keyed off which
  authorization path admitted the request — not by forking endpoints. The
  student client's ordering source becomes the layout map exclusively.
- **Examinee-path list responses are additionally returned in id order, not
  canonical array order.** (Adversarial-review finding: zeroing the field
  alone is insufficient — the response array itself was still sorted by
  `sort_order`, letting an API-literate student reconstruct canonical order
  from raw responses. The client never relies on array order once it consumes
  the layout map, so id-ordering the examinee arrays costs nothing.)

### D6. Grading safety (invariant, test-enforced)

Per-student order is a **presentation-layer property that never touches
`sort_order` and never feeds materialization**. The layout endpoint performs
no writes and triggers no re-materialization; `composeGeneratorInput`
continues to walk canonical `sort_order`. Since grading artifacts are keyed by
slug, the materialized config is bit-identical whether or not any shuffle
flag is set. This invariant is enforced by integration test: two students
receive different layouts while the materialized grading config remains
identical and canonical.

### D7. Question references in chat

- **Token convention**: `@[q:slug]` inline in the existing plain-text
  `proctoring.chat_message.body` (and announcements). No schema change; no
  structured-mention column.
- **Compose**: a mention picker (typeahead over the already-loaded document
  outline) on the existing textareas; the instructor searches by their
  canonical number or display name, and the picker inserts the slug token.
- **Render**: a body tokenizer renders each token as **the viewer's own local
  label** (instructor: canonical; each student: theirs), linking/scrolling to
  the question in the student app. This dissolves the shuffle-ambiguity
  problem — a broadcast announcement about "question 2b" is stored as the
  slug and reads correctly in every student's private numbering.
- Unknown or stale tokens render as literal text (v1); server-side validation
  of slugs at send time is deferred (cross-schema proctoring→examination
  validation has NATS req-reply precedent when wanted).

### D8. Nested-context completion

Small, no schema change: an optional `parent_description_id` on context
creation (create-in-place, atomic with the relation row), write-time cycle
rejection on reparent, the depth-cap validation from D1, and multi-level
sidebar grouping in the student app.

Structural-integrity writes (reparent, create-with-parent) validate and write
inside one transaction holding a **per-document row lock**: the cycle/depth
checks are check-then-write, and without document-scoped serialization two
concurrent reciprocal reparents (A→B, B→A) each pass their check and commit a
real cycle — an in-memory mutex cannot prevent this across replicas.
Validation runs **before** any content side effects (a rejected create must
leave no orphan meta rows, or a client-supplied id becomes permanently
un-creatable).

### D9. Known properties and operational caveats (reviewed, accepted)

- **Mid-exam authoring edits re-permute.** The permutation is a stateless
  function of the canonical sibling list, so adding/removing/reordering items
  under a shuffled parent mid-window re-shuffles that sibling set for every
  student (gap-rebalancing is order-preserving and safe). Mid-exam structural
  edits are already discouraged; this is documented rather than defended
  against. Toggling a shuffle flag mid-window likewise flips that parent for
  all students.
- **Exam bundles round-trip the flags.** `shuffle_children` (document and
  context) is part of the bundle schema; export/apply preserve it (a silent
  default-off on re-import was an adversarial-review finding, fixed).
- **Depth cap vs old bundles:** a bundle nesting contexts 3+ deep (previously
  unvalidated) now fails apply with the depth-cap fault.
- **Layout endpoint is uncached** (3 reads + O(N) shuffle per call) — same
  scope as existing per-document reads; revisit only if live-exam polling
  shows pressure.
- **Client degrade path:** if the layout fetch fails outright, the student
  client falls back to deterministic id-order (canonical order is
  deliberately unavailable to examinees) so the exam stays takeable; the
  layout query is otherwise pinned (`staleTime: Infinity`) so a background
  refetch can never reorder a live sitting even if server determinism were
  violated.

## Alternatives considered

- **Rewriting `sort_order` per-caller in existing list endpoints** instead of
  a layout endpoint: avoids a new route but pushes role-conditional response
  mutation into shared handlers and still leaks structure/order semantics into
  two payloads; rejected for a single clean order authority.
- **Client-side shuffle from a server-issued seed**: the client cannot be
  trusted with a derivable seed, and the canonical order would still have to
  be served; rejected.
- **Stored per-delivery seed/permutation**: adds a table and a lifecycle
  (what happens on member move, re-open, review?) for something a keyed hash
  gives statelessly; rejected.
- **Server-computed numbering**: no current server-side consumer; numbering is
  per-viewer and the client owns tree assembly. Rejected for v1 (revisit if a
  server-rendered export appears).
- **Structured mention column on chat messages**: heavier contract for no v1
  gain over an in-body token that also works in announcements; rejected.
- **Attributes JSONB on context**: rejected in favor of plain boolean columns,
  per the `pagination_mode` precedent.

## Delivery plan

Two stacked umbrella branches (`feat/question-layout` in `core` and `ui-v2`),
streams landing onto them; two final PRs.

1. **Nesting completion** (core then ui-v2) — D8.
2. **Numbering library + UI integration** (ui-v2 only) — D1.
3. **Shuffle backend** (core: migration, flags, layout endpoint, seed,
   `sort_order` hiding, grading-safety tests) then **shuffle UI** (ui-v2:
   toggles, layout adoption, review parity) — D2–D6.
4. **Chat mentions** (ui-v2, after the numbering library) — D7.

Verification includes a live two-browser drive on a simulate stack: two
students in one shuffled exam (different orders, stable across reload,
identical outside shuffled contexts), hierarchical numbering, per-viewer
mention rendering, and post-close review parity.

## Open questions

- **Post-window student review order.** Should students be able to revisit
  their paper after the window closes, in the order they sat it? The server
  currently denies all post-window examinee content reads (pre-existing;
  unrelated to this feature), so this needs a deliberate access-surface
  decision — publishedanswer-keyed, content and layout uniformly — before the
  results view can render a re-fetched paper. Owner call.

## Out of scope / future work

- **MC choice shuffling** — same seed machinery, own purpose string; needs its
  own pass over answer modalities.
- **Auto-labeled contexts** ("Part A") and per-context numbering styles.
- **"Preview as student" with a sample seed** in the console.
- **Server-side slug validation for chat mentions** at send time.
- **PDF/print export** honoring canonical order (would mirror the numbering
  function server-side or reuse the layout endpoint).
