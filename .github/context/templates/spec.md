# <Title that states the change>

Status: draft · Author: <user> · Date: YYYY-MM-DD · Decisions: D<a>-D<b> (next free after: D<c>)
Priority: <P0-P3> · Effort: <Small|Medium|Large>

## Handoff instructions

- Implement on `<branch>`, one commit per item, test first when it fixes a defect.
- Commit messages name the decision (`D<n>: …`) where there is one, and carry **no AI attribution**.
- Update the per-file changelog header (80-column box comment) of every file touched, plus the
  package version in `Project.toml` (patch digit; minor for a new component type) and `CHANGELOG.md`.
- Targeted tests per commit; the full suite once at the end (`julia --project=. -e "using Pkg;
  Pkg.test()"`).
- Everything the implementer needs is quoted here (file, line, sentence). Don't rely on other notes.

## Evidence

What happens today — file:line, and an actual run's output, not just a reading of the source.

## Root cause

The specific line or function responsible.

## Fix

What to build. Name any new public API, which decisions it needs (`record-decision` before or
alongside implementation), and what it deliberately leaves alone.

## Verification

The command or test that proves the fix — ideally one that would have failed before it.

## What this deliberately does not decide

Adjacent questions left open, and where they are tracked (backlog id / open question id).
