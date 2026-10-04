################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.11.0 - the supply of an island, and the check a model makes of it         #
################################################################################

################################################################################
# Islands — what supplies them                                                 #
################################################################################

"the unit types that put power into an island"
const _SOURCES = Union{AbstractGenerator,AbstractStorage,EnergyNotServed}

"whether node `i` is a reference node at network index `n`"
function _is_reference(net::Network, i::Int, n::Int)
    nd = node(net, i; nw = n)

    return nd isa Node && nd.type == REF
end

_has_reference(net::Network, island, n::Int) = any(i -> _is_reference(net, i, n), island)

_has_unit(net::Network, island, n::Int) =
    any(i -> !isempty(node_units(net, i; nw = n)), island)

_has_source(net::Network, island, n::Int) =
    any(i -> any(u -> unit(net, u; nw = n) isa _SOURCES, node_units(net, i; nw = n)), island)

"""
    anchor_nodes(nm; nw)

The lowest node of every island at network index `nw` that has a source but no
reference node, sorted. These are the nodes
[`constraint_node_voltage_anchor`](@ref) pins.
"""
function anchor_nodes(net::Network, n::Int)
    return [first(part) for part in islands(net; nw = n)
            if !_has_reference(net, part, n) && _has_source(net, part, n)]
end

anchor_nodes(nm::NetworkModel; nw::Int = nw_id_default(nm)) = anchor_nodes(network(nm), nw)

################################################################################
# Islands — the check                                                          #
################################################################################

"at most `max` identifiers, for an error message"
_list(x; max::Int = 10) = length(x) <= max ? string(x) :
    string("[", join(x[1:max], ", "), ", … and ", length(x) - max, " more]")

"""
    check_islands(data; islanding = :error)

Refuse a network that cannot pose a sensible problem over its islands, at every
network index of `data`; [`instantiate_model`](@ref) calls it before it builds.
Two things are refused, both with an `ArgumentError` that names the nodes:

- an island that has units but no reference node and no source, i.e., no
  generator, storage or unserved-energy unit. Its load has nothing to be
  supplied by, so the problem over it is infeasible or, worse, solved with
  the load silently dropped. An island without units, such as an empty busbar
  section, is fine, and so is an island with a source but no reference node,
  which is anchored instead, see [`constraint_node_voltage_anchor`](@ref).
- unless `islanding = :allow`, an edge that the problem may open, see
  [`can_open`](@ref), when opening all of them would split an island. A model
  that chooses which switches to open is entitled to open one that leaves a
  section of the network on its own, and it would be wrong to find out from
  the solver. Pass `islanding = :allow` to accept that.

Network indices that share a topology and have the same edges locked open are
checked once.
"""
function check_islands(data::NetworkData; islanding::Symbol = :error)
    islanding in (:error, :allow) ||
        throw(ArgumentError("`islanding` is `:error` or `:allow`, not `:$islanding`"))

    net  = network(data)
    seen = Set{Tuple{UInt,Vector{Int}}}()

    for n in nw_ids(data)
        top  = topology(net; nw = n)
        key  = (objectid(top), [e for e in top.edge if !connects(net.dim, net.edge[e], n)])
        key in seen && continue
        push!(seen, key)

        parts = islands(net; nw = n)
        for part in parts
            _check_supply(net, part, n)
        end

        islanding === :allow && continue
        free = [e for e in top.edge if can_open(net.dim, net.edge[e], n)]
        isempty(free) || _check_free(net, parts, free, n)
    end

    return nothing
end

function _check_supply(net::Network, island, n::Int)
    (_has_reference(net, island, n) || _has_source(net, island, n) ||
     !_has_unit(net, island, n)) && return nothing

    throw(ArgumentError(
        "at network index $n the nodes $(_list(island)) are an island with units but " *
        "no reference node and no source, so nothing can supply them; connect it to " *
        "the rest of the network, give it a generator, or take its units out of service"))
end

function _check_free(net::Network, parts, free, n::Int)
    split = islands(net; nw = n, without = free)
    length(split) == length(parts) && return nothing

    whole    = first(p for p in parts if p ∉ split)
    pieces   = [p for p in split if issubset(p, whole)]
    part_of  = Dict(i => k for (k, p) in enumerate(pieces) for i in p)
    culprits = [e for e in free
                if all(in(whole), terminals(net.edge[e])) &&
                   length(unique(part_of[i] for i in terminals(net.edge[e]))) > 1]
    shown    = join((_list(p; max = 5) for p in pieces[1:min(end, 3)]), ", ")

    throw(ArgumentError(
        "at network index $n opening the free edges $(_list(culprits)) would split the " *
        "island $(_list(whole)) into $(length(pieces)) islands, $shown" *
        (length(pieces) > 3 ? ", …" : "") * "; the problem was not posed over a network " *
        "that comes apart, so give those nodes another path, lock the edges, or pass " *
        "`islanding = :allow` to accept it"))
end
