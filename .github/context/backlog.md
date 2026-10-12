# Backlog

One line per item: `- [ ] B<n> · <what> · owner · added YYYY-MM-DD` plus an optional indented note.
Move items between sections; tick and move to Done when finished (keep the last ~10 done, delete
older ones: git has them). Next id: **B43**.

## Now

## Next

- [ ] B41 · `print_summary` fails on a linearized result: it reads `q_unit`, which `LPFFormulation` does not write (`KeyError`) · Tom · 2026-10-12
  - Found by a B35 test; the docs only print current based results. Either skip the column or write a zero.

- [ ] B42 · Building a model is not linear in the time steps: 2000 quarter-hour steps take 1.1 s, 35040 take 111 s, with a cycle limit or without one · Tom · 2026-10-12
  - Found timing B38 (`%LOCALAPPDATA%\Temp\nmb_b33\time_cycle.jl`, `instantiate_model` of one battery, one generator, one load over a year of 15-minute steps). The cycle rows are not the cause (110.8 s with them, 114.8 s without). Profile `instantiate_model` on it before guessing: `energy_at`, `_serves`, `ids` per step and `topology` are the suspects.

## Later

- [ ] B39 · Detailed battery physics and self-discharge, a storage ramp limit (D77) · Tom · 2026-10-12
  - Fortenbacher et al. 2017 (loss curve, rate capacity, degradation map); Li 2016, Wang 2023, Zafar 2020 (self-discharge); Qin et al. 2025 (ramp).
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
- [ ] B20 · Cut the rest of the per-window cost of a rolling horizon · Tom · 2026-10-07
  - After B6 a step-3 roll spends its own time on `update_model!` 26 %, `build_solution` 19 %, the solve
    12 %, `_signature` 11 % (profile of 8 windows, 29.6 s; `scratch/b6_roll_profile.jl`). `_signature` still
    builds a `BitVector` bit by bit for every node, edge and unit lookup of every network index; a packed
    status matrix read by column would not tabulate topologies, but check it against the invariant first.
    `build_solution` is dominated by building the result `Dict`s, not by reading values (0.07 s of 0.7 s).
    Candidate, now measured and closed: `nw_component` takes 0.01 s for the 53,112 resolutions of a step-3
    window (`build-solution.md`), so no unchecked constructor. The first two moves are B21 (done,
    `_signature` now 0.6 % of the samples) and B22 (done, `build_solution` now 7.8-9.3 % of a step-3 roll).
  - Peak memory per process rose from 6.2 GB to 7.3 GB (mean 5.9 GB), the held model; 73 processes fit in
    1 TB, watch it if the process count grows. B22 took it to 2.9 GB a 24 h chunk in week 1 (was 5.0).
- [ ] B26 · The pipeline's settings in a TOML file copied into `runs/<id>/`, `main(config)`, no absolute paths in
  the script, no `NMB_*` variables · Tom · 2026-10-08 · proposed
  - 12 variables and two absolute paths today. Plan item 6.
- [ ] B27 · `[sources]` in `docs/`, `[compat]` for `docs/`, `scripts/` and the test solvers; decide on
  `test/Project.toml`, on the export surface (Q7) and on tags (Q8) · Tom · 2026-10-08 · proposed
  - 267 exported names; tags only for 0.6.0, 0.9.1-0.9.7, 0.12.0. Plan item 7.
- [ ] B28 · Measure NMB's share of the first-call latency (8.7-11.8 s on case14); a `PrecompileTools` workload
  only if it is large · Tom · 2026-10-08 · proposed
  - Plan item 8.
- [ ] B29 · `redispatch_volumes` writes its rows in `Dict` order, so a change to how a solution `Dict` is built
  reorders the CSV: sort by (unit, hour) as the other reports do · Tom · 2026-10-09 · proposed
  - Seen in B22: 14 of 14 `0[23]_redispatch_volumes.csv` held the same rows, once sorted, in another order.
- [ ] B4 · Bus factor: solo maintainer, get a second reviewer/co-committer (gap #11, P3/Large) · Tom · 2026-09-30
- [ ] B13 · A `Transformer` constructor from datasheet values (winding resistances, pairwise short-circuit
  reactances, no-load power) and a mesh instead of a star for four or more windings · Tom · 2026-10-05
  - Claeys et al. 2020, Algorithm 1; follows B11 (D30).
- [ ] B7 · Revisit closed switches as equality rows (D17) in the context of network reduction, where a
  closed switch would merge its nodes · Tom · 2026-10-04
- [ ] B19 · Re-evaluate the per-window feasibility check (`worst_violation`) once the pipeline has proven
  stable: sample it or drop it · Tom · 2026-10-07
  - D44 keeps it for now. It cost 2.4 s of 9.6 s a step-3 window, 0.45 s since B6 item 2; 365 of 365
    chunks of `_year_b10` had a first violation of 0.

## Done

- [x] B40 · Curative range of `Storage`: `h_cur`, the net power of a corrective unit within one band over the contingencies (D86) · Tom · 2026-10-12
  - v0.15.7 on `b33-storage-fields`, merged into `main` 2026-10-12; plan item 7, the last storage item. Suite 4140 (4118 at v0.15.6), `docs/make.jl` clean. On the one-step three-contingency network (three branches of 0.4 into a load of 1.0, branch 3 out in the second state, 2 and 3 in the third, every measure corrective): no band 6.0 with net power [0.0, 0.2, 0.5]; `h_cur` 2 (band 0.25) 7.0 with [0.25, 0.25, 0.5]; `h_cur` 1 6.0 as without; `e_max` 0.8 and `h_cur` 2 (band 0.4) 6.3333 with [0.1, 0.2, 0.5]. Rows: 6 `cstr_stor_range` and 1 `cstr_stor_range_limit`; none for a preventive unit, for no `h_cur`, for one state, for an optimal power flow, and 4 where the unit is lost in one of three states.
  - The vocabulary grew by the symbol `h` (a holding time) and the word `cur` (curative), as D86 proposed and Tom did not object to; `docs/src/manual/nomenclature.md` and `knowledge/nomenclature.md` say so. The band is two free variables per time step, `:p_stor_max` and `:p_stor_min`, registered at the first state the unit is in service at and written inside `fnct_stor_range!` as the peak variable is; the two rows per state are `(u, :min)` and `(u, :max)` and the width has a key of its own so that each key keeps one id shape.
  - Left to know: the band is per time step, not per trajectory, so a unit may still move between steps as the energy allows. A unit in service in one state only has nothing to be held with and no row. The band variables are not in the solution. `test/nomenclature.jl` carries an invented old name for the key and for the function (`storage_range`, `constraint_storage_range`), because it compares the `fnct_*` names defined with the values of its map. Nothing carries the band across the windows of a roll: it is a row on the states of one step.
- [x] B38 · Cycle limit of `Storage`: both sides of the store over any sliding 24 h window, carried across the windows of a roll, `c_cycl` per index; the same carry for `Generator.e_per_max`; Switch and DCLink `s_max > 0`; a preventive unit lost in a contingency is an error (D79-D82, D91, D92) · Tom · 2026-10-12
  - v0.15.6 on `b33-storage-fields`, merged into `main` 2026-10-12; plan item 6 with D91 and D92 folded in. Suite 4118 (4019 at v0.15.5), `docs/make.jl` clean. A full unit with `k_cycl_max` 0.2 on `e_max` 0.5 sells 0.2 at 100 in the first of prices (100, 10, 90, 10) whole and rolled at horizon/step 2/2, 4/2, 2/1, 3/1; a unit with 0.06 counted in the hour before sells 0.08, one with 0.06 counted 23.5 h before 0.2 (the entry no longer fits with the step). At η 0.9 a charge of 0.1/0.9 delivers 0.09; four steps of 12 h prices (100, 10, 100, 10) hold 0.4 pu·h of energy at `k_cycl_max` 0.8 (0.5 without), also grouped into days. A generator with `e_per_max` 0.3 over two-step days costs 46.0 in a roll of any shape as whole (103.0 with no days: 0.3 over all four). Redispatch: 90.0 with `c_cycl` 20 against 85.0; 2 cycle rows preventive, 4 corrective over two contingencies.
  - Built as 24 h/`Δt` terms a row, not a running sum: 35040 quarter-hour rows added no measurable build time (110.8 s against 114.8 s without, both dominated by B42) and 5000 steps solved in 2.3 s against 1.5-2.9 s without the limit. A roll carries `e_cycl_init`, the `(hours, energy)` of every step of the last 24 h (the plan's vector of `d` lost the step lengths); `e_per_init` on `Generator` is the energy of the period of the last committed step and `_slice` starts a window that begins a period of its own with nothing (a window that ends on the commit boundary cannot see the next step, so the decision is the window's, not `initial_state`'s).
  - Left to know: a right hand side already used up is taken as zero, so an inconsistent `e_cycl_init` blocks the unit until it ages out and is not refused. Rows are written at every index in service, also where an earlier row already implies them (no redundancy removal). Independent chunks of the pipeline start with nothing counted; the Zorba cap (Q11) is not counted by any of this. `period_cost` has no user in the package now and stays as the hook; the market-schedule check still ignores `e_cycl_init`. With η 1 and no price difference, charging and discharging at once is free and an interior point solver (Ipopt) returns it, so a test reads the state of charge and not the sum of `p_dch`.
- [x] B37 · Outage support for `Storage`: a unit out of service holds its energy, `energy_at`, the end conditions and `initial_state` read through it, a status over `:contingency` too (D76) · Tom · 2026-10-12
  - v0.15.5 on `b33-storage-fields`, merged into `main` 2026-10-12; plan item 5. Suite 4019 (3984 at v0.15.4), `docs/make.jl` clean. Five steps: an outage over steps 2-3 gives 28.216 against 10.432 in service, equal to ratings of zero to 1e-6 with the same energy at the steps it is in service, also in a roll of horizon 3 whose boundary falls in the gap. An end condition on a unit out at the last step reads what it holds (`Pin(0.4)` 34.0, `Value(150)` -31.0), and a unit out for a whole contingency is asked nothing.
  - Left to know: a preventive unit that is lost in a contingency cannot serve what it does at the base case (the redispatch with a pin that makes it move is infeasible), so the test poses it corrective. The storage `period_cost` (`c_cycl`) is still written at the first step of a period for units in service there, and goes with B38. The price warning reads the lowest price and the lowest prices of the unit over every index, which is conservative. The `status` of other components over `:contingency` is unchanged.
- [x] B36 · Terminal conditions on `Storage`: `Pin`, `Cyclic`, `Floor`, `Value`, `Soft`, `Quad` as a list `terminal`, the scheduled energy as a target, a price on the end kept in every window of a roll (D72, D85, D90) · Tom · 2026-10-12
  - v0.15.4 on `b33-storage-fields`, merged into `main` 2026-10-12; plan item 4, with D90 folded in (`s_max > 0` for a branch and a transformer). Suite 3984 (3868 at v0.15.3), `docs/make.jl` clean. Three steps: `Pin`, `Cyclic`, `Floor(0.2)` 14.0, `Floor(0.1)` 9.0, `Value(40)` 4.0, `Value(60)` 0.0, `Soft(0.2; c_dn = 30)` 10.0 and 80 14.0, `Quad(0.2; weight = 200)` 10.875; the radial redispatch ended on its scheduled energy 110.0 against 85.0. Roll with HiGHS: 26.2, 10.1, 8.4, 0 above perfect foresight with no price, 0 with `Value(90)`, 47.5 with `Value(500)`.
  - Left to know: the plan's `Value(95.0)` is the sale value after the losses (100 x 0.95), a tie at which the unit keeps its energy to the end of the problem (47.5), so the test uses 90. A price on the end is in the objective of a problem solved whole and not in what a roll reports, the last window's included, so energy kept at the end for a value is not credited. The plan's `fnct_stor_terminal!` is `fnct_stor_final_energy!` with a method per condition, since a new `fnct_` name needs an old one in the map. A table cell cannot give a `terminal`. Names standing unless Tom objects: `:e_stor_up`, `:e_stor_dn`, `:cstr_stor_final_limit`, `:cstr_stor_final_balance`, `variable_stor_terminal!`, `terminal_cost`.
  - From D90: `scripts/SteeringPlanData.jl` builds a `Branch`, `Switch` and `Transformer` from the capacity of its CSV, so a capacity of 0 in that data is now refused for a branch and a transformer; a Zorba link with 0 is refused by name.
- [x] B35 · `exact` on `Storage`: `Exclusion` (`RELAXED`, `EXACT`, `FROZEN`), `refine!` after every solve, the gap, the price guard, the docs correction (D71, D78, D89) · Tom · 2026-10-12
  - v0.15.3 on `b33-storage-fields`, merged into `main` 2026-10-12; plan item 3. Suite 3868 (3813 at v0.15.2), `docs/make.jl` clean. Three-step run: 393.00 relaxed, 426.54 `EXACT` and with a binary on every step; `c_dch` 100 gives 441.60 and 446.54, 130 gives 450.00 for both; in current through Juniper 426.54 too.
  - Left to know: no hull row is written, the two big-M rows imply it; `exact` is `RELAXED` by default, so existing models are unchanged; the guard reads the first network index (B37 widens it); `EXACT` and `FROZEN` need finite ratings; the 10-node chain of the plan (36 binaries, FROZEN within 1 %) is not run.
  - Names proposed here, standing unless Tom objects: `exact` (a word), `exclusion` (a role), `chg` and `dch` (id parts), `:z_stor`, `:cstr_stor_exclusion`, the solution key `relaxation_gap`.
- [x] B34 · Converter limit `s_max` on `Storage`: the circle in IVR, a limit on the active power in LPF (D73) · Tom · 2026-10-12
  - v0.15.2 on `b33-storage-fields`, stacked on B33, merged into `main` 2026-10-12; plan item 2. Red then green; suite 3813 (3788 at v0.15.1), `docs/make.jl` clean. Rows `:cstr_stor_rating`: id `u` in IVR, `(u, :max)` and `(u, :min)` in LPF, none at `Inf`.
  - Left to know: the limit is on the net injection, so with efficiencies of one each side can exceed it; LPF skips a held unit (the base case's rows imply it), IVR writes a circle at every index since `q_stor` is not held; `structure_gates` of a storage unit is `(:s_max,)` (an existing `rd.jl` test said `()`); `s_max = 0` is accepted and gives a degenerate circle in IVR.

- [x] B33 · Storage fields and validation: `_check_storage`, `check_storage` before the build, `e_min`, `c_chg` and `c_dch` in place of `c_thru`, `c_up + c_dn >= 0`, a market schedule inside the energy bounds, `scheduled_energy` (D74, D75, D83, D84, D87, D88) · Tom · 2026-10-12
  - v0.15.1 on `b33-storage-fields`, merged into `main` 2026-10-12; plan item 1. Red then green: 31 of the 130 tests of `validation.jl` failed on v0.15.0; suite 3788 (3686 at v0.15.0), `docs/make.jl` clean. A hard removal of `c_thru`.
  - Left to know: the constructor does not compare `e_init` or `e_fin` with the bounds (`check_storage` does, within 1e-5); a roll checks the schedule once and its windows skip it (`schedule = false`); the schedule checks read a plain `Storage` only. The Zorba pipeline excludes its storage, so none of it is read there.

- [x] B32 · Name the constraints, the functions that write them and their duals: `cstr_<owner>_<role>` keys and ids, `fnct_*` functions, `dual_*` solution keys, names in JuMP behind `debug_mode`, the old letters B31 left (D63-D70) · Tom · 2026-10-11
  - v0.15.0, merged and tagged; spec `knowledge/plan/naming-constraints.md`, map `knowledge/nomenclature.md`, a hard removal. Red then green: the testset "constraint nomenclature" of `test/nomenclature.jl` (89 of 99 passed on v0.14.0, 680 old names written); suite 3,686; `debug_mode = false` builds the step-3 window in 1,707 ms and 764 MB, `true` in 2,401 ms and 1,372 MB; a 24 h chunk byte-identical to v0.12.7.
  - Left: the 14 private `_constraint_*` helpers keep their names; `variables!` names an arc `[Arc(1, 1, 1)]` where `variable!` flattens it; the `julia.instructions.md` line is in (SC9); the vocabulary note for `domain-invariants` (B31's plan) is dropped, `julia.instructions.md` points to `nomenclature.md`.
- [x] B31 · One nomenclature for variables and parameters (`symbol_primary_secondary[_unit]`): fields, variable keys, solution keys, keywords and a node's `ext` start keys; `set_string_name` on every solve; per-type tables in the docs (D55-D62) · Tom · 2026-10-11
  - v0.14.0, merged into `main` and tagged `v0.14.0` on 2026-10-11; spec `knowledge/plan/naming.md`, names `knowledge/nomenclature.md`, a hard removal.
    Test first: `test/nomenclature.jl` red on 1,639 old names, green at the end; `test/docs_tables.jl` found fields missing from 12 of 12 tables
    (23 in all) and 6 variable keys on no component page. Suite 3551 (3351 at v0.13.0); names on cost 2-4 %, off 19-27 % faster in `instantiate_model`;
    a 24 h chunk byte-identical to v0.13.0 at stages 3 and 4. Left: `scripts/NMinusOneScreen.jl` (untracked) had its field accesses renamed only.

- [x] B30 · One `Branch` (`l_km`, NaN by default) instead of `Branch`, `Cable` and `OverheadLine`; `pi_model.jl` split by who
  uses what; a rating and an angle limit apart; then a branch of two or more terminals (D50-D54) · Tom · 2026-10-10
  - v0.13.0, merged into `main` and tagged `v0.13.0` on 2026-10-11; plans `knowledge/plan/one-branch.md` and `one-branch-terminals.md`.
    Suite 3351, a 24 h chunk byte-identical to v0.12.7, window cut 7.7-7.8 ms against a control's 7.7-8.0, a lossy transformer
    gives v0.12.9's objectives to 9 digits. Left: `scripts/NMinusOneScreen.jl` (untracked) reads a branch's `r`, `x`, `s_max` as numbers.

- [x] B24 · The package's own registers are fields of `NetworkModel`, not keys of `nm.ext`; a `var`/`con` key is not
  reused with another index set, nor a constraint id in a build (D49) · Tom · 2026-10-08
  - v0.12.9, merged into `main` and tagged `v0.12.9` on 2026-10-10; plan `knowledge/plan/typed-registers.md`. Seven write-only registers deleted, a
    reused variable key was accepted four ways out of five, now refused. A held step-3 model is 7.3 MB smaller (not the
    56.5 MB first read), `update_model!` 1.18 s against 1.29 s same day, suite 3322, a 24 h chunk byte-identical to v0.12.7.

- [x] B23 · A constructor refuses input a model cannot use: `Node`, `Generator`, `FixedLoad`, `Shunt` and the branch
  family (D48) · Tom · 2026-10-08
  - v0.12.8, merged into `main` and tagged `v0.12.8` on 2026-10-10; plan `knowledge/plan/validation.md`. 19 of 19 invalid inputs built
    before; the Zorba year (8,760 h) loads in 36 s and breaks none of the rules, case14's `v_base_kv` 0 is allowed.
    Cutting a real step-3 window 7.5 ms (was 7.7; stop rule 16), a 24 h chunk byte-identical to v0.12.7, suite 3295.

- [x] B25 · Guard rails for the measure step: an allocation test that reproduces B6's defect, a `benchmark/`
  environment on a synthetic N-1 network, GC time and bytes per chunk in `chunk.csv` (D47) · Tom · 2026-10-08
  - v0.12.7, merged into `main` and tagged `v0.12.7` on 2026-10-10; tests and tooling only; plan `knowledge/plan/guard-rails.md`. The test
    fails on the sources before v0.12.2 (1,248-2,176 B a call) and passes now; `@inferred` passes on both. The
    benchmark agrees with itself within 3 % and shows B21 and B22 against v0.12.4. Week 1, 7 threads against 7
    processes: 224 s against 125 s a chunk, GC 14.4 % against 14.2 %, so the collector is not what threads lose to.

- [x] B22 · A roll builds the solution of the network indices it keeps, a `report` keyword says which families
  and identifiers a solution holds, and the builders get cheaper (D46) · Tom · 2026-10-08
  - v0.12.6, merged into `main` and tagged `v0.12.6` on 2026-10-09; plan `knowledge/plan/build-solution.md`. Week 1, 7 + 7 processes
    at once against `main`: 14 of 14 sound, objectives, overload, shedding, spillage and congestion files
    bit-identical, the redispatch volume files the same rows in another order (B29); chunk 871 s against 993 s
    (-12.3 %, faster in 7 of 7; predicted -9 to -12 %), peak 2.9 GB against 5.0 (predicted -1.0 to -1.6).
  - Stop rule (`build_solution` above 8 % of the wall, or a chunk holding over 1.5 GB of result): 7.8-9.3 % of a
    step-3 roll's wall timed inside the roll, ~6 % of a chunk, a chunk holds under 1 GB. At the threshold: Q9.

- [x] B21 · A repeated `topology` lookup is answered from the last answer, and returns one concrete type
  (D45) · Tom · 2026-10-08
  - v0.12.5, merged into `main` and tagged `v0.12.5` on 2026-10-09, plan `knowledge/plan/topology-lookup.md`. Week 1, 7 + 7
    processes at once against `main`: 14 of 14 sound, objectives, overload rows and volumes bit-identical,
    chunk 135.2 s against 151.3 s (-10.7 %); `topology` 16 % of the wall before, 1.7 % after (stop rule,
    3 %, not fired, so one entry stays). First move of B20; B22 is next.

- [x] B8 · `test/lf.jl:124` asserted `solve_time > 0.0` and failed when a small case solved faster than
  the `time()` tick on Windows (2 failures in 7 runs on 2026-10-07) · Tom · 2026-10-07
  - Now `>= 0.0`, which still fails for the `NaN` of an unrecorded time; v0.12.4, tests only.
- [x] B6 · Cut NMB's per-window overhead in rolling-horizon solves (D43, D44) · Tom · 2026-10-07
  - v0.12.1-v0.12.3 and `scripts/ParallelRun.jl`, 9 commits `123d895`..`8b84c14`: the `same_structure` gates
    so a window reuses the model, a feasibility check read through MOI, generated `nw_component`, a typed
    `Network.status`. Each step beside a same-day control in week 1 (two pairs, launch order swapped):
    chunk time -26.2 %, -16.5 %, -13.6 %, -15.6 %, objectives within 4e-10 and from item 2 on bit-identical.
  - Full year `runs/_year_b6` against `_year_b10`: 24 min against 52 min, chunk mean 237 s against 549 s
    (-57 %; target -35 %), 365 of 365 sound, 0 fallback, 0 violation; objectives median 1e-14, max 2.6e-8
    (one chunk above 1e-8, none above 1e-7); overload rows equal (step 3: -7 of 5.7 M), total overload
    equal; largest unit-hour volume difference 0.14 pu (step 2, another optimum). Peak 7.3 GB.
  - The planned bulk read of values for `build_solution` failed its stop rule (0.07 s of 0.7 s); the
    profile found `has_nw_data` and `_signature` instead. Rest of the cost: B20.
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
