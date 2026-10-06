# Backlog

One line per item: `- [ ] B<n> · <what> · owner · added YYYY-MM-DD` plus an optional indented note.
Move items between sections; tick and move to Done when finished (keep the last ~10 done, delete
older ones: git has them). Next id: **B15**.

## Now

- [ ] B11 · One `Transformer` for every transformer (windings, tap changer, phase shifter), replacing
  `TapChanger`, `PhaseShifter` and `MultiWindingTransformer` · Tom · 2026-10-05
  - Plan `knowledge/plan/unified-transformer.md` (D28-D34), branch `b11-unified-transformer`, v0.12.0,
    tagged at the merge. Accepted by Tom; commits 1-5 of 6 done, 6 (docs, CHANGELOG, 0.12.0) left.

## Next

- [ ] B12 · After B11 merges: move `test-zorba-run` (`scripts/SteeringPlanData.jl`, `NMinusOneScreen.jl`,
  `ContingencyData.jl`) to `Transformer`, then re-run week 1 beside a control run made the same day
  · Tom · 2026-10-05
  - Objective equal to 1e-9 relative to `runs/_week1_switches`; chunk time within the control's spread.
- [ ] B10 · Re-run the full year on `test-zorba-run` with the couplers as switches; `runs/_year_orig_prices`
  has the 1e-5 floor · Tom · 2026-10-05
  - Week 1 moved the objective by under 0.02 % (B9), so expect the year's overload rows within
    about 0.1 % of 341,787 (step 2) and 5,720,514 (step 3). Recipe in the header of
    `scripts/run_year_redispatch.jl`.

## Later

- [ ] B3 · No parallel-throughput option for long-horizon solves (gap #10, P2/Large) · Tom · 2026-09-30
  - Needs a design decision first (chunked-parallel vs. document-the-trade-off) — see
    `open-questions.md` Q1.
- [ ] B6 · Cut NMB's per-window overhead in rolling-horizon solves: ~85% of a Zorba chunk is
  `update_model!` (~3 s/window), `build_solution` (~1 s) and allocation/GC, not the solver · Tom · 2026-10-02
  - Measured, cause of the loss of thread scaling not proven. Profile one window under `-t 1` first.
    Relates to B3. Longer windows do not help: the overhead follows the hour-states solved, not the
    number of windows (`lessons.md`, Performance), so the target is the cost per hour-state.
- [ ] B4 · Bus factor: solo maintainer, get a second reviewer/co-committer (gap #11, P3/Large) · Tom · 2026-09-30
- [ ] B13 · A `Transformer` constructor from datasheet values (winding resistances, pairwise short-circuit
  reactances, no-load power) and a mesh instead of a star for four or more windings · Tom · 2026-10-05
  - Claeys et al. 2020, Algorithm 1; follows B11 (D30).
- [ ] B7 · Revisit closed switches as equality rows (D17) in the context of network reduction, where a
  closed switch would merge its nodes · Tom · 2026-10-04
- [ ] B8 · `test/lf.jl:124` (`solve_time > 0.0`) fails now and then on Windows: `time()` has a coarse
  resolution and case14 solves faster; seen once in a full run, passes alone. Likely `>= 0.0` · Tom · 2026-10-04

## Done

- [x] B14 · A preventive phase shifter set at exactly zero stopped Ipopt in the current-based
  redispatch: the tie and each state's magnitude row were dependent. A held measure now builds no
  restricting rows of its own (D35); reuse of the base case's variables is Q6 · Tom · 2026-10-06
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
