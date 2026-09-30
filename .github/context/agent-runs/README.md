# Agent runs

A run is a task handed to an agent (often overnight/unattended) with a prompt, producing a report.
Write the prompt with `new-run-prompt` (shape: `../templates/run-prompt.md`); review the report
with `review-run-report`.

Not the same thing as the top-level `runs/` directory at the repo root, which holds NMB's own
simulation output (contingency/market/redispatch scenario logs) — this folder holds agent task
prompts and reports, a different concept that just happens to share a common English word.

- File names: `R<nnn>-<slug>-prompt.md` and `R<nnn>-<slug>-report.md`, numbered from R001.
- The report is committed next to its prompt, on the run's branch. Both may be removed once merged
  to `main` (git history keeps them); keep the index row with the merge commit.
- After review, the lasting findings go to `decisions.md`, `lessons.md`, `environment.md` or
  `STATE.md`. The report itself is history.

## Index

| Run | Branch | Prompt by | Status |
| --- | --- | --- | --- |
