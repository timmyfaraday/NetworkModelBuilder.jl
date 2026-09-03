# The network index

Time, contingencies, harmonics and scenarios are all axes of the same problem. A
[`Dimension`](@ref) holds their names and sizes and gives the bijection between a
tuple of coordinates and the scalar **network index** ``n`` that labels the
variables and constraints of the JuMP model.

```@docs
Dimension
add_dimension
```

```julia
julia> dim = Dimension(:time => 24, :contingency => 3);

julia> nw_ids(dim; contingency = 2)     # every hour of the second contingency
julia> coordinates(dim, 26)             # (time = 2, contingency = 2)
julia> prev_id(dim, 26, :time)          # 25, the hour before, same contingency
```

The first dimension varies fastest: the network index is column-major in the
coordinates.

## Index arithmetic

This is what a coupling constraint needs. A storage balance links ``n`` to
`prev_id(dim, n, :time)`; a non-anticipativity constraint links the scenarios
`similar_ids(dim, n; scenario = 1:S)` returns.

```@docs
nw_ids
coordinates
similar_id
similar_ids
first_id
last_id
is_first_id
is_last_id
prev_id
next_id
prev_ids
next_ids
dim_names
dim_length
dim_position
has_dim
dim_prop
dim_meta
nw_id_default
```

## Data that varies over the network index

There is **one** extended graph, not one per network index. A field whose value
the network index changes is stored on its component as a
[`NetworkVector`](@ref) with one entry per index; a field that does not change is
stored as a plain value.

```@docs
NetworkVector
NetworkQuantity
```

The wrapper, rather than a bare `Vector`, removes an ambiguity: the terminals of
an edge and the cost polynomial of a generator are vectors too, and nothing in
their type says whether entry two means the second terminal or the second hour.

### Reading it

Both cases go through one getter, so no calling code has to ask which it holds:

```@docs
nw_value
nw_values
nw_component
is_nw_varying
has_nw_data
all_nw
```

[`nw_component`](@ref) is why the component files read plain fields — `br.r`,
`ld.pd` — and never mention profiles: `edge(nm, e; nw = n)` hands them a
component already resolved at ``n``.

### Writing it

```@docs
set_dimension
nw_vector
replicate
```

```julia
data = set_dimension(data, Dimension(:time => 24); apply! = function (net, dim)
    for (u, ld) in net.unit
        ld isa FixedLoad || continue
        net.unit[u] = FixedLoad(; id = ld.id, name = ld.name, node = ld.node,
                                pd = nw_vector(dim, :time, ld.pd .* profile),
                                qd = nw_vector(dim, :time, ld.qd .* profile))
    end
end)
```

Everything `apply!` leaves alone stays a plain value, and is therefore constant
over the network index.

### Time steps

A component that couples network indices along `:time` reads the duration of a
step from the `:duration` property of that dimension:

```julia
Dimension(:time => [Dict{Symbol,Any}(:duration => 0.25) for _ in 1:96])
```

## Periods

A **period** groups the coordinates of one dimension into sub-horizons: the days
of a year of hours, the weeks of a season. It is what a constraint that holds
once per day rather than once per horizon is written against — a daily energy
limit, a storage cycle limit, the worst overload of a day.

There are two ways to declare one, and they answer different questions.

| grouping | declared as | period of a coordinate | cost |
|:----------|:-------------------------------------------|:--------------------|:-----------------|
| regular   | `dim_meta(dim, :time)[:period_length] = 24` | arithmetic          | one number       |
| irregular | a `:period` property per coordinate         | read off            | one dict each    |
| none      | nothing                                     | always `1`          | nothing          |

The property wins where both are given, being the more specific statement.
Saying nothing gives **one period spanning the whole dimension**, which is the
right answer for a problem with no daily structure: a constraint written per
period is then written once, over the horizon.

```julia
dim = Dimension(:time => 8760, :contingency => 3)
dim_meta(dim, :time)[:period_length] = 24
```

What makes this worth having over a table from time step to day is not the
storage — a `:period` property per coordinate *is* that table — but that the
grouping **composes**. [`period_ids`](@ref) holds every other coordinate of the
network index fixed, so the problem above gets one constraint per day *per
contingency* without a second table, and without the component asking whether a
contingency dimension exists at all:

```julia
period_ids(dim, n)                  # the day holding n, in n's own contingency
is_first_period_id(dim, n)          # gate a per-period constraint on this
```

A [window](@ref "Cutting a window out") renumbers the coordinates it cuts from
one, so a regular grouping is written out per coordinate as the window is taken,
computed against the source. A window over hours 20 to 31 of the problem above
therefore holds the rest of day 1 and the start of day 2, rather than regrouping
its twelve steps into a day of its own.

```@docs
period_id
period_ids
is_first_period_id
is_last_period_id
period_count
```

## Cutting a window out

A problem posed over a dimension can be restricted to part of it, which is what a
[rolling horizon](@ref "Redispatch") cuts one step of its work out of:

```julia
w = window(mn, :time, 7:12)
```

The result is an ordinary [`NetworkData`](@ref) over a smaller `Dimension`, with
every other dimension left whole. The properties of the coordinates, the
[`NetworkVector`](@ref) field of every component and the topology all follow the
cut — the last re-derived from the sliced statuses rather than copied, and a
slice that no longer varies collapsed back to a plain value, so a window that
steps over an outage is back on the single-topology fast path.

```@docs
window
window_indices
```

### Do two indices give the same model?

Two network indices produce a model of the same *shape* when the same components
are in service and the same constraints get written between them. The first is
cheap to ask, because [`topology`](@ref) hands indices that agree **the same
object** rather than an equal one:

```@docs
same_topology
```

The second is the half that is easy to miss. A handful of fields are not
coefficients but switches — the model asks a question of them and writes nothing
when the answer is no, so a `rate_a` of `Inf` produces no rating at all and a
`pmax` of `Inf` produces no upper bound. A field like that changes the shape of
the model while the topology sits perfectly still:

```@docs
structure_gates
same_structure
structure_varies
```

Ask [`structure_varies`](@ref) once before asking anything else: where it is
`false` — no status varies and no gate varies — one shape serves the whole
problem and nothing further needs checking.

None of this is expensive. Over a year of 8760 hours, with windows of 24 stepped
by 4:

| planned outages | [`structure_varies`](@ref) | one [`same_structure`](@ref) per hour | all 2190 windows | reusable |
|:--|--:|--:|--:|--:|
| none | 0.01 ms | 119 ms | 0.4 ms | 2189 / 2189 |
| 5 | 0.001 ms | 73 ms | 0.5 ms | 2135 / 2189 |
| 30 | 0.001 ms | 160 ms | 0.4 ms | 1835 / 2189 |

The last two columns are the recipe in the [`same_structure`](@ref) example: build
the shift-stability map once, prefix-sum it, and every window is then answered in
constant time. Against the milliseconds it takes to *build* one model, the whole
year's worth of checking is free — and even with thirty maintenance outages, 84%
of consecutive windows still have the same shape.

## Nothing is stored per network index

On case14 with an hourly demand profile:

| indices | build | `Dimension` | whole graph | topologies |
|--------:|------:|------------:|------------:|-----------:|
| 1       | —     | 928 B       | 44 kB       | 1          |
| 24      | 0.1 ms| 928 B       | 48 kB       | 1          |
| 168     | 0.3 ms| 928 B       | 74 kB       | 1          |
| 8760    | 12 ms | 928 B       | 1.59 MB     | 1          |

The 1.59 MB at 8760 hours is 1.54 MB of profile plus the 44 kB the same network
costs over a single index. The graph is the data you asked for plus a constant,
and the `Dimension` is flat: its index is arithmetic rather than tabulated, and a
dimension given as a plain size stores that size rather than a dictionary per
coordinate.
