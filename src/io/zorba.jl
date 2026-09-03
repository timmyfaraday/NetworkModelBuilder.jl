################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.8.0 - initial implementation                                              #
################################################################################

################################################################################
# The Zorba adapter                                                            #
################################################################################

# Zorba poses a security constrained redispatch as five tables and four numbers,
# and reads the answer back as two more. Everything in this file is the
# translation of the one into the other; nothing else in the package knows that
# Zorba exists, and nothing here knows what an Arrow file is — a table is
# anything whose columns can be reached by name, as in `parse_tables`.
#
# The translation is deliberately on this side of the boundary rather than in
# Python. It keeps the caller thin, it makes the package independently
# exercisable on real Zorba grids, and it puts the unit conversion in one place:
# Zorba is in MW and degrees, this package is per unit on `baseMVA` and radians.

"""
    ZorbaLink

One row of the answer: a link of the Zorba grid, together with the edge it
became.

# Fields
- `id`: the identifier of the edge in the [`Network`](@ref).
- `name`: the Zorba link id, the `Name` of every output row about it.
- `from`, `to`: the Zorba names of its two nodes, in the order the input gave
  them, which is the direction a positive flow runs in.
- `dc`: whether it is one of the HVDC links rather than a row of the grid table.
"""
struct ZorbaLink
    id  ::Int
    name::String
    from::String
    to  ::String
    dc  ::Bool
end

"""
    ZorbaStudy

What [`zorba_tables`](@ref) needs to write Zorba's answer that the network
itself does not carry: the names on both sides of the boundary, the coordinates
of the network index, and the setup the problem is posed with.

Held in `data.ext[:zorba]` by [`parse_zorba`](@ref) and reached with
[`zorba_study`](@ref).

# Fields
- `link`: every link, the grid rows first and the HVDC links after, see
  [`ZorbaLink`](@ref).
- `outage`: the name of the outage each `:contingency` coordinate stands for,
  `missing` for the base case, which is always the first.
- `time_id`: the Zorba `time_id` each `:time` coordinate stands for, ascending.
- `redispatch`: the [`Redispatch`](@ref) the settings amount to.
"""
struct ZorbaStudy
    link      ::Vector{ZorbaLink}
    outage    ::Vector{Union{Missing,String}}
    time_id   ::Vector{UInt16}
    redispatch::Redispatch
end

Base.show(io::IO, zs::ZorbaStudy) =
    print(io, "ZorbaStudy(", count(!l.dc for l in zs.link), " link(s), ",
          count(l -> l.dc, zs.link), " hvdc, ", length(zs.outage) - 1, " outage(s), ",
          length(zs.time_id), " step(s))")

"""
    zorba_study(data)

The [`ZorbaStudy`](@ref) of a network built by [`parse_zorba`](@ref).
"""
function zorba_study(data::NetworkData)
    haskey(data.ext, :zorba) ||
        throw(ArgumentError("this network was not built by `parse_zorba`, so it carries " *
                            "none of the Zorba naming its answer has to be written in"))

    return data.ext[:zorba]::ZorbaStudy
end

################################################################################
# The Zorba adapter — input                                                    #
################################################################################

"""
    parse_zorba(; grid, net_position, hvdc, outage, kwargs...)

Build a [`NetworkData`](@ref) from Zorba's `MinimalStudy` and the arguments its
`RedispatchSolver.run` takes, posed over `Dimension(:time, :contingency)`.

The result is an ordinary network, and the [`Redispatch`](@ref) the settings
amount to travels with it in `data.ext[:zorba]`. [`solve_zorba`](@ref) poses the
security constrained redispatch Zorba poses by default and any other problem and
formulation this package implements on request; [`zorba_tables`](@ref) writes the
answer to either back in the shape `GfOverloadSchema` and `PstDispatchSchema`
validate.

# The tables

| table          | columns                                                            | required |
|:---------------|:-------------------------------------------------------------------|:---------|
| `grid`         | `id`, `from_node`, `to_node`, `capacity`, `reactance_pu`, `pst_deg` | yes      |
| `net_position` | `node`, `time_id`, `value_mw`                                       | yes      |
| `hvdc`         | `id`, `from_node`, `to_node`, `cost`                                | no       |
| `outage`       | `name`, `link`                                                      | no       |

`grid` is Zorba's `GridModelSchema` and every further column of it — `could_trip`,
`trip_with`, the tap columns — is ignored: what an outage is, is decided by the
`outage` table rather than by a flag on a line. A blank `capacity` is an
unlimited one.

`net_position` is Zorba's `NetPositionSchema`, one row per node and time step,
and it is what fixes the node order: the nodes are numbered in the order they
first appear in it, as they are in `MinimalStudy.node_list`. A positive
`value_mw` is a node that *exports*.

`hvdc` is one row per `Hvdc`, `id` being the Antares link name its answer is
reported under; leave the column out and it is `"\$from - \$to"`.

`outage` is one row per link taken out by an outage, so a substation trip is
several rows sharing a `name` — the general case of the list of link names
`RedispatchSolver.run` takes. The base case is not in the table: it is always the
first `:contingency` coordinate. An outage naming a link the grid does not have
is an error here rather than a warning, since the caller is Zorba's own
`_clean_outages`, which has already dropped those.

# Keywords

The four settings are `RdsSettings` and its defaults:

- `overload_penalty`: the price of one MWh of overload, or `:force` for a hard
  rating. `1e3` by default.
- `wiggle_room`: how many MW the balance of a node may be missed by, free, in
  either direction. Zero by default, and it becomes an
  [`EnergyNotServed`](@ref) and a [`Spill`](@ref) at every node.
- `pst_cost`: the price of one radian of phase shift. `1.0` by default.
- `baseMVA`: Zorba's `BASE_POWER_MVA`, `100.0` by default. The reactances are
  per unit on it, so it has to be the number Zorba used.

and two that Zorba has no way of saying:

- `contingency_weight`: the probability of each state of the world, the base case
  first. Uniform by default, and left uniform is what reproduces Zorba — which
  charges a measure once and its congestion once per state, summed rather than
  averaged, so the congestion price is grossed up by the number of states to
  match. Pass real probabilities to ask the expected-cost question instead, which
  Zorba has no way of posing; the gross-up is then not applied. See
  [`default_weight`](@ref).
- `name`: the name of the data set.

# Examples
```julia
data = parse_zorba(; grid, net_position, hvdc, outage,
                     overload_penalty = 1e3, pst_cost = 1.0)

result = solve_zorba(data, HiGHS.Optimizer)
tables = zorba_tables(data, result)
```
"""
function parse_zorba(; grid, net_position, hvdc = nothing, outage = nothing,
                       name::String = "zorba", baseMVA::Real = 100.0,
                       overload_penalty::Union{Real,Symbol} = 1e3,
                       wiggle_room::Real = 0.0, pst_cost::Real = 1.0,
                       contingency_weight::Union{Nothing,AbstractVector{<:Real}} = nothing)
    base = Float64(baseMVA)
    base > 0 || throw(ArgumentError("`baseMVA` is $base, which is not a power base"))

    nodes, times, injection = _zorba_net_position(net_position, base)
    outages, out_links      = _zorba_outages(outage)
    dim, states             = _zorba_dimension(length(times), length(outages),
                                               contingency_weight)

    E, links = _zorba_edges(grid, hvdc, nodes, dim, outages, out_links, base, Float64(pst_cost))
    I        = _zorba_nodes(nodes)
    U        = _zorba_units(nodes, injection, dim, Float64(wiggle_room), base)

    study = ZorbaStudy(links, outages, times,
                       _zorba_redispatch(overload_penalty, base, states))
    data  = NetworkData(Network(I, E, U; dim); name, baseMVA = base,
                        ext = Dict{Symbol,Any}(:zorba => study))

    return data
end

"""
    _zorba_redispatch(overload_penalty, base, states)

The [`Redispatch`](@ref) the Zorba settings amount to.

The price is per MWh against a flow this package holds in per unit, hence the
`base`. The `states` factor is the subtler half, and it is what makes the two
objectives the same function rather than two similar ones.

Zorba prices its measures **once** — its phase shifts and its HVDC flows carry no
outage coordinate — and its congestion **once per state of the world**, summed
over the outages unweighted. This package weights every cost by the weight of its
network index, and a contingency coordinate carries a probability, see
[`default_weight`](@ref): a preventive measure is then charged once because `N`
copies of it are each worth `1/N`, and the congestion is an *expectation* rather
than a sum. Multiplying the congestion price by `N` turns that average back into
the sum Zorba wrote, and nothing else has to move. A caller who gives real
probabilities is asking the expected-cost question instead and gets no such
factor.
"""
function _zorba_redispatch(overload_penalty::Union{Real,Symbol}, base::Float64, states::Int)
    if overload_penalty isa Symbol
        overload_penalty === :force ||
            throw(ArgumentError("`$overload_penalty` is not an overload penalty, which is " *
                                "a price per MWh or `:force` for a hard rating"))

        return Redispatch()
    end

    # the peak price Zorba has no field for is left at zero
    return Redispatch(;
        overload = OverloadPrice(; per_energy = overload_penalty * base * states))
end

"""
    _zorba_dimension(nt, nc, weight)

The network index a study over `nt` steps and `nc` states of the world is posed
over, and the number of states its congestion price has to be grossed up by, see
[`_zorba_redispatch`](@ref).

Without weights the `:contingency` dimension is a plain size and its coordinates
carry nothing at all, which is the representation a dimension is supposed to keep
wherever it says nothing about itself.
"""
function _zorba_dimension(nt::Int, nc::Int, weight)
    weight === nothing && return Dimension(:time => nt, :contingency => nc), nc

    w = collect(Float64, weight)
    length(w) == nc ||
        throw(ArgumentError("`contingency_weight` holds $(length(w)) weights but the study " *
                            "has $nc states of the world, the base case included"))

    return Dimension(:time => nt,
                     :contingency => [Dict{Symbol,Any}(:weight => x) for x in w]), 1
end

"""
    _zorba_net_position(tbl, base)

The node names, the time steps, and the injection of each node at each step in
per unit.

A node *exports* `value_mw`, and this package's node balance is written as what
leaves a node against what its units inject, so the injection is `+value_mw` and
the load that carries it is its negation. Every node has to have a value at every
step: a missing row is far more likely to be a filter than a statement that a
node is absent for an hour, and reading it as zero would balance the network
against a number nobody wrote.
"""
function _zorba_net_position(tbl, base::Float64)
    for c in (:node, :time_id, :value_mw)
        c in _columns(tbl) ||
            throw(ArgumentError("the `net_position` table has no `$c` column; it needs " *
                                "`node`, `time_id` and `value_mw`"))
    end

    node  = _column(tbl, :node)
    time  = _column(tbl, :time_id)
    value = _column(tbl, :value_mw)

    nodes = String[]
    seen  = Dict{String,Int}()
    steps = Set{UInt16}()
    for r in 1:_nrows(tbl)
        nm = String(node[r])
        haskey(seen, nm) || (push!(nodes, nm); seen[nm] = length(nodes))
        push!(steps, UInt16(time[r]))
    end
    times = sort!(collect(steps))
    at    = Dict{UInt16,Int}(t => k for (k, t) in enumerate(times))

    injection = fill(NaN, length(nodes), length(times))
    for r in 1:_nrows(tbl)
        i, k = seen[String(node[r])], at[UInt16(time[r])]
        isnan(injection[i, k]) ||
            throw(ArgumentError("the `net_position` table gives node $(node[r]) twice at " *
                                "time_id $(time[r])"))
        injection[i, k] = Float64(value[r]) / base
    end

    for i in eachindex(nodes), k in eachindex(times)
        isnan(injection[i, k]) &&
            throw(ArgumentError("the `net_position` table gives no value for node " *
                                "$(nodes[i]) at time_id $(times[k]); every node needs one " *
                                "at every step"))
    end

    return nodes, times, injection
end

"""
    _zorba_outages(tbl)

The name of every state of the world, the base case first, and the links each
takes out.

The base case is `missing` rather than `"NONE"`: it is the absence of an outage,
and `GfOverloadSchema` has a nullable `outage` column for exactly that reason.
"""
_zorba_outages(::Nothing) = (Union{Missing,String}[missing], Dict{String,Vector{String}}())

function _zorba_outages(tbl)
    for c in (:name, :link)
        c in _columns(tbl) ||
            throw(ArgumentError("the `outage` table has no `$c` column; it needs `name` " *
                                "and `link`, one row per link an outage takes out"))
    end

    name = _column(tbl, :name)
    link = _column(tbl, :link)

    outages = Union{Missing,String}[missing]
    taken   = Dict{String,Vector{String}}()
    for r in 1:_nrows(tbl)
        o, l = String(name[r]), String(link[r])
        haskey(taken, o) || (push!(outages, o); taken[o] = String[])
        l in taken[o] ||  push!(taken[o], l)
    end

    return outages, taken
end

"one [`Node`](@ref) per Zorba node, the first of them the reference"
function _zorba_nodes(nodes::Vector{String})
    I = Dict{Int,AbstractNode}()
    for (i, nm) in enumerate(nodes)
        I[i] = Node(; id = i, name = nm, type = i == 1 ? REF : PQ, va = 0.0)
    end

    return I
end

"""
    _zorba_edges(grid, hvdc, nodes, dim, outages, out_links, base, pst_cost)

One edge per row of the grid table and one per HVDC link, together with the
[`ZorbaLink`](@ref) each became.

A row with a phase shift range is a [`PhaseShifter`](@ref) and one without is a
[`Branch`](@ref): the range is what makes the angle a decision rather than data,
which is the test a type has to pass to exist. An outage is carried on the
`status` of the links it takes out, which is what turns Zorba's trick of nulling
a susceptance into a topology this package derives.
"""
function _zorba_edges(grid, hvdc, nodes::Vector{String}, dim::Dimension,
                      outages::Vector{Union{Missing,String}},
                      out_links::Dict{String,Vector{String}},
                      base::Float64, pst_cost::Float64)
    for c in (:id, :from_node, :to_node, :reactance_pu)
        c in _columns(grid) ||
            throw(ArgumentError("the `grid` table has no `$c` column"))
    end

    at    = Dict{String,Int}(nm => i for (i, nm) in enumerate(nodes))
    id    = _column(grid, :id)
    from  = _column(grid, :from_node)
    to    = _column(grid, :to_node)
    x     = _column(grid, :reactance_pu)
    cap   = :capacity in _columns(grid) ? _column(grid, :capacity) : nothing
    shift = :pst_deg   in _columns(grid) ? _column(grid, :pst_deg)   : nothing

    E     = Dict{Int,AbstractEdge}()
    links = ZorbaLink[]

    for r in 1:_nrows(grid)
        e    = length(links) + 1
        nm   = String(id[r])
        i, j = _zorba_node(at, from[r], nm), _zorba_node(at, to[r], nm)
        rate = cap === nothing || _blank(cap[r]) ? Inf : Float64(cap[r]) / base
        deg  = shift === nothing || _blank(shift[r]) ? 0.0 : Float64(shift[r])
        deg < 90 ||
            throw(ArgumentError("link $nm has a phase shift range of $deg degrees, and a " *
                                "ratio angle lies inside (-90, 90) degrees"))

        # Zorba writes no angle difference limits at all, and ±π/2 is what this
        # package reads as *unbounded* rather than as a very wide bound
        common = (; id = e, name = nm, terminals = [i, j], r = 0.0, x = Float64(x[r]),
                    rate_a = rate, angmin = -pi / 2, angmax = pi / 2,
                    status = _zorba_status(dim, outages, out_links, nm))

        E[e] = iszero(deg) ? Branch(; common...) :
                             PhaseShifter(; common..., tm = 1.0, ta = 0.0,
                                            ta_min = -deg2rad(deg), ta_max = deg2rad(deg),
                                            cost = pst_cost)
        push!(links, ZorbaLink(e, nm, String(from[r]), String(to[r]), false))
    end

    _zorba_check_outages(out_links, Set(l.name for l in links))

    hvdc === nothing && return E, links

    for c in (:from_node, :to_node, :cost)
        c in _columns(hvdc) ||
            throw(ArgumentError("the `hvdc` table has no `$c` column; it needs " *
                                "`from_node`, `to_node` and `cost`, and may name each link " *
                                "in an `id` column"))
    end
    hid  = :id in _columns(hvdc) ? _column(hvdc, :id) : nothing
    hfr  = _column(hvdc, :from_node)
    hto  = _column(hvdc, :to_node)
    cost = _column(hvdc, :cost)

    for r in 1:_nrows(hvdc)
        e    = length(links) + 1
        f, t = String(hfr[r]), String(hto[r])
        nm   = hid === nothing || _blank(hid[r]) ? "$f - $t" : String(hid[r])
        i, j = _zorba_node(at, f, nm), _zorba_node(at, t, nm)

        # Zorba prices the magnitude of the transfer, per MWh; a link scheduled
        # at zero pays for every per unit it moves away from that, which is the
        # same sum written as a redispatch
        E[e] = DCLink(; id = e, name = nm, terminals = [i, j], rate_a = Inf,
                        pdc = 0.0, cost = Float64(cost[r]) * base)
        push!(links, ZorbaLink(e, nm, f, t, true))
    end

    return E, links
end

"""
    _zorba_check_outages(out_links, known)

Refuse an outage that takes out a link the grid does not have.

Zorba drops those with a warning, in `_clean_outages`, because the outage list
and the grid it applies to are assembled separately there. By the time a study
reaches this side of the boundary that has already happened, so a name that is
still unknown is a mismatch between two files rather than a mismatch this should
paper over — and papering over it would silently pose a *weaker* problem, since
an outage that takes nothing out is the base case again.
"""
function _zorba_check_outages(out_links::Dict{String,Vector{String}}, known::Set{String})
    for (outage, links) in sort!(collect(out_links), by = first), l in links
        l in known ||
            throw(ArgumentError("outage $outage takes out link $l, which the `grid` " *
                                "table does not have"))
    end

    return nothing
end

"the identifier of the node named `nm`, which a link has to be connected to"
function _zorba_node(at::Dict{String,Int}, nm, link::String)
    i = get(at, String(nm), nothing)
    i === nothing &&
        throw(ArgumentError("link $link is connected to node $nm, which the " *
                            "`net_position` table does not have"))

    return i
end

"the in-service status of link `nm`, false at every state of the world that takes it out"
function _zorba_status(dim::Dimension, outages::Vector{Union{Missing,String}},
                       out_links::Dict{String,Vector{String}}, nm::String)
    out = Set(c for c in 2:length(outages) if nm in out_links[outages[c]])
    isempty(out) && return true

    return nw_vector(dim, (n, c) -> c.contingency ∉ out)
end

"""
    _zorba_units(nodes, injection, dim, wiggle, base)

One [`FixedLoad`](@ref) per node carrying its net position, and the pair of
slack units the wiggle room is.

Zorba's `wiggle_room` is a bounded, free relaxation of the node balance in either
direction, which is what an [`EnergyNotServed`](@ref) and a [`Spill`](@ref)
already are — priced at zero, since Zorba charges nothing for it. That it is
*free* is worth reading twice: the network is allowed to miss its balance by that
much wherever doing so is cheaper than the congestion it would otherwise pay for.
"""
function _zorba_units(nodes::Vector{String}, injection::Matrix{Float64}, dim::Dimension,
                      wiggle::Float64, base::Float64)
    wiggle >= 0 ||
        throw(ArgumentError("`wiggle_room` is $wiggle MW, which is not a width"))

    U = Dict{Int,AbstractUnit}()
    for (i, nm) in enumerate(nodes)
        U[i] = FixedLoad(; id = i, name = nm, node = i, qd = 0.0,
                           pd = nw_vector(dim, :time, -injection[i, :]))
    end

    iszero(wiggle) && return U

    n, room = length(nodes), wiggle / base
    for (i, nm) in enumerate(nodes)
        U[n + i]     = EnergyNotServed(; id = n + i, name = nm, node = i,
                                         pmax = room, cost = 0.0)
        U[2 * n + i] = Spill(; id = 2 * n + i, name = nm, node = i,
                               pmax = room, cost = 0.0)
    end

    return U
end

################################################################################
# The Zorba adapter — the solve                                                #
################################################################################

"""
    solve_zorba(data, optimizer; kwargs...)
    solve_zorba(data, P, F, optimizer; horizon, step, reuse, warm_start, ext, kwargs...)

Solve a network built by [`parse_zorba`](@ref) as problem `P` in formulation `F`,
defaulting to the [`RedispatchProblem`](@ref) in the [`LPFFormulation`](@ref)
that Zorba poses.

**A Zorba study is a network, not a problem.** What arrives over the boundary is
a grid, a schedule and a set of outages; which question to ask of it is a
separate choice, and every problem and formulation this package implements is
available — see [`implemented_models`](@ref). A [`LoadFlowProblem`](@ref) says
where the power goes with the phase shifters left at their setpoints, an
[`OptimalPowerFlowProblem`](@ref) prices the level of what the units do rather
than the deviation, and an [`IVRFormulation`](@ref) asks the alternating current
question about the same grid. [`zorba_tables`](@ref) writes the answer to any of
them, since what it reports — a terminal power, an overload, a tap angle — is
what every formulation that has a model writes.

The [`Redispatch`](@ref) the settings amounted to travels with the data and is
placed in the `ext` of the model whatever `P` is. Only a redispatch consults it,
so it is inert in every other problem rather than something to strip out.

`horizon` and `step` roll the study the way Zorba's `Batcher` batches it, see
[`solve_rolling_horizon`](@ref); without a `horizon` this is
[`solve_model`](@ref).

# Examples
```julia
result = solve_zorba(data, HiGHS.Optimizer)                          # as Zorba poses it
flows  = solve_zorba(data, LoadFlowProblem, LPFFormulation, opt)     # where the power goes
ac     = solve_zorba(data, RedispatchProblem, IVRFormulation, opt)   # the same, in ac
```

!!! note "Not every study can be posed in every formulation"
    A [`DCLink`](@ref) has no model in an alternating current formulation — what
    couples one to an AC network is a converter station, which is a component in
    its own right — so a study carrying an `hvdc` table posed in an
    [`IVRFormulation`](@ref) raises rather than answering with a link that has no
    reactive power. A phase shifter priced per radian is linearized-only for a
    related reason, see [`redispatch_cost`](@ref); `pst_cost = 0.0` is what asks
    the current based question about a study that has one.
"""
solve_zorba(data::NetworkData, optimizer; kwargs...) =
    solve_zorba(data, RedispatchProblem, LPFFormulation, optimizer; kwargs...)

function solve_zorba(data::NetworkData, ::Type{P}, ::Type{F}, optimizer;
                     horizon::Union{Nothing,Int} = nothing, step::Int = 1,
                     reuse::Bool = false, warm_start::Bool = false,
                     ext::Dict{Symbol,Any} = Dict{Symbol,Any}(), kwargs...
                    ) where {P<:AbstractProblemType,F<:AbstractFormulationType}
    ext = merge(ext, Dict{Symbol,Any}(:redispatch => zorba_study(data).redispatch))

    horizon === nothing && return solve_model(data, P, F, optimizer; ext, kwargs...)

    return solve_rolling_horizon(data, P, F, optimizer;
                                 horizon, step, reuse, warm_start, ext, kwargs...)
end

################################################################################
# The Zorba adapter — output                                                   #
################################################################################

"""
    zorba_tables(data, result)

Zorba's answer, as the two tables it validates.

Returns `(; grid_flows, pst_dispatch)`, each a `NamedTuple` of columns carrying
the names and the types the schemas on the other side declare:

| table          | columns                                                                          |
|:---------------|:---------------------------------------------------------------------------------|
| `grid_flows`   | `outage`, `Name`, `from_node`, `to_node`, `time_id`, `flow_mw`, `overload_mw`     |
| `pst_dispatch` | `Name`, `from_node`, `to_node`, `time_id`, `pst_deg`                              |

`grid_flows` is `GfOverloadSchema`: one row per link, time step and state of the
world, the HVDC links included with an overload of zero, and `outage` `missing`
in the base case. A link an outage took out carries a flow of zero rather than no
row at all, which is what Zorba reports for it and what a downstream join
expects.

`pst_dispatch` is `PstDispatchSchema`: one row per link and time step, with
`pst_deg` `missing` for a link that has no phase shifter. There is no `outage`
column because there is nothing to put in one — a phase shifter is a preventive
measure and holds one setting across every state of the world, see
[`Redispatch`](@ref).

What this reads is the terminal power of an edge, the overload where the problem
priced one, and the tap angle where the edge has one, so it writes the answer to
**any** problem and formulation rather than only to the redispatch Zorba poses,
see [`solve_zorba`](@ref). Where the problem enforced its ratings rather than
pricing them the overload column is zero throughout, which is the true answer to
a question that never allowed one; where the phase shifters were data rather than
decisions — a [`LoadFlowProblem`](@ref) — `pst_deg` reports the setpoints they
were held at.

# The sign of a phase shift

This package writes the flow as `p = -b(θᵢ - θⱼ - ta)` and Zorba as
`P = (θᵢ - θⱼ + shift)·B`, so `ta` is the negation of Zorba's phase shift and the
negation is applied here. A study that compares the two column by column would
otherwise find every phase shifter mirrored and every flow right.
"""
function zorba_tables(data::NetworkData, result::Dict{String,Any})
    haskey(result, "solution") ||
        throw(ArgumentError("this result carries no solution, termination status is " *
                            "$(result["termination_status"])"))

    return (grid_flows   = _zorba_flows(data, result),
            pst_dispatch = _zorba_phase_shifts(data, result))
end

"the flow and the overload of every link, at every step of every state of the world"
function _zorba_flows(data::NetworkData, result::Dict{String,Any})
    zs   = zorba_study(data)
    dim  = dimension(data)
    base = data.baseMVA
    rows = length(zs.link) * length(zs.time_id) * length(zs.outage)

    outage      = Vector{Union{Missing,String}}(undef, rows)
    name        = Vector{String}(undef, rows)
    from_node   = Vector{String}(undef, rows)
    to_node     = Vector{String}(undef, rows)
    time_id     = Vector{UInt16}(undef, rows)
    flow_mw     = Vector{Float32}(undef, rows)
    overload_mw = Vector{Float32}(undef, rows)

    r = 0
    for c in eachindex(zs.outage), t in eachindex(zs.time_id)
        n   = similar_id(dim, nw_id_default(dim); time = t, contingency = c)
        sol = nw_solution(result, n)["edge"]

        for l in zs.link
            r += 1
            outage[r], name[r]      = zs.outage[c], l.name
            from_node[r], to_node[r] = l.from, l.to
            time_id[r]              = zs.time_id[t]

            # a link an outage took out is absent from the topology, and so from
            # the solution; Zorba reports it at rest rather than not at all
            entry = get(sol, "$(l.id)", nothing)
            flow_mw[r]     = entry === nothing ? 0.0f0 :
                             Float32(_zorba_terminal_power(entry, l) * base)
            overload_mw[r] = entry === nothing ? 0.0f0 :
                             Float32(max(get(entry, "overload", 0.0), 0.0) * base)
        end
    end

    return (; outage, Name = name, from_node, to_node, time_id, flow_mw, overload_mw)
end

"""
    _zorba_terminal_power(entry, link)

The active power flowing into the first terminal of a link, which is its flow in
the direction the input listed its nodes in.

Every formulation with a model reports this — the linearized one as the flow
itself and the current based one as `vr·cr + vi·ci` — so a formulation that does
not is one this package has no model for, and saying that is better than a
`KeyError` from inside a dictionary.
"""
function _zorba_terminal_power(entry::Dict{String,Any}, link::ZorbaLink)
    terminal = get(entry, "terminal", nothing)
    from     = terminal === nothing ? nothing : get(terminal, "1", nothing)
    (from === nothing || !haskey(from, "p")) &&
        throw(ArgumentError("the solution of link $(link.name) carries no terminal power, " *
                            "which every formulation with a model reports; this one has none"))

    return from["p"]
end

"the setting of every phase shifter at every step, in Zorba's sign and in degrees"
function _zorba_phase_shifts(data::NetworkData, result::Dict{String,Any})
    zs   = zorba_study(data)
    dim  = dimension(data)
    ac   = [l for l in zs.link if !l.dc]
    rows = length(ac) * length(zs.time_id)

    name      = Vector{String}(undef, rows)
    from_node = Vector{String}(undef, rows)
    to_node   = Vector{String}(undef, rows)
    time_id   = Vector{UInt16}(undef, rows)
    pst_deg   = Vector{Union{Missing,Float32}}(undef, rows)

    r = 0
    for t in eachindex(zs.time_id)
        n   = similar_id(dim, nw_id_default(dim); time = t, contingency = 1)
        sol = nw_solution(result, n)["edge"]

        for l in ac
            r += 1
            name[r], from_node[r], to_node[r] = l.name, l.from, l.to
            time_id[r] = zs.time_id[t]

            entry      = get(sol, "$(l.id)", nothing)
            tap        = entry === nothing ? nothing : get(entry, "tap", nothing)
            pst_deg[r] = tap === nothing ? missing : Float32(-rad2deg(tap["ta"]))
        end
    end

    return (; Name = name, from_node, to_node, time_id, pst_deg)
end
