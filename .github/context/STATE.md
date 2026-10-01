# STATE

Overwrite, don't append. Keep under 80 lines. Last updated: 2026-10-01 by Tom Van Acker (Xpress
false-INFEASIBLE finding on the Zorba pipeline, see `lessons.md`).

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

- `main` is in sync with `origin/main` at `5318428` (D12) — already pushed (this was stale here;
  see `setup-feedback.md` F2).
- `test-zorba-run` (standalone `scripts/` env running the three-step redispatch pipeline against
  real steering-plan data) merged up to date with `main` and pushed: `6cd0af1`. Conflicts resolved
  in main's favor for `.github/copilot-instructions.md`/`.vscode/settings.json` (branch's own
  Sept-15 versions predated this setup); dropped the branch's now-superseded
  `.github/agents/`/`.github/clean-code.instructions.md`/`.github/prompts/`. `scripts/` itself
  untouched. Full suite (2502 tests) and `docs/make.jl` verified green post-merge.
- Next free decision id: **D13**.

## In progress

- Zorba three-step redispatch pipeline (`test-zorba-run` branch, `scripts/`, not on `main`):
  diagnosing why step 3 (internal-BE redispatch) reports hour 61 `INFEASIBLE` under Xpress.
  Confirmed it is a false positive — HiGHS solves the identical model `OPTIMAL` — see `lessons.md`.
  Next: investigate Xpress scaling/tolerance controls (option chosen over rescaling the model or a
  standing HiGHS cross-check). `scripts/Project.toml`/`Manifest.toml` have an uncommitted,
  stashed HiGHS addition from this diagnosis on `test-zorba-run`.

## Next

1. Gap #10 (parallel rolling-horizon throughput) and #11 (bus factor) remain — see `backlog.md`.

## Blocked / waiting

- Gap #10 (parallel rolling-horizon throughput) needs a design decision before implementation
  (chunked-parallel vs. document-the-trade-off) — see `open-questions.md` Q1.

