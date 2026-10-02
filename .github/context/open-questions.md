# Open questions

Questions only a person can settle. Before asking Tom, check here; when one is answered, record
the answer as a decision (if it changes a rule) and delete the question. Next id: **Q4**.

Format: `### Q<n> · <question>` then who can settle it, what depends on it, and the options.

### Q1 · Chunked-parallel rolling horizon, or document the trade-off?
Owner: Tom (not yet settled). Depends on: `context/knowledge/plan/GAP_CLOSURE_PLAN.md` gap #10,
backlog B3.
`solve_rolling_horizon` is inherently sequential — each window needs the previous window's solved
state (`initial_state`) — while SmaLoadFlow gets throughput on long horizons via OS-level
multiprocessing, cutting one horizon into independent batches and approximating the coupling at
batch boundaries. Options: (A) an opt-in chunked-parallel mode alongside the exact sequential path,
with an approximate boundary condition at chunk edges; (B) document today's already-free
embarrassingly-parallel case (many independent `NetworkModel`s via `Threads.@threads`) as the
answer, since it needs zero code changes but gives no speedup on a single long horizon. Benchmark
the current sequential path's wall-clock throughput on real multi-core hardware before committing
to (A)'s added complexity — if model-reuse/warm-start already closes most of the gap, the honest
fix may be "document the trade-off," not "add parallelism."
Evidence 2026-10-02: Zorba's independent daily chunks scaled with one-thread *processes* (7: 330-400 s
per chunk) but not with threads in one process (7: 860 s; 30 threads: no gain), so option (B)'s
"`Threads.@threads` over independent models" is weaker than it reads. See `lessons.md`, Performance.

### Q2 · Restore the original last-resort prices in the Zorba pipeline?
Owner: Tom (not yet settled). Depends on: `scripts/run_year_redispatch.jl`, `SteeringPlanData.jl`.
The pipeline prices are 3x the thermal ceiling for overload, 2x that again for spillage and 4x the
overload price for shedding — rescaled in `4ef3472` as a (wrong) fix for false INFEASIBLE. The real
fix was the reactance floor (D13). Options: (A) restore the original 10x overload / 5x spillage /
10x shedding; (B) keep the rescaled ones. The year run used (B): 0 load-shedding rows, 635 spillage rows.

### Q3 · Retire `scripts/run_three_step_redispatch.jl`?
Owner: Tom (not yet settled). The sequential reference script. The chunked driver reproduces its
corrected week to solver tolerance (objective rel diff 1e-12), so it is no longer needed to validate
with. Options: (A) delete it; (B) keep it as the sequential reference.
