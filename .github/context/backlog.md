# Backlog

One line per item: `- [ ] B<n> · <what> · owner · added YYYY-MM-DD` plus an optional indented note.
Move items between sections; tick and move to Done when finished (keep the last ~10 done, delete
older ones: git has them). Next id: **B19**.

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
    reads a generator's `pmin`/`pmax` crossing +-pi/2 as a change of shape. Plan in the next session.
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
