# Open questions

Questions only a person can settle. Before asking Tom, check here; when one is answered, record
the answer as a decision (if it changes a rule) and delete the question. Next id: **Q7**.

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

### Q6 · Should a held measure reuse the base case's variables instead of being tied to them?
Owner: Tom (not yet settled). Depends on: B11 commit 5 (`STEPPED`), D35.
Today a preventive measure has its own variables at every contingency, tied to the base case's by an
equality row, and builds no restricting rows of its own (D35). Options: (A) keep that; (B) a held
winding's variables are the base case's own, with no duplicate variables and no tie rows. It matters
for binaries: Juniper does not presolve, so a tied binary per contingency is a branching variable that
(B) removes. (B) means changing `variable!` and the in-place rebuild so that an aliased variable is not
written twice. Settle it in commit 5 by counting the binaries and the solve time of a stepped
preventive winding over several contingencies both ways.
