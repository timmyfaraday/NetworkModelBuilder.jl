# STATE

Overwrite, don't append. Keep under 80 lines. Last updated: 2026-10-02 by Tom Van Acker (Zorba
year run finished, 365 of 365 chunks sound).

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

- `main` is 5 commits ahead of `origin/main` (`c966558`) recording the Zorba work's lessons and
  D13 — not yet pushed; `git log --oneline -1` has the real local hash. The context files are kept
  current on `main` only; `test-zorba-run` lags them.
- `test-zorba-run` is `6cd0af1` (a merge of `main`) plus 6 local commits, none pushed, all under
  `scripts/`: the price rescale (`4ef3472`), phases 0-3 (`20d88dc`, `f7571aa`, `e100616`,
  `f939763`: hour ids, parallel step 1, the N-1 screen, parallel steps 2-3 with the contingency fix,
  the reactance floor and checked solves) and the driver's `NMB_MERGE` flag (`9a8b676`).
- Next free decision id: **D14**.

## In progress

- Zorba three-step redispatch, full year (`test-zorba-run`, `scripts/`): DONE. 365 of 365 daily
  chunks `OPTIMAL` and violation-free, 0 on the HiGHS fallback, in 63 min as 73 one-thread processes
  (`runs/_year_full`, gitignored). Reactance floor 1e-5 applied (D13), `with_contingencies` fixed, the
  N-1 screen dropped (it skips ~3% of hours). The week reproduces the sequential baseline to solver
  tolerance (objective rel diff 1e-12). Year totals: 129,109 step-1 congestion rows, 352,540 step-2 and
  5,953,226 step-3 overload rows, 0 load-shedding rows, 635 spillage rows. Lessons: `lessons.md`.
- Run it with processes, not threads: 7 threads in one process give 860 s per 24 h chunk, 7
  processes 330-400 s, and 30 threads no more throughput than 7. Recipe in the header of
  `scripts/run_year_redispatch.jl`. About 85% of a chunk's wall time is NMB's own per-window work
  (B6), not the solver.

## Next

1. The year-scale Zorba work is finished: raise B5 (the `Switch` edge type) with Tom now, without
   being asked — he asked to be triggered. See D13.
2. Q2 and Q3 (restore the original last-resort prices? retire `run_three_step_redispatch.jl`?).
3. Gap #10 (parallel rolling-horizon throughput) and #11 (bus factor) remain — see `backlog.md`.

## Blocked / waiting

- Gap #10 (parallel rolling-horizon throughput) needs a design decision before implementation
  (chunked-parallel vs. document-the-trade-off) — see `open-questions.md` Q1.

