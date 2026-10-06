# STATE

Overwrite, don't append. Keep under 80 lines. Last updated: 2026-10-06 by Tom Van Acker (B11: commit 6,
docs and 0.12.0, is in; the branch is complete and not merged).

## Where NMB stands

- v0.12.0 (D28-D36, on `b11-unified-transformer`): one `Transformer`, see below. v0.11.0 (D13,
  D15-D27): the `Switch` edge. v0.10.2 (D11): `solution_tables` and `docs/src/manual/concepts.md`.
  v0.10.1 (D10): `src/comp/` is auto-included by a directory walk (`_include_dir`) and each
  component file exports its own names. v0.10.0: `security_tables`.
- Gap-closure items #1-9 of `context/knowledge/plan/GAP_CLOSURE_PLAN.md` are closed; #10-11 are
  open, see `backlog.md`. Tags: `v0.6.0` and `v0.9.1`-`v0.9.7`; v0.10.x and v0.11.0 are untagged.

## Branches

- `main` carries B5 (`git log --oneline -1` has the hash); `test-zorba-run` has the B9 loader change.
- `test-zorba-run` is `6cd0af1` (an earlier merge of `main`) plus 9 commits, all under `scripts/`: the
  price rescale (`4ef3472`), phases 0-3 (`20d88dc`, `f7571aa`, `e100616`, `f939763`: hour ids, parallel
  steps, N-1 screen, contingency fix, reactance floor), the `NMB_MERGE` flag (`9a8b676`), restored
  prices (`76a52ce`, D14), the `_diag_*` deletion (`9fc06d4`), the window/step settings (`3ea65d4`),
  then `main` merged in (`420b1aa`, so it has B5) and the B9 loader change in `SteeringPlanData.jl`.
- `b11-unified-transformer` is `main` (`01122bd`), the plan and decisions, and the 6 commits of the plan.
- `b5-switch-edge` is merged and can be deleted. Next free decision id: **D37**.

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

- B11 is done on `b11-unified-transformer` (plan `context/knowledge/plan/unified-transformer.md`, D28-D36):
  one `Transformer` with a T-model, `oltc`/`pst` as `TapMode`, `STEPPED` windings, `is_held`; old types
  gone, no shims. Docs, `CHANGELOG.md` (with a migration table) and `version = "0.12.0"` are in.
  Suite 3126, docs build clean. Not merged, not tagged. Zorba flows are not unique (D34).
- Zorba three-step redispatch, full year (`test-zorba-run`, `scripts/`), done with the original
  prices (D14) and the 1e-5 floor: `runs/_year_orig_prices`, 365 of 365 chunks sound, 0 fallback, 58
  min; overload rows 341,787 (step 2) and 5,720,514 (step 3), no load shedding or spillage (the
  rescaled-price run `_year_full` had 352,540, 5,953,226, 0 and 635). `with_contingencies` fixed,
  N-1 screen dropped, the old script and `_diag_*` retired. See `lessons.md`.
- B9 done, week 1 (`runs/_week1_switches`, 7 processes): `load_network` loads the 21 couplers (reactance
  < `max_coupler_reactance` = 1e-6, all 1e-7) as locked, closed `Switch`es, no reactance floored. Against
  the floor run `runs/_phase5_week_orig`: 7 of 7 chunks sound, 0 fallback, 0 violation, no shedding or
  spillage, objective +0.009 % (step 2) and +0.018 % (step 3), overload rows 7,718 against 7,729 and
  127,323 against 127,368, step 1 flows on the 2,853 congested rows within 0.14 % of rating (spec:
  2.2 %); chunks 376 s against 358 s, which was the machine's (`lessons.md`). `check_islands` passes.
- Tom asked for 48 h windows committing 8 h in both steps; tried, and worse. They are settings now
  (`NMB_HORIZON_CB/STEP_CB/HORIZON_BE/STEP_BE`, defaults unchanged 8/8 and 1/1; the chunk must be at
  least as long as the horizon). `runs/_phase6_h48_probe`, hours 1-48: same results (objectives
  within 5e-11, identical overload rows) but 4,944 s against ~670 s, 27 GB, 6 builds per step; see
  `lessons.md`. Awaiting Tom: keep 8/8 and 1/1 (recommended).
- Run it with processes, not threads: 7 threads in one process give 860 s per 24 h chunk, 7
  processes 330-400 s, and 30 threads no more throughput than 7. Recipe in the header of
  `scripts/run_year_redispatch.jl`. About 85% of a chunk's wall time is NMB's own per-window work
  (B6), not the solver.

## Next

1. Merge B11 and tag `v0.12.0` (Tom's OK), then B12: move `test-zorba-run` to `Transformer`.
2. B10: re-run the full year with the switches (`_year_orig_prices` has the floor), recipe in the
   header of `scripts/run_year_redispatch.jl`.
3. B7 (closed switches under network reduction), B8 (timing flake), B3/B6 (throughput) and B4
   (bus factor) remain, see `backlog.md`.

## Blocked / waiting

- Gap #10 (parallel rolling-horizon throughput) needs a design decision before implementation
  (chunked-parallel vs. document-the-trade-off) — see `open-questions.md` Q1.

