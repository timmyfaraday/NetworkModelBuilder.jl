# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Versions before 0.9.1 were never tagged in git; the version numbers and dates
below are reconstructed from `Project.toml`'s own history, cross-referenced
against the per-file changelog comments the source already carries.

## [Unreleased]

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
