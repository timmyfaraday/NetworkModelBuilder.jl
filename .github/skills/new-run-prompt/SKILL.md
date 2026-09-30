---
name: new-run-prompt
description: Write a prompt for an agent run (implementation, cross-check, diagnostic, overnight run) with hard rules, numeric predictions and judging criteria. Use when the user wants to hand a task to an agent run or an overnight session.
argument-hint: what the run must establish, and attended or overnight
---
# Write a run prompt

Read `.github/context/templates/run-prompt.md` and `.github/context/lessons.md` first.

## Steps

1. Pin the facts: branch and base sha, last spent decision id, which outputs exist in `scratch/`.
   Verify, don't assume.
2. Ask the user for anything that changes the run's shape: attended with stop points or overnight
   without; what is out of scope; which outcomes are acceptable.
3. Write predictions as numbers with tolerances. If a result can go either way, say both are
   acceptable and that code must not change in response.
4. Write the hard rules from the template, adapted: no monkeypatching NMB internals from a script
   (extend via the registered type hierarchy or a documented constructor keyword instead); a
   cross-check against a reference implementation (e.g. PowerModels.jl) reads it live, not a
   frozen or hand-copied constant; scope limits; test cadence (targeted per commit, full suite at
   the end).
5. Failure triage: likely failures, first check, fix / report / stop.
6. "How this run is judged": disqualifiers, and deviation from the check's own expectation.
7. Self-contained: quote file, line and sentence for every fact the run relies on.

## Save

`.github/context/agent-runs/R<nnn>-<slug>-prompt.md` (next number from the index in
`agent-runs/README.md`); add the row to the index; commit it on the run's branch so the run can
read it.
