# Open questions

Questions only a person can settle. Before asking Tom, check here; when one is answered, record
the answer as a decision (if it changes a rule) and delete the question. Next id: **Q10**.

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

### Q7 · Trim the export list, and mark the builder internals `public`?
Owner: Tom (not yet settled). Depends on: B27, plan `knowledge/plan/julia-guide-review.md` item 7.
`names(NetworkModelBuilder)` is 267 names, including `ids`, `node`, `edge`, `unit`, `nodes`, `edges`,
`units`, `status`, `window`, `solution`, `objective`, `network`, `topology`. `using PowerModels`
already collided on `ids`/`parse_file` (D5); `edges` (Graphs.jl) and `unit` (Unitful) are the same kind.
Options: (A) keep everything exported; (B) export the entry points and types only (`solve_*`, `parse_*`,
the component types, `Dimension`, `NetworkData`, the solution accessors) and mark the rest `public`,
which needs `Compat.@compat` or a `VERSION` guard while CI tests Julia 1.10, and breaks every
`using NetworkModelBuilder` script and doc example that calls an internal unqualified.

### Q8 · Tag every version that lands on `main`?
Owner: Tom (not yet settled). Depends on: B27; D1 and D20 ("no git tag per bump").
Tags exist for `v0.6.0`, `v0.9.1`-`v0.9.7` and `v0.12.0`. `Project.toml` is 0.12.4 and `CHANGELOG.md`
describes 0.10.x, 0.11.0 and 0.12.1-0.12.4, none of which `Pkg.add(...; rev = "v...")` can pin. The
pipeline's `scripts/Manifest.toml` points at the repo by path, so a run is reproducible by git sha only.
Options: (A) as today, tag only what Tom asks for; (B) tag each merge to `main` (still Tom's call to
push); (C) (A), and write the git sha and version into `runs/<id>/` (B26), so a run names its code.

### Q9 · A typed solution under the nested `Dict`?
Owner: Tom (not yet settled). Depends on: B22; D11 (the nested `Dict` is the default result).
`build_solution` is 19 % of a roll's wall: a `Dict{String,Any}` per component, built from `"$u"` keys.
Options: (A) keep the `Dict` and build only the indices a roll keeps (no API change, B22 item a);
(B) fill the columns `solution_tables` already produces and make `result["solution"]` a view that builds a
nested entry on access: same reads, a different type behind them (`AbstractDict{String,Any}`), so code
that does `result["solution"] isa Dict` or mutates it breaks; (C) (B) with the `Dict` removed.
