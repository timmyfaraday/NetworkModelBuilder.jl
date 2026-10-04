# Open questions

Questions only a person can settle. Before asking Tom, check here; when one is answered, record
the answer as a decision (if it changes a rule) and delete the question. Next id: **Q6**.

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

### Q5 · Should a loop of free switches get the loop equation a locked loop has?
Owner: Tom (not yet settled). Depends on: `knowledge/plan/switch-edge.md`, D21, B5 (commits 5-6).
A locked loop of closed switches gets unit-weight loop equations (D21), so its flow split is unique.
A free switch writes only its big-M rows, so when the problem closes a loop of free switches its
flow split is unconstrained and the model may route it as it likes. Toy (3 nodes, three free
switches, `test/switch.jl`): all three closed costs 12.6 locked and 5.4 with free switches fixed
closed; the optimum with free switches (4.5) is still the best locked run, so the claim "equals
the best of the 2^k locked runs" held there, but nothing guarantees it. Options: (A) leave it and
say so (what the code and docstring do now); (B) loop rows made conditional on the free switches
of each simple cycle of the switch graph being closed, `|Σ σ p| ≤ Σ rate (1 - z)`, exact, one
row per simple cycle and so exponential in the worst case, fine for a substation; (C) a second
potential per node with `p = Δφ` where closed, exact and linear in size but more variables, and
the locked switches in the same component would need it too. Recommended: (B), with an error
above a cycle count, once a case with a loop of free switches exists.
