# Guard rails for the measure step: a hot-path allocation test, a benchmark, GC columns (B25)

Status: implemented on `b25-guard-rails` (v0.12.7), measured, not merged · Author: Tom Van Acker (requested) · Date: 2026-10-09
Decisions: D47 recorded 2026-10-09 (next free after: D48); no open question
Priority: P2 · Effort: Medium. Branch `b25-guard-rails`, cut from `main` at `0e28585` (v0.12.6);
becomes v0.12.7. Third move of the review `julia-guide-review.md`, item 5; B22 was the second.

## Handoff instructions

- Implement on `b25-guard-rails`, one commit per part, the test first, no AI attribution.
- `src/` is not touched. Per-file changelog header (80 columns) on `test/hot_path.jl` (new) and
  `test/runtests.jl`; `Project.toml` 0.12.7; `CHANGELOG.md` (tests and tooling only, as 0.12.4 was).
- Targeted test, then the full suite once with `$env:JULIA_NUM_THREADS = '4'`; the benchmark and the pipeline
  runs are measured, not tested. `scripts/` and `benchmark/` carry no per-file header.

## Evidence

- The profiles behind B6 (-57 %) are in the gitignored `scratch/`; the only guard against a repeat is a private
  full-year run. B6's boxed field loop cost 12 % of a roll and no correctness test saw it
  (`julia-guide-review.md` item 5).
- **`@inferred` does not catch that defect, an allocation count does.** Probes `scratch/b25_inference_probe.jl`
  and `scratch/b25_alloc_probe.jl`, run on `6ccf515` (the parent of `aa33f8d`, v0.12.2) and on `main`:

  | call, case14, no network data on the component | before v0.12.2 | now |
  |:--|--:|--:|
  | `@inferred has_nw_data(c)`, `nw_component(dim, c, n)`, `ids`, `nw_value` | concrete | concrete |
  | `@inferred topology(net; nw)` | `Union{Nothing,Topology}` | concrete |
  | bytes per call, `has_nw_data` of a `Generator`, `Branch`, `Node` | 2,176, 1,664, 1,248 | 0, 0, 0 |
  | bytes per call, `nw_component` of a `Generator`, `Branch` | 2,176, 1,664 | 0, 0 |

  `topology`'s `@inferred` and its zero-allocation repeat are already tests (`test/multinetwork.jl:196-197`,
  `:215`, B21). `node`, `edge` and `unit` of a `Network` infer `Any` by design, the `::T` barrier of every
  caller contains it; `coordinates(dim, n)` is not inferable, the names are values.
- The pipeline's `chunk.csv` has `seconds` and `maxrss_gb` (`scripts/run_year_redispatch.jl:131-137`, `:247`,
  written by `:260-263`, concatenated line by line under one header by `merge_csv`, `:269-284`). The only GC figure
  is the process total printed at the end of a run (`:312`, `:335`). `lessons.md` says GC is 13-20 % of wall and
  that its cause as the limit of thread scaling is "not proven"; 7 threads in one process gave 860 s a chunk,
  7 processes 330-400 s.

## Root cause

Every check NMB has asks whether the answer is right. Nothing asks what an answer costs, so a change that makes a
lookup allocate, or a window slower, is found only when somebody profiles. The cause is the missing check, not a
line of code.

## Fix

1. **A hot-path test, `test/hot_path.jl`, allocation checks only (D47).** Case14 over
   `Dimension(:time => 3, :contingency => 2)`, no network data on any component. In a function, after one warm-up
   call: `has_nw_data(c)` and `nw_component(dim, c, n)` allocate 0 bytes for a `Node`, a `Branch` and a
   `Generator`. Included from `runtests.jl`. It reproduces a defect that happened (`tests.instructions.md`).
   No `@inferred` beyond B21's: on the defect they would have passed. If the count is not 0 on every one of five
   runs with 4 threads, the test is wrong, not the code: stop and report.
2. **`benchmark/`, an environment of its own, run by hand (D47).** `benchmark/Project.toml` with BenchmarkTools and
   HiGHS and `[sources] NetworkModelBuilder = {path = ".."}`; `benchmark/window.jl`. Case14 as a redispatch with
   one contingency per branch whose loss does not island, over a few time steps, and the stages of one window each
   timed: `instantiate_model`, `update_model!`, `optimize_model!`, `build_solution` whole and with a `report`, and
   a whole `solve_rolling_horizon(...; horizon = 1, step = 1, reuse = true)`. It prints minimum and median time,
   bytes and the GC share of each. Case14 has to be given ratings that bind, else no overload exists: settle that
   in a spike before writing it. The header says how to use it: run it on `main` in a worktree and on the branch
   the same day. Not in CI, no baseline numbers in the repository (they belong to one machine).
3. **GC columns in `chunk.csv` (D47).** Six: `gc_s` and `alloc_gb` for the chunk, `step2_gc_s`, `step2_alloc_gb`,
   `step3_gc_s`, `step3_alloc_gb`, appended to `ROW_FIELDS`. A snapshot `Base.gc_num()` at the start of the chunk
   and of each step, a small `gc_since(snapshot)` giving the pause seconds and gigabytes allocated since.
   The counters are process-wide, so the columns are exact for a process that runs one chunk at a time (the
   7-process recipe) and say so in the script's header. A run started before this change must not be resumed
   after it: `merge_csv` would join rows of different widths.

## Decisions

- **D47, recorded 2026-10-09 (Tom Van Acker):** guard rails that each reproduce a defect that happened. Tom chose
  the allocation checks only over adding the review's `@inferred` list, BenchmarkTools in its own environment over
  a hand-rolled `@timed`, six GC columns over two, and one same-day pair of 7 threads against 7 processes once the
  columns exist.

## Verification

- Part 1, red and green: `test/hot_path.jl` run against a worktree of `aa33f8d^` fails on `has_nw_data` and
  `nw_component` with the byte counts above; on the branch it passes; then the full suite, 4 threads.
- Part 2: run on `main` and on the branch the same day: the two agree within noise, and `build_solution` with the
  pipeline's `report` is a fraction of the whole one (0.14 s against 0.31 s on a real step-3 window, B22).
- Part 3: one chunk in one process, `gc_s` within 5 % or 0.5 s of the `[run]` line's total; the three `alloc_gb`
  positive and the steps no larger than the chunk; week 1 as 7 processes gives 7 rows with the new columns and a
  merged `chunks.csv` whose rows have the same width.
- The GC lesson: week 1 as 7 threads in one process (`-t 7`, `NMB_NTASKS = 7`) and as 7 processes, same day,
  `gc_s` over `seconds` per chunk. `lessons.md` then says what the numbers show, or that they settle nothing.

## Commit order

1. `test/hot_path.jl` and its include, red on the old sources, green now.
2. `benchmark/`, after the spike on case14's ratings.
3. The six `chunk.csv` columns and the `gc_since` helper in `scripts/run_year_redispatch.jl`.
4. `Project.toml` 0.12.7, `CHANGELOG.md`, headers; after the pair of runs, STATE, B25 and the lesson.

## Stop rule

If the benchmark's repeat runs of one stage on one machine differ by more than 10 % in the minimum, it cannot guard
anything: report it and fix the setup before it is merged. Otherwise B25 is done and B23 is next.

## What this deliberately does not decide

- A baseline kept in the repository, or the benchmark in CI: numbers are per machine, a CI runner is noisy.
- Other functions under test than the two B6 changed; a new one earns its place with its own defect.
- Q9 and B20's rest; the GC lesson's conclusion (the pair of runs gives numbers, `lessons.md` draws it).

## Result (2026-10-09)

- Commits `d449261` (test), `1ba9524` (benchmark), `41dc47d` (columns), `933c1f3` (0.12.7); suite 3223.
- Part 1: `test/hot_path.jl` fails all six checks on `aa33f8d^` (1,248, 1,664, 2,176 bytes, twice each), passes on the
  branch, five of five runs with 4 threads. `@inferred` passes on the old sources.
- Part 2: every minimum agrees within 3 % between two runs; against v0.12.4 on the same day `update_model!` 30.4 to
  26.9 ms, `build_solution` 9.3 to 4.7 ms, the roll 868 to 706 ms, the solve unchanged (35.8, 35.6 ms). It is a
  case14 benchmark (52 indices a window, 17 rated edges, 1,143 overloaded rows), about 1/25 of a pipeline window.
- Part 3: one chunk in one process, `gc_s` 14.7 s against the `[run]` line's 15.4 s (4.7 %); the merged `chunks.csv` of 7
  processes has 7 rows of 32 fields.
- The pair (`runs/_b25_proc`, `_b25_thread`, side by side): 7 processes 125.0 s a chunk, GC 17.7 s = 14.2 %, 24.4 GB
  allocated, peak 2.9 GB each; 1 process on 7 threads 224.1 s a chunk (238.5 s wall), GC 14.4 % (34.3 s), peak
  14.3 GB. Threads cost 1.79x and the collector's share is the same, so GC is not what they lose to.
