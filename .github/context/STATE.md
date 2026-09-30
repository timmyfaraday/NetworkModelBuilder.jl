# STATE

Overwrite, don't append. Keep under 80 lines. Last updated: 2026-09-30 by Tom Van Acker (seeded
while adopting this agent setup, from `plans/GAP_CLOSURE_PLAN.md`, `CHANGELOG.md` and prior
session history; same-day `/probe-environment` run verified Julia/git/docs gates and found the
hooks inert — F1).

## Where NMB stands

- v0.9.7. All P0 (gaps #1-4) and P1 (gaps #5-7) items from `plans/GAP_CLOSURE_PLAN.md` are closed:
  doc examples resolve bundled fixtures from any cwd, `parse_tables` raises clear errors on
  length-mismatched/empty tables, type registries are thread-safe (one `ReentrantLock` each), a
  real `CHANGELOG.md` exists, every complete doc example runs in CI (`test/docs.jl` sweep +
  Documenter `@example` blocks), and `test/powermodels.jl` live-cross-checks against
  PowerModels.jl v0.21 alongside the existing frozen-value tests.
- Only P2/P3 (structural/organizational, gaps #8-11) remain, none started — see `backlog.md`.
- Full suite: 2436 tests, ~3 minutes, fully offline (see `environment.md`). Only tag in git
  history is `v0.6.0`; 0.7.0-0.9.7 are real `Project.toml` states that were never tagged (a
  deliberate choice, not an oversight — see `decisions.md`).

## Branches

- `main` holds everything through v0.9.7. No other branches in flight.
- Next free decision id: **D9** (see `decisions.md`).

## In progress

- `.github/` agent setup adopted 2026-09-30 (B0 done). Same-day `/probe-environment` run confirmed
  Julia/git/docs-build gates but found the SessionStart/PreToolUse/Stop hooks never fire on this
  VS Code build (no `.git/agent-session/`, no `.git/agent-hooks.log`) — see `setup-feedback.md` F1
  and `environment.md`. `STATE.md` injection etc. rely on the prose fallback in
  `copilot-instructions.md` for now.

## Next

1. Pick up `plans/GAP_CLOSURE_PLAN.md` gap #8 (central include/export file tax) when ready — see
   `backlog.md` B1.
2. Gaps #9-11 are `Large` effort / process items, not single-PR fixes — see `backlog.md` B2-B4.

## Blocked / waiting

- Gap #10 (parallel rolling-horizon throughput) needs a design decision before implementation
  (chunked-parallel vs. document-the-trade-off) — see `open-questions.md` Q1.
