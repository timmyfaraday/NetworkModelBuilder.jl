################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.10.0 - initial implementation                                             #
################################################################################

################################################################################
# Security screening output                                                    #
################################################################################

# A dashboard reads a security screening as three tables of one shape: the flow
# of every edge at every time step in every contingency but the base case, and
# the two tables that reduce those down to the worst case in either direction.
# This file builds that shape from any solved `NetworkData` posed over a
# `:contingency` dimension. It is not part of the Zorba adapter and does not
# read `data.ext[:zorba]` — the shape is what an N-1 security screening is, for
# any grid this package can solve, and a study `parse_zorba` built happens to
# already carry the names a dashboard was written against. See
# `docs/src/manual/dashboard.md` for how the two vocabularies line up.

"the active power into the first terminal of `entry`, the flow of `label` in the direction its nodes were given"
function _terminal_power(entry::Dict{String,Any}, label::String)
    terminal = get(entry, "terminal", nothing)
    from     = terminal === nothing ? nothing : get(terminal, "1", nothing)
    (from === nothing || !haskey(from, "p")) &&
        throw(ArgumentError("the solution of edge $label carries no terminal power, which " *
                            "every formulation with a model reports; this one has none"))

    return from["p"]
end

"""
    security_tables(data, result; edge_ids, contingencies, outage, time_id)

The flow of every edge, at every time step and every contingency, and the two
tables that reduce that down to the worst case in either direction.

Returns `(; frank_safe_borders, nm1_max_flows, nm1_min_flows)`, each a
`NamedTuple` of columns:

| column      | meaning                                                          |
|:------------|:------------------------------------------------------------------|
| `outage`    | the label of the contingency, see the `outage` keyword             |
| `Name`      | the name of the edge                                               |
| `from_node` | the name of its first terminal's node                              |
| `to_node`   | the name of its last terminal's node                               |
| `time_id`   | the label of the time step, see the `time_id` keyword              |
| `flow_mw`   | the active power into the first terminal, in MW                    |

The names are a specific dashboard's own — see
`.github/context/knowledge/plan/dashboard-output-mapping.md` — adopted directly
so a straight [`write_security_tables`](@ref) needs no relabelling to be read
where that dashboard expects it.

`frank_safe_borders` has one row per edge, time step and contingency — the base
case is never one of them, since there is nothing to screen for in a state
nothing has tripped. `nm1_max_flows` and `nm1_min_flows` have one row per edge
and time step: the largest, respectively the smallest, `flow_mw` among its
contingencies, together with the `outage` that attains it. A dashboard commonly
wants only the latter two; `frank_safe_borders` is the table they are both
computed from, and is kept because screening a border for safety needs the
whole sweep, not just its extremes.

# Keywords
- `edge_ids`: the identifiers of the edges to report, every edge of the network
  by default. Every one is reported at every contingency, at rest — `0.0` — in a
  state that takes it out of service, which is what a dashboard expects to find
  rather than a missing row.
- `contingencies`: the `:contingency` coordinates to sweep, every one but the
  base case (coordinate `1`) by default.
- `outage`: the label written for each of `contingencies`, in the same order.
  Defaults to its coordinate as a string; give the real names of an adapter that
  tracks them, e.g. `zorba_study(data).outage[2:end]`.
- `time_id`: the label written for each `:time` coordinate, `1:dim_length(data,
  :time)` by default. Give the real ones where the network's own time steps are
  not what a reader outside this package expects — `zorba_study(data)` carries
  them for a Zorba study.

# Examples
```julia
tables = security_tables(data, result)
tables = security_tables(data, result; outage = zorba_study(data).outage[2:end],
                                       time_id = zorba_study(data).time_id)
```
"""
function security_tables(data::NetworkData, result::Dict{String,Any};
                         edge_ids::Union{Nothing,AbstractVector{Int}} = nothing,
                         contingencies::Union{Nothing,AbstractVector{Int}} = nothing,
                         outage::Union{Nothing,AbstractVector} = nothing,
                         time_id::Union{Nothing,AbstractVector} = nothing)
    has_dim(data, :time) && has_dim(data, :contingency) ||
        throw(ArgumentError("a security screening needs a `:time` and a `:contingency` " *
                            "dimension, and this network has $(dim_names(data))"))

    net           = network(data)
    edge_ids      = edge_ids      === nothing ? sort!(collect(keys(edges(net)))) : edge_ids
    contingencies = contingencies === nothing ? collect(2:dim_length(data, :contingency)) : contingencies
    outage        = outage        === nothing ? string.(contingencies) : outage
    time_id       = time_id       === nothing ? collect(1:dim_length(data, :time)) : time_id

    length(outage) == length(contingencies) ||
        throw(ArgumentError("`outage` holds $(length(outage)) label(s) but `contingencies` " *
                            "holds $(length(contingencies))"))
    length(time_id) == dim_length(data, :time) ||
        throw(ArgumentError("`time_id` holds $(length(time_id)) label(s) but the network " *
                            "has $(dim_length(data, :time)) time steps"))

    dim  = dimension(data)
    base = baseMVA(data)
    nt, nc, ne = length(time_id), length(contingencies), length(edge_ids)

    comp   = [edge(net, e; nw = nw_id_default(net)) for e in edge_ids]
    enames = [c.name for c in comp]
    efrom  = [node(net, first(c.terminals); nw = nw_id_default(net)).name for c in comp]
    eto    = [node(net, last(c.terminals);  nw = nw_id_default(net)).name for c in comp]

    flow = Array{Float32}(undef, nc, nt, ne)
    for (ci, c) in enumerate(contingencies), t in 1:nt
        n   = similar_id(dim, nw_id_default(dim); time = t, contingency = c)
        sol = nw_solution(result, n)["edge"]
        for (ei, e) in enumerate(edge_ids)
            entry = get(sol, "$e", nothing)
            flow[ci, t, ei] = entry === nothing ? 0.0f0 :
                             Float32(_terminal_power(entry, enames[ei]) * base)
        end
    end

    return (; frank_safe_borders = _security_flows(outage, enames, efrom, eto, time_id, flow),
            nm1_max_flows = _security_extreme(findmax, outage, enames, efrom, eto, time_id, flow),
            nm1_min_flows = _security_extreme(findmin, outage, enames, efrom, eto, time_id, flow))
end

"one row per edge, time step and contingency, the full sweep `frank_safe_borders` reports"
function _security_flows(outage, name, from_node, to_node, time_id, flow::Array{Float32,3})
    nc, nt, ne = size(flow)
    rows = nc * nt * ne

    o  = Vector{eltype(outage)}(undef, rows)
    nm = Vector{eltype(name)}(undef, rows)
    fr = Vector{eltype(from_node)}(undef, rows)
    to = Vector{eltype(to_node)}(undef, rows)
    ti = Vector{eltype(time_id)}(undef, rows)
    fl = Vector{Float32}(undef, rows)

    r = 0
    for ci in 1:nc, t in 1:nt, ei in 1:ne
        r += 1
        o[r], nm[r], fr[r], to[r] = outage[ci], name[ei], from_node[ei], to_node[ei]
        ti[r], fl[r] = time_id[t], flow[ci, t, ei]
    end

    return (; outage = o, Name = nm, from_node = fr, to_node = to, time_id = ti, flow_mw = fl)
end

"one row per edge and time step, the extreme of `flow` across contingency that `pick` finds"
function _security_extreme(pick, outage, name, from_node, to_node, time_id, flow::Array{Float32,3})
    nc, nt, ne = size(flow)
    rows = nt * ne

    o  = Vector{eltype(outage)}(undef, rows)
    nm = Vector{eltype(name)}(undef, rows)
    fr = Vector{eltype(from_node)}(undef, rows)
    to = Vector{eltype(to_node)}(undef, rows)
    ti = Vector{eltype(time_id)}(undef, rows)
    fl = Vector{Float32}(undef, rows)

    r = 0
    for ei in 1:ne, t in 1:nt
        r += 1
        value, ci = pick(view(flow, :, t, ei))
        o[r], nm[r], fr[r], to[r] = outage[ci], name[ei], from_node[ei], to_node[ei]
        ti[r], fl[r] = time_id[t], value
    end

    return (; outage = o, Name = nm, from_node = fr, to_node = to, time_id = ti, flow_mw = fl)
end
