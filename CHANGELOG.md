# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Versions before 0.9.1 were never tagged in git; the version numbers and dates
below are reconstructed from `Project.toml`'s own history, cross-referenced
against the per-file changelog comments the source already carries.

## [Unreleased]

## [0.12.1] - 2026-10-07

### Fixed

- A rolling horizon with `reuse = true` built almost every window from scratch when a
  generator's limit varied over the network index: `same_structure` read a power limit
  or a rating that crossed ±π/2 = 1.571 pu as a change of the shape of the model. That
  test is now asked only of an angle limit, `angmin` or `angmax`; every other limit is
  asked whether it is finite. On the Zorba year 8,353 of 8,760 windows of the internal
  redispatch were built from scratch, and 5 of 6 windows of a short roll now reuse the
  model, which took about 17 % off its wall time.
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
