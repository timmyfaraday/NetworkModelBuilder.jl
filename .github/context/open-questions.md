# Open questions

Questions only a person can settle. Before asking Tom, check here; when one is answered, record
the answer as a decision (if it changes a rule) and delete the question. Next id: **Q5**.

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

### Q4 · A multi-terminal switch: one device with an integer position, or a group of two-terminal switches?
Owner: Tom (not yet settled). Depends on: B5, D15 (`position` is an `Int`). Zorba's 21 couplers are
two-terminal, so nothing waits on it.
A device lists a common terminal first and takes `position` 0 (open) to n-1 (common terminal tied
to terminal k+1). A group is n-1 two-terminal switches plus an allowed-states set (Goldis et al.
2017, Eq. (53)). Written with one binary per alternative and at most one closed they are the same
mixed-integer program, so solve time and numerical behaviour do not separate them; what does is
the big-M values, the number of binaries and islanding. A one-of-n device cannot express both
selectors closed, nor a junction that ties all terminals at once. Options: (A) device; (B) group;
(C) validate exactly two terminals now and decide when a double-busbar selector turns up.
