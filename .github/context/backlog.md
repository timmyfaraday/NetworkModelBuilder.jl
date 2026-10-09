# Backlog

One line per item: `- [ ] B<n> · <what> · owner · added YYYY-MM-DD` plus an optional indented note.
Move items between sections; tick and move to Done when finished (keep the last ~10 done, delete
older ones: git has them). Next id: **B30**.

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
- [ ] B23 · Validate in the inner constructors what `Node`, `Generator`, `FixedLoad` and the branch family accept
  today: ordered limits, finite impedance, non-negative rating, no NaN · Tom · 2026-10-08 · proposed
  - 11 of 11 invalid inputs accepted; `pmin > pmax` gives an `INFEASIBLE` OPF with no pointer. Load the
    Zorba data and the Matpower cases before deciding a rule. Plan item 3.
- [ ] B24 · Move the package's own registers (nine keys) out of `nm.ext` into typed fields; refuse a `var`/`con`
  key reused with another index set · Tom · 2026-10-08 · proposed
  - The refusal changes the extension contract: a decision. Plan item 4.
- [ ] B25 · Guard rails for the measure step: an allocation test that reproduces B6's defect, a `benchmark/`
  environment on a synthetic N-1 network, GC time and bytes per chunk in `chunk.csv` · Tom · 2026-10-08 · branch
  `b25-guard-rails`
  - Plan `knowledge/plan/guard-rails.md`, D47. `@inferred` passes on the B6 defect; `has_nw_data` allocated
    1,248-2,176 B a call before v0.12.2 and 0 now. A same-day pair, 7 threads against 7 processes, settles the GC
    lesson once the columns exist.
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

- [x] B22 · A roll builds the solution of the network indices it keeps, a `report` keyword says which families
  and identifiers a solution holds, and the builders get cheaper (D46) · Tom · 2026-10-08
  - v0.12.6 on `b22-build-solution`, not merged; plan `knowledge/plan/build-solution.md`. Week 1, 7 + 7 processes
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
