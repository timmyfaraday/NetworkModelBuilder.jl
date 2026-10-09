# A roll builds the solution it keeps, and only what is asked for (B22)

Status: implemented on `b22-build-solution` (v0.12.6), measured, not merged · Author: Tom Van Acker (requested) · Date: 2026-10-09
Decisions: D46 recorded 2026-10-09 (next free after: D47); Q9 stays open
Priority: P2 · Effort: Medium. Branch `b22-build-solution`, cut from `main` at `047fe4b` (v0.12.5);
becomes v0.12.6. Second move of B20; the review it comes from is `julia-guide-review.md`, item 2.

## Handoff instructions

- Implement on `b22-build-solution`, one commit per level, tests first, no AI attribution.
- Per-file changelog header (80 columns) of every file touched, `Project.toml` 0.12.6, `CHANGELOG.md`.
- Targeted tests per commit, the full suite once with `$env:JULIA_NUM_THREADS = '4'`, the docs build.
- Measure with `scratch/b22_solution_study.jl` (local, gitignored); a prototype goes in scratch first.

## Evidence

- `build_solution` is 2,039 of 8,340 samples of a roll on `main` (24 %, **16 % of the 25.2 s wall**,
  `scratch/b21_roll_profile_branch_flat.txt`). It is called from `optimize_model!` only (`model.jl:277`).
- One window, `main`, real data (`b22_solution_study.jl`). Step 3, hour 1, 80 network indices: `build_solution`
  0.44-0.86 s, 0.20 GB, GC 0-0.42 s; **105,282 entries** (18,720 node, 34,962 edge, 51,600 unit) and 69,924
  terminal dicts; the result is **91 MB**. Step 2, 3 hours, 42 indices: 9,828 + 18,375 + 13,734 entries, 40 MB.
  A 24 h step-3 chunk keeps 24 such windows, about 2.2 GB of the 5.0-5.2 GB the week-1 processes peak at.
- Where five calls go (1,289 samples at 1 ms): `JuMP.value` 22 %; `Dict{String,Any}(pairs...)`, `setindex!` and
  `rehash!` about 30 %; `string(::Int)` for the `"$u"`, `"$i"` and `"$(a.terminal)"` keys 10 %; `var(nm, key, idx;
  nw)` lookups 7 % self; resolving a component with `nw_component` **5 %**. `unit.jl:260-264` builds `"$u"` twice
  for one entry and `node.jl:598-612` builds `"$i"` up to five times. 53,112 resolutions take 0.01 s, so the
  Transformer rebuild B20 suspected is not here.
- A roll keeps only the committed indices (`rd.jl:717` copies `nm.sol["solution"]["nw"]["$m"]` for those) but every
  window builds all of them: nothing wasted at the pipeline's 8/8 and 1/1, **83 %** at `horizon = 24, step = 4`,
  `48/8` and the doc example `6/1`.
- The pipeline reads a small part (`PipelineReports.jl:54,103-107,140-143,203`, `SteeringPlanData.jl:522-538`):
  terminal `p` and `overload` of monitored edges, `pg`, `pgup`, `pgdn` of units, and **no node**. Monitored edges
  are 19 of 439 (step 2) and 113 of 439 (step 3); a step-3 index has 645 units, 234 loads and 411 generators.
- `solution_processors` has one user, `ParallelRun.jl:173`, which reads the model and not `sol["solution"]`.

## Root cause

`build_solution(nm)` is all or nothing: every family, every network index, every component, eagerly, as a nested
`Dict{String,Any}` with string keys, one `Dict` and boxed floats per entry. The roll throws most of it away or
never reads it, and what it keeps is held until the chunk ends.

## Fix

1. **Build only the indices asked for, and cheaper; no API change.**
   (a) `build_solution(nm; nws = nw_ids(nm))` and `optimize_model!(...; solution_indices)`; `solve_rolling_horizon`
   passes the committed indices. A roll's `solution_processors` then see `nm.sol` for those indices only.
   (b) In the six builders (`solution_node/edge/unit`, IVR and LPF): take `var(nm, key; nw)` once per call, make the
   key string once per component, build each entry with `sizehint!` and assignments, not the vararg `Dict(...)`.
   Estimate, not measured: -30 to -35 % of `build_solution`, so -5 % of the wall; a result `==` to today's.
2. **A `report` keyword, additive; D46.** `report = (; node = false, edge = monitored, unit = generators)`: each
   family `true`, `false` or a vector of identifiers; the default `(; node = true, edge = true, unit = true)` is
   today. All three keys stay in the result, empty for `false`, so `nw_solution(r)["node"]` still works. Taken
   by `build_solution`, `optimize_model!`, `solve_model`, `solve_rd`, `solve_rolling_horizon`, checked (an unknown
   family is an `ArgumentError`). On step 3: nodes 0, edges 9,000, terminals 18,000, units 32,900, **60,000 of
   175,000 (-66 %)** in time, in `JuMP.value` reads and in bytes.
   `solution_tables`, `print_summary`, `zorba_tables` and `security_tables` read what the result holds; say so in the
   docstring of `report`.
3. **A typed core under the nested `Dict`: not now (Q9).**

## Decisions

- **D46, recorded 2026-10-09 (Tom Van Acker):** a solution holds what was asked for: a roll builds the committed
  indices, `report` names families and identifiers, and the default is everything. Tom chose option (B), levels
  1 and 2, over (A) level 1 only (-5 %, no memory change) and (C) Q9 first (largest, unmeasured).
- **`report` is a `NamedTuple`** whose `node`, `edge` and `unit` are each `true`, `false` or a vector of
  identifiers; a key left out means `true`. A roll's `solution_processors` see the committed indices only; its one
  user, `ParallelRun.jl:173`, reads the model.

## Verification

- Level 1: `build_solution(nm; nws = [2])` has exactly index 2 and equals the full result's entry; red on `main`
  (`MethodError`). `Base.summarysize` and `@timed` of a one-of-three build are about a third. A roll with
  `horizon > step` gives a `==` result on `main` and on the branch; the whole suite is unchanged.
- Level 2: the default equals today's; `node = false` leaves the node dict empty and the rest `==`; an id vector
  keeps exactly those; `solution_tables` of a filtered result has only those rows.
- Time and size: `b22_solution_study.jl` before and after, `full` 0.26 s (profile) and 0.20 GB to at most 0.17 s
  and 0.14 GB after level 1, and the result MB and entry counts above after level 2.
- Pipeline, week 1, 7 + 7 processes beside a same-day control of `main` (the B21 recipe, `scratch/b21_compare.jl`):
  objectives, overload rows and volumes bit-identical with `report` set to what the reports read; chunk time
  **-9 to -12 %** (16 % is the ceiling); `maxrss_gb` 5.0 down by 1.0 to 1.6.

## Commit order

1. `nws` in `build_solution` and `optimize_model!`, the roll passes the committed ones, with its tests.
2. The six builders cheaper, the result `==` (the level-1 numbers go in `CHANGELOG.md`).
3. After D46: `report`, its tests, the docstring, `scripts/run_year_redispatch.jl` using it.
4. `Project.toml` 0.12.6, `CHANGELOG.md`, headers; after the pipeline run STATE and B22.

## Stop rule, and what follows

If after levels 1 and 2 `build_solution` is still above 8 % of the wall, or a 24 h chunk still holds more than
1.5 GB of result: Q9, a typed core and a nested `Dict` view. Otherwise B22 is done and B25 is next.

## What this deliberately does not decide

- Q9, and B20's rest (`update_model!`, 26 % of the wall, the next biggest).
- `JuMP.value` (22 % of `build_solution`): a bulk read through MOI was B6's stop-rule failure; revisit only after
  level 2 has cut the number of reads.

## Result (2026-10-09)

- Commits `abb5dc6` (indices), `88dbc6c` (builders), `735b7e2` (`report`), then the release commit; suite 3217.
- One real window, `build_solution` over every index, minimum of five: step 3 (80 indices) 0.43 s to 0.29 s with
  the builders alone, 0.14 s and 89 MB to 31 MB with the pipeline's `report` (9,762 of 34,962 edges, 32,880 of
  51,600 units, no node); step 2 (42 indices) 0.134 to 0.080 to 0.018 s, 39 MB to 5 MB. Equal to the old result.
- Week 1, 7 + 7 against `main` (`runs/_b22_new`, `_b22_control`): chunk -12.3 %, peak 5.0 to 2.9 GB, objectives
  bit-identical. `redispatch_volumes` reads a `Dict`, so its CSVs came in another row order (B29).
- Stop rule, timed inside an 8-window step-3 roll (`scratch/b22_share.jl`): 7.8-9.3 % of the wall with the
  report, 12.6-13.3 % without; a 24 h chunk holds under 1 GB. The 8 % line is crossed or not by the noise of
  a shared machine: Tom decides on Q9. A sampled profile said 12.9 % of samples, 22.1 % without the report.
