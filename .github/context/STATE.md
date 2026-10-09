# STATE

Overwrite, don't append. Keep under 80 lines. Last updated: 2026-10-09 by Tom Van Acker (B21 done on `b21-topology-lookup`, not merged).

## Where NMB stands

- v0.12.1-v0.12.5 (B6, B8, B21; v0.12.5 only on `b21-topology-lookup`, all untagged): rolling-horizon
  reuse and cheaper per-window work. v0.12.0 (D28-D36, tagged): one `Transformer`. v0.11.0 (D13,
  D15-D27): the `Switch` edge. v0.10.2 (D11): `solution_tables` and `docs/src/manual/concepts.md`.
  v0.10.1 (D10): `src/comp/` is auto-included by a directory walk (`_include_dir`) and each
  component file exports its own names. v0.10.0: `security_tables`.
- Gap-closure items #1-9 of `context/knowledge/plan/GAP_CLOSURE_PLAN.md` are closed; #10-11 are
  open, see `backlog.md`. Tags: `v0.6.0`, `v0.9.1`-`v0.9.7` and `v0.12.0`; v0.10.x and v0.11.0 are untagged.

## Branches

- `main` carries B5 and B11 (`--no-ff`), tagged `v0.12.0`, the setup commits D37-D41 and, merged `--no-ff`
  on 2026-10-07, all of `test-zorba-run`: `scripts/` (the Zorba pipeline), B9, B10, B12, B6, B8 (v0.12.4).
- `test-zorba-run` is merged into `main` and kept; the next Zorba change can start from `main`.
- `b5-switch-edge` and `b11-unified-transformer` are merged and deleted. Next free decision id: **D46**.
- `b21-topology-lookup` (v0.12.5, B21): 7 commits ahead of `main`, not merged, not pushed.

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

- Review of `main` (v0.12.4) against the Julia Modeling knowledge base: proposals only, no code changed.
  Plan `context/knowledge/plan/julia-guide-review.md`, backlog B21-B28, questions Q7-Q9. Measured: the
  topology lookup is 13 % and `build_solution` 19 % of a roll's wall; 11 of 11 invalid inputs are accepted.
- B21 done (v0.12.5, D45, plan `context/knowledge/plan/topology-lookup.md`): week 1 beside `main`, chunk
  -10.7 %, results bit-identical, `topology` 16 % of the wall to 1.7 %; one entry stays (stop rule not fired).
- Agent setup runs on the second-brain plugin (D37-D41, SC6); a fresh chat must inject STATE (F1).
- B11 is merged and tagged `v0.12.0` (plan `context/knowledge/plan/unified-transformer.md`, D28-D36),
  suite 3126. Zorba flows are not unique without a phase shifter price (D34).
- B12 done: `scripts/` run on `Transformer`. Week 1 beside a same-day pre-B11 control (`runs/_b12*`, two
  pairs): 14 of 14 chunks sound, objectives equal to 8e-14, overload rows and volumes (3e-10 pu) equal
  to the control; the new code is 1.0 % slower a chunk, in NMB's own work, not the solver.
- B10 done, full year (`runs/_year_b10`, 73 processes, 52 min, original prices D14, couplers as
  switches, one `Transformer`): 365 of 365 chunks sound, 0 fallback, no shedding or spillage. Overload
  rows 340,623 (step 2) and 5,719,307 (step 3) against 341,787 and 5,720,514 with the floor
  (`_year_orig_prices`); step 2's 0.34 % is 1,382 tiny overloads (median 2e-5 pu) against 218 of the
  same volume: total overload +0.010 % and +0.018 %, objectives per chunk median 1e-4, max 7e-4. Peak
  6.2 GB. `with_contingencies` fixed, the old script and `_diag_*` retired; see `lessons.md`.
- B6 done (v0.12.1-v0.12.3, D43, D44): a window reuses its model, the feasibility check reads rows through
  MOI, `nw_component` is generated, `Network.status` is typed. Full year `runs/_year_b6` against
  `_year_b10`: 24 min against 52 min, chunk mean 237 s against 549 s (-57 %), 365 of 365 sound, 0 fallback,
  objectives max 2.6e-8 (median 1e-14), overload rows equal, peak 7.3 GB (was 6.2). Rest: B20.
- Tom asked for 48 h windows committing 8 h in both steps; tried, and worse. They are settings now
  (`NMB_HORIZON_CB/STEP_CB/HORIZON_BE/STEP_BE`, defaults unchanged 8/8 and 1/1; the chunk must be at
  least as long as the horizon). `runs/_phase6_h48_probe`, hours 1-48: same results (objectives
  within 5e-11, identical overload rows) but 4,944 s against ~670 s, 27 GB, 6 builds per step; see
  `lessons.md`. Awaiting Tom: keep 8/8 and 1/1 (recommended).
- Run it with processes, not threads: 7 threads in one process give 860 s per 24 h chunk, 7 processes
  330-400 s; 30 threads no more throughput than 7. Recipe in the header of `scripts/run_year_redispatch.jl`.
  About 85% of a chunk's wall time is NMB's own per-window work, not the solver (B6: 549 s to 237 s a chunk).

## Next

1. Tom reviews `b21-topology-lookup`, then merge. B22 and B25 next (measured, no API change, the review's
   order), then B23, B24, B26, B27. B20 keeps the rest of the per-window cost; B7, B3, B4, B13, B19, B28
   remain, see `backlog.md`.

## Blocked / waiting

- Q7 (exports), Q8 (tags) and Q9 (typed solution) wait for Tom; B22 item (b) and B24 item (b) need them.
- Gap #10 (parallel rolling-horizon throughput) needs a design decision before implementation
  (chunked-parallel vs. document-the-trade-off) — see `open-questions.md` Q1.

