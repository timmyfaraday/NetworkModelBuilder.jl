# Review of `main` against the Julia Modeling knowledge base

Status: proposed, nothing decided · Requested by: Tom Van Acker · Date: 2026-10-08
Decisions: D45 (item 1, see `topology-lookup.md`); next free: D46 · Backlog: B21-B28 · Questions: Q7-Q9

Reviewed: `main` at `6d6f6f1` (v0.12.4): `src/`, `ext/`, `scripts/`, `docs/`, `test/`, CI. Guide: the
node *Julia Modeling* of the knowledge base (`D:\KnowledgeBase\Julia Modeling`), one source, a 2026
workshop deck tagged `internal`. NMB is public, so this file cites the wiki pages and deck page
numbers (`p.N`) and never quotes them.

Order: the guide's own order for run time (measure, algorithms and data structures, type stability,
allocations, parallelisation, cache locality), then modeling patterns, then packaging. "Measured" =
read from the profiles in `scratch/` (local, gitignored: `b6_roll_profile_flat.txt`, 8 windows, 29.6 s
wall, 9,782 samples at 2 ms; `b6_stages_after_out.txt`) or run on 2026-10-08 (read-only scripts, not kept).

## Already as the guide asks (keep, do not redo)

- Builder pattern (*Composing submodels*, p.76): every variable, constraint and objective is a method on
  `NetworkModel{P,F}`; the registries make a new type join without touching a problem.
- Structs with validating constructors over dictionaries (*Structs over dicts*, p.62-66), with
  `ArgumentError` where the deck's example uses `@assert`; `Switch`, `Transformer`, `DCLink`, `Storage`.
- Function barriers (*Type stability*, rule 6, p.32): `edge(nm, e; nw)::T` before each loop, and
  `registered_constraints(...)::Dict{...}`. The `@generated` `has_nw_data`/`nw_component` is rules 4-5 and
  was B6's -13.6 %.
- One environment per task, the playground with `[sources]` (*Environments*, p.10): `scripts/`; the
  package's `Manifest.toml` ignored, the application's tracked; extensions for Arrow and Parquet2 (p.11).
- Measure first, then a same-day control run (`lessons.md`, Performance).

## 1. Topology lookups: reduce the calls, not only the cost of one (B21)

- Guide: *Optimisation priorities* (measure, then algorithms), *Type stability* rules 4-5.
- Evidence: `topology` is 1,929 of 9,782 samples = **13 % of the wall**, `_signature` 1,608 (11 %), and
  1,338 (9 %) of it arrive through `edge_arcs`. `edge_arcs(nm, e; nw)` is called once per edge inside
  `for e in ids(nm, T; nw)` (`branch.jl:153`, `:177`, `:223`, `:244`; the same in `transformer.jl`,
  `switch.jl`, `dc_link.jl`; `node_arcs` and `node_units` once per node, `node.jl:147`, `:298`), and each
  call derives the signature again: a `BitVector` and an `nw_value` per switchable component. Measured on
  case14 with 17 switchable statuses: 432 B and 0.7 µs per call, so it grows with the number of outages.
  `Base.return_types(topology, ...)` is `Union{Nothing,Topology}`: `net.fixed === nothing || return
  net.fixed` reads the field twice.
- Proposal: (a) bind `fixed = net.fixed` once; (b) answer a repeat of the last index from a one-entry memo
  on the `Network`, rather than hoisting the lookup at over 130 call sites (measured, `topology-lookup.md`);
  (c) only if still hot, B20's packed status matrix; (d) a slot per index would **change the invariant
  "derived, never tabulated"**, so it needs a decision first.
- Check: `@inferred topology(net; nw = 1)`; flat profile share of `topology` under 3 %; same-day control:
  objectives bit-identical, chunk time. The 13 % is an upper bound (Amdahl).

## 2. Building the result (B22, decision Q9)

- Guide: *Structs over dicts* (p.62-65), *Allocations* #1 (p.40), abstract element types (p.29, p.41).
- Evidence: `build_solution` is 2,750 samples = **19 % of the wall**; B6 found reading values is 0.07 s
  of 0.7 s, so the rest is `"$u"` string keys and one `Dict{String,Any}` per component. A 1-hour step-3
  window allocates 1.47-1.51 GB and spends 0.73-1.60 s of 5.4-6.5 s in GC. The pipeline's header blames the
  shared garbage collector for threads not scaling (not proven, `lessons.md`); the guide ranks allocation
  (#4) before parallelisation (#5), so the allocation rate is the first thing to lower.
- Proposal: (a) `build_solution` only for the network indices a roll keeps: `solve_rolling_horizon`
  discards `horizon - step` of every window, nothing in the pipeline (8/8, 1/1) but 83 % at 48/8;
  (b) fill the typed columns `solution_tables` already builds and make the nested `Dict` a view over
  them. D11 keeps the nested `Dict` as the default, so (b) is Q9. (a) changes no API.
- Check: bytes and GC per window with `@timed`, before and after; `nw_solution` equal on the test suite.

## 3. Validation in the inner constructors (B23)

- Guide: *Structs over dicts* p.65-67 (an inner constructor validates every instance), p.69.
- Evidence: 11 of 11 invalid inputs were accepted: `Generator(pmin = 2, pmax = 1)`, `qmin > qmax`,
  `pmax = NaN`; `Node(vmin = 1.1, vmax = 0.9)`, `vmin = -1`, `base_kv = -380`; `FixedLoad(pd = NaN)`;
  `Branch(r = NaN)`, `r = x = 0`, `rate_a = -1`; `Cable(length_km = -5)`. A generator with `pmin 3 > pmax 1`
  in case5 gives an OPF `INFEASIBLE` with nothing pointing at it. `Switch`, `Transformer`, `DCLink`, `Storage`,
  `FlexibleLoad`, the slack units validate; `Node`, `Generator` (energy only), `FixedLoad`, the branch family
  (terminals and angles only) do not.
- Proposal: the same style as `_check_branch` and `all_nw`: ordered limits, finite impedance, non-negative
  rating and length, no NaN in a setpoint. Load the Zorba data and the Matpower cases first: a rule that
  real data breaks (`rate_a = 0` in Matpower means unlimited) is a decision, not a fix.
- Check: one `@test_throws` per refusal; suite; week 1 loads.

## 4. State the package keeps in free-form dictionaries (B24)

- Guide: *Structs over dicts* p.64 (extra keys go unnoticed), *Composing submodels* p.78 (who owns a shared
  variable).
- Evidence: `ext` is documented as storage for extension packages, yet the package keeps nine registers in
  `nm.ext`: `:registered`, `:redispatch`, `:redispatch_control`, `:overload_peak`, `:storage_balance`,
  `:storage_final`, `:storage_cycles`, `:generator_energy`, `:flexible_load_energy`. `var`/`con` are keyed
  by `Symbol`, shared with every extension: the `StarEdge`/`:vsr` incident in `lessons.md`. `constrain!`
  keys its register by `Tuple{Int,Symbol,Any}` to values that are abstract (`ConstraintRef`,
  `ScalarConstraint`); `constrain!` is 656 samples (4 % of the wall), the register's share unmeasured.
- Proposal: (a) typed fields on `NetworkModel` for the package's own registers, `registered` first;
  (b) a second registration of a key with another index set is an error, and `extending.md` says to prefix
  an extension's keys. (a) is internal; (b) changes the extension contract and needs a decision.
- Check: suite unchanged; `Base.return_types(registered_constraints, ...)` concrete without the assertion.

## 5. Guard rails for the measure step (B25)

- Guide: *Benchmarking and profiling tools* (p.48), *Optimisation priorities* #1.
- Evidence: the profiles behind B6 (-57 %) are in `scratch/`, gitignored; the only guard is a private
  full-year run. There is no `benchmark/` and no `@inferred`; B6's boxed field loop was invisible to every
  correctness test and cost 12 %.
- Proposal: (a) `test/inference.jl`: `@inferred` on `topology`, `ids`, `nw_component`, `has_nw_data`,
  `nw_value`; it earns its place by reproducing a defect that happened (`tests.instructions.md`);
  (b) `benchmark/`: case14 repeated with N-1 statuses, time, bytes and GC of one window, run by hand;
  (c) GC time and bytes per chunk in `chunk.csv`, which would settle the "cause not proven" in `lessons.md`.
- Check: red/green: restore the `Union` return of item 1 and `@inferred` must fail.

## 6. Run configuration of the pipeline (B26)

- Guide: *Config-driven scripts* (p.53-58): the script stays generic, a config file names the experiment.
- Evidence: `run_year_redispatch.jl` reads 12 `NMB_*` variables, hardcodes two absolute paths (`D:`, `O:`)
  and `XPRESSDIR`, and does its setup as top-level code with non-const globals that `run_chunk` reads
  (rule 1, p.28; small, once per chunk). `runs/` holds 70+ folders whose settings live in shell history.
- Proposal: a TOML run file (Base `TOML`, no dependency) read by `read_config`, copied to
  `runs/<id>/config.toml` with the git sha and `Project.toml` version, `main(config)` and a `Setup` struct;
  the file path as `ARGS[1]`; the variables become overrides or go.
- Check: week 1 through a config file gives the same `chunks.csv` and objectives as the variables.

## 7. Packaging (B27, decisions Q7, Q8)

- Guide: *Environments* p.9-11 (a package is a namespace, versions have a meaning, `[sources]`).
- `docs/Project.toml`: no `[sources]` (CI runs `Pkg.develop`), `[compat]` for two of six deps.
  `scripts/Project.toml`: no `[compat]` at all; `[sources]` needs Julia 1.11, which `scripts/` and `docs/`
  can assume. HiGHS, Ipopt, Juniper and PowerModels in `[extras]` have none, so a PowerModels major bump
  would break the live cross-check silently. Optional, a taste call: `test/Project.toml` for `[extras]`.
- Q7: **267 exported names**, among them `ids`, `node`, `edge`, `unit`, `nodes`, `edges`, `units`, `status`,
  `window`, `solution`, `objective`, `network`, `topology`. The collision with PowerModels (`ids`, `parse_file`)
  already cost D5; `edges` (Graphs.jl) and `unit` (Unitful) are the same kind. Keep entry points and types
  exported, mark builder internals `public`: breaking, and `public` needs `Compat.@compat` or a `VERSION`
  guard while CI tests 1.10.
- Q8: tags exist for `v0.6.0`, `v0.9.1`-`v0.9.7`, `v0.12.0` only; `Project.toml` says 0.12.4, the changelog
  lists 0.10.x, 0.11.0, 0.12.1-0.12.4 (no tag), the tracked `scripts/Manifest.toml` says 0.10.2.

## 8. Start-up cost (B28)

- Guide: *Config-driven scripts* p.59 names the problem and no remedy; `PrecompileTools` is beyond the guide.
- Evidence: `using NetworkModelBuilder` 1.8 s; first `solve_lf` on case14 (LPF, HiGHS) 11.3-11.8 s against
  5 ms for the second; `solve_opf` (IVR, Ipopt) 8.7 s against 16 ms; the first window of a pipeline roll
  16.1 s against 6.1 s. NMB's share of that is not separated from JuMP's and the solver's.
- Proposal: measure the split first. A workload through `instantiate_model` and `build_model!` (no solver)
  covers NMB's share; 73 processes of ~20 min each pay it, a few percent of a year run, so this is for
  interactive use and the 3-minute suite.

## Considered, not proposed

- Abstract container fields (`Network.node::Dict{Int,AbstractNode}`, `Network.dim::Dimension`,
  `NetworkModel.var`): rules 2-3 of the guide, but the `::T` barriers contain them; `nw_value` is under 2 %.
- Runtime-index field loops left (`_slice`, `same_structure`, `structure_varies`): 0.01-0.12 s a window.
- `nw_component` through a validating constructor (B20 candidate): 77 samples, 0.8 %.
- A reader registry for `parse_file` (*Deserialising model configs*): one format beyond Matpower today.
- Locals of `solve_rolling_horizon` that start as `nothing` (`held`, `previous`): window level, below the bar.

## Suggested order

1, 2(a), 5 first: measured, no API change, and 5 protects the rest. Then 3, 4(a), 6, 7. Items 2(b), 4(b) and
Q7, Q8 wait for Tom's answers. Each item is its own branch and version, tested against a same-day control.
