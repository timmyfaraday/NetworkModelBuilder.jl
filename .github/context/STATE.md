# STATE

Overwrite, don't append. Keep under 80 lines. Last updated: 2026-10-03 by Tom Van Acker (original
Zorba prices restored, D14; year re-run started).

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
- `test-zorba-run` is `6cd0af1` (a merge of `main`) plus 9 local commits, none pushed, all under
  `scripts/`: the price rescale (`4ef3472`), phases 0-3 (`20d88dc`, `f7571aa`, `e100616`,
  `f939763`: hour ids, parallel step 1, the N-1 screen, parallel steps 2-3 with the contingency fix,
  the reactance floor and checked solves), the driver's `NMB_MERGE` flag (`9a8b676`), and the
  restored prices plus the retirement of the sequential script (`76a52ce`, D14), the `_diag_*`
  deletion (`9fc06d4`) and the window/step settings (`3ea65d4`).
- Next free decision id: **D15**.

## In progress

- Zorba three-step redispatch, full year (`test-zorba-run`, `scripts/`): run with the rescaled prices
  (`runs/_year_full`, gitignored): 365 of 365 daily chunks `OPTIMAL`, 0 fallback, 63 min as 73
  one-thread processes. Tom then restored the original prices (D14); week 1 with them is sound too
  (`runs/_phase5_week_orig`, 7 of 7, 444 s). The year with them is DONE as `runs/_year_orig_prices`:
  365 of 365 chunks sound, 0 fallback, 58 min (chunks 333-817 s, mean 616 s). Overload rows
  341,787 (step 2) and 5,720,514 (step 3), 0 load shedding, 0 spillage; with the rescaled prices
  (`_year_full`) 352,540, 5,953,226, 0 and 635. Step-1 congestion is 129,109 rows either way. The
  summed objectives are ~3x larger (1.68e11 / 2.87e11 against 5.3e10 / 8.8e10), consistent with
  priced overload dominating them. Reactance floor 1e-5 (D13), `with_contingencies` fixed, N-1
  screen dropped (skips ~3% of hours), `run_three_step_redispatch.jl` and the `_diag_*` scripts
  retired. See `lessons.md`.
- Tom asked for 48 h windows committing 8 h in both steps. Now settings, defaults unchanged 8/8 and
  1/1: `NMB_HORIZON_CB/STEP_CB/HORIZON_BE/STEP_BE`; the chunk must be at least as long as the
  horizon. Probe `runs/_phase6_h48_probe` (one 48 h chunk, machine fully loaded): step 2 gives the
  same objective (relative 1.7e-11) but takes 578 s wall / 290 s solver against ~123 s / 40 s for
  the 8 h windows; step 3 was past 45 min and 20 GB. A clean week-1 timing run is next.
- Run it with processes, not threads: 7 threads in one process give 860 s per 24 h chunk, 7
  processes 330-400 s, and 30 threads no more throughput than 7. Recipe in the header of
  `scripts/run_year_redispatch.jl`. About 85% of a chunk's wall time is NMB's own per-window work
  (B6), not the solver.

## Next

1. The year re-run is checked: start B5 (the `Switch` edge type) — Tom asked to be triggered
   (D13); raised 2026-10-02 and 2026-10-03, not answered yet.
2. Gap #10 (parallel rolling-horizon throughput) and #11 (bus factor) remain — see `backlog.md`.

## Blocked / waiting

- Gap #10 (parallel rolling-horizon throughput) needs a design decision before implementation
  (chunked-parallel vs. document-the-trade-off) — see `open-questions.md` Q1.

