################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.1.0 - initial implementation                                              #
# v0.2.0 - network dependent data stored per component                         #
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

Every concrete component carries an `id::Int`, a `status`, and an
`ext::Dict{Symbol,Any}`. Edges additionally carry `terminals::Vector{Int}` and
units a `node::Int`.

There is one extended graph per data set, not one per network index. A field
whose value the network index changes is stored on the component itself as a
[`NetworkVector`](@ref); a field that is the same at every network index is
stored as a plain value. Component types therefore declare such fields as
[`NetworkQuantity`](@ref), and their fields are read at a network index with
[`nw_component`](@ref) or [`nw_value`](@ref).
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

"the in-service status of a component, which may be a [`NetworkVector`](@ref)"
status(c::AbstractComponent) = c.status

"""
    is_active(c)
    is_active(dim, c, n)

Whether a component is in service, either outright or at network index `n`.

The one-argument form is for a component whose status does not change over the
network index; it raises an error when the status is a [`NetworkVector`](@ref),
since there is then no single answer.
"""
function is_active end

is_active(dim::Dimension, c::AbstractComponent, n::Int) = nw_value(dim, c.status, n)::Bool

function is_active(c::AbstractComponent)
    is_nw_varying(c.status) &&
        throw(ArgumentError("the status of component $(component_id(c)) varies over the network index, ask for `is_active(dim, component, n)` instead"))

    return c.status::Bool
end

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
# Topology                                                                     #
################################################################################

"""
    Topology

The incidence of the extended graph at one network index, covering the
in-service components only.

# Fields
- `node`, `edge`, `unit`: the identifiers of the in-service components, sorted.
- `arc`: every arc of every in-service edge, sorted.
- `node_arc`: the arcs incident to each node.
- `node_unit`: the identifiers of the in-service units connected to each node.
- `edge_arc`: the arcs of each in-service edge, in terminal order.

Only the status of a component can change the topology, so network indices that
agree on which components are in service share a single `Topology` object, and
nothing about a network index is stored per network index: which topology an
index has is *derived* from the statuses of the components whose status varies,
see [`topology`](@ref).
"""
struct Topology
    node     ::Vector{Int}
    edge     ::Vector{Int}
    unit     ::Vector{Int}
    arc      ::Vector{Arc}
    node_arc ::Dict{Int,Vector{Arc}}
    node_unit::Dict{Int,Vector{Int}}
    edge_arc ::Dict{Int,Vector{Arc}}
end

################################################################################
# Network                                                                      #
################################################################################

"""
    Network

The extended graph `(I, E, U)` of a power system, together with the
[`Dimension`](@ref) of the problem it is posed over and the topology it has at
each network index.

# Fields
- `dim`: the network index of the problem.
- `node`, `edge`, `unit`: the components, keyed by identifier. Identifiers are
  unique within each of the three families, not across them. There is one copy
  of each component, whatever the number of network indices; the data that
  varies lives in its [`NetworkVector`](@ref) fields.
- `switchable`: the components whose status varies over the network index, as
  `(family, id)` pairs. These, and only these, decide which [`Topology`](@ref) a
  network index has.
- `topology`: the distinct topologies, keyed by the statuses of the switchable
  components that produce them, and materialized as they are first asked for.
- `fixed`: the single topology, when no component's status varies at all; the
  common case, and the one [`topology`](@ref) answers without doing any work.
- `ext`: free-form storage for extension packages.

Nothing here is stored per network index. A problem over 8760 hours holds one
copy of each component, and one topology, exactly as a problem over one hour
does; a problem over 8760 hours with two switching patterns holds two
topologies. Both the components and the topology therefore scale with the data
rather than with the size of the network index.

Out-of-service components are retained in `node`, `edge` and `unit` so that they
survive a round trip through the data layer; they are absent from the topology at
the network indices where they are out of service, and are never given variables
or constraints there.
"""
struct Network
    dim       ::Dimension
    node      ::Dict{Int,AbstractNode}
    edge      ::Dict{Int,AbstractEdge}
    unit      ::Dict{Int,AbstractUnit}
    switchable::Vector{Tuple{Symbol,Int}}
    topology  ::Dict{BitVector,Topology}
    fixed     ::Union{Nothing,Topology}
    ext       ::Dict{Symbol,Any}
end

"""
    Network(I, E, U; dim = Dimension(), ext = Dict{Symbol,Any}())

Build a [`Network`](@ref) from the nodes `I`, edges `E` and units `U`, keyed by
identifier.

Edges and units connected to an out-of-service node are out of service too; a
reference to a node that is not part of the network is an error.

The topology is derived, not tabulated. When no component has a status that
varies over the network index the single topology is built here; otherwise each
distinct one is built the first time a network index that has it is asked about.
"""
function Network(I::AbstractDict{Int,<:AbstractNode},
                 E::AbstractDict{Int,<:AbstractEdge},
                 U::AbstractDict{Int,<:AbstractUnit};
                 dim::Dimension = Dimension(),
                 ext::Dict{Symbol,Any} = Dict{Symbol,Any}())

    nodes = Dict{Int,AbstractNode}(I)
    edges = Dict{Int,AbstractEdge}(E)
    units = Dict{Int,AbstractUnit}(U)

    for (e, cmp) in edges
        length(terminals(cmp)) >= 2 ||
            throw(ArgumentError("edge $e has $(length(terminals(cmp))) terminal(s), an edge needs at least two"))
        for i in terminals(cmp)
            haskey(nodes, i) ||
                throw(ArgumentError("edge $e is connected to node $i, which is not part of the network"))
        end
    end
    for (u, cmp) in units
        haskey(nodes, node(cmp)) ||
            throw(ArgumentError("unit $u is connected to node $(node(cmp)), which is not part of the network"))
    end

    switchable = _switchable(nodes, edges, units)
    fixed = isempty(switchable) ?
            _topology_at(dim, nodes, edges, units, nw_id_default(dim)) : nothing

    return Network(dim, nodes, edges, units, switchable,
                   Dict{BitVector,Topology}(), fixed, ext)
end

"the components whose status varies over the network index, in a stable order"
function _switchable(nodes, edges, units)
    out = Tuple{Symbol,Int}[]
    for (family, d) in ((:node, nodes), (:edge, edges), (:unit, units))
        for id in sort!(collect(keys(d)))
            is_nw_varying(d[id].status) && push!(out, (family, id))
        end
    end

    return out
end

"the stored component behind a `(family, id)` pair"
_stored(net::Network, family::Symbol, id::Int) =
    family === :node ? net.node[id] : family === :edge ? net.edge[id] : net.unit[id]

"the statuses of the switchable components at network index `n`, which pick out a topology"
function _signature(net::Network, n::Int)
    sig = BitVector(undef, length(net.switchable))
    for (k, (family, id)) in enumerate(net.switchable)
        sig[k] = nw_value(net.dim, _stored(net, family, id).status, n)
    end

    return sig
end

function _topology_at(dim::Dimension, nodes, edges, units, n::Int)
    alive     = Set(i for (i, c) in nodes if is_active(dim, c, n))
    node_ids  = sort!(collect(alive))

    arc       = Arc[]
    node_arc  = Dict{Int,Vector{Arc}}(i => Arc[] for i in node_ids)
    node_unit = Dict{Int,Vector{Int}}(i => Int[] for i in node_ids)
    edge_arc  = Dict{Int,Vector{Arc}}()
    edge_ids  = Int[]
    unit_ids  = Int[]

    for e in sort!(collect(keys(edges)))
        is_active(dim, edges[e], n) || continue
        term = terminals(edges[e])
        all(in(alive), term) || continue
        edge_arc[e] = [Arc(e, t, i) for (t, i) in enumerate(term)]
        append!(arc, edge_arc[e])
        push!(edge_ids, e)
    end

    for u in sort!(collect(keys(units)))
        is_active(dim, units[u], n) || continue
        i = node(units[u])
        i in alive || continue
        push!(node_unit[i], u)
        push!(unit_ids, u)
    end

    for a in arc
        push!(node_arc[a.node], a)
    end
    for v in values(node_arc)
        sort!(v)
    end

    return Topology(node_ids, edge_ids, unit_ids, sort!(arc), node_arc, node_unit, edge_arc)
end

################################################################################
# NetworkData                                                                  #
################################################################################

"""
    NetworkData

A complete data set: one [`Network`](@ref), its name and its power base.

The network index of the problem lives on the network, see
[`dimension`](@ref). Use [`set_dimension`](@ref) to pose an existing data set
over a new one.
"""
struct NetworkData
    name   ::String
    baseMVA::Float64
    net    ::Network
    ext    ::Dict{Symbol,Any}
end

"""
    NetworkData(network; name, baseMVA, ext)

Wrap a [`Network`](@ref) as a data set.
"""
NetworkData(net::Network; name::String = "unnamed", baseMVA::Float64 = 100.0,
            ext::Dict{Symbol,Any} = Dict{Symbol,Any}()) =
    NetworkData(name, baseMVA, net, ext)

"""
    set_dimension(data, dim; apply! = nothing)

Pose `data` over the network index `dim`, and return the result.

The extended graph is *not* duplicated. `apply!`, when given, is called once as
`apply!(net, dim)`, and is where the data that depends on the network index is
written into the components as [`NetworkVector`](@ref)s; everything it leaves
alone stays a plain value and is therefore constant over the network index.
[`nw_vector`](@ref) builds those vectors.

The topology is derived after `apply!` runs, so `apply!` may make a component's
status network dependent, which is how a contingency is expressed.

# Examples
```julia
julia> dim = Dimension(:time => 24);

julia> data = set_dimension(data, dim; apply! = function (net, dim)
           for (u, ld) in net.unit
               ld isa Load || continue
               net.unit[u] = Load(; id = ld.id, name = ld.name, node = ld.node,
                                  pd = nw_vector(dim, :time, ld.pd .* profile),
                                  qd = nw_vector(dim, :time, ld.qd .* profile))
           end
       end);
```
"""
function set_dimension(data::NetworkData, dim::Dimension; apply! = nothing)
    source = data.net
    net    = Network(deepcopy(source.node), deepcopy(source.edge), deepcopy(source.unit);
                     dim, ext = deepcopy(source.ext))

    if apply! !== nothing
        # `apply!` writes into the component dictionaries of `net`, so the
        # topology has to be derived again afterwards: a status it made network
        # dependent changes which components are in service where
        apply!(net, dim)
        net = Network(net.node, net.edge, net.unit; dim, ext = net.ext)
    end

    return NetworkData(net; name = data.name, baseMVA = data.baseMVA,
                       ext = deepcopy(data.ext))
end

"""
    replicate(data, dim; apply! = nothing)

!!! warning "Deprecated"
    `replicate` is deprecated and will be removed in a future release. It gave
    every network index its own copy of the extended graph, which stores the
    same value once per network index however little of it actually changes.
    Use [`set_dimension`](@ref) instead, which keeps one graph and stores only
    the data that varies, as a [`NetworkVector`](@ref) on the component it
    belongs to.

This method still works: it runs the old `apply!(net, n, coordinates)` against a
copy of the graph per network index, then folds the copies back into a single
graph, keeping a field as a plain value where every copy agreed on it and
wrapping it in a `NetworkVector` where they did not.
"""
function replicate(data::NetworkData, dim::Dimension; apply! = nothing)
    Base.depwarn("`replicate` is deprecated, use `set_dimension` and store the " *
                 "data that varies as a `NetworkVector` on its component", :replicate)

    copies = Dict{Int,NTuple{3,AbstractDict}}()
    for n in nw_ids(dim)
        net = Network(deepcopy(data.net.node), deepcopy(data.net.edge),
                      deepcopy(data.net.unit); ext = deepcopy(data.net.ext))
        apply! === nothing || apply!(net, n, coordinates(dim, n))
        copies[n] = (net.node, net.edge, net.unit)
    end

    nws = nw_ids(dim)
    I = Dict{Int,AbstractNode}(i => _fold(copies, nws, 1, i) for i in keys(data.net.node))
    E = Dict{Int,AbstractEdge}(e => _fold(copies, nws, 2, e) for e in keys(data.net.edge))
    U = Dict{Int,AbstractUnit}(u => _fold(copies, nws, 3, u) for u in keys(data.net.unit))

    return NetworkData(Network(I, E, U; dim, ext = deepcopy(data.net.ext));
                       name = data.name, baseMVA = data.baseMVA, ext = deepcopy(data.ext))
end

"fold one component across the per-index copies, keeping constants as plain values"
function _fold(copies, nws, family::Int, id::Int)
    first_copy = copies[first(nws)][family][id]
    T = typeof(first_copy)
    all(typeof(copies[n][family][id]) === T for n in nws) ||
        throw(ArgumentError("`apply!` changed the type of component $id between network indices, which `set_dimension` cannot express"))

    fields = map(1:fieldcount(T)) do k
        values = [getfield(copies[n][family][id], k) for n in nws]
        all(isequal(first(values)), values) ? first(values) : NetworkVector(values)
    end

    return T(fields...)
end

################################################################################
# Accessors                                                                    #
################################################################################

"the [`Network`](@ref) of a data set"
network(data::NetworkData) = data.net

"the [`Dimension`](@ref) of a data set or a network"
dimension(data::NetworkData) = data.net.dim
dimension(net::Network) = net.dim

"the system power base, in MVA"
baseMVA(data::NetworkData) = data.baseMVA

for f in (:dim_names, :has_dim, :dim_length, :dim_position, :coordinates, :dim_prop,
          :dim_meta, :nw_ids, :similar_ids, :similar_id, :first_id, :last_id,
          :is_first_id, :is_last_id, :prev_id, :next_id, :prev_ids, :next_ids,
          :nw_value, :nw_values, :nw_vector, :nw_component)
    @eval $f(net::Network, args...; kwargs...) = $f(net.dim, args...; kwargs...)
    @eval $f(data::NetworkData, args...; kwargs...) = $f(data.net.dim, args...; kwargs...)
end

"the default network index, i.e., the first one"
nw_id_default(net::Network) = first(nw_ids(net.dim))
nw_id_default(data::NetworkData) = nw_id_default(data.net)

"the nodes `I` of a network, as stored"
nodes(net::Network) = net.node
"the edges `E` of a network, as stored"
edges(net::Network) = net.edge
"the units `U` of a network, as stored"
units(net::Network) = net.unit

"""
    node(net, i; nw)
    edge(net, e; nw)
    unit(net, u; nw)

A component of a network, resolved at network index `nw` by
[`nw_component`](@ref): every field of it that varies over the network index has
been replaced by its value at `nw`.

Reach a component as stored, with its [`NetworkVector`](@ref) fields intact,
through [`nodes`](@ref), [`edges`](@ref) or [`units`](@ref), e.g.
`units(net)[3]`.

The same three names take a [`NetworkModel`](@ref) in place of the network, and
resolve against its dimension; that is the form the component files use.
"""
function node end

node(net::Network, i::Int; nw::Int = nw_id_default(net)) = nw_component(net.dim, net.node[i], nw)
edge(net::Network, e::Int; nw::Int = nw_id_default(net)) = nw_component(net.dim, net.edge[e], nw)
unit(net::Network, u::Int; nw::Int = nw_id_default(net)) = nw_component(net.dim, net.unit[u], nw)

"""
    topology(net; nw)

The [`Topology`](@ref) of a network at network index `nw`.

Which topology an index has is derived from the statuses of the components whose
status varies, never looked up in a table indexed by `nw`. When no status varies
— every problem without contingencies or switching — the answer is a single
stored topology and this costs nothing. Otherwise the statuses of the switchable
components at `nw` are read, and the topology they produce is built the first
time it is asked for and shared by every index that produces the same statuses.
"""
function topology(net::Network; nw::Int = nw_id_default(net))
    net.fixed === nothing || return net.fixed

    return get!(() -> _topology_at(net.dim, net.node, net.edge, net.unit, nw),
                net.topology, _signature(net, nw))
end

"the distinct topologies of a network that have been materialized so far"
topologies(net::Network) = net.fixed === nothing ? collect(values(net.topology)) : [net.fixed]

"the components of a network whose status varies over the network index"
switchable(net::Network) = net.switchable

"the arcs of a network at network index `nw`"
arcs(net::Network; nw::Int = nw_id_default(net)) = topology(net; nw).arc

"the arcs incident to node `i` at network index `nw`"
node_arcs(net::Network, i::Int; nw::Int = nw_id_default(net)) = topology(net; nw).node_arc[i]

"the in-service units connected to node `i` at network index `nw`"
node_units(net::Network, i::Int; nw::Int = nw_id_default(net)) = topology(net; nw).node_unit[i]

"the arcs of edge `e` at network index `nw`, in terminal order"
edge_arcs(net::Network, e::Int; nw::Int = nw_id_default(net)) = topology(net; nw).edge_arc[e]

"""
    ids(net, T; nw)

Sorted identifiers of the components of `net` that are instances of `T` and in
service at network index `nw`, where `T` is a node, edge or unit type.

# Examples
```julia
julia> ids(net, Node)
julia> ids(net, Branch; nw = 7)
julia> ids(net, AbstractUnit)
```
"""
function ids(net::Network, ::Type{T}; nw::Int = nw_id_default(net)) where {T<:AbstractComponent}
    top = topology(net; nw)
    if T <: AbstractNode
        return [i for i in top.node if net.node[i] isa T]
    elseif T <: AbstractEdge
        return [e for e in top.edge if net.edge[e] isa T]
    elseif T <: AbstractUnit
        return [u for u in top.unit if net.unit[u] isa T]
    end

    throw(ArgumentError("`$T` is neither a node, an edge nor a unit type"))
end

"""
    arcs(net, T; nw)

Sorted arcs of the in-service edges of `net` that are instances of the edge type
`T`, at network index `nw`.
"""
arcs(net::Network, ::Type{T}; nw::Int = nw_id_default(net)) where {T<:AbstractEdge} =
    sort!(reduce(vcat, (edge_arcs(net, e; nw) for e in ids(net, T; nw)); init = Arc[]))

function Base.show(io::IO, net::Network)
    print(io, "Network(|I| = $(length(net.node)), |E| = $(length(net.edge)), ",
          "|U| = $(length(net.unit))")
    dim_length(net.dim) == 1 || print(io, " over $(dim_length(net.dim)) network indices")
    print(io, ")")
end

function Base.show(io::IO, data::NetworkData)
    dim = data.net.dim
    print(io, "NetworkData(\"$(data.name)\", $(dim_length(dim)) network ",
          dim_length(dim) == 1 ? "index" : "indices")
    isempty(dim_names(dim)) || print(io, " over $(dim_names(dim))")
    print(io, ")")
end
