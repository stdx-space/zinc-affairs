# Example formula (pipeline config v3) for the pipeline in `example-pipeline.hcl`.
#
# Scoring structure:
#   - Each programming question is its own component, configured explicitly.
#     The platform may generate the boilerplate from the examination's
#     question list at authoring time, but the stored config holds each
#     question as a static block — coding questions don't share a uniform
#     scoring rule, so they don't share a generator.
#   - All multiple-choice questions roll up into one component. The MC
#     pipeline is itself a dynamic batch, so the formula side mirrors that
#     with a single `sum([for ...])` aggregation.
#   - The final total is the sum of all component scores, capped at the
#     examination's total marks.
#
# Note on the document contract: `marks` is exposed on questions only in
# the formula's view of `document.examination` — the pipeline view does
# not see it. This enforces the pipeline-is-score-blind principle at the
# parser level.

version = 3

document "examination" {
  id = 1
}

# -------------------------------------------------------------------
# Pipeline declarations
# -------------------------------------------------------------------
# Every `pipeline.<name>` reference below must be grounded by a
# matching declaration here. The validate phase catches missing
# declarations as a local single-file check; the parse phase cross-
# references these names against the paired pipeline config.
pipeline "programming-q1" {}
pipeline "programming-q2" {}
pipeline "mc" {}

# -------------------------------------------------------------------
# Q1 — weighted per-scenario marks
# -------------------------------------------------------------------
# Each test scenario carries a different share of Q1's marks: `small`
# is a sanity check, `large` is the load-bearing case. Explicit weights
# rather than equal distribution.
#
# Pipeline data is read from the reserved top-level `pipeline.<name>`
# namespace; bracket-indexed form is used here because "programming-q1"
# contains a dash and isn't a bare HCL identifier.
component "q1" {
  max_score = document.examination.questions["q1"].marks

  score = (
    (succeeded(pipeline["programming-q1"].scenarios["small"].test)  ? document.examination.questions["q1"].marks * 0.20 : 0) +
    (succeeded(pipeline["programming-q1"].scenarios["medium"].test) ? document.examination.questions["q1"].marks * 0.30 : 0) +
    (succeeded(pipeline["programming-q1"].scenarios["large"].test)  ? document.examination.questions["q1"].marks * 0.50 : 0)
  )
}

# -------------------------------------------------------------------
# Q2 — all-or-nothing
# -------------------------------------------------------------------
# Q2 awards full marks only when every graph variant passes; otherwise
# zero. Models a question where partial-credit doesn't make sense (e.g.,
# the algorithm is correct or it isn't).
component "q2" {
  max_score = document.examination.questions["q2"].marks

  score = alltrue([
    succeeded(pipeline["programming-q2"].scenarios["tree"].test),
    succeeded(pipeline["programming-q2"].scenarios["cyclic"].test),
    succeeded(pipeline["programming-q2"].scenarios["dense"].test),
  ]) ? document.examination.questions["q2"].marks : 0
}

# -------------------------------------------------------------------
# Multiple-choice batch — one component, sum across question scenarios
# -------------------------------------------------------------------
# Each scenario in the `mc` pipeline corresponds to one MC question
# (the scenario code equals the question id, set via the pipeline's
# dynamic block's `labels`). Each question contributes its own marks
# from the marking scheme if its diff passed.
component "mc_total" {
  max_score = sum([for q in document.examination.questions : q.marks if q.type == "mc"])

  # "mc" is a bare HCL identifier, so dotted access works directly.
  score = sum([for code, sc in pipeline.mc.scenarios :
               document.examination.questions[code].marks
               if succeeded(sc.test)])
}

# -------------------------------------------------------------------
scoring {
  # `total` is optional — the default is the sum of every component's score,
  # which is what we want here. Made explicit to demonstrate the syntax.
  total      = q1.score + q2.score + mc_total.score

  # The examination's total marks, summed across all question types.
  # Both the UI's "out of X" denominator and a hard cap on `total`.
  max_score  = sum([for q in document.examination.questions : q.marks])

  min_score = 0
}
