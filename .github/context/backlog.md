# Backlog

One line per item: `- [ ] B<n> · <what> · owner · added YYYY-MM-DD` plus an optional indented note.
Move items between sections; tick and move to Done when finished (keep the last ~10 done, delete
older ones: git has them). Next id: **B7**.

## Now

- [ ] B5 · A `Switch` edge type (children: busbar switch, circuit breaker), replacing near-zero-impedance couplers · Tom · 2026-10-02
  - Started 2026-10-03 on branch `b5-switch-edge`. See D13. Until it exists the Zorba pipeline floors
    line reactance at 1e-5.

## Next

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

## Done

- [x] B0 · Adopt this `.github/` agent setup, ported from a colleague's FlowBasedDomains repo and
  adapted for Julia/GitHub/solo maintainer · Tom · 2026-09-30
- [x] B1 · Central include/export file is a growing manual-edit tax (gap #8) · Tom · 2026-09-30
  - `src/comp/` auto-discovered by `_include_dir`, each component exports its own names — see D10.
- [x] B2 · API ergonomics / onboarding curve vs. SmaLoadFlow (gap #9) · Tom · 2026-09-30
  - `solution_tables` alongside `nw_solution`, plus a `concepts.md` newcomer page — see D11.
