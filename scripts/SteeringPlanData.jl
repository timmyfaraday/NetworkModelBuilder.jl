################################################################################
# SteeringPlanData.jl                                                          #
# Loads the LongTermSteeringPlan CSV export into a NetworkModelBuilder.jl      #
# `NetworkData`, mirroring the pattern `src/io/matpower.jl` uses: read the     #
# tables, build `Dict{Int,<:Component}` per family, hand them to `Network`.    #
################################################################################

module SteeringPlanData

using CSV
using DataFrames
using NetworkModelBuilder

export load_network, country, cross_border, internal_be,
       cross_border_edges, internal_be_edges, freeze_dispatch, exclude_all_storage!,
       restrict_to_belgium!, add_load_shedding!, load_shedding_ids,
       add_spillage!, spillage_ids, hour_ids, hour_positions, select_hours

################################################################################
# Reading the tables                                                          #
################################################################################

"stream `path`'s `(id_col, time_col, value_col)` rows into `id => value-per-hour`

Only rows whose `time_col` falls in `hours` are kept, and the result vector is
indexed positionally — entry `k` is hour `first(hours) + k - 1` — which is what
[`nw_vector`](@ref) over a `:time` [`Dimension`](@ref) of `length(hours)`
coordinates expects. A `CSV.Rows` stream is used rather than a `DataFrame`
because the largest of these tables carries one row per storage unit per hour
of the whole year, and reading all of it just to keep one week would be most of
the cost of loading it."
function _read_hourly(path::AbstractString, id_col::Symbol, time_col::Symbol,
                      value_col::Symbol, hours::UnitRange{Int})
    out = Dict{Int,Vector{Float64}}()
    for row in CSV.Rows(path; types = Dict(id_col => Int, time_col => Int, value_col => Float64))
        t = getproperty(row, time_col)
        t in hours || continue
        v = get!(() -> fill(NaN, length(hours)), out, getproperty(row, id_col))
        v[t - first(hours) + 1] = getproperty(row, value_col)
    end

    return out
end

"the raw net position [MW] of every node in `node_ids`, over `hours`, from the wide `market_clearing_net_positions.csv`"
function _load_net_positions(dir::AbstractString, node_ids::Vector{Int}, hours::UnitRange{Int})
    path = joinpath(dir, "market_clearing_net_positions.csv")
    df   = DataFrame(CSV.File(path; limit = maximum(hours)))

    return Dict{Int,Vector{Float64}}(i => df[!, string(i)][hours] for i in node_ids)
end

################################################################################
# Nodes                                                                       #
################################################################################

"""
    _load_nodes(dir, thermal_df)

One [`Node`](@ref) per row of `nodes.csv`, its country in `ext[:country]`.

The node hosting the largest Belgian thermal generator by nameplate capacity —
ids 1-23 of `thermal_generators.csv` are Belgian, see [`load_network`](@ref) —
becomes the reference; a load flow needs exactly one, and the data names none.
Every other node defaults to `PQ`.
"""
function _load_nodes(dir::AbstractString, thermal_df::DataFrame)
    df = DataFrame(CSV.File(joinpath(dir, "nodes.csv")))

    be       = filter(:id => <=(23), thermal_df)
    ref_node = be.node[argmax(be.capacity)]

    I = Dict{Int,AbstractNode}()
    for row in eachrow(df)
        I[row.id] = Node(; id = row.id, name = row.name,
                         type = row.id == ref_node ? REF : PQ,
                         # CSV.jl infers a short `InlineStrings.String3` for a
                         # column this narrow; normalize to `String` so `country`
                         # can promise a stable, ordinary return type
                         ext = Dict{Symbol,Any}(:country => String(row.country)))
    end

    return I
end

################################################################################
# Edges — lines and phase shifters                                            #
################################################################################

"""
    _load_lines!(E, e, dir, baseMVA, max_coupler_reactance)

One edge per row of `lines.csv`, appended to `E` from edge identifier `e`, and
the last identifier used: a locked, closed [`Switch`](@ref) where the reactance
is below `max_coupler_reactance`, a [`Branch`](@ref) otherwise, see
[`load_network`](@ref). A switch keeps the identifier its row would have had as
a branch.

`lines.csv` carries no resistance and its `capacity` is `Inf` wherever the data
leaves a line unconstrained; `CSV.jl` parses that token as `Inf` itself, so no
special casing is needed beyond `coalesce` for a blank cell. `angmin`/`angmax`
are set to the widest angle this package treats as "no limit" — see the
`Branch` docstring and `src/io/matpower.jl`'s own fallback — because the
struct's narrower default (`±π/3`) would otherwise impose a stability limit
this data never asked for.
"""
function _load_lines!(E::Dict{Int,AbstractEdge}, e::Int, dir::AbstractString, baseMVA::Float64,
                      max_coupler_reactance::Float64)
    df = DataFrame(CSV.File(joinpath(dir, "lines.csv")))
    for row in eachrow(df)
        e += 1
        rate_a = coalesce(row.capacity, Inf) / baseMVA
        ext    = Dict{Symbol,Any}(:source_id => row.id)
        E[e]   = row.reactance < max_coupler_reactance ?
                 Switch(; id = e, name = row.name, terminals = [row.from, row.to], rate_a, ext) :
                 Branch(; id = e, name = row.name, terminals = [row.from, row.to],
                        r = 0.0, x = row.reactance, rate_a,
                        angmin = -pi / 2, angmax = pi / 2, ext)
    end

    return e
end

"""
    _load_psts!(E, e, dir, baseMVA)

One [`PhaseShifter`](@ref) per row of `pst.csv`, appended to `E` from edge
identifier `e`.

`pst.csv`'s `angle_min`/`angle_max` are the *control* range of the ratio angle,
mapped onto `ta_min`/`ta_max`; they are not the edge's own stability range,
which is not in this data at all, so `angmin`/`angmax` get the same wide-open
`±π/2` a `Branch` does, for the same reason. The data carries no market angle
setpoint, so `ta = 0.0` — an assumption, noted here rather than left silent.
"""
function _load_psts!(E::Dict{Int,AbstractEdge}, e::Int, dir::AbstractString, baseMVA::Float64)
    df = DataFrame(CSV.File(joinpath(dir, "pst.csv")))
    for row in eachrow(df)
        e += 1
        E[e] = PhaseShifter(; id = e, name = row.name, terminals = [row.from, row.to],
                            r = 0.0, x = row.reactance,
                            rate_a = row.capacity_max / baseMVA,
                            ta = 0.0, ta_min = row.angle_min, ta_max = row.angle_max,
                            angmin = -pi / 2, angmax = pi / 2,
                            ext = Dict{Symbol,Any}(:source_id => row.id))
    end

    return e
end

################################################################################
# Units — thermal generators                                                  #
################################################################################

"""
    _load_thermal_generators!(U, u, dir, thermal_df, net_position, neighbour_pg, dim, hours, baseMVA)

One [`Generator`](@ref) per row of `thermal_generators.csv`, appended to `U`
from unit identifier `u`.

Ids 1-23 are Belgian and carry an hourly market dispatch in
`thermal_generator_market_dispatch.csv`: `pg` is that schedule, and `pmax`/`pmin`
follow it up and down by `rd_capacity_up`/`rd_capacity_down`. Ids 24-93 are
neighbours with no market dispatch at all, so their `pg` is *estimated* by
[`_apportion_neighbour_generation!`](@ref) instead, which also records what it
assigned in `neighbour_pg` — see that function and [`_load_fixed_loads!`](@ref)
for why.
"""
function _load_thermal_generators!(U::Dict{Int,AbstractUnit}, u::Int, dir::AbstractString,
                                   thermal_df::DataFrame, net_position::Dict{Int,Vector{Float64}},
                                   neighbour_pg::Dict{Int,Vector{Float64}},
                                   dim::Dimension, hours::UnitRange{Int}, baseMVA::Float64)
    market = _read_hourly(joinpath(dir, "thermal_generator_market_dispatch.csv"),
                         :generator, :time_id, :market_dispatch_mw, hours)

    for row in eachrow(filter(:id => <=(23), thermal_df))
        pg_mw   = market[row.id]
        pmax_mw = pg_mw .+ row.rd_capacity_up
        pmin_mw = pg_mw .- row.rd_capacity_down
        u += 1
        U[u] = Generator(; id = u, name = row.name, node = row.node,
                         pg   = nw_vector(dim, :time, pg_mw   ./ baseMVA),
                         pmax = nw_vector(dim, :time, pmax_mw ./ baseMVA),
                         pmin = nw_vector(dim, :time, pmin_mw ./ baseMVA),
                         cost_up = row.rd_cost_up * baseMVA, cost_dn = row.rd_cost_down * baseMVA,
                         ext = Dict{Symbol,Any}(:source_id => row.id))
    end

    return _apportion_neighbour_generation!(U, u, filter(:id => >(23), thermal_df),
                                            net_position, neighbour_pg, dim, hours, baseMVA)
end

"""
    _apportion_neighbour_generation!(U, u, neighbour, net_position, neighbour_pg, dim, hours, baseMVA)

An *estimated* `pg` for every neighbour thermal generator, since none of them
carry a market dispatch: at each neighbour node `n`, the raw net position is
clipped to what the node's generators could produce,

```math
P_{\\text{node}}(n,t) = \\mathrm{clamp}(NP(n,t),\\, 0,\\, {\\textstyle\\sum_{g}} \\text{capacity}(g)),
```

and split over its generators in proportion to nameplate capacity,

```math
p^{\\text{g}}(g,t) = \\mathrm{clamp}\\!\\Big(P_{\\text{node}}(n,t) \\cdot
    \\frac{\\text{capacity}(g)}{\\sum_{g'} \\text{capacity}(g')},\\, 0,\\, \\text{capacity}(g)\\Big).
```

`pmax`/`pmin` then follow this `pg` up and down by `rd_capacity_up`/`_down`
exactly as they do for a Belgian generator. A node whose generators carry no
capacity at all gets `pg = 0` throughout rather than a division by zero.

`P_{\\text{node}}(n,t)` is recorded into `neighbour_pg[n]`: it was *carved out
of* `net_position[n]`, not observed independently of it, so
[`_load_fixed_loads!`](@ref) has to subtract it back out — leaving it in would
count the same megawatt once as this generator's `pg` and a second time as the
node's fixed load.
"""
function _apportion_neighbour_generation!(U::Dict{Int,AbstractUnit}, u::Int, neighbour::DataFrame,
                                          net_position::Dict{Int,Vector{Float64}},
                                          neighbour_pg::Dict{Int,Vector{Float64}}, dim::Dimension,
                                          hours::UnitRange{Int}, baseMVA::Float64)
    for grp in groupby(neighbour, :node)
        total_cap = sum(grp.capacity)
        p_node    = total_cap > 0 ? clamp.(net_position[grp.node[1]], 0.0, total_cap) :
                                    zeros(length(hours))
        neighbour_pg[grp.node[1]] = p_node

        for row in eachrow(grp)
            pg_mw   = total_cap > 0 ? clamp.(p_node .* (row.capacity / total_cap), 0.0, row.capacity) :
                                     zeros(length(hours))
            pmax_mw = pg_mw .+ row.rd_capacity_up
            pmin_mw = pg_mw .- row.rd_capacity_down
            u += 1
            U[u] = Generator(; id = u, name = row.name, node = row.node,
                             pg   = nw_vector(dim, :time, pg_mw   ./ baseMVA),
                             pmax = nw_vector(dim, :time, pmax_mw ./ baseMVA),
                             pmin = nw_vector(dim, :time, pmin_mw ./ baseMVA),
                             cost_up = row.rd_cost_up * baseMVA, cost_dn = row.rd_cost_down * baseMVA,
                             ext = Dict{Symbol,Any}(:source_id => row.id))
        end
    end

    return u
end

################################################################################
# Units — storage                                                             #
################################################################################

"""
    _load_storage!(U, u, dir, dim, hours, baseMVA)

One [`Storage`](@ref) per row of `storage.csv`, appended to `U` from unit
identifier `u`.

`ps` is the hourly market schedule of `storage_market_dispatch.csv`;
`cost_up`/`cost_dn` are hourly too, from the two `storage_redispatch_cost_*`
tables. `charge_rating` and `discharge_rating` both take `capacity` — the data
carries `rd_capacity_min`/`rd_capacity_max` as well, but every row has them
equal to `capacity`, so there is nothing more specific to read. `energy_initial`
is set to half of `energy_capacity`: the data has no column for it, and this is
an assumption, not a measurement.
"""
function _load_storage!(U::Dict{Int,AbstractUnit}, u::Int, dir::AbstractString, dim::Dimension,
                        hours::UnitRange{Int}, baseMVA::Float64)
    df   = DataFrame(CSV.File(joinpath(dir, "storage.csv")))
    ps   = _read_hourly(joinpath(dir, "storage_market_dispatch.csv"),
                        :storage, :time_id, :market_dispatch_mw, hours)
    cup  = _read_hourly(joinpath(dir, "storage_redispatch_cost_up.csv"),
                        :storage, :time_id, :rd_cost_up, hours)
    cdn  = _read_hourly(joinpath(dir, "storage_redispatch_cost_down.csv"),
                        :storage, :time_id, :rd_cost_down, hours)

    for row in eachrow(df)
        cap  = row.capacity / baseMVA
        ecap = row.energy_capacity / baseMVA
        u += 1
        U[u] = Storage(; id = u, name = row.name, node = row.node,
                       ps = nw_vector(dim, :time, ps[row.id] ./ baseMVA),
                       charge_rating = cap, discharge_rating = cap,
                       charge_efficiency = row.efficiency_charge,
                       discharge_efficiency = row.efficiency_discharge,
                       energy_capacity = ecap, energy_initial = 0.5 * ecap,
                       cost_up = nw_vector(dim, :time, cup[row.id] .* baseMVA),
                       cost_dn = nw_vector(dim, :time, cdn[row.id] .* baseMVA),
                       ext = Dict{Symbol,Any}(:source_id => row.id))
    end

    return u
end

################################################################################
# Units — fixed loads (net position)                                          #
################################################################################

"""
    _load_fixed_loads!(U, u, node_ids, net_position, neighbour_pg, dim, baseMVA)

One [`FixedLoad`](@ref) per node, carrying its net position net of whatever
[`_apportion_neighbour_generation!`](@ref) already assigned to an explicit
generator at that node, as `pd = -(net_position - neighbour_pg)`.

For a Belgian node `neighbour_pg` has no entry and this is exactly `pd =
-net_position`: the market clears every node's net export, and what is
explicitly modelled elsewhere — the thermal generators and storage units above
— is already excluded from it (by the data), so the two are additive on the
node balance without further adjustment. A neighbour node is different: it has
no independent generation data, so its explicit generator's `pg` is *derived
from* `net_position` rather than excluded from it, and leaving the full net
position here as well would inject that generator's `pg` a second time.
"""
function _load_fixed_loads!(U::Dict{Int,AbstractUnit}, u::Int, node_ids::Vector{Int},
                            net_position::Dict{Int,Vector{Float64}},
                            neighbour_pg::Dict{Int,Vector{Float64}}, dim::Dimension, baseMVA::Float64)
    for i in node_ids
        u += 1
        residual = haskey(neighbour_pg, i) ? net_position[i] .- neighbour_pg[i] : net_position[i]
        U[u] = FixedLoad(; id = u, name = "net position $i", node = i,
                         pd = nw_vector(dim, :time, (-residual) ./ baseMVA),
                         ext = Dict{Symbol,Any}(:source_id => i))
    end

    return u
end

################################################################################
# Loading the network                                                        #
################################################################################

"""
    load_network(dir; hours = 1:8760, baseMVA = 100.0, max_coupler_reactance = 1e-6) -> NetworkData

Build a [`NetworkData`](@ref) from the LongTermSteeringPlan CSV export in
`dir`, over the hour range `hours`.

Every quantity is converted to per unit on `baseMVA`, following the convention
`src/io/matpower.jl` uses: a power in MW is divided by it, a price per MW is
multiplied by it. Reactances and angles in the source data are already per unit
and radians respectively and are carried through unchanged.

The export models the 21 busbar couplers as lines of reactance `1e-7`, a
susceptance of `1e7` against about `60` for an ordinary line; a matrix spanning
that range made Xpress return `INFEASIBLE` for feasible problems and `OPTIMAL`
for solutions that break node balance. A line with a reactance below
`max_coupler_reactance` is therefore loaded as a locked, closed [`Switch`](@ref),
which has no impedance to get wrong. Pass `max_coupler_reactance = 0.0` to load
every line as a branch, as exported.

The hour identifiers of `hours` are kept in `data.ext[:hour_ids]`, see
[`hour_ids`](@ref), so a data set cut down to some of them later still knows
which hours of the year it holds.
"""
function load_network(dir::AbstractString; hours::UnitRange{Int} = 1:8760,
                      baseMVA::Float64 = 100.0, max_coupler_reactance::Float64 = 1e-6)
    thermal_df = DataFrame(CSV.File(joinpath(dir, "thermal_generators.csv")))

    I        = _load_nodes(dir, thermal_df)
    node_ids = sort!(collect(keys(I)))
    dim      = Dimension(:time => length(hours))

    net_position = _load_net_positions(dir, node_ids, hours)
    neighbour_pg = Dict{Int,Vector{Float64}}()

    E = Dict{Int,AbstractEdge}()
    e = _load_lines!(E, 0, dir, baseMVA, max_coupler_reactance)
    _load_psts!(E, e, dir, baseMVA)

    U = Dict{Int,AbstractUnit}()
    u = _load_thermal_generators!(U, 0, dir, thermal_df, net_position, neighbour_pg, dim, hours, baseMVA)
    u = _load_storage!(U, u, dir, dim, hours, baseMVA)
    _load_fixed_loads!(U, u, node_ids, net_position, neighbour_pg, dim, baseMVA)

    return NetworkData(Network(I, E, U; dim); name = "steering_plan", baseMVA,
                       ext = Dict{Symbol,Any}(:hour_ids => collect(hours)))
end

################################################################################
# Hours of the year                                                           #
################################################################################

"""
    hour_ids(data) -> Vector{Int}

The hour of the year behind every `:time` coordinate of `data`, in order.

`1:8760` for a full year as [`load_network`](@ref) returns it, and the hours
kept for a data set cut down by [`select_hours`](@ref). A report writes these
rather than the position along `:time`, which means something different in every
cut.
"""
hour_ids(data::NetworkData) =
    get(() -> collect(1:dim_length(dimension(data), :time)), data.ext, :hour_ids)::Vector{Int}

"""
    hour_positions(data, hours) -> Vector{Int}

The position along `:time` of each of the hours of the year `hours` in `data`.
"""
function hour_positions(data::NetworkData, hours::AbstractVector{Int})
    index = Dict(h => k for (k, h) in enumerate(hour_ids(data)))

    return map(hours) do h
        haskey(index, h) || throw(ArgumentError("hour $h is not part of this data set"))
        index[h]
    end
end

"""
    select_hours(data, hours) -> NetworkData

`data` cut down to the hours of the year `hours`, in the order given.

This is [`window`](@ref) along `:time`, which keeps every profile as it was at
those hours, with the hour identifiers carried along so [`hour_ids`](@ref) still
reports the hour of the year rather than a position. It is what lets the year be
loaded once and handed out in pieces: no hour of this pipeline depends on
another, so a piece solves exactly as it would inside the whole.
"""
function select_hours(data::NetworkData, hours::AbstractVector{Int})
    cut = window(data, :time, hour_positions(data, hours))
    ext = deepcopy(cut.ext)
    ext[:hour_ids] = collect(Int, hours)

    return NetworkData(network(cut); name = cut.name, baseMVA = baseMVA(cut), ext)
end

################################################################################
# Country classification                                                     #
################################################################################

"""
    country(data, n) -> String

The country of node `n`, from `ext[:country]`.

This, and everything built on it below, reads whatever countries actually
appear in `nodes.csv` rather than a fixed list: the current export only has
BE/FR/NL/DE/... and no GB or HVDC table, and the intent is for this to keep
working unchanged once those are added.
"""
country(data::NetworkData, n::Int) = nodes(network(data))[n].ext[:country]::String

"whether edge `e` has exactly one terminal node in Belgium, not merely two differing countries"
function cross_border(data::NetworkData, e::Int)
    i, j = terminals(edges(network(data))[e])
    return (country(data, i) == "BE") != (country(data, j) == "BE")
end

"whether edge `e`'s two terminal nodes are both in Belgium"
function internal_be(data::NetworkData, e::Int)
    i, j = terminals(edges(network(data))[e])
    return country(data, i) == "BE" && country(data, j) == "BE"
end

"sorted identifiers of the in-service edges crossing a country border"
cross_border_edges(data::NetworkData) =
    sort!([e for e in ids(network(data), AbstractEdge) if cross_border(data, e)])

"sorted identifiers of the in-service edges with both terminals in Belgium"
internal_be_edges(data::NetworkData) =
    sort!([e for e in ids(network(data), AbstractEdge) if internal_be(data, e)])

################################################################################
# Freezing a solved dispatch                                                  #
################################################################################

"`c`'s fields as a `NamedTuple`, so `T(; _fields(c)..., field = value) ` copies `c` with one field changed"
_fields(c::T) where {T} = NamedTuple{fieldnames(T)}(map(f -> getfield(c, f), fieldnames(T)))

"""
    freeze_dispatch(data, result; positions = 1:dim_length(data, :time)) -> NetworkData

`data` with every [`Generator`](@ref)'s `pg`, every [`Storage`](@ref)'s `ps` and
every [`PhaseShifter`](@ref)'s `ta` replaced by their solved values in `result`.

`positions[i]` is the position along `:time` in `data` of the `i`-th hour
`result` solved, so a `result` that only covered some of the hours of `data` —
the ones a screen kept — freezes just those, and every other hour keeps the
dispatch `data` already has. The default is a `result` over every hour of
`data`, in order.

The solved values are read from network indices `1:length(positions)` of
`result`. That range is the **base case** of `result` only because `result` is
assumed to have been solved over a `Dimension(:time => T, :contingency => K)`
built in that order: with `:time` varying fastest, its `contingency = 1`
coordinates are exactly network indices `1:T`, see [`Dimension`](@ref).
Everything in this module builds its contingency dimensions that way, so the
assumption holds for any `result` this pipeline produces.

A [`Storage`](@ref) unit that was out of service throughout `result` (e.g.
[`exclude_all_storage!`](@ref) applied before it was solved) keeps its own
pre-freeze `ps` instead — **not** `0`: `ids`/`topology` drop an out-of-service
component from its network index entirely, so `result`'s solution carries no
`"unit"` entry at all for it, but that is silence about what the *model* did
with it, not evidence the unit itself injected nothing. `data`'s own fixed
loads (`FixedLoad.pd`, untouched here) were built from net positions that
already price in whatever this unit's original schedule was (see
[`load_network`](@ref)); zeroing `ps` here without adjusting `pd` to match
would silently erase that MW from the balance instead of leaving it for a
later [`exclude_all_storage!`](@ref) to fold in correctly. This was exactly the
bug behind step 3's hour-1 INFEASIBLE: with storage excluded from step 2,
`result` had no solution for any storage unit, `ps` collapsed to `0`
system-wide, and every node's fixed load stayed calibrated against the
original non-zero dispatch — a raw imbalance equal to the network's *entire*
excluded storage fleet at that hour, restated as apparently having nowhere
near enough shed/spill headroom to close it.
"""
function freeze_dispatch(data::NetworkData, result::Dict{String,Any};
                         positions::AbstractVector{Int} = 1:dim_length(dimension(data), :time))
    dim = dimension(data)

    return set_dimension(data, dim; apply! = function (net, _)
        for (u, c) in net.unit
            if c isa Generator
                pg = nw_values(dim, c.pg)
                for (i, t) in enumerate(positions)
                    pg[t] = nw_solution(result, i)["unit"]["$u"]["pg"]
                end
                net.unit[u] = Generator(; _fields(c)..., pg = nw_vector(dim, :time, pg))
            elseif c isa Storage
                ps = nw_values(dim, c.ps)
                for (i, t) in enumerate(positions)
                    sol = nw_solution(result, i)["unit"]
                    haskey(sol, "$u") && (ps[t] = sol["$u"]["psd"] - sol["$u"]["psc"])
                end
                net.unit[u] = Storage(; _fields(c)..., ps = nw_vector(dim, :time, ps))
            end
        end
        for (e, c) in net.edge
            c isa PhaseShifter || continue
            ta = nw_values(dim, c.ta)
            for (i, t) in enumerate(positions)
                ta[t] = nw_solution(result, i)["edge"]["$e"]["tap"]["ta"]
            end
            net.edge[e] = PhaseShifter(; _fields(c)..., ta = nw_vector(dim, :time, ta))
        end
    end)
end

################################################################################
# Hard-excluding everything outside Belgium                                  #
################################################################################

"""
    exclude_all_storage!(data) -> NetworkData

`data` with every [`Storage`](@ref) unit taken out of service (`status =
false`) and its frozen `ps` folded into its node's [`FixedLoad`](@ref) (`pd -=
ps`), so the node's net injection is unchanged — unconditionally, every
storage unit, BE and neighbour alike, with no country or size exception.

This pipeline used to carve out a handful of large-scale ITM batteries as a
genuine redispatch resource. That exemption was removed once a week-scale run
diagnosed storage state-of-charge depletion under the rolling horizon (98% of
units down to <1% SoC by hour ~105, given the `energy_initial = 50%`
assumption with no re-anchoring — see the retired `run_three_step_redispatch.jl` in git history): storage
cannot be trusted as a redispatch resource anywhere in this pipeline, so it is
excluded everywhere it appears, step 2 included. Capping its ratings at
`abs(ps)` instead of excluding it was rejected, as before: that would still
leave it free to redispatch within that cap, which is not what "excluded"
means here.

`Network`/`NetworkData` are immutable, so despite the `!` — kept for
consistency with [`restrict_to_belgium!`](@ref), which calls this — this
returns the excluded data set rather than mutating `data` in place; reassign
at the call site.
"""
function exclude_all_storage!(data::NetworkData)
    dim = dimension(data)
    net = network(data)
    I   = deepcopy(nodes(net))
    E   = deepcopy(edges(net))
    U   = deepcopy(units(net))

    frozen_ps = Dict{Int,Vector{Float64}}()

    for (u, c) in U
        c isa Storage || continue
        ps = nw_values(dim, c.ps)
        frozen_ps[c.node] = get(frozen_ps, c.node, zeros(length(ps))) .+ ps
        U[u] = Storage(; _fields(c)..., status = false)
    end

    for (u, c) in U
        c isa FixedLoad || continue
        haskey(frozen_ps, c.node) || continue
        pd = nw_values(dim, c.pd) .- frozen_ps[c.node]
        U[u] = FixedLoad(; _fields(c)..., pd = nw_vector(dim, pd))
    end

    net = Network(I, E, U; dim, ext = deepcopy(net.ext))

    return NetworkData(net; name = data.name, baseMVA = baseMVA(data), ext = deepcopy(data.ext))
end

"""
    restrict_to_belgium!(data) -> NetworkData

`data` prepared for a redispatch confined to Belgium:

- a non-BE [`Generator`](@ref) is pinned at its current `pg` (`pmin = pmax = pg`);
- a non-BE [`PhaseShifter`](@ref) is pinned at its current `ta` (`ta_min =
  ta_max = ta`);
- every [`Storage`](@ref) unit, Belgian included, not just outside it, is
  excluded via [`exclude_all_storage!`](@ref) — with no exemption; unlike
  `Generator`/`PhaseShifter` above, storage is dropped as a *redispatch
  resource* for this step rather than pinned by geography.

`Network`/`NetworkData` are immutable, so despite the `!` — kept because the
project's spec asks for this exact name — this returns the restricted data set
rather than mutating `data` in place; reassign at the call site.
"""
function restrict_to_belgium!(data::NetworkData)
    dim = dimension(data)
    net = network(data)
    I   = deepcopy(nodes(net))
    E   = deepcopy(edges(net))
    U   = deepcopy(units(net))

    for (u, c) in U
        c isa Generator && country(data, c.node) != "BE" || continue
        U[u] = Generator(; _fields(c)..., pmin = c.pg, pmax = c.pg)
    end

    for (e, c) in E
        c isa PhaseShifter || continue
        i, j = terminals(c)
        country(data, i) == "BE" && country(data, j) == "BE" && continue
        E[e] = PhaseShifter(; _fields(c)..., ta_min = c.ta, ta_max = c.ta)
    end

    net  = Network(I, E, U; dim, ext = deepcopy(net.ext))
    data = NetworkData(net; name = data.name, baseMVA = baseMVA(data), ext = deepcopy(data.ext))

    return exclude_all_storage!(data)
end

################################################################################
# Corrective load shedding at Belgian nodes                                  #
################################################################################

"""
    add_load_shedding!(data; price) -> NetworkData

`data` with one synthetic [`Generator`](@ref) added at every Belgian node,
each able to inject up to that node's own hourly demand and priced at `price`
per pu — a corrective, priced unserved-energy slack for the internal-BE
redispatch, built from `Generator`'s existing `pgup`/`pgdn` redispatch
machinery rather than a new component type: `pg = 0`, so `pgup` *is* the shed
volume, and [`redispatch_controls`](@ref) already knows a `Generator` carries
one.

Every node already carries exactly one [`FixedLoad`](@ref) (see
[`load_network`](@ref)), so "one per Belgian node" and "one per node that has
a `FixedLoad`" are the same set here; this adds one wherever `country(data, ·)
== "BE"`.

`pmax` is that node's own `pd` at each hour, clamped at 0 — a net-exporting
node (`pd < 0`) has no demand there to shed. `pmin = pg = 0`, so `pgdn`'s own
upper bound (`pg - pmin = 0`) pins the downward volume at zero regardless of
price: this is one-directional shedding, not curtailment, because the
infeasibility it targets is a shortfall, not a surplus (see the step 3 section of the retired
`run_three_step_redispatch.jl` in git history for how that was checked).
`cost_dn = 0` reflects that the downward direction is inert, not priced.

The new ids continue after the highest one already in use, and are recorded in
`data.ext[:load_shedding_ids]` (see [`load_shedding_ids`](@ref)) so the caller
can mark them `:corrective` in a [`Redispatch`](@ref)'s `exception` without
having to know the scheme.

Call this after [`freeze_dispatch`](@ref)/[`restrict_to_belgium!`](@ref) and
before [`with_contingencies`](@ref): the new generators' `pmax` is built as a
`:time`-only [`NetworkVector`](@ref), and `with_contingencies` is what spreads
every component's `:time` profile over the added `:contingency` dimension —
exactly as it already does for every pre-existing unit.
"""
function add_load_shedding!(data::NetworkData; price::Float64)
    dim = dimension(data)
    net = network(data)
    U   = deepcopy(units(net))

    next_id = maximum(keys(U))
    shed_ids = Int[]

    for (_, c) in units(net)
        c isa FixedLoad && country(data, c.node) == "BE" || continue

        pmax = nw_vector(dim, max.(nw_values(dim, c.pd), 0.0))
        next_id += 1
        U[next_id] = Generator(; id = next_id, name = "load shedding node $(c.node)",
                               node = c.node, pg = 0.0, pmin = 0.0, pmax = pmax,
                               cost_up = price, cost_dn = 0.0,
                               ext = Dict{Symbol,Any}(:load_shedding => true))
        push!(shed_ids, next_id)
    end

    net = Network(nodes(net), edges(net), U; dim, ext = deepcopy(net.ext))
    ext = deepcopy(data.ext)
    ext[:load_shedding_ids] = sort!(shed_ids)

    return NetworkData(net; name = data.name, baseMVA = baseMVA(data), ext)
end

"the identifiers of the synthetic load-shedding generators [`add_load_shedding!`](@ref) added to `data`, or `Int[]` if it has not been called"
load_shedding_ids(data::NetworkData) = get(data.ext, :load_shedding_ids, Int[])::Vector{Int}

################################################################################
# Corrective spillage at Belgian nodes                                       #
################################################################################

"""
    add_spillage!(data; price) -> NetworkData

`data` with one synthetic [`Generator`](@ref) added at every Belgian node, each
able to withdraw up to that node's own hourly market surplus and priced at
`price` per pu — the surplus-side counterpart of [`add_load_shedding!`](@ref):
a corrective, priced relief valve for generation that has nowhere to go, built
from the same `pgup`/`pgdn` redispatch machinery, mirrored rather than
duplicated.

A generator with a negative lower bound already withdraws as well as injects —
see the note on [`AbstractStorage`](@ref) in `docs/src/components/storage.md`,
which is what a [`Storage`](@ref) is deliberately *not* just this — so this
needs no new component type, only the mirror image of the load-shedding
bounds: `pg = 0` and `pmax = 0` pin the *upward* volume `pgup` at zero (`pmax -
pg = 0`), the same way load shedding pins `pgdn` at zero, so this is
one-directional spillage, not generation. `pmin` is negative, so `pgdn` — the
withdrawal volume — is what moves, and is what `cost_dn = price` prices;
`cost_up = 0` reflects that the upward direction is inert, exactly mirroring
load shedding's `cost_dn = 0`.

`pmin` is that node's own `pd` at each hour, clamped at 0 from above: `pd < 0`
is exactly how [`_load_fixed_loads!`](@ref) already records a node whose
market-cleared generation exceeds its consumption (a net exporter), so `-pd`
is the surplus already implied by the data, and a net-importing node (`pd >
0`) has no surplus there to spill.

The new ids continue after the highest one already in use — including any
[`add_load_shedding!`](@ref) generators already added, since that function
never touches `pd` and neither does this one, so the two may be called in
either order — and are recorded in `data.ext[:spillage_ids]` (see
[`spillage_ids`](@ref)) so the caller can mark them `:corrective` in a
[`Redispatch`](@ref)'s `exception`, the same reasoning as for load shedding.

Call this after [`freeze_dispatch`](@ref)/[`restrict_to_belgium!`](@ref) and
before [`with_contingencies`](@ref), for the same reason as
[`add_load_shedding!`](@ref): the new generators' `pmin` is a `:time`-only
[`NetworkVector`](@ref) that `with_contingencies` still needs to spread over
the added `:contingency` dimension.
"""
function add_spillage!(data::NetworkData; price::Float64)
    dim = dimension(data)
    net = network(data)
    U   = deepcopy(units(net))

    next_id = maximum(keys(U))
    spill_ids = Int[]

    for (_, c) in units(net)
        c isa FixedLoad && country(data, c.node) == "BE" || continue

        pmin = nw_vector(dim, min.(nw_values(dim, c.pd), 0.0))
        next_id += 1
        U[next_id] = Generator(; id = next_id, name = "spillage node $(c.node)",
                               node = c.node, pg = 0.0, pmin = pmin, pmax = 0.0,
                               cost_up = 0.0, cost_dn = price,
                               ext = Dict{Symbol,Any}(:spillage => true))
        push!(spill_ids, next_id)
    end

    net = Network(nodes(net), edges(net), U; dim, ext = deepcopy(net.ext))
    ext = deepcopy(data.ext)
    ext[:spillage_ids] = sort!(spill_ids)

    return NetworkData(net; name = data.name, baseMVA = baseMVA(data), ext)
end

"the identifiers of the synthetic spillage generators [`add_spillage!`](@ref) added to `data`, or `Int[]` if it has not been called"
spillage_ids(data::NetworkData) = get(data.ext, :spillage_ids, Int[])::Vector{Int}

end # module
