# STATE

Overwrite, don't append. Keep under 80 lines. Last updated: 2026-10-04 by Tom Van Acker (commit 3
of the Switch plan, islands, on `b5-switch-edge`).

## Where NMB stands

- Specs/plans live in `context/knowledge/plan/` (D12).
- v0.10.2 (D11): `solution_tables` and `docs/src/manual/concepts.md`. v0.10.1 (D10): `src/comp/` is
  auto-included by a directory walk (`_include_dir`) and each component file exports its own names;
  the public API was checked unchanged (258 names). v0.10.0: `security_tables`.
- Gap-closure items #1-9 of `context/knowledge/plan/GAP_CLOSURE_PLAN.md` are closed; #10-11 are
  open, see `backlog.md`. The only tag is `v0.6.0`; later versions are untagged `Project.toml` states.

## Branches

- `main` and `test-zorba-run` were pushed to `origin` on 2026-10-03, nothing local ahead.
  `git log --oneline -1` has the real hash. The context files are kept current on `main` only;
  `test-zorba-run` lags them.
- `test-zorba-run` is `6cd0af1` (a merge of `main`) plus 9 commits, all under `scripts/`: the price
  rescale (`4ef3472`), phases 0-3 (`20d88dc`, `f7571aa`, `e100616`, `f939763`: hour ids, parallel
  step 1, the N-1 screen, parallel steps 2-3 with the contingency fix, the reactance floor and
  checked solves), the driver's `NMB_MERGE` flag (`9a8b676`), and the restored prices plus the
  retirement of the sequential script (`76a52ce`, D14), the `_diag_*` deletion (`9fc06d4`) and the
  window/step settings (`3ea65d4`).
- `b5-switch-edge` is the branch for B5, created from `main` on 2026-10-03.
- Next free decision id: **D26**.

## In progress

- B5, the `Switch` edge type (D13, D15-D25), on branch `b5-switch-edge`, ships as v0.11.0; spec
  `knowledge/plan/switch-edge.md`. Commits 1-3 of 9 are done: `variable!` takes `binary` and an
  integer is a structure gate (`9f88d73`); the `Switch` type (`29a11b3`), with `cbc4ed3`, a fix so
  that a new component file is not missed by the compiled package; `islands`, `check_islands` and
  `constraint_node_voltage_anchor` (`28f65ea`, D22: `connects`/`can_open` are the edge hooks, a
  source is a generator, storage or `EnergyNotServed`, `islanding = :allow` skips only the
  free-switch check). Full suite 2622 with 1 timing flake (B8). Next is commit 4, the locked
  switch in the linearized formulation. The Zorba scripts stay on `test-zorba-run`. To run one test
  file use `scratch/switch_spike/run_tests.jl <files in runtests order>` (`hierarchy.jl` has helpers).
- Zorba three-step redispatch, full year (`test-zorba-run`, `scripts/`), done with the original
  prices (D14): `runs/_year_orig_prices`, 365 of 365 chunks sound, 0 fallback, 58 min; overload rows
  341,787 (step 2) and 5,720,514 (step 3), no load shedding or spillage (the rescaled-price run
  `_year_full` had 352,540, 5,953,226, 0 and 635). Reactance floor 1e-5 (D13), `with_contingencies`
  fixed, N-1 screen dropped, the old script and `_diag_*` retired. See `lessons.md`.
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

1. B5: implement `switch-edge.md` on `b5-switch-edge`. When it exists, drop the 1e-5
   reactance floor from `scripts/SteeringPlanData.jl` and re-run week 1 to compare.
2. Gap #10 (parallel rolling-horizon throughput) and #11 (bus factor) remain — see `backlog.md`.

## Blocked / waiting

- Gap #10 (parallel rolling-horizon throughput) needs a design decision before implementation
  (chunked-parallel vs. document-the-trade-off) — see `open-questions.md` Q1.

