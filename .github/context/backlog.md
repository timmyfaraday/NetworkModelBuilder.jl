# Backlog

One line per item: `- [ ] B<n> · <what> · owner · added YYYY-MM-DD` plus an optional indented note.
Move items between sections; tick and move to Done when finished (keep the last ~10 done, delete
older ones: git has them). Next id: **B20**.

## Now

- (nothing)

## Next

- (nothing)

## Later

- [ ] B15 · Plugin PR: make `new-spec`, `new-run-prompt`, `review-run-report`, `probe-environment` and
  `pr-description` project-neutral, so NMB's five overrides in `.github/skills/` can be deleted (D37)
  · Tom · 2026-10-07
  - What NMB's versions have that the plugin's lack: spec and run folders from `conventions.md` or
    `hook_config.json` (`knowledge/plan/`, `agent-runs/`, not `specs/`, `runs/`); the reference-
    implementation checks; probe steps that follow the repo's language (Julia/juliaup/threads here);
    a PR skill that does not assume Azure DevOps (4,000 characters, mypy/ruff/lint-imports).
- [ ] B16 · Plugin PR: a `hook_config.json` key to turn off the "no .venv" note in `launch.py`, then
  delete the empty `.venv` (D39) · Tom · 2026-10-07
- [ ] B17 · When the package moves internal: add `.github/copilot/settings.json` from the plugin's
  template and drop the public-repo caution (D38) · Tom · 2026-10-07
- [ ] B3 · No parallel-throughput option for long-horizon solves (gap #10, P2/Large) · Tom · 2026-09-30
  - Needs a design decision first (chunked-parallel vs. document-the-trade-off) — see
    `open-questions.md` Q1.
- [ ] B6 · Cut NMB's per-window overhead in rolling-horizon solves: ~85% of a Zorba chunk is
  `update_model!` (~3 s/window), `build_solution` (~1 s) and allocation/GC, not the solver · Tom · 2026-10-02
  - Measured, cause of the loss of thread scaling not proven. Profile one window under `-t 1` first.
    Relates to B3. Longer windows do not help: the overhead follows the hour-states solved, not the
    number of windows (`lessons.md`, Performance), so the target is the cost per hour-state.
  - 2026-10-07, one window of step 3 (80 indices): build 4.2-4.8 s, the agent's feasibility check 2-3 s,
    `build_solution` 1.0-1.4 s, solve 1.4 s, GC 1.2-2.8 s, 2.2 GB allocated. No window ever reuses its
    model: the year built 1095 of 1095 (step 2) and 8353 of 8760 (step 3), because `same_structure`
    reads a generator's `pmin`/`pmax` crossing +-pi/2 as a change of shape.
  - Plan agreed 2026-10-07 (Tom): full scope, in order: `same_structure` gates (D43, v0.12.1), a cheaper
    feasibility check in `scripts/ParallelRun.jl` (D44), a cheaper `build_solution` (v0.12.2), then a
    re-measure and a full-year run. Accepted when the objective of every chunk equals the control's
    within 1e-7 relative (an equal optimum, not equal unit volumes), with 0 fallbacks.
  - Item 1 done (`edaca89`, v0.12.1), 2026-10-07. Week 1 beside a same-day control (`runs/_b6i1a*`,
    `_b6i1b*`, two pairs, launch order swapped): 14 of 14 chunks sound, 0 fallbacks, objectives within
    4.1e-10 (the rest 1e-14), `built` 1 of 3 (step 2) and 1 of ~23 (step 3) against 3 and ~23, chunk
    254 s against 344 s (-26.2 %, every chunk -20 to -32 %; predicted -15 %), step 3 solver 16-24 s
    against 45-105 s (the basis is kept). Largest unit-hour volume difference 1e-10 pu, except one
    step-2 unit-hour in chunk 121-144 (1.25e-2 pu, equal objective: another optimum).
  - Item 2 done (`c7d26ac`, scripts only), 2026-10-07. `worst_violation` reads every row through MOI
    instead of `primal_feasibility_report`: 2.24 s to 0.45 s a step-3 window, 1.35 s to 0.30 s a step-2
    window; same violation on 27 solved windows, on 27 perturbed points, on a moved row (0.7), a cut
    bound (0.25) and a HiGHS window. Week 1 (`runs/_b6i2a*`, `_b6i2b*`, two pairs, launch order swapped,
    control = item 1): 14 of 14 sound, 0 fallbacks, objectives and unit volumes bit-identical, chunk
    213 s against 255 s (-16.5 %, every chunk -13 to -18 %; predicted -18 %).
  - Item 3 as planned (read all values in bulk) fails its stop rule, 2026-10-07: `JuMP.value` over all
    249,118 variables of a step-3 window takes 0.07 s of the 1.0 s `build_solution`. A roll still spends
    5.7 s of its own per window (update 35 %, `build_solution` 14 %, solve 7 %). Profile of a whole roll:
    `has_nw_data` 12 % (a `getfield` with a runtime index inside `any`, called by `nw_component` for every
    component of every network index), `topology` 18 % (`_signature` re-reads the status of every
    switchable component on each call, through an abstract `Dict` value). Prototype of generated
    `has_nw_data` and `nw_component` (scratch only): own work 5.68 s to 4.75 s a window, `build_solution`
    1.13 s to 0.93 s, window solutions `isequal`. Revised item 3 proposed to Tom, not started.
  - Item 3 revised and done, 2026-10-07 (Tom: two versions). 3a v0.12.2 (`aa33f8d`): generated
    `has_nw_data`/`nw_component`; 3b v0.12.3 (`5ea1a26`): `Network.status`, typed, for `_signature`. Suite
    3142 of 3142 for 3b (3a: one `lf.jl:124` timer flake, B8, then 3 of 3 passes alone). Week 1 beside a
    control, two pairs each, launch order swapped (`runs/_b6i3a*`, `_b6i3b*`): 14 of 14 sound, 0 fallbacks,
    objectives and unit volumes bit-identical; 3a chunk 180 s against 208 s (-13.6 %, predicted -10 %), 3b
    152 s against 180 s (-15.6 %, predicted -12 %); step-3 non-solver 140 s to 113 s a chunk.
  - B12 measured the one `Transformer` at +1.0 % a chunk against the old types, all non-solver time.
    Candidate, not measured: `nw_component` rebuilds a `Transformer` through its validating constructor
    for every network index.
- [ ] B4 · Bus factor: solo maintainer, get a second reviewer/co-committer (gap #11, P3/Large) · Tom · 2026-09-30
- [ ] B13 · A `Transformer` constructor from datasheet values (winding resistances, pairwise short-circuit
  reactances, no-load power) and a mesh instead of a star for four or more windings · Tom · 2026-10-05
  - Claeys et al. 2020, Algorithm 1; follows B11 (D30).
- [ ] B7 · Revisit closed switches as equality rows (D17) in the context of network reduction, where a
  closed switch would merge its nodes · Tom · 2026-10-04
- [ ] B8 · `test/lf.jl:124` (`solve_time > 0.0`) fails now and then on Windows: `time()` has a coarse
  resolution and case14 solves faster; seen once in a full run, passes alone. Likely `>= 0.0` · Tom · 2026-10-04
- [ ] B19 · Re-evaluate the per-window feasibility check (`worst_violation`) once the pipeline has proven
  stable: sample it or drop it · Tom · 2026-10-07
  - D44 keeps it for now. It cost 2.4 s of 9.6 s a step-3 window, 0.45 s since B6 item 2; 365 of 365
    chunks of `_year_b10` had a first violation of 0.

## Done

- [x] B10 · Re-run the full year on `test-zorba-run` with the couplers as switches and the one
  `Transformer` · Tom · 2026-10-05
  - `runs/_year_b10`, 73 processes, 52 min: 365 of 365 sound, 0 fallback; step 3 rows -0.02 %, step 2
    rows -0.34 % (predicted 0.1 %) but total overload +0.010 % / +0.018 % (STATE.md, lessons.md).
- [x] B18 · `scripts/NMinusOneScreen.jl`: deleted (D42), it skipped about 3 % of hours and could not run on
  the data with `Switch`es · Tom · 2026-10-07
- [x] B12 · `test-zorba-run`'s scripts on `Transformer`, then week 1 beside a same-day control · Tom ·
  2026-10-05
  - `40dc645`; `runs/_b12_new` against `runs/_b12_control`: 7 of 7 sound, objectives within 8e-14,
    overload rows equal, volumes within 3e-10 pu; chunks 1.0 % slower, pooled over two pairs with the
    launch order swapped (STATE.md).
- [x] B11 · One `Transformer` for every transformer (windings, tap changer, phase shifter), replacing
  `TapChanger`, `PhaseShifter` and `MultiWindingTransformer` · Tom · 2026-10-05
  - Plan `knowledge/plan/unified-transformer.md` (D28-D36), branch `b11-unified-transformer`, v0.12.0,
    6 commits, suite 3126. Merged into `main`, pushed, tagged `v0.12.0` on the merge.
- [x] B14 · A preventive phase shifter set at exactly zero stopped Ipopt in the current-based
  redispatch: the tie and each state's magnitude row were dependent. A held measure now builds no
  restricting rows of its own (D35); reusing the base case's binaries is D36 · Tom · 2026-10-06
- [x] B9 · On `test-zorba-run`, load the couplers as locked-closed `Switch`es, drop the 1e-5
  reactance floor, re-run week 1 and compare · Tom · 2026-10-05
  - `scripts/SteeringPlanData.jl`; `runs/_week1_switches` against `runs/_phase5_week_orig`: 7 of 7
    sound, 0 violation, objective +0.009 % / +0.018 %, flows within 0.14 % of rating (STATE.md).
- [x] B5 · A `Switch` edge type, replacing near-zero-impedance couplers · Tom · 2026-10-02
  - v0.11.0, branch `b5-switch-edge`, D13 and D15-D26; spec `knowledge/plan/switch-edge.md`.
    Busbar switch and circuit breaker (D19) are not built.
- [x] B0 · Adopt this `.github/` agent setup, ported from a colleague's FlowBasedDomains repo and
  adapted for Julia/GitHub/solo maintainer · Tom · 2026-09-30
- [x] B1 · Central include/export file is a growing manual-edit tax (gap #8) · Tom · 2026-09-30
  - `src/comp/` auto-discovered by `_include_dir`, each component exports its own names — see D10.
- [x] B2 · API ergonomics / onboarding curve vs. SmaLoadFlow (gap #9) · Tom · 2026-09-30
  - `solution_tables` alongside `nw_solution`, plus a `concepts.md` newcomer page — see D11.
