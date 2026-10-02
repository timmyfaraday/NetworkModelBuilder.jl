################################################################################
# Contingencies.jl                                                            #
# Posing a data set over a `:contingency` dimension from a list of            #
# `ContingencyEvent`s, and sorting out which events can be posed at all.      #
################################################################################

module Contingencies

using NetworkModelBuilder
using ..ContingencyData: ContingencyEvent
import ..SteeringPlanData

export with_contingencies, bridge_events, contingency_events, touches

"""
    with_contingencies(data, events)

`data` rebuilt over `Dimension(:time => T, :contingency => length(events) + 1)`:
contingency `1` is the base case and contingency `k + 1` takes out every edge
and unit `events[k]` lists, together — following `test/rd.jl`'s N-1 pattern,
generalized from one contingency coordinate per outaged edge to one per
[`ContingencyEvent`](@ref), which may bundle several edges (a multi-section
line, a busbar's connected elements) that trip as one.

A component is out at every contingency whose event lists it, not just the
first: a line that is a simple N-1 event of its own and also part of a busbar
group is out in both. A unit is overridden the exact same way an edge is, since
a [`Generator`](@ref) carries the same `status` field an edge does.

Every component's existing `:time` profile is spread unchanged over every
contingency, since `set_dimension` does not do this on its own: a `NetworkVector`
built against the smaller `:time`-only dimension has to be re-wrapped over the
larger one, exactly as the `nw_vector(dim, name, values)` docstring describes
for "a daily profile in a problem that also has contingencies".
"""
function with_contingencies(data::NetworkData, events::Vector{ContingencyEvent})
    new_dim   = add_dimension(dimension(data), :contingency, length(events) + 1)
    edge_sets = [ev.edges for ev in events]
    unit_sets = [ev.units for ev in events]

    return set_dimension(data, new_dim; apply! = function (net, dim)
        for (id, c) in net.node
            net.node[id] = _spread_over(c, dim)
        end
        for (id, c) in net.edge
            net.edge[id] = _taken_out_by(_spread_over(c, dim), dim, edge_sets, id)
        end
        for (id, c) in net.unit
            net.unit[id] = _taken_out_by(_spread_over(c, dim), dim, unit_sets, id)
        end
    end)
end

"every `NetworkVector` field of `c`, re-spread from its old `:time`-only dimension onto `new_dim`"
function _spread_over(c::T, new_dim::Dimension) where {T}
    kwargs = Dict{Symbol,Any}()
    for f in fieldnames(T)
        v = getfield(c, f)
        kwargs[f] = v isa NetworkVector ? nw_vector(new_dim, :time, v.data) : v
    end

    return T(; kwargs...)
end

"`c` with its `status` false at the contingency of every event in `outages` that lists component `id`"
function _taken_out_by(c::T, dim::Dimension, outages, id::Int) where {T}
    events = findall(set -> id in set, outages)
    isempty(events) && return c

    return T(; SteeringPlanData._fields(c)...,
             status = nw_vector(dim, (n, coord) -> nw_value(dim, c.status, n) &&
                                                   !(coord.contingency - 1 in events)))
end

"the number of connected components of `net`'s nodes when only `active_edges` carry a connection"
function _n_components(net::Network, active_edges)
    node_ids = ids(net, AbstractNode)
    index    = Dict(i => k for (k, i) in enumerate(node_ids))
    n        = length(node_ids)

    parent = collect(1:n)
    find(x) = (while parent[x] != x
                   parent[x] = parent[parent[x]]
                   x = parent[x]
               end; x)
    for e in active_edges
        i, j   = terminals(edges(net)[e])
        ri, rj = find(index[i]), find(index[j])
        ri == rj || (parent[ri] = rj)
    end

    return length(Set(find(k) for k in 1:n))
end

"""
    bridge_events(net, events)

The `events` whose edges, removed *together*, disconnect the graph — the
group generalization of a bridge (cut-edge) to a [`ContingencyEvent`](@ref) that
may outage several edges at once. Found by brute force — remove each event's
edges in turn and count connected components with a union-find — which is fine
at this network's size (a few hundred edges, under a hundred events), and
specializes to the single-edge bridge test for an event that outages only one.

This matters because an N-1 outage of a bridge — or of a set of edges that
together act as one — islands whatever sits on the far side of it with no path
back to the rest of the network. If that island's net position is not exactly
zero — the general case — no redispatch can rebalance it: there is no
alternate route for power to take. That is a structurally non-securable
contingency, not a shortfall of generation headroom, and no [`Redispatch`](@ref)
measure can fix it.

An event with no resolved edges at all (a busbar group that only resolved to a
generator, say) cannot disconnect anything by this test and is never excluded
by it.
"""
function bridge_events(net::Network, events::Vector{ContingencyEvent})
    all_edges = ids(net, AbstractEdge)
    base      = _n_components(net, all_edges)

    return [ev for ev in events if !isempty(ev.edges) &&
                                    _n_components(net, setdiff(all_edges, ev.edges)) > base]
end

"""
    contingency_events(net, candidates)

`candidates` with its [`bridge_events`](@ref) removed, and the excluded ones —
in that order — since an event whose combined outage disconnects the graph is
excluded from getting its own N-1 contingency coordinate but its edges are
still worth monitoring for congestion.
"""
function contingency_events(net::Network, candidates::Vector{ContingencyEvent})
    bridges       = bridge_events(net, candidates)
    bridge_labels = Set(ev.label for ev in bridges)
    kept          = [ev for ev in candidates if !(ev.label in bridge_labels)]

    return kept, bridges
end

"whether any resolved edge of contingency event `ev` satisfies `pred(data, e)` — e.g. `touches(cross_border, data, ev)`"
touches(pred, data::NetworkData, ev::ContingencyEvent) = any(e -> pred(data, e), ev.edges)

end # module
