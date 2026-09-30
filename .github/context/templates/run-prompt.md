# R<nnn> — <what this run establishes>

Author: <user> · Date: YYYY-MM-DD · Branch: `<branch>` (cut from `<sha>`) · Report: `R<nnn>-<slug>-report.md`
Mode: <attended with stop points | overnight, no stop points> · Next free decision id: D<n>

## Hard rules

- Never patch a package function from a script to get past an error. Extend via the registered
  type hierarchy (`register_edge_type!` / `register_unit_type!` / `register_model!`) or a
  documented constructor keyword instead.
- A cross-check against a reference implementation (e.g. PowerModels.jl) is read live in the run,
  never a hand-copied constant from a previous run.
- Fixes land as commits on this branch, one per fix, test first, named `D<n>: …`, no AI attribution.
- A suspected defect in a reference implementation is reported with file and line, never patched;
  the comparison continues on NMB's side.
- Targeted tests per commit; the full suite once, at the end (`julia --project=. -e "using Pkg;
  Pkg.test()"`).
- Stay in scope: <what this run must not do: benchmarks, reruns, re-checks beyond the tasks>.

## What changed since the last run

Bullets with commits, and anything the run must not re-litigate.

## Tasks

1. **<task>** — what to run, what to produce. **Prediction:** <numbers>. Acceptable outcomes: <both
   outcomes if the result can go either way>. *(Stop point: … — only in attended mode.)*

## Failure triage

For each likely failure: what it would look like, the first thing to check, and whether to fix,
report, or stop.

## How this run is judged

- Disqualifiers: an adjective where a number was asked; "measured, not root-caused"; a monkeypatch;
  work outside scope; a difference not driven to a cause or a named defect.
- Each comparison reports deviation from the check's own expectation as well as from the reference.

## Deliverable

`R<nnn>-<slug>-report.md` with: summary table (task → result → number), commits table (decision,
hash, files, tests, pass count), one section per task, open items, and memory updates proposed
(decisions, lessons, environment, STATE).
