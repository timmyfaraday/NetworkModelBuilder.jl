# STATE

Overwrite, don't append. Keep under 80 lines. Last updated: 2026-10-01 by Tom Van Acker (moving
specs/plans from `plans/` to `context/knowledge/plan/`, D12).

## Where NMB stands

- Specs/plans moved from a top-level `plans/` to `context/knowledge/plan/` (D12) — content
  unchanged, only location; every cross-reference updated. No code or package behavior touched, no
  version bump.
- v0.10.2 (D11): `solution_tables(data, result)` — a tidy `NamedTuple`-of-columns view alongside
  `nw_solution`, edge rows per terminal, dimensions become columns, all-missing columns dropped —
  plus `docs/src/manual/concepts.md` (a newcomer-facing page working one network through all three
  problem types and both formulations, then `nw_solution` vs `solution_tables`, then a grounded
  SmaLoadFlow comparison). Full suite green: 2501 tests (2465 + 36 new in `test/solution_tables.jl`).
  `docs/make.jl` builds clean.
- v0.10.1, committed and pushed (`7801238`): `src/comp/{node,edge,unit}/` is now
  auto-included by a `_include_dir` directory walk instead of ~19 explicit lines in
  `src/NetworkModelBuilder.jl`, and each component file exports its own public names next to their
  definition. Public API verified unchanged (`names(NetworkModelBuilder)` identical before/after,
  258 names).
- v0.10.0 (`security_tables`/`write_security_tables`) committed and pushed at `efc271c`/`4adad89`.
- All P0/P1 gap-closure items (#1-7) from `context/knowledge/plan/GAP_CLOSURE_PLAN.md` stay closed;
  #8 (D10) and #9 (D11) now closed too; #10-11 untouched — see `backlog.md`.
- Only tag in git history is `v0.6.0`; later versions are real untagged `Project.toml` states
  (see `decisions.md`).

## Branches

- `main` is one commit ahead of `origin/main` (`baa6c97`) with the D12 reorg above — not yet
  pushed; `git log --oneline -1` has the real local hash.
- Next free decision id: **D13**.

## In progress

- Nothing in progress. D12 is implemented and committed locally; push on request.

## Next

1. Push the D12 commit when asked.
2. Gap #10 (parallel rolling-horizon throughput) and #11 (bus factor) remain — see `backlog.md`.

## Blocked / waiting

- Gap #10 (parallel rolling-horizon throughput) needs a design decision before implementation
  (chunked-parallel vs. document-the-trade-off) — see `open-questions.md` Q1.

