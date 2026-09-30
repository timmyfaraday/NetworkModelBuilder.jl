# NMB → dashboard output mapping

**What this is**: a record of how [`security_tables`](../src/io/dashboard.jl) /
[`write_security_tables`](../src/io/common.jl) (added towards v0.10.0) line up
against the output an existing GRIP/Zorba market-model run produces for the
horizontal grid, so a future pass can unify the two vocabularies deliberately
instead of guessing at it again. As of 2026-09-30 the table names are a
decision (below); everything else here is the correspondence as it stands
today, not a decision to change either side.

**Source example** (the one the mapping below was checked against):
`GRIP/market_models/TY2040_Base_Central_eco_Reference_full_battery_old/
TY2040_Base_Central_eco_Reference/output/20260910-1434eco-full_battery/
economy/nm1/battery_abundance_2040/` on `isoapp1541_D`. Note for next time: the
top-level folder has since been renamed from `..._full_battery` to
`..._full_battery_old` — if it moves again, the shape below is what to look for
under whatever replaces it (`economy/nm1/<scenario>/*.parquet`).

## Table names

Decided 2026-09-30 (Tom Van Acker): use the dashboard's own names directly, so
its output can be plugged in with no relabelling. `security_tables` returns
`(; frank_safe_borders, nm1_max_flows, nm1_min_flows)` and
`write_security_tables` writes exactly those three files:

| NMB (`security_tables` key) | GRIP file                    | what it is |
|:-----------------------------|:------------------------------|:------------------------------------------|
| `frank_safe_borders`         | `frank_safe_borders.parquet`  | every edge, every time step, every contingency but the base case — the full N-1 sweep |
| `nm1_max_flows`               | `nm1_max_flows.parquet`       | per edge and time step, the largest flow across contingency, and which one attained it |
| `nm1_min_flows`               | `nm1_min_flows.parquet`       | the same, smallest |

A caller that wants different names on disk reads the table it wants under its
own — `write_security_tables` writes one file per `NamedTuple` entry, named
after its key, nothing more:

```julia
write_security_tables(dir, (; flows = tables.frank_safe_borders))
```

This trades away the more neutral names an earlier draft of this feature used
(`flows` / `max_flows` / `min_flows` — a mechanism that is really "the worst
case across whatever the `:contingency` dimension holds", true N-1 only because
that is what the source data happens to sweep) for zero-friction interop with
one specific consumer. See "Options for a future unification pass" below for
what revisiting this would look like.

## Why Parquet, not Arrow

NMB already writes Arrow (`write_zorba`, `parse_arrow`), and Arrow and Parquet
are sometimes assumed to be the same thing because both belong to the wider
Apache Arrow project — they are not. Arrow.jl (this package's existing weak
dependency) implements only the Arrow IPC format (`.arrow`/Feather2); its own
README says Parquet needs a separate package (`Parquet.jl` or, here,
`Parquet2.jl`), the same way it names `Avro.jl` for Avro. There is no way to
get a literal `.parquet` file out of Arrow.jl — reading `frank_safe_borders.parquet`
needs a Parquet-capable reader regardless of which Julia package writes it, so
Parquet2 is a new dependency either way, not a choice NMB could avoid by
reusing Arrow.

## Columns

The column names were made to match exactly, so the two are interchangeable at
the schema level — a straight `write_security_tables` output is a drop-in
replacement for what the old Python nm1 calculator wrote, column for column:

| column      | GRIP type      | NMB type (default)          | match, and what a Zorba study adds                |
|:------------|:---------------|:-----------------------------|:---------------------------------------------------|
| `outage`    | `large_string` | `String` (stringified coordinate) | exact once given real names: `outage = zorba_study(data).outage[2:end]` |
| `Name`      | `large_string` | `String`                     | exact whenever the network's own edge names are the ones a reader expects — always true for a `parse_zorba` study |
| `from_node` | `large_string` | `String`                     | exact under the same condition; NMB reads it off the edge's first terminal |
| `to_node`   | `large_string` | `String`                     | exact under the same condition; NMB's last terminal |
| `time_id`   | `uint16`       | `Int` (plain `1:nt` coordinate) | exact once given real ones: `time_id = zorba_study(data).time_id` |
| `flow_mw`   | `float` (32-bit) | `Float32`                   | exact — same unit, same sign convention (the terminal power of the edge's first-listed node, `GridModelSchema`'s `from_node < to_node`) |

Nothing needs casting on the four columns `security_tables` derives from the
network itself (`Name`, `from_node`, `to_node`, `flow_mw`); `outage` and
`time_id` need the real labels passed in because NMB's own `:contingency` and
`:time` dimensions are plain coordinates and carry no name of their own — a
`ZorbaStudy` is what tracks them for a Zorba-built network, see
`docs/src/manual/zorba.md`. A network built any other way either doesn't have
this problem (its own `:time` coordinate *is* the time step a reader wants) or
needs the same treatment a Zorba study gets: pass the real names in.

## Verified against the source example

Read directly out of the three parquet files (`pyarrow`, 2026-09-30) rather
than assumed, since the shape is exactly what decided the design:

- 291 monitored lines (`Name`), 131/124 distinct `from_node`/`to_node` values,
  79 named outages, time steps 1–8736 (8729 of them actually present — Antares
  trims a year to 364 whole days; 8760 − 8736 = 24 h never appear as a
  `time_id` at all in this study, and a further 7 of the 8736 have no row in
  any of the three files here).
- `frank_safe_borders.parquet`: exactly `79 × 291 × 8729` rows — every outage,
  every line, every time step that occurs, no base case. This is what confirmed
  the base case has to be excluded by construction, not filtered afterwards:
  `security_tables`'s `frank_safe_borders` does the same by sweeping
  `contingencies = 2:dim_length(data, :contingency)` by default.
- `nm1_max_flows.parquet` / `nm1_min_flows.parquet`: exactly `291 × 8729` rows
  each (one per line and time step) — confirming the aggregation is over
  contingency only, nothing else. Only 78 / 77 of the 79 outages ever appear as
  the attained `outage`, which is expected: most lines have one or two
  contingencies that are ever their binding case, not all 79.
- Neither `nm1_max_flows.parquet` nor `nm1_min_flows.parquet` carries an
  `overload_mw` column, so there was nothing to drop to get from `zorba_tables`'
  `grid_flows` (which does carry one, for `GfOverloadSchema`) to this shape —
  only the base case had to go.

## What this does not cover

The dashboard's own inputs (`input/time_series_flows.parquet`,
`input/horizontal_grid_stats.parquet` in `ZorbaDashboard`) are not this shape:
they carry `year`, `scenario` and `mapping_id` columns that combine many runs
and many physical-line groupings into one file, and `horizontal_grid_stats.parquet`
is a further statistical rollup (percentiles, hours in overload, …) over a whole
year. Both are built by a step downstream of the raw per-run nm1 output —
outside this repository, and outside what `security_tables` is for. NMB
produces one run's worth of security screening; combining runs and computing
statistics over them stays a separate concern.

## Options for a future unification pass

Not decided, not started — for whoever next has both sides open together:

- Point GRIP's nm1-writing step at `write_security_tables` directly — as of
  2026-09-30 this needs no key rename at all, only reading the three files back
  in from wherever `write_security_tables` put them, retiring whatever Python
  currently builds `frank_safe_borders.parquet` / `nm1_max_flows.parquet` /
  `nm1_min_flows.parquet`.
- If NMB ever gains other consumers with different naming needs, revisit
  whether `frank_safe_borders`/`nm1_max_flows`/`nm1_min_flows` should stay the
  default — `flows`/`max_flows`/`min_flows` (this file's own suggestion, not
  adopted) is the alternative to weigh against whatever the other consumer
  wants, rather than optimizing for a second specific name.
- The `year`/`scenario` columns the dashboard's own inputs add could become
  optional keywords `write_security_tables` stamps onto every row, if the
  combining step ever wants to move into this package — no evidence yet that it
  should.
