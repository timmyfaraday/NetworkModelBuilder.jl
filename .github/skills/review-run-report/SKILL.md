---
name: review-run-report
description: Review an agent run's report against its prompt - check the numbers, the commits and the claims, then carry lasting findings into project memory. Use when a run report comes back or the user asks to review a report.
argument-hint: path to the report (and prompt, if not next to it)
---
# Review a run report

Read the prompt first, then the report. Be a skeptical reviewer: the report was written by the
agent that did the work.

## Check

1. **Scope**: every task done? Anything done that the prompt excluded (benchmarks, reruns, extra
   checks)? Stop points respected?
2. **Disqualifiers**: adjectives where numbers were asked; "measured, not root-caused"; a
   monkeypatch instead of a documented extension point; a hand-copied reference value used as if
   it were a live comparison.
3. **Numbers**: recompute every derived figure you can (subtractions, totals, percentages). Compare
   predictions with results; an unexplained miss is an open item.
4. **Commits**: `git log` and `git show --stat` for each hash the report cites; the diff matches
   the description; tests were added for fixes; no AI attribution in messages; per-file changelog
   headers updated.
5. **Claims about a reference implementation** (e.g. "PowerModels.jl does X") need a file/line or
   a reproducible call; spot-check one.
6. **Expectation vs. reference**: deviations reported against the check's own expectation, not
   only against the reference implementation.

## Output

A short review for the user: verdict (accept / accept with corrections / reject), the corrections
with evidence, open items, and proposed memory updates. Then, with the user's OK:

- decisions confirmed → `record-decision`
- new facts about the machine → `environment.md`
- mistakes worth a rule → `lessons.md`
- state of the work → `STATE.md`, backlog
- the run's row in `agent-runs/README.md` → status `reviewed (accept|corrections|reject)`
