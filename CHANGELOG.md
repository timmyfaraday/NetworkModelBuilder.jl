# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Versions before 0.9.1 were never tagged in git; the version numbers and dates
below are reconstructed from `Project.toml`'s own history, cross-referenced
against the per-file changelog comments the source already carries.

## [Unreleased]

## [0.12.8] - 2026-10-10

### Changed

- A constructor refuses input a model cannot use. Before, 19 of 19 such inputs built, and the solver
  answered `INFEASIBLE` with nothing pointing at the component, or a row held a `NaN`. Each now raises an
  `ArgumentError` that names the component, and checks a `NetworkVector` at every network index, whether
  or not the component is in service:
  - `Node`: `vmin` below 0 or above `vmax`, a `base_kv` below 0, a `vm` or `va` that is not finite.
    A `base_kv` of 0 stands for unknown, as Matpower's case14 has it.
  - `Generator`: `pmin` above `pmax`, `qmin` above `qmax`, a NaN limit, a setpoint or a cost coefficient
    that is not finite. An infinite limit is how a bound is left out, and `cost_up` and `cost_dn` may be NaN.
  - `FixedLoad` and `Shunt`: a demand or an admittance that is not finite.
  - `Branch`, `Cable` and `OverheadLine`: `r` or `x` not finite, `r` and `x` both 0 (a bus coupler is a
    `Switch`), a shunt admittance not finite, a negative or NaN `rate_a` (`Inf` is unlimited); `Cable`
    and `OverheadLine` also a `length_km` negative or not finite.
  - Not refused: the sign of `r` and `x` (a series capacitor has a negative `x`), a negative demand, a
    negative `bs`, and `pg` outside its limits.
  Code that built such a component now fails where it builds it. The rules were run over the four bundled
  Matpower cases and the Zorba year of 8,760 hours (234 nodes, 93 generators, 234 loads, 399 branches):
  only `base_kv > 0` failed, on case14, hence the 0. Cutting a real step-3 window, which rebuilds 1,437
  components, takes 7.5 ms against 7.7 ms before, and a 24 h chunk of the Zorba pipeline comes out
  byte-identical to the same chunk of 0.12.7.

## [0.12.7] - 2026-10-09

Tests and tooling only; nothing under `src/` changed.

### Added

- `test/hot_path.jl`: `has_nw_data` and `nw_component` of a node, a branch and a generator without
  network data allocate nothing. Run against the sources before 0.12.2 the same file fails all six
  checks, with the 1,248, 1,664 and 2,176 bytes a call that the boxed field loop cost; `@inferred` passes
  on those sources, so it is not used.
- `benchmark/`, an environment of its own (BenchmarkTools, HiGHS, JuMP and the package by path), and
  `benchmark/window.jl`: one window of a rolling redispatch on case14 with an outage per branch, timed stage
  by stage (cutting the window, `instantiate_model`, `update_model!`, the solve, `build_solution` whole and with
  a `report`, the whole roll). Run by hand beside a worktree of the other version. Two runs apart every
  minimum agrees within 3 %; against 0.12.4 it shows `update_model!` 30.4 to 26.9 ms, `build_solution`
  9.3 to 4.7 ms and the roll 868 to 706 ms, and leaves the solve at 35.7 ms.
- `scripts/run_year_redispatch.jl`: `chunk.csv` gains `gc_s` and `alloc_gb` for the chunk and for steps 2 and 3
  (six columns), the seconds of garbage-collection pause and the gigabytes allocated, read from the process's
  own counters, so exact for a process that runs one chunk. A run begun before them must not be resumed
  after. Zorba week 1, 7 one-thread processes against one process on 7 threads, side by side: a chunk takes
  125 s against 224 s and spends 14.2 % against 14.4 % of it in pauses (step 3: 16.7 % against 14.9 %), so
  the collector does not explain why threads stop paying.

### Changed

- The `[run]` lines of that script report the pause since the start of the solve, which is what the
  elapsed time beside them measures, rather than the process total with its set-up.

## [0.12.6] - 2026-10-09

### Added

- A solution holds what it is asked for. `build_solution(nm; nws, report)` and
  `optimize_model!(nm, optimizer; solution_indices, report)` take the network indices to build
  and a `report`, a `NamedTuple` whose `node`, `edge` and `unit` are each `true`, `false` or a
  vector of identifiers; a family left out is `true`, so the default is the whole solution, as
  before. A family that is not asked for stays in the result, empty. An unknown family, an
  identifier the model does not have, or any other value is an `ArgumentError`. `solve_model`,
  `solve_rd` and `solve_rolling_horizon` take `report` too. `solution_tables` and `print_summary`
  show what the result holds; `zorba_tables` and `security_tables` read every edge, so leave
  `report` alone for a result they are to read.

### Changed

- A rolling horizon builds, for each window, the solution of the network indices that window
  commits and no others, where it built the lookahead too and threw it away. The `solution_processors`
  of a roll therefore see the committed indices in `nm.sol["solution"]`. The result of the roll
  is unchanged.
- The six solution builders (node, edge and unit, in current and linearized form) look a container
  up once per component type, make a component's key once and assign each entry, where they looked
  up per component, made the key up to five times and built each entry through the vararg `Dict`
  constructor. The result is `isequal` to the old one on case14, on case5 with time and contingency
  dimensions, and on real windows. One real window, `build_solution` over every index, minimum of
  five: 80 indices 0.43 s to 0.29 s and 0.20 to 0.18 GB, 42 indices 0.134 s to 0.080 s.
- With the `report` the Zorba pipeline reads (`pipeline_report` in `scripts/PipelineReports.jl`: no
  node, the monitored edges and the phase shifting transformers, every generator and storage
  unit), the same window builds 9,762 of 34,962 edges and 32,880 of 51,600 units: 0.31 s to 0.14 s
  and 89 MB to 31 MB. A Zorba week of 24 h chunks against 0.12.5, side by side, took 12.3 % less
  wall time (871 s against 993 s over the 7 chunks, faster in 7 of 7), and a chunk peaked at 2.9 GB
  where it peaked at 5.0 GB. Objectives are bit-identical and so are the overload, shedding,
  spillage and congestion files; the redispatch volume files hold the same rows in another order,
  since `redispatch_volumes` reads them in `Dict` order.

## [0.12.5] - 2026-10-09

### Changed

- `topology` remembers the answer it gave last. `Network` has a new field, `last`: one
  slot, written atomically, holding the network index asked last and its topology. A model
  build asks for the topology of one index many times in a row (80 to 142 times per index
  on case14), and each ask derived the statuses of every switchable component again; a
  repeat is now a comparison and allocates nothing. It is one entry however many network
  indices there are, not a table of them. `topology` also returns one concrete type,
  `Topology`, where it inferred `Union{Nothing,Topology}`. Results are unchanged;
  `update_model!` of a redispatch on case14 with an outage per branch, against 0.12.4 on
  the same machine, took 4.8 ms against 6.7 ms (-28 %) and allocated 3.1 MB against 4.0 MB.
  A Zorba week of 24 h chunks against 0.12.4, side by side, took 10.7 % less wall time
  (135 s against 151 s a chunk, faster in 7 of 7), with objectives, overload rows and
  redispatch volumes bit-identical.

## [0.12.4] - 2026-10-07

### Fixed

- `test/lf.jl` asserted `solve_time > 0.0`, which failed whenever a small case solved
  faster than the resolution of `time()` on Windows. It now asserts `>= 0.0`, which still
  fails for the `NaN` a solve that never recorded its time would leave. Tests only.

## [0.12.3] - 2026-10-07

### Changed

- `Network` has a new field, `status`: the status of each switchable component, in the
  order of `switchable`. `topology` is asked for every node, edge and unit of every
  network index, and picked the topology of an index by reading the status of each
  switchable component through the component, an abstract `Dict` value, on every call.
  It now reads the typed vectors. Results are unchanged; a Zorba week of 24 h chunks
  against 0.12.2, side by side, took 15.6 % less wall time (152 s against 180 s a chunk).
  Together with 0.12.1 and 0.12.2 the Zorba year, as 73 one-thread processes, took 24
  minutes against 52 with 0.12.0, for the same objectives to 3e-8.

## [0.12.2] - 2026-10-07

### Changed

- `has_nw_data` and `nw_component`, which resolve a component at a network index, are
  generated per component type and read every field by a constant index. The loop over
  `getfield(c, k)` with a runtime `k` boxed every field of every component at every
  network index, in the model build, `update_model!` and `build_solution` alike. Results
  are unchanged; a Zorba week of 24 h chunks against 0.12.1 with the same feasibility
  check, side by side, took 13.6 % less wall time (180 s against 208 s a chunk).

## [0.12.1] - 2026-10-07

### Fixed

- A rolling horizon with `reuse = true` built almost every window from scratch when a
  generator's limit varied over the network index: `same_structure` read a power limit
  or a rating that crossed ±π/2 = 1.571 pu as a change of the shape of the model. That
  test is now asked only of an angle limit, `angmin` or `angmax`; every other limit is
  asked whether it is finite. On the Zorba year 8,353 of 8,760 windows of the internal
  redispatch were built from scratch; a Zorba week of 24 h chunks, side by side with
  0.12.0, now takes 26 % less wall time (254 s against 344 s a chunk) for the same
  objective to 4e-10.
- `same_structure` did not tell a `DCLink` whose `loss_prop` is zero from one whose
  `loss_prop` is positive, although the transfer variable of the link exists only for
  the second. A model updated across the change kept a transfer variable and a loss row
  the window does not have; the objective was equal in the cases checked, and it is now
  rebuilt.

## [0.12.0] - 2026-10-06

This release replaces four transformer types with one, and breaks the code that
named them: there are no shims for the old names. See the migration table at the end
of the section.

### Added

- `Transformer` is every transformer: two or more windings, each with a ratio, a
  series impedance and a shunt, meeting at a star point that carries the
  magnetising branch, `g_m` and `b_m`. The model is a T for two windings as for
  more, and the π-equivalent a Matpower branch with a ratio is, is the special case
  of no magnetising branch and the whole impedance on the first winding. The star
  point is an edge variable, not a node. A transformer with two windings accepts a
  scalar for the first winding where a field takes an entry per winding.
- `TapMode`, with `FIXED`, `CONTINUOUS` and `STEPPED`: the `oltc` field of a winding
  says whether its ratio magnitude can move, as a tap changer's does, and `pst`
  whether its angle can, as a phase shifter's does. A `Bool` is accepted, `true`
  for `CONTINUOUS`. A winding can be both, which in the `IVRFormulation` keeps the
  ratio in a ring between `tm_min` and `tm_max`, cut to the angles between `ta_min`
  and `ta_max`, and a transformer can have a control on any of its windings.
- `STEPPED` windings, with `tm_step` and `ta_step`: the winding takes one of the
  positions `lo, lo + step, …, hi`, a binary `zt` for each. A dispatch problem is
  then mixed-integer, a MILP in the `LPFFormulation` and a nonconvex MINLP in the
  `IVRFormulation`, with no duals, so the nodal prices are `nothing`. A winding can
  step its magnitude, its angle, or both over every pair; in the `LPFFormulation`
  only the angle exists, so only `pst` steps there. The solution reports the index
  of the position as `step`.
- `is_held(nm, family, id; nw)`: whether a preventive measure takes the setting of
  the base case at a network index. A held measure writes no row that only restricts
  it, and a held winding that steps reuses the binaries of the base case instead of
  tying copies of them, which leaves a mixed-integer solver `P` binaries rather
  than `P × N`.
- `constraint_linear_ratings!`, the rating of every terminal of an edge, and a
  rating per terminal where `constraint_edge_rating!` took one for the edge.
- `docs/src/components/transformer.md` rewritten for the one type, with the
  literature it follows.

### Changed

- **Breaking.** The fields of a `Transformer` are per winding: `r`, `x`, `g_sh`,
  `b_sh`, `tm`, `ta`, `tm_min`, `tm_max`, `ta_min`, `ta_max` and `rate_a` are vectors
  with an entry per terminal, and the shunt that was `b_fr` and `b_to` is
  `b_sh = [b_fr, b_to]`. `parse_matpower` builds the transformer with the ratio on
  the first winding and half the charging on each.
- **Breaking.** The tap of a transformer is reported under each terminal,
  `solution["edge"][e]["terminal"][k]["tap"]`, and not under the edge. In a
  redispatch it carries `tm_market` and `ta_market`, the setpoint the market left it
  at; `taup` and `tadn` are gone with the price.
- A phase shifter is a non-costly measure, and so is a tap changer: a transformer has
  no `cost` and no `redispatch_cost` method. Without the price that picked the
  least movement, a free angle is one of however many settings relieve the
  congestion equally; the overload of a redispatch is unchanged, but how the flow
  splits between parallel paths is not determined.
- A ratio that is held is substituted into the rows in the `IVRFormulation`, so a
  transformer that holds its ratio has no variable for the voltage behind it:
  case14 is 192 variables instead of 198.
- A transformer held at the base case writes the rows that restrict its ratio once.
  Written at every contingency as well, they were dependent next to the tie, and
  Ipopt stopped at its first iteration on a preventive phase shifter set at exactly
  zero.

### Deprecated

- `pst_cost` of `parse_zorba` warns and has no effect.

### Removed

- `PhaseShifter`, `TapChanger`, `MultiWindingTransformer` and
  `AbstractTwoWindingTransformer`, with `solution_tap`, `variable_two_winding!`,
  `constraint_two_winding_limits!` and `constraint_two_winding_flow!`.

### Fixed

- A transformer with three or more windings and a winding without impedance, which
  the `LPFFormulation` would write with an infinite susceptance and fail on with
  `NaN`, is an `ArgumentError` that names the winding.

### Migrating

| before | now |
|:-------|:----|
| `PhaseShifter(; ta_min, ta_max, cost)` | `Transformer(; pst = true, ta_min, ta_max)`; there is no price |
| `TapChanger(; tm_min, tm_max)` | `Transformer(; oltc = true, tm_min, tm_max)` |
| `MultiWindingTransformer(; terminals, r, x, g_m, b_m)` | `Transformer(; terminals, r, x, g_m, b_m)` |
| `Transformer(; b_fr, b_to)` | `Transformer(; b_sh = [b_fr, b_to])` |
| `solution["edge"][e]["tap"]` | `solution["edge"][e]["terminal"][k]["tap"]` |
| `parse_zorba(; pst_cost = c)` | `parse_zorba()`; the keyword warns and does nothing |
| a type test, `edge isa PhaseShifter` | `any(tf.pst .!== FIXED)` on the `Transformer` |

## [0.11.0] - 2026-10-04

### Added

- `Switch`, under `AbstractSwitch`, with `SwitchLock` (`FREE` and `LOCKED`): an
  edge with exactly two terminals that is closed or open and has no impedance,
  so a busbar coupler need not be a branch with a reactance of `1e-7`. Closed
  it equates the voltages at its two nodes, open it stops the flow, in both the
  `LPFFormulation` and the `IVRFormulation`. A locked switch is data; a free
  one is a binary variable `zsw` in a dispatch problem, which makes that model
  mixed-integer — with no duals, so the nodal prices are `nothing`, and a
  finite `rate_a` that the big-M rows are written with. A power flow holds every
  switch where its `position` puts it.
- Loops of closed switches share the flow equally, in every solver: the
  equality of voltages is written for a spanning tree of each group and every
  other switch gets the equation of its loop instead. A loop that free
  switches can close gets a row that holds when they are closed, one per
  simple cycle, and the model is not built above 1000 of them.
- A free switch is a preventive or a corrective measure of a redispatch, and
  non-costly. The solution carries the `"position"` and the `"lock"` of every
  switch, and so do the tables of `solution_tables`.
- `islands`, `connects` and `can_open`, and `check_islands`, which
  `instantiate_model` runs before it builds. An island that has units but no
  reference node and no source is now an `ArgumentError` that names its nodes;
  opening every free switch may not split an island unless
  `instantiate_model(...; islanding = :allow)`. An island that has a source but
  no reference node has its lowest node anchored, by
  `constraint_node_voltage_anchor`.
- `variable!` takes `binary = true`, and an integer is a structure gate, so a
  model of a different position is rebuilt rather than updated in a rolling
  horizon.
- `docs/src/components/switch.md`, with the literature it follows, the islands in
  the manual, and a
  cross-check of the switch against PowerModels.jl's `_solve_opf_sw` and
  `_solve_oswpf` on `test/data/matpower/switch_loop.m`. They agree except on a
  loop of closed switches, which PowerModels.jl leaves with a free flow.
- DocumenterCitations in the documentation: the references are in
  `docs/src/refs.bib`, cited author-year from the pages, and listed on a
  References page.
- Juniper, a test-only dependency like HiGHS, for the free switch in the
  `IVRFormulation`.

### Changed

- A network with an island that has load and no source no longer reaches the
  solver: where it came back as `INFEASIBLE`, or in the current-based load flow
  as a false `LOCALLY_SOLVED` with the voltage pushed towards infinity, it is
  refused when the model is instantiated.

### Fixed

- A file added under `src/comp/` was not seen by a package loaded from its
  compiled cache, so the new component was left undefined. `_include_dir` now
  declares every directory it walks with `include_dependency`.

## [0.10.2] - 2026-09-30

### Added

- `solution_tables(data, result)`: a tidy view of a `result` alongside
  `nw_solution` — one `NamedTuple` of plain columns per family of the
  extended graph (`node`, `edge`, `unit`), every dimension `data` is posed
  over becoming its own column, an edge's row per terminal rather than per
  edge, and a column no component or network index ever reports at all
  dropped rather than kept `missing` throughout. For a caller who wants every
  node or edge at once rather than one value at a time, e.g.
  `DataFrame(tables.node)` with DataFrames.jl, no new dependency of this
  package's own (gap #9 of `plans/GAP_CLOSURE_PLAN.md`).
- `docs/src/manual/concepts.md`: a "concepts for newcomers" page working one
  small network through `LoadFlowProblem`, `OptimalPowerFlowProblem` and
  `RedispatchProblem`, and through both formulations, then showing
  `nw_solution` and `solution_tables` side by side — plus a short, honest
  comparison to SmaLoadFlow's `PowerSystem`/`SolveOptions`/`RunResultXr`.

## [0.10.1] - 2026-09-30

### Changed

- `src/NetworkModelBuilder.jl` no longer lists every file under `src/comp/` or
  every name a component exports: a new `_include_dir` helper walks
  `comp/node/`, `comp/edge/` and `comp/unit/` (the file named like its own
  directory loading first in each one), and each component file now exports
  its own public names next to their definition. Adding a new edge or unit
  type needs no edit to the central file at all now — only its own file, in
  the right folder (gap #8 of `plans/GAP_CLOSURE_PLAN.md`). Purely internal:
  the public API is unchanged, verified by comparing `names(NetworkModelBuilder)`
  before and after.

## [0.10.0] - 2026-09-30

### Added

- `security_tables`: the flow of every edge, at every time step and every
  contingency but the base case, plus the two tables that reduce those to the
  worst case in either direction across contingency, together with which one
  attained it. Works on any `NetworkData` posed over a `:contingency`
  dimension, not only one `parse_zorba` built — towards feeding a dashboard's
  N-1 security screening directly from a solved model.
- `write_security_tables`: writes what `security_tables` returned as Parquet,
  one file per table. Parquet2 is a new weak dependency, gated the same way
  Arrow already is.
- `docs/src/manual/dashboard.md` and `plans/dashboard-output-mapping.md`: the
  manual page for the new output, and a reference mapping it against a real
  GRIP/Zorba-dashboard run's own file and column names.

## [0.9.7] - 2026-09-29

### Added

- `test/powermodels.jl`: a live cross-check against PowerModels.jl v0.21 on
  `case14` (load flow, optimal power flow in both formulations), alongside
  the existing frozen-value regression tests rather than instead of them.
  PowerModels.jl is a test-only dependency, like Ipopt and HiGHS.

## [0.9.6] - 2026-09-29

### Added

- Every complete example in the documentation now runs in CI, as a
  `test/docs.jl` check and as Documenter `@example` blocks, so a broken one
  (like 0.9.1's) fails the build instead of going unnoticed.

### Fixed

- The redispatch LPF example referenced an undefined `data`; it now builds
  the two-node network its own surrounding prose describes.

## [0.9.5] - 2026-09-29

### Added

- `CHANGELOG.md`.

## [0.9.4] - 2026-09-29

### Fixed

- `register_edge_type!`, `register_unit_type!` and `register_model!` could
  crash with `ConcurrencyViolationError` when called from more than one
  thread at once; each registry is now guarded by its own lock.

## [0.9.3] - 2026-09-29

### Changed

- `parse_tables` now warns when the `node`, `edge` and `unit` tables all come
  back empty, rather than silently building an empty network.

## [0.9.2] - 2026-09-29

### Fixed

- `parse_tables` raised a raw `BoundsError` when a table's columns disagreed
  on how many rows they had; it now raises a clear `ArgumentError` naming
  every column and its length.

## [0.9.1] - 2026-09-29

### Fixed

- A bare Matpower case file name (e.g. `"case14.m"`) now resolves against
  the package's own bundled case files when it isn't found relative to the
  working directory, so the documentation's quick-start examples work from
  anywhere, not only from `test/data/matpower/`.

## [0.9.0] - 2026-09-03

### Added

- The asset model: an energy limit per generator period; `EnergyNotServed`
  and `Spill` as slack units; storage cycle limits, a throughput cost, an
  inflow hook and an end-of-horizon target.
- Nodal prices, read from the duals of the node balance.
- The Zorba adapter (`parse_zorba`, `solve_zorba`, `zorba_tables`,
  `write_zorba`), translating a Zorba study into a network and back.
- A phase shifter's movement can be priced.
- A slack unit can take a side in the preventive-corrective split.

### Changed

- Price accessor nomenclature, to say which price each one returns.

## [0.6.0] - 2026-09-03

### Added

- `DCLink`.
- Tabular input (`parse_tables`, `parse_arrow`): a network as four tables,
  one Arrow file per table, without a hard dependency on Arrow.
- Periods group the coordinates of a `Dimension`, and a rolling-horizon
  window carries the periods it cut.
- A monitored edge's rating can be priced instead of enforced, and its
  overload is reported in the solution.

### Changed

- A flexible load's energy balance runs per period.

### Fixed

- A markdown table whose alignment row used a narrow cell (e.g. `|:-|`)
  silently fell back to a paragraph instead of rendering as a table; every
  table in the documentation is now checked for this in CI.

### Removed

- Ipopt as a hard dependency of the package; it remains a test dependency.

## [0.5.0] - 2026-08-28

### Added

- `RedispatchProblem`, and `solve_rolling_horizon`: a long horizon solved as
  a sequence of windows, reusing one `JuMP.Model` and warm-starting each
  window from the one before it.

## [0.4.0] - 2026-08-27

### Added

- `LPFFormulation`, the linearized power flow.
- A full problem statement per formulation in the documentation.

## [0.3.0] - 2026-08-27

### Added

- The component type hierarchy: `Branch`, `Cable`, `OverheadLine`,
  `Transformer`, `PhaseShifter`, `TapChanger`, `MultiWindingTransformer`,
  `Generator`, `FixedLoad`, `FlexibleLoad`, `Storage`, `Shunt`.
- A documentation site.

## [0.2.0] - 2026-08-26

### Changed

- Data that varies over the network index is now stored on the component
  itself as a `NetworkVector`, rather than the extended graph being
  replicated per index; the topology of a network index is derived from the
  statuses that vary, rather than tabulated.

### Deprecated

- `replicate`.

## [0.1.0] - 2026-08-26

### Added

- Initial implementation: the extended graph `(I, E, U)`, `NetworkModel{P,F}`,
  the load flow and optimal power flow problems in the IVR formulation, and a
  Matpower reader.
