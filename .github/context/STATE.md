# STATE

Overwrite, don't append. Keep under 80 lines. Last updated: 2026-10-07 by Tom Van Acker (B10 done).

## Where NMB stands

- v0.12.0 (D28-D36, tagged): one `Transformer`, see below. v0.11.0 (D13,
  D15-D27): the `Switch` edge. v0.10.2 (D11): `solution_tables` and `docs/src/manual/concepts.md`.
  v0.10.1 (D10): `src/comp/` is auto-included by a directory walk (`_include_dir`) and each
  component file exports its own names. v0.10.0: `security_tables`.
- Gap-closure items #1-9 of `context/knowledge/plan/GAP_CLOSURE_PLAN.md` are closed; #10-11 are
  open, see `backlog.md`. Tags: `v0.6.0`, `v0.9.1`-`v0.9.7` and `v0.12.0`; v0.10.x and v0.11.0 are untagged.

## Branches

- `main` carries B5 and B11 (`--no-ff`), tagged `v0.12.0`, and the setup commits D37-D41.
- `test-zorba-run` is `6cd0af1` (an earlier merge of `main`) plus 9 commits under `scripts/` (price
  rescale `4ef3472`, phases 0-3 `20d88dc`..`f939763`, `NMB_MERGE` `9a8b676`, original prices `76a52ce`
  D14, `_diag_*` deletion `9fc06d4`, window settings `3ea65d4`), `main` merged in (`420b1aa`), the B9
  loader change, `main` merged in again (`a2d8897`, B11), the B12 migration (`40dc645`) and D42
  (`ec4e49c`). Pushed up to `ec4e49c`; the B10 record is local.
- `b5-switch-edge` and `b11-unified-transformer` are merged and deleted. Next free decision id: **D45**.

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

- Agent setup runs on the second-brain plugin (D37-D41, SC6); a fresh chat must inject STATE (F1).
- B11 is merged and tagged `v0.12.0` (plan `context/knowledge/plan/unified-transformer.md`, D28-D36),
  suite 3126. Zorba flows are not unique without a phase shifter price (D34).
- B12 done: `scripts/` run on `Transformer`. Week 1 beside a same-day pre-B11 control, two pairs with
  the launch order swapped (`runs/_b12*`): 14 of 14 chunks sound, objectives equal to 8e-14, overload
  rows and volumes (3e-10 pu) equal to the control and `_week1_switches`; the new code is 1.0 % slower
  a chunk, in NMB's own work, not the solver.
- B10 done, full year (`runs/_year_b10`, 73 processes, 52 min, original prices D14, couplers as
  switches, one `Transformer`): 365 of 365 chunks sound, 0 fallback, no shedding or spillage. Overload
  rows 340,623 (step 2) and 5,719,307 (step 3) against 341,787 and 5,720,514 with the floor
  (`_year_orig_prices`); step 2's 0.34 % is 1,382 tiny overloads (median 2e-5 pu) against 218 of the
  same volume: total overload +0.010 % and +0.018 %, objectives per chunk median 1e-4, max 7e-4. Peak
  6.2 GB. `with_contingencies` fixed, the old script and `_diag_*` retired; see `lessons.md`.
- B9 done, week 1 (`runs/_week1_switches`): `load_network` loads the 21 couplers (reactance <
  `max_coupler_reactance` = 1e-6) as locked, closed `Switch`es, none in a contingency list; against the
  floor run `_phase5_week_orig` 7 of 7 chunks sound, objective +0.009 % and +0.018 %, flows within
  0.14 % of rating (spec: 2.2 %).
- Tom asked for 48 h windows committing 8 h in both steps; tried, and worse. They are settings now
  (`NMB_HORIZON_CB/STEP_CB/HORIZON_BE/STEP_BE`, defaults unchanged 8/8 and 1/1; the chunk must be at
  least as long as the horizon). `runs/_phase6_h48_probe`, hours 1-48: same results (objectives
  within 5e-11, identical overload rows) but 4,944 s against ~670 s, 27 GB, 6 builds per step; see
  `lessons.md`. Awaiting Tom: keep 8/8 and 1/1 (recommended).
- Run it with processes, not threads: 7 threads in one process give 860 s per 24 h chunk, 7 processes
  330-400 s; 30 threads no more throughput than 7. Recipe in the header of `scripts/run_year_redispatch.jl`.
  About 85% of a chunk's wall time is NMB's own per-window work (B6), not the solver.

## Next

1. B6, plan agreed. Item 1 (`same_structure` gates, D43, v0.12.1, `edaca89`): week 1 chunk time -26.2 %.
   Item 2 (feasibility check through MOI, `c7d26ac`): -16.5 % more, objectives bit-identical. Next: a
   cheaper `build_solution`, then a full-year run. Detail in `backlog.md`.
2. B7 (closed switches under network reduction), B8 (timing flake), B3 (throughput), B4 (bus factor),
   B13 and B19 remain, see `backlog.md`.

## Blocked / waiting

- Gap #10 (parallel rolling-horizon throughput) needs a design decision before implementation
  (chunked-parallel vs. document-the-trade-off) — see `open-questions.md` Q1.

