# Tabular input

A network as tables — one row per component, one row per value that varies over
the network index — which is the shape a dataframe library already holds a grid
in. A caller in another language writes it without knowing anything about this
package beyond the column names.

```@docs
parse_tables
```

## What a table is

Nothing in the reader knows what a table *is*. A table is **anything whose
columns can be reached by name**, which is true of an `Arrow.Table`, a
`DataFrame` and a plain `NamedTuple` of vectors alike.

That is why the package takes no dependency to read one. It also means a test
fixture is a literal, with no file and no library anywhere near it:

```julia
data = parse_tables(
    node = (id        = [1, 2],
            type      = ["REF", "PQ"]),
    edge = (id        = [1],
            component = ["Branch"],
            terminals = [[1, 2]],
            r         = [0.0],
            x         = [0.1],
            rate_a    = [0.5]),
    unit = (id        = [1, 2],
            component = ["Generator", "FixedLoad"],
            node      = [1, 2],
            pmax      = [5.0, missing],
            pd        = [missing, 1.0]))
```

## The tables

| table       | required | one row per                         |
|:------------|:---------|:------------------------------------|
| `node`      | yes      | node                                |
| `edge`      | yes      | edge                                |
| `unit`      | yes      | unit                                |
| `profile`   | no       | value that varies over the index    |
| `dimension` | no       | coordinate of a dimension           |

### Components

The `node`, `edge` and `unit` tables carry two columns the reader reads and any
number of columns that are **fields of the component**, matched by name:

| column      | meaning                                                          |
|:------------|:-----------------------------------------------------------------|
| `id`        | the identifier, and what the other tables refer to it by          |
| `component` | the name of the concrete type — `"Branch"`, `"DCLink"`, `"Generator"` |

`component` is optional in the `node` table, which defaults to [`Node`](@ref).
What is known comes off the registries rather than a list inside the reader, so
a type an extension package registers is readable the moment it exists:

```@docs
component_types
```

A cell that is `missing` — or an empty string in a text column — is **not
given**, and the component takes its default. This is what lets one flat table
hold several component types: a `Branch` row leaves the columns belonging to a
`DCLink` empty, which is also exactly what stacking two frames produces.

### Profiles

Everything that varies over the network index goes in one long table:

| column   | meaning                                    |
|:---------|:-------------------------------------------|
| `family` | `"node"`, `"edge"` or `"unit"`             |
| `id`     | which component of that family             |
| `field`  | which of its fields                        |
| `nw`     | the network index                          |
| `value`  | the value there                            |

Each `(family, id, field)` group becomes a [`NetworkVector`](@ref) on that
component, and overrides whatever constant the component's own table gave. An
outage is a `status` that varies; a load profile is a `pd` that does; a rating
that follows the weather is a `rate_a` that does.

Every group has to give **every** network index, exactly once. A group that is
short is far more likely to be a filter that dropped rows than a deliberate
statement, and one in the wrong order would be read as a different profile
without ever failing, so both are refused rather than reaching a component.

### The dimension

One row per coordinate, with a column per coordinate property:

| column       | meaning                                      |
|:-------------|:---------------------------------------------|
| `name`       | the dimension, e.g. `"time"`, `"contingency"` |
| `coordinate` | its coordinate, numbered from one             |
| anything else | a property of that coordinate — `duration`, `weight`, `period`, … |

```julia
dimension = (name       = fill("time", 8760),
             coordinate = collect(1:8760),
             period     = [(h - 1) ÷ 24 + 1 for h in 1:8760])
```

A dimension **none** of whose coordinates carry a property is stored as a plain
size rather than a dictionary per coordinate — see [Nothing is stored per
network index](@ref). Describing a year of hours that says nothing about itself
therefore costs nothing, and the two dimensions of one problem may differ in
this.

Pass `dim` instead to give a [`Dimension`](@ref) directly; it wins over the
table.

## Arrow files

```@docs
parse_arrow
```

One Arrow file per table, in a directory:

```
belgium/
├── node.arrow
├── edge.arrow
├── unit.arrow
├── profile.arrow      # optional
└── dimension.arrow    # optional
```

which [`parse_file`](@ref) recognises by being a directory:

```julia
using Arrow                     # switches the extension on
data = parse_file("belgium")
```

!!! note "Arrow is a weak dependency"
    The package does not depend on Arrow. Reading one file format should not put
    a compression codec and a time-zone database into every install that never
    reads one, so [`parse_arrow`](@ref) arrives with a package extension and
    `using Arrow` somewhere in the session is what switches it on.

    Nothing else is gated. [`parse_tables`](@ref) reads an `Arrow.Table` without
    any of this — the extension exists only to turn a path into one.

## Writing the tables from Python

polars writes Arrow natively, and the columns are the field names of the
component types, so the boundary is the schema rather than a call signature:

```python
import polars as pl

pl.DataFrame({
    "id":        [1, 2],
    "component": ["Generator", "FixedLoad"],
    "node":      [1, 2],
    "pmax":      [5.0, None],
    "pd":        [None, 1.0],
}).write_ipc("belgium/unit.arrow")
```

A `None` is a `missing`, and therefore a default. A list column — `terminals`,
or the `cost` polynomial of a generator — is a list column on both sides.
