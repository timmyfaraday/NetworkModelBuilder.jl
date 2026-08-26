################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.1.0 - initial implementation                                              #
################################################################################

################################################################################
# The extended graph (I, E, U)                                                 #
################################################################################

"""
    AbstractComponent

Root of the component type hierarchy. A power system is represented by an
extended graph `(I, E, U)`:

- `I`, the **nodes**, subtypes of [`AbstractNode`](@ref);
- `E`, the **edges**, subtypes of [`AbstractEdge`](@ref), each connected to an
  ordered list of nodes `(e, i, j, ...)`, which allows an edge to have more than
  two terminals;
- `U`, the **units**, subtypes of [`AbstractUnit`](@ref), each connected to a
  single node `(u, i)`.

Every concrete component carries an `id::Int`, a `status::Bool` and an
`ext::Dict{Symbol,Any}`. Edges additionally carry `terminals::Vector{Int}` and
units a `node::Int`.
"""
abstract type AbstractComponent end

"a node `i ∈ I` of the extended graph"
abstract type AbstractNode <: AbstractComponent end

"an edge `(e, i, j, ...) ∈ E` of the extended graph, connected to two or more nodes"
abstract type AbstractEdge <: AbstractComponent end

"a unit `(u, i) ∈ U` of the extended graph, connected to a single node"
abstract type AbstractUnit <: AbstractComponent end

"the identifier of a component"
component_id(c::AbstractComponent) = c.id

"whether a component is in service"
is_active(c::AbstractComponent) = c.status

"the ordered node identifiers an edge is connected to, `(i, j, ...)`"
terminals(e::AbstractEdge) = e.terminals

"the number of terminals of an edge"
nterminals(e::AbstractEdge) = length(terminals(e))

"the node identifier a unit is connected to"
node(u::AbstractUnit) = u.node

################################################################################
# Arcs                                                                         #
################################################################################

"""
    Arc(edge, terminal, node)

One terminal of one edge, i.e., the pair `(e, t)` of edge `e` and terminal
position `t`, together with the node `i` that terminal is connected to.

An arc, not an unordered `(e, i)` pair, is the index of every edge flow
variable. The terminal position is part of the identity because the terminals of
an edge are not interchangeable — the high and low voltage windings of a
transformer behave differently — and because two terminals of the same edge may
be connected to the same node.

Arcs are ordered lexicographically by `(edge, terminal, node)`.
"""
struct Arc
    edge    ::Int
    terminal::Int
    node    ::Int
end

Base.:(==)(a::Arc, b::Arc) = a.edge == b.edge && a.terminal == b.terminal && a.node == b.node
Base.hash(a::Arc, h::UInt) = hash(a.node, hash(a.terminal, hash(a.edge, hash(:Arc, h))))
Base.isless(a::Arc, b::Arc) = (a.edge, a.terminal, a.node) < (b.edge, b.terminal, b.node)
Base.show(io::IO, a::Arc) = print(io, "Arc($(a.edge), $(a.terminal), $(a.node))")

"the identifier of the edge an arc belongs to"
edge_id(a::Arc) = a.edge

"the terminal position of an arc within its edge"
terminal_id(a::Arc) = a.terminal

"the identifier of the node an arc is connected to"
node_id(a::Arc) = a.node

################################################################################
# Network                                                                      #
################################################################################

"""
    Network

The extended graph `(I, E, U)` of a power system at a single network index,
together with the derived topology used when building a model.

# Fields
- `node`, `edge`, `unit`: the components, keyed by identifier. Identifiers are
  unique within each of the three families, not across them.
- `arc`: every arc of every in-service edge, sorted.
- `node_arc`: the arcs incident to each node.
- `node_unit`: the identifiers of the in-service units connected to each node.
- `edge_arc`: the arcs of each in-service edge, in terminal order.
- `ext`: free-form storage for extension packages.

The derived fields cover in-service components only. Out-of-service components
are retained in `node`, `edge` and `unit` so that they survive a round trip
through the data layer, but they are never given variables or constraints.
"""
struct Network
    node     ::Dict{Int,AbstractNode}
    edge     ::Dict{Int,AbstractEdge}
    unit     ::Dict{Int,AbstractUnit}
    arc      ::Vector{Arc}
    node_arc ::Dict{Int,Vector{Arc}}
    node_unit::Dict{Int,Vector{Int}}
    edge_arc ::Dict{Int,Vector{Arc}}
    ext      ::Dict{Symbol,Any}
end

"""
    Network(I, E, U; ext = Dict{Symbol,Any}())

Build a [`Network`](@ref) from the nodes `I`, edges `E` and units `U`, keyed by
identifier, and derive its topology.

Edges and units connected to an out-of-service or unknown node are taken out of
service, with a warning for the unknown case.
"""
function Network(I::AbstractDict{Int,<:AbstractNode},
                 E::AbstractDict{Int,<:AbstractEdge},
                 U::AbstractDict{Int,<:AbstractUnit};
                 ext::Dict{Symbol,Any} = Dict{Symbol,Any}())

    nodes = Dict{Int,AbstractNode}(I)
    edges = Dict{Int,AbstractEdge}(E)
    units = Dict{Int,AbstractUnit}(U)

    live(i) = haskey(nodes, i) && is_active(nodes[i])

    arc       = Arc[]
    node_arc  = Dict{Int,Vector{Arc}}(i => Arc[] for i in keys(nodes))
    node_unit = Dict{Int,Vector{Int}}(i => Int[] for i in keys(nodes))
    edge_arc  = Dict{Int,Vector{Arc}}()

    for e in sort!(collect(keys(edges)))
        cmp = edges[e]
        is_active(cmp) || continue
        term = terminals(cmp)
        length(term) >= 2 ||
            throw(ArgumentError("edge $e has $(length(term)) terminal(s), an edge needs at least two"))
        for i in term
            haskey(nodes, i) ||
                throw(ArgumentError("edge $e is connected to node $i, which is not part of the network"))
        end
        all(live, term) || continue
        edge_arc[e] = [Arc(e, t, i) for (t, i) in enumerate(term)]
        append!(arc, edge_arc[e])
    end

    for u in sort!(collect(keys(units)))
        cmp = units[u]
        is_active(cmp) || continue
        i = node(cmp)
        haskey(nodes, i) ||
            throw(ArgumentError("unit $u is connected to node $i, which is not part of the network"))
        live(i) || continue
        push!(node_unit[i], u)
    end

    for a in arc
        push!(node_arc[a.node], a)
    end
    for v in values(node_arc)
        sort!(v)
    end

    return Network(nodes, edges, units, sort!(arc), node_arc, node_unit, edge_arc, ext)
end

################################################################################
# NetworkData                                                                  #
################################################################################

"""
    NetworkData

A complete data set: one [`Network`](@ref) per network index, plus the
[`Dimension`](@ref) that gives those indices their meaning.

A single-network data set has `Dimension()` and the single network index `1`.
Use [`replicate`](@ref) to expand a single-network data set over a dimension.
"""
struct NetworkData
    name   ::String
    baseMVA::Float64
    dim    ::Dimension
    nw     ::Dict{Int,Network}
    ext    ::Dict{Symbol,Any}
end

"""
    NetworkData(network; name, baseMVA, ext)

Wrap a single [`Network`](@ref) as a single-network data set.
"""
NetworkData(network::Network; name::String = "unnamed", baseMVA::Float64 = 100.0,
            ext::Dict{Symbol,Any} = Dict{Symbol,Any}()) =
    NetworkData(name, baseMVA, Dimension(), Dict(1 => network), ext)

"""
    replicate(data, dim; apply! = nothing)

Expand a single-network `data` set over `dim`, giving every network index its own
deep copy of the extended graph.

`apply!`, when given, is called as `apply!(network, n, coordinates)` for each
network index `n`, where `coordinates` is the `NamedTuple` returned by
[`coordinates`](@ref). Use it to write the network-index-dependent data — a time
series of loads, the outage of an edge in a contingency, the source impedance at
a harmonic — into the copy.

The topology is rebuilt after `apply!` runs, so `apply!` may change the status of
a component.
"""
function replicate(data::NetworkData, dim::Dimension; apply! = nothing)
    dim_length(data.dim) == 1 ||
        throw(ArgumentError("`replicate` expects a single-network data set, this one spans $(dim_length(data.dim)) network indices"))

    source = first(values(data.nw))
    nw = Dict{Int,Network}()
    for n in nw_ids(dim)
        I   = Dict{Int,AbstractNode}(deepcopy(source.node))
        E   = Dict{Int,AbstractEdge}(deepcopy(source.edge))
        U   = Dict{Int,AbstractUnit}(deepcopy(source.unit))
        ext = deepcopy(source.ext)
        net = Network(I, E, U; ext)
        if apply! !== nothing
            apply!(net, n, coordinates(dim, n))
            net = Network(net.node, net.edge, net.unit; ext = net.ext)
        end
        nw[n] = net
    end

    return NetworkData(data.name, data.baseMVA, dim, nw, deepcopy(data.ext))
end

################################################################################
# Accessors                                                                    #
################################################################################

"the network at network index `n`"
network(data::NetworkData, n::Int = first(nw_ids(data))) = data.nw[n]

"the [`Dimension`](@ref) of a data set"
dimension(data::NetworkData) = data.dim

for f in (:dim_names, :has_dim, :dim_length, :dim_position, :coordinates, :dim_prop,
          :dim_meta, :nw_ids, :similar_ids, :similar_id, :first_id, :last_id,
          :is_first_id, :is_last_id, :prev_id, :next_id, :prev_ids, :next_ids)
    @eval $f(data::NetworkData, args...; kwargs...) = $f(data.dim, args...; kwargs...)
end

"the nodes `I` of a network"
nodes(net::Network) = net.node
"the edges `E` of a network"
edges(net::Network) = net.edge
"the units `U` of a network"
units(net::Network) = net.unit
"the arcs of a network"
arcs(net::Network) = net.arc

"the node `i`"
node(net::Network, i::Int) = net.node[i]
"the edge `e`"
edge(net::Network, e::Int) = net.edge[e]
"the unit `u`"
unit(net::Network, u::Int) = net.unit[u]

"the arcs incident to node `i`"
node_arcs(net::Network, i::Int) = net.node_arc[i]
"the in-service units connected to node `i`"
node_units(net::Network, i::Int) = net.node_unit[i]
"the arcs of edge `e`, in terminal order"
edge_arcs(net::Network, e::Int) = net.edge_arc[e]

"""
    ids(net, T)

Sorted identifiers of the in-service components of `net` that are instances of
`T`, where `T` is a node, edge or unit type.

# Examples
```julia
julia> ids(net, Node)
julia> ids(net, Branch)
julia> ids(net, AbstractUnit)
```
"""
function ids(net::Network, ::Type{T}) where {T<:AbstractComponent}
    d = T <: AbstractNode ? net.node :
        T <: AbstractEdge ? net.edge :
        T <: AbstractUnit ? net.unit :
        throw(ArgumentError("`$T` is neither a node, an edge nor a unit type"))
    return sort!([i for (i, c) in d if c isa T && is_active(c)])
end

"""
    arcs(net, T)

Sorted arcs of the in-service edges of `net` that are instances of the edge type
`T`.
"""
arcs(net::Network, ::Type{T}) where {T<:AbstractEdge} =
    sort!(reduce(vcat, (net.edge_arc[e] for e in ids(net, T)); init = Arc[]))

Base.show(io::IO, net::Network) = print(io, "Network(|I| = $(length(net.node)), " *
    "|E| = $(length(net.edge)), |U| = $(length(net.unit)))")

function Base.show(io::IO, data::NetworkData)
    print(io, "NetworkData(\"$(data.name)\", $(dim_length(data.dim)) network ",
          dim_length(data.dim) == 1 ? "index" : "indices")
    isempty(dim_names(data.dim)) || print(io, " over $(dim_names(data.dim))")
    print(io, ")")
end
