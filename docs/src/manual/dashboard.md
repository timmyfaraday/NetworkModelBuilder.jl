# Security screening output

A dashboard reads a security screening — an N-1 sweep — as three tables of one
shape: the flow of every edge, at every time step, in every contingency but the
base case, and the two tables that reduce those down to the worst case in
either direction. [`security_tables`](@ref) builds that shape from any solved
[`NetworkData`](@ref) posed over a `:contingency` dimension.

```@docs
security_tables
```

## Not part of the Zorba adapter

This has nothing to do with Zorba. An N-1 security screening is a question
about any grid this package can solve, not something [the Zorba
adapter](@ref "The Zorba adapter") alone can ask: `security_tables` does not
read `data.ext[:zorba]`, and reads a network [`parse_matpower`](@ref) or
[`parse_tables`](@ref) built exactly as it reads one [`parse_zorba`](@ref) did.

A study `parse_zorba` built happens to already carry the names a dashboard was
written against, so applying `security_tables` to one needs nothing beyond
trading the plain contingency and time coordinates for the real names
[`zorba_study`](@ref) tracks:

```julia
zs     = zorba_study(data)
tables = security_tables(data, result; outage = zs.outage[2:end], time_id = zs.time_id)
```

Everything else — which edges, which contingencies, the shape of the three
tables — is the same call whether or not `data` ever crossed the Zorba boundary.

## The files

```@docs
write_security_tables
```

Needs the Parquet2 package loaded, for the same reason Arrow is a weak
dependency of [`parse_arrow`](@ref) and [`write_zorba`](@ref): reading or
writing one file format should not put its dependencies into every install that
never touches one.

```julia
using Parquet2, NetworkModelBuilder

tables = security_tables(data, result)
write_security_tables("out", tables)
```

```
out/
├── frank_safe_borders.parquet
├── nm1_max_flows.parquet
└── nm1_min_flows.parquet
```

Those are a specific dashboard's own file and column names, adopted directly so
its output can be plugged in with no relabelling — see
`.github/context/knowledge/plan/dashboard-output-mapping.md` in the repository
for where they came from and why. A caller that wants different names reads the
table it wants under its own, the same way `write_security_tables` always works
— one file per entry of the `NamedTuple` it is given, under that entry's own
key:

```julia
write_security_tables("out", (; flows = tables.frank_safe_borders))
```
