# STATE

Overwrite, don't append. Keep under 80 lines. Last updated: 2026-10-09 by Tom Van Acker (B25 done on `b25-guard-rails`, not merged).

## Where NMB stands

- v0.12.1-v0.12.7 (B6, B8, B21, B22, B25; v0.12.5 and v0.12.6 tagged, v0.12.7 on `b25-guard-rails`, the others
  not): rolling-horizon reuse, cheaper per-window work, guard rails. v0.12.0 (D28-D36, tagged): one `Transformer`.
  v0.11.0 (D13, D15-D27): the `Switch` edge. v0.10.2 (D11): `solution_tables`, `docs/src/manual/concepts.md`.
  v0.10.1 (D10): `src/comp/` is walked, not listed, and each component file exports its own names.
- Gap-closure items #1-9 of `context/knowledge/plan/GAP_CLOSURE_PLAN.md` are closed; #10-11 are open
  (`backlog.md`). Tags: `v0.6.0`, `v0.9.1`-`v0.9.7`, `v0.12.0`, `v0.12.5`, `v0.12.6`; not v0.10.x, v0.11.0, v0.12.1-4.

## Branches

- `main` carries B5 and B11 (`--no-ff`), tagged `v0.12.0`, the setup commits D37-D41 and, merged `--no-ff`
  on 2026-10-07, all of `test-zorba-run`: `scripts/` (the Zorba pipeline), B9, B10, B12, B6, B8 (v0.12.4);
  on 2026-10-09 B21 (v0.12.5), the Julia guide review and B22 (v0.12.6), both tagged and pushed.
- `test-zorba-run` is merged into `main` and kept; the next Zorba change can start from `main`.
- `b5-switch-edge`, `b11-unified-transformer` merged and deleted; `b21-topology-lookup`, `b22-build-solution`
  merged, kept; `b25-guard-rails` holds B25 (v0.12.7), not merged. Next free decision id: **D48**.

## Done: B5, the `Switch` edge type (v0.11.0)

- A `Switch` has a `lock` (`SwitchLock`, free or locked) and a `position` (D15, D25); a locked one
  writes exact rows, a free one a binary `zsw` and big-M rows, so a dispatch with free switches is
  mixed-integer with no duals (D16, D17, D23). Both formulations; Juniper is a test dependency.
  Closed locked switches in a loop share the flow, and a loop free switches can close gets a
  loop row, at most 1000 (D21, D26). A free switch is preventive or corrective, non-costly (D18).
- `islands`, `check_islands`, `connects`, `can_open`: an island needs a reference node or a source;
  opening every free switch may not island unless `islanding = :allow` (D22).
- Checked against PowerModels.jl's `_solve_opf_sw`/`_solve_oswpf` in `test/powermodels.jl`: equal
  except a closed loop, where PowerModels.jl leaves the flow free. Docs page
  `docs/src/components/switch.md`, cited through DocumenterCitations (D27). To run one test file use
  `scratch/switch_spike/run_tests.jl <files in runtests order>` (`hierarchy.jl` has helpers).

## In progress

- Julia guide review (plan `context/knowledge/plan/julia-guide-review.md`, B21-B28, Q7-Q9): B21 done and
  merged (v0.12.5, D45), week 1 chunk -10.7 %, results bit-identical.
- B22 done (v0.12.6, D46, tagged): a roll builds the committed indices, `report` names families and identifiers.
  Week 1 against `main` (`runs/_b22_*`): objectives bit-identical, chunk -12.3 %, peak 5.0 to 2.9 GB. Stop rule at
  its line: `build_solution` 7.8-9.3 % of a step-3 roll, ~6 % of a chunk (Q9); volume file row order (B29).
- B25 done on `b25-guard-rails` (v0.12.7, D47), not merged; tests and tooling only, suite 3223: `test/hot_path.jl`,
  `benchmark/window.jl`, six GC columns in `chunk.csv`. Week 1, 7 threads against 7 processes (`runs/_b25_*`): 224 s
  against 125 s a chunk, GC 14.4 % against 14.2 %: the collector is not what threads lose to (`lessons.md`).
- Agent setup runs on the second-brain plugin (D37-D41, SC6); a fresh chat must inject STATE (F1).
- B11 merged, tagged `v0.12.0` (`unified-transformer.md`, D28-D36); Zorba flows are not unique without a phase shifter price (D34).
- B12 done: `scripts/` run on `Transformer`. Week 1 beside a same-day pre-B11 control (`runs/_b12*`, two
  pairs): 14 of 14 chunks sound, objectives equal to 8e-14, overload rows and volumes (3e-10 pu) equal
  to the control; the new code is 1.0 % slower a chunk, in NMB's own work, not the solver.
- B10 done, full year (`runs/_year_b10`, 73 processes, 52 min, original prices D14, couplers as
  switches, one `Transformer`): 365 of 365 chunks sound, 0 fallback, no shedding or spillage; total
  overload +0.010 % (step 2) and +0.018 % (step 3) against the floor run `_year_orig_prices`, objectives
  per chunk median 1e-4. Peak 6.2 GB. `with_contingencies` fixed, the old script and `_diag_*` retired.
- B6 done (v0.12.1-v0.12.3, D43, D44): a window reuses its model, the feasibility check reads rows through
  MOI, `nw_component` is generated, `Network.status` is typed. Full year `runs/_year_b6` against
  `_year_b10`: 24 min against 52 min, chunk mean 237 s against 549 s (-57 %), 365 of 365 sound, 0 fallback,
  objectives max 2.6e-8 (median 1e-14), overload rows equal, peak 7.3 GB (was 6.2). Rest: B20.
- Tom asked for 48 h windows committing 8 h in both steps; tried, and worse (4,944 s against ~670 s, 27 GB,
  same results; `runs/_phase6_h48_probe`, `lessons.md`). The windows are settings now (`NMB_HORIZON_CB/
  STEP_CB/HORIZON_BE/STEP_BE`, defaults 8/8 and 1/1). Awaiting Tom: keep 8/8 and 1/1 (recommended).
- Run it with processes, not threads: 7 threads in one process give 224 s per 24 h chunk, 7 processes 125 s (week 1,
  B25; recipe in the header of `scripts/run_year_redispatch.jl`). NMB's own per-window work is ~85 % of a chunk.

## Next

1. Tom to merge B25 (tag and push on his word), then B23, B24, B26, B27 (the review's order). B20 keeps the rest of
   the per-window cost; B7, B3, B4, B13, B19, B28, B29 remain, see `backlog.md`.

## Blocked / waiting

- Q7 (exports) and Q8 (tags) wait for Tom, Q9 (typed solution) waits on B22's stop rule, which sits at its
  threshold: Tom decides (`open-questions.md`); B24 item (b) too.
- Gap #10 (parallel rolling-horizon throughput) needs a design decision before implementation
  (chunked-parallel vs. document-the-trade-off) — see `open-questions.md` Q1.

