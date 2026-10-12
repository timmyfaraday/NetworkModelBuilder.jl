# Performance history

How long a rolling-horizon redispatch takes has changed a good deal between versions. This page
records, version by version, what was changed to make it faster and what each change was measured
to do. The figures are measurements on one machine (112 cores, 1 TB of memory) and say how large a
change was there, not what it will be elsewhere.

## The workload

Every figure comes from the three-step redispatch pipeline in `scripts/run_year_redispatch.jl`, run
over one year of real network data: 8,760 hours, 234 nodes and 399 branches, with 13 cross-border
and 79 internal contingencies.

1. A load flow at the market-cleared dispatch.
2. A cross-border N-1 redispatch, in rolling windows of 8 hours that commit 8.
3. An internal N-1 redispatch, in rolling windows of 1 hour that commit 1. One window is 80 network
   indices, the base case and 79 contingencies, with about 249,000 variables and 274,500
   constraints.

No hour depends on another there (storage is left out, nothing ramps), so the year is cut into 365
chunks of 24 hours that solve independently. A chunk runs all three steps for its hours. The year is
run as 73 one-thread processes of five chunks each, all at once, with two solver threads per solve.
A chunk's time is what the tables below call *chunk time*; the wall time of a year is that of its
slowest process.

## A year, three versions

| Version | Wall time | Chunk time (mean) | Peak memory a process | Chunks sound |
|:--------|----------:|------------------:|----------------------:|-------------:|
| 0.12.0  | 52 min    | 549 s             | 6.2 GB                | 365 of 365   |
| 0.12.3  | 24 min    | 237 s             | 7.3 GB                | 365 of 365   |
| 0.15.7  | 17.1 min  | 177 s             | 3.5 GB                | 365 of 365   |

From 0.12.0 to 0.12.3 the wall time fell by 54 % and the chunk time by 57 %; from 0.12.3 to 0.15.7
by a further 28.5 % and 25.3 %. A year of 0.15.7 takes a third of the time of one of 0.12.0.

The three runs solve the same problem. Objectives agree between 0.12.0 and 0.12.3 to 2.6e-8
relative (median 1e-14). Between 0.12.3 and 0.15.7 every objective, every overload row and every
unit-hour volume is identical. In all three years no chunk needed the fallback solver and none had
a solution that broke one of its own constraints by more than 1e-3.

Between 0.12.3 and 0.15.7 the time moved as follows, in seconds of chunk time:

| | 0.12.3 | 0.15.7 | change |
|:--|------:|-------:|-------:|
| load flow (step 1)            |   4.2 |   3.8 |   -7.4 % |
| cross-border redispatch (step 2) |  29.3 |  25.9 |  -11.8 % |
| of which the solver           |   7.8 |   7.5 |   -3.6 % |
| internal redispatch (step 3)  | 203.3 | 146.9 |  -27.7 % |
| of which the solver           |  38.8 |  34.6 |  -10.8 % |
| the whole chunk               | 237.3 | 177.3 |  -25.3 % |

The solver is a small part of a chunk and barely moved. What was made faster is the work the
package does around each solve.

## What changed, version by version

Each figure is the effect of that change alone, measured against the version before it (see
[How the effects were measured](@ref)).

### Up to 0.12.3

| Version | Change | Effect |
|:--------|:-------|:-------|
| 0.12.1 | A rolling horizon with `reuse = true` rebuilt almost every window from scratch. `same_structure` read a power limit or a rating that crossed ±π/2 = 1.571 pu as a change of the shape of the model; it now asks that of an angle limit only, and asks every other limit whether it is finite. On the year, 8,353 of 8,760 windows of step 3 were built from scratch. A window now reuses its model, and the solver starts from the last basis. | Chunk time 344 s to 254 s (-26.2 %); solver time of step 3 -60 to -75 % |
| scripts only | The feasibility check of each window (`worst_violation` in `scripts/ParallelRun.jl`) reads the rows back from the solver's interface into a plain vector, where it read them through JuMP, which builds an object per row. | 2.24 s to 0.45 s on a step-3 window; chunk time -16.5 % |
| 0.12.2 | `has_nw_data` and `nw_component`, which resolve a component at a network index, are generated per component type and read every field by a constant index. A loop over `getfield(c, k)` with a runtime `k` had boxed every field of every component at every network index, 1,248 to 2,176 bytes a call. | Chunk time 208 s to 180 s (-13.6 %) |
| 0.12.3 | `Network` holds the status of each switchable component as typed vectors, and `topology` reads those. It had read each status through the component, an abstract `Dict` value, on every call. | Chunk time 180 s to 152 s (-15.6 %) |

Together these took the year from 52 to 24 minutes.

### After 0.12.3

| Version | Change | Effect |
|:--------|:-------|:-------|
| 0.12.5 | `topology` remembers the answer it gave last, in one atomic slot of the `Network`, and returns one concrete type. A model build asks for the topology of one index 80 to 142 times in a row, and each ask derived the statuses of every switchable component again. | Chunk time 151 s to 135 s (-10.7 %); `topology` 16 % of the wall time before, 1.7 % after |
| 0.12.6 | A rolling horizon builds the solution of the network indices it commits, where it built the lookahead too and threw it away. A `report` says which families and identifiers a solution holds, and the pipeline reads no node, only the monitored edges and the phase shifting transformers, and every unit. The six solution builders look a container up once per component type and make each key once. | Chunk time 993 s to 871 s over seven chunks (-12.3 %); peak memory a chunk 5.0 GB to 2.9 GB; the solution of one real window, reading only what the pipeline reads, 0.31 s to 0.14 s and 89 MB to 31 MB |
| 0.12.9 | The registers of a model are typed fields of `NetworkModel` and no longer keys of `nm.ext`; seven keys the package wrote and nothing read are gone. | A held step-3 model 243.6 MB to 236.3 MB; `update_model!` 1.29 s to 1.18 s (about -9 %) |
| 0.14.0, 0.15.0 | Every variable was given a name built at its call site. 0.14.0 made that optional (`set_string_name`), and from 0.15.0 nothing is named unless `debug_mode = true`, with JuMP's string names on creation switched off. | A cold build of a step-3 window 1,707 ms and 764 MB by default, 2,401 ms and 1,372 MB in debug mode with every variable and constraint named. A window is built cold once per step and then updated, so the gain is under a second of a chunk |

### Without an effect on the year

These versions changed the package without making the pipeline faster, and each was checked not to
make it slower.

| Version | Change | What was checked |
|:--------|:-------|:-----------------|
| 0.12.4 | A test asserted a solve time above 0 and failed when a small case solved faster than the clock's resolution. | Tests only |
| 0.12.7 | A test that `has_nw_data` and `nw_component` allocate nothing, the `benchmark/` environment, and the seconds of garbage collection and gigabytes allocated of each chunk in `chunk.csv`. | The allocation test fails on the sources before 0.12.2 and passes now |
| 0.12.8 | A constructor refuses input a model cannot use. | Cutting a step-3 window takes 7.5 ms against 7.7 ms before |
| 0.13.0 | One `Branch`, of two or more terminals, in place of `Branch`, `Cable` and `OverheadLine`. | Rebuilding a branch costs 47 ns and 32 B against 62 ns and 144 B; cutting a step-3 window 7.7 to 7.8 ms against 7.7 to 8.0 ms |
| 0.15.1 to 0.15.7 | The storage review: end conditions, a cycle limit, outages, a curative range. | The pipeline has no storage, so none of it is read there |

A 24-hour chunk of 0.12.8, 0.12.9, 0.13.0 and 0.15.0 is byte-identical to the one of 0.12.7, and
that of 0.14.0 to the one of 0.13.0.

## How the effects were measured

- **A pair of weeks.** A change is run over hours 1 to 168, seven chunks, as seven one-thread
  processes beside seven of the version before it, started together, on the same hours; where the
  pair was run twice the launch order was swapped. The chunk times above are from such pairs. The
  same code run three days apart differed by 5 %, the machine being busier, so a change is only
  compared with a control run the same day.
- **The year runs** of the first table are one run each, days apart, without a same-day control.
  They agree with the single changes: those up to 0.12.3 compound to -55 % of chunk time, against
  the -57 % measured, and 0.12.5 and 0.12.6 alone to -22 %, against the -25 % measured, the rest
  being 0.12.9 and the state of the machine.
- **One window.** `benchmark/window.jl` times one window of a rolling redispatch on case14 with an
  outage per branch, stage by stage, and is run beside a worktree of the other version. Against
  0.12.4, 0.12.7 shows `update_model!` at 26.9 ms against 30.4, `build_solution` at 4.7 ms against
  9.3 and the whole roll at 706 ms against 868, with the solve unchanged at 35.7 ms.

## Where the time goes now

In a chunk of 0.15.7, 177 s on average, step 3 takes 147 s (83 %), step 2 26 s (15 %) and the load
flow 4 s (2 %). The solver takes 42 s (24 %) and garbage collection 24 s (13.5 %); a chunk
allocates 25 GB. The rest is Julia work around the solve: cutting windows, building and updating
the model, building the solution and checking it.

## Settings that did not help

- **Threads in one process.** Seven chunks as seven threads of one process took 224 s a chunk;
  as seven processes 125 s. Garbage collection was 14.4 % of a chunk in one and 14.2 % in the
  other, so the collector is not what the threads lose to. Run many one-thread processes.
- **Longer windows.** Windows of 48 hours committing 8 gave the same answer as 8 and 1 hour but took
  4,944 s for hours 1 to 48, against about 670 s for two 24-hour chunks, and 27 GB. With no
  coupling between hours a longer window only adds model size and overlap.

## Running a year

The header of `scripts/run_year_redispatch.jl` has the recipe: one-thread Julia processes, each on
its own range of hours (`NMB_HOURS`) with a shared `NMB_RUN_ID`, `NMB_CHUNK_HOURS = 24`,
`NMB_XPRESS_THREADS = 2` and `NMB_MERGE = 0`, then one last run over the whole range with
`NMB_RESUME = 1`, which finds every chunk done and only merges them.
