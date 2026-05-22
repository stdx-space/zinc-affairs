# Example pipeline config v3 for a mixed-format examination.
#
# This config grades a single examination that contains:
#   - 2 programming questions (q1, q2), each with compile → execute → test
#     stages. Per-scenario stdin handling demonstrates both exec-level
#     inline content and per-scenario file overrides.
#   - All multiple-choice questions, batched into one pipeline whose test
#     stage uses `dynamic "scenario"` to generate one diff per question
#     from the examination's question list.
#
# See `example-formula.hcl` for the corresponding scoring formula.

version = 3

locals {
  compile_flags = ["-std=c++17", "-Wall", "-Wextra", "-O2"]
  diff_flags    = ["--ignore-case", "--strip-trailing-cr"]
}

document "examination" {
  id = 1
}

# -------------------------------------------------------------------
# Programming question 1 — linked-list reversal
# -------------------------------------------------------------------
pipeline "programming-q1" {
  description = "Q1 — reverse a singly linked list"

  stage "compile" {
    exec {
      command = "g++"
      args    = concat(local.compile_flags, ["-o", "q1.out", "q1.cpp"])
      timeout = "10s"
    }
  }

  stage "execute" {
    exec {
      command       = "./q1.out"
      timeout       = "5s"
      # Most scenarios share this default stdin; one scenario overrides
      # it with a file (see "large" below). stdin_path on a scenario
      # shadows stdin_content on the exec — no parse-time conflict
      # because the rules are scoped per level.
      stdin_content = "default seed: 42\n"

      scenario "small"  { args = ["--mode=small"];  stdout_path = "small.out" }
      scenario "medium" { args = ["--mode=medium"]; stdout_path = "medium.out" }
      scenario "large" {
        args        = ["--mode=large"]
        stdout_path = "large.out"
        stdin_path  = "examination-assets/q1/large_seed.txt"
      }
    }
  }

  stage "test" {
    # This stage runs `diff` against the marking scheme — its exit code IS
    # the pass/fail result. Hide everything (including metadata) until the
    # collection deadline; otherwise students can read off whether each
    # test case matched before the exam closes.
    visibility {
      filter { effect = "hide"; until = "collection_stop" }
    }

    exec {
      command = "diff"
      scenario "small"  { args = concat(local.diff_flags, ["small.out",  "examination-assets/q1/small.expected"]) }
      scenario "medium" { args = concat(local.diff_flags, ["medium.out", "examination-assets/q1/medium.expected"]) }
      scenario "large"  { args = concat(local.diff_flags, ["large.out",  "examination-assets/q1/large.expected"]) }
    }
  }
}

# -------------------------------------------------------------------
# Programming question 2 — shortest path on a DAG
# -------------------------------------------------------------------
pipeline "programming-q2" {
  description = "Q2 — shortest path in a weighted DAG"

  stage "compile" {
    exec {
      command = "g++"
      args    = concat(local.compile_flags, ["-o", "q2.out", "q2.cpp"])
      timeout = "10s"
    }
  }

  stage "execute" {
    exec {
      command    = "./q2.out"
      timeout    = "10s"
      stdin_path = "examination-assets/q2/common_seed.txt"

      scenario "tree"   { args = ["--graph=tree"];   stdout_path = "tree.out" }
      scenario "cyclic" { args = ["--graph=cyclic"]; stdout_path = "cyclic.out" }
      scenario "dense"  { args = ["--graph=dense"];  stdout_path = "dense.out" }
    }
  }

  stage "test" {
    visibility {
      filter { effect = "hide"; until = "collection_stop" }
    }

    exec {
      command = "diff"
      scenario "tree"   { args = concat(local.diff_flags, ["tree.out",   "examination-assets/q2/tree.expected"]) }
      scenario "cyclic" { args = concat(local.diff_flags, ["cyclic.out", "examination-assets/q2/cyclic.expected"]) }
      scenario "dense"  { args = concat(local.diff_flags, ["dense.out",  "examination-assets/q2/dense.expected"]) }
    }
  }
}

# -------------------------------------------------------------------
# Multiple-choice question batch
# -------------------------------------------------------------------
# All MC questions are graded by the same logic: the student's answer
# for question `<qid>` is in `<qid>.txt` (uploaded by the exam runner),
# and we diff it against the marking scheme's expected answer.
#
# The expected-answer file path is sourced from the document's
# per-question `marking` field — the runtime resolves the path from
# the marking-scheme blob and exposes it here. This is the v3 idiom:
# the pipeline reads what it needs to test from the document, rather
# than depending on a hardcoded asset-path convention.
#
# Generated as one scenario per MC question via a dynamic block driven
# by the examination's question list.
pipeline "mc" {
  description = "All multiple-choice questions, batched"

  stage "test" {
    visibility {
      filter { effect = "hide"; until = "collection_stop" }
    }

    exec {
      command    = "diff"
      stdin_path = "/dev/null"

      dynamic "scenario" {
        for_each = [for q in document.examination.questions : q if q.type == "mc"]
        labels   = [scenario.value.id]
        content {
          args = concat(local.diff_flags, [
            "${scenario.value.id}.txt",
            scenario.value.marking.expected_file,
          ])
        }
      }
    }
  }
}
