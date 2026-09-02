################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.5.0 - the redispatch problem                                              #
# v0.6.0 - a window carries the periods it cut                                 #
################################################################################

################################################################################
# Windows over a dimension                                                     #
################################################################################

"""
    window(data, name, coordinates)

The data set `data` restricted to `coordinates` along dimension `name`.

The result is an ordinary [`NetworkData`](@ref) over a smaller
[`Dimension`](@ref) — one that a model is instantiated from exactly like any
other — with `name` reduced to `length(coordinates)` coordinates and every other
dimension left alone. It is what a rolling horizon cuts one step of its problem
out of, see [`solve_rolling_horizon`](@ref).

Three things follow the cut:

- the **properties** of the coordinates, so the duration of a time step and the
  weight of a scenario survive into the window;
- the [`NetworkVector`](@ref) field of every component, sliced to the network
  indices the window keeps, so a load profile or an outage pattern is carried
  across without being recomputed;
- the **topology**, which is re-derived from the sliced statuses rather than
  copied, so a window that drops the coordinate at which an edge was out of
  service has that edge in service throughout — and holds a plain status rather
  than a vector of identical ones, which puts it back on the single-topology
  fast path.

The window is indexed from one, whatever it was cut from: its first network
index is `1`, not the source index it came from. Use
[`window_indices`](@ref) to map back.

# Examples
```julia
julia> mn = set_dimension(data, Dimension(:time => 24, :contingency => 3));

julia> w = window(mn, :time, 7:12);

julia> dim_length(w), dim_length(w, :time), dim_length(w, :contingency)
(18, 6, 3)
```
"""
function window(data::NetworkData, name::Symbol, coord)
    dim   = dimension(data)
    coord = collect(Int, coord)

    has_dim(dim, name) || _no_dim(dim, name)
    isempty(coord) && throw(ArgumentError("a window over `$name` needs at least one coordinate"))
    all(c -> 1 <= c <= dim_length(dim, name), coord) ||
        throw(ArgumentError("a window over `$name` at $(coord) reaches outside its $(dim_length(dim, name)) coordinate(s)"))

    sub     = _window_dimension(dim, name, coord)
    indices = window_indices(dim, name, coord)

    I = Dict{Int,AbstractNode}(i => _slice(c, dim, indices) for (i, c) in nodes(network(data)))
    E = Dict{Int,AbstractEdge}(e => _slice(c, dim, indices) for (e, c) in edges(network(data)))
    U = Dict{Int,AbstractUnit}(u => _slice(c, dim, indices) for (u, c) in units(network(data)))

    net = Network(I, E, U; dim = sub, ext = deepcopy(network(data).ext))

    return NetworkData(net; name = data.name, baseMVA = baseMVA(data),
                       ext = deepcopy(data.ext))
end

"""
    window_indices(dim, name, coordinates)

The network index of `dim` behind every network index of the window
[`window`](@ref) cuts at `coordinates` along `name`, in window order.

The first entry is the source index of window index `1`, the second of window
index `2`, and so on, which is what maps a window's solution back onto the
problem it was cut from.
"""
function window_indices(dim::Dimension, name::Symbol, coord)
    coord = collect(Int, coord)
    sub   = _window_dimension(dim, name, coord)

    return map(nw_ids(sub)) do m
        # the window index `m` sits at the same coordinates in the source, except
        # along `name`, where its k-th coordinate is the source's `coord[k]`
        here  = coordinates(sub, m)
        there = merge(here, NamedTuple{(name,)}((coord[here[name]],)))

        return only(nw_ids(dim; there...))
    end
end

window_indices(data::NetworkData, name::Symbol, coord) =
    window_indices(dimension(data), name, coord)

"""
    _window_dimension(dim, name, coord)

The dimension a window over `coord` along `name` is posed on.

A window renumbers the coordinates it cut from one, so anything the source
stated *arithmetically* about them has to be carried over as data rather than
copied as a rule. A regular period declared on `dim` is the one such statement:
`:period_length` on a window starting at hour 5 would group hours 5–28 as its
first day, which is not what the problem said. The periods the window inherits
are therefore written out per coordinate, computed against the source, and the
rule they came from is left behind — a window is a horizon long, so holding them
costs nothing.
"""
function _window_dimension(dim::Dimension, name::Symbol, coord::Vector{Int})
    periods = _window_periods(dim, name, coord)

    pairs = map(dim_names(dim)) do nm
        prop = dim.prop[nm]
        nm === name || return Pair{Symbol,Any}(nm, prop)
        periods === nothing &&
            return Pair{Symbol,Any}(nm, prop isa Int ? length(coord) : prop[coord])

        sliced = prop isa Int ? [Dict{Symbol,Any}() for _ in coord] : prop[coord]
        return Pair{Symbol,Any}(nm, [merge(d, Dict{Symbol,Any}(:period => p))
                                     for (d, p) in zip(sliced, periods)])
    end

    sub = Dimension(pairs...)
    merge!(sub.meta, dim.meta)
    # `merge!` shares the source's metadata dictionaries, so the entry that no
    # longer holds is replaced rather than deleted from one the source still uses
    periods === nothing ||
        (sub.meta[name] = filter(p -> first(p) !== :period_length, dim_meta(dim, name)))

    return sub
end

"the source periods of the coordinates a window cuts, or `nothing` where the rule survives"
function _window_periods(dim::Dimension, name::Symbol, coord::Vector{Int})
    _period_length(dim, name) === nothing && return nothing

    return [_period_of(dim, name, id) for id in coord]
end

"""
    _slice(c, dim, indices)

The component `c` with every one of its [`NetworkVector`](@ref) fields sliced to
`indices`.

A slice that no longer varies is collapsed back to a plain value, exactly as
`replicate` folds one: a window that steps over the coordinate at which a
component was out of service holds a constant status again, not a vector of
identical ones, and the network it belongs to is back on the single-topology
fast path rather than deriving one per index.
"""
function _slice(c::T, dim::Dimension, indices::Vector{Int}) where {T<:AbstractComponent}
    has_nw_data(c) || return c

    fields = map(1:fieldcount(T)) do k
        f = getfield(c, k)
        f isa NetworkVector || return f

        sliced = [nw_value(dim, f, n) for n in indices]
        return allequal(sliced) ? first(sliced) : NetworkVector(sliced)
    end

    return T(fields...)
end

################################################################################
# What a component carries from one window to the next                         #
################################################################################

"""
    initial_state(component, nm, n)

`component` as it should start the next window, with whatever it carries across
windows read from the solved model `nm` at network index `n`.

Returned unchanged unless the type says otherwise, which is what makes this the
one thing a rolling horizon needs from a component. A [`Storage`](@ref) unit
carries its state of charge and has a method; nothing else in the package
carries anything, and neither does an extension type until it is given one.

The distinction it draws is between a *decision*, which each window makes afresh
over its own horizon, and a *state*, which the previous window has already fixed
and the next one inherits. Only the second survives the roll.
"""
initial_state(c::AbstractComponent, ::NetworkModel, ::Int) = c

################################################################################
# Whether two network indices give the same model                              #
################################################################################

"""
    same_topology(net, a, b)

Whether network indices `a` and `b` have the same [`Topology`](@ref).

This is a pointer comparison and costs almost nothing. [`topology`](@ref) does
not build a fresh object per network index: indices that agree on which
components are in service are handed *the same* object, because the topologies
are cached under the statuses that produce them. Where no status varies at all
the question is answered before a signature is even computed.

It is the cheap half of [`same_structure`](@ref), and on its own it is
**necessary but not sufficient** — see there.
"""
same_topology(net::Network, a::Int, b::Int) =
    a == b || topology(net; nw = a) === topology(net; nw = b)

same_topology(data::NetworkData, a::Int, b::Int) = same_topology(network(data), a, b)

"""
    structure_gates(component)

The fields of `component` whose value decides *which* constraints and bounds a
model has, rather than only what they say.

Most component data is a coefficient: change a load and the same constraint
holds a different number. A handful of fields are not, because the code that
writes the model asks a question of them first and writes nothing when the
answer is no — a `rate_a` of `Inf` produces no rating at all, a `pmax` of `Inf`
produces no upper bound, an `angmin` of `-π/2` produces no angle limit. A field
like that changes the *shape* of the model, not a number in it.

Returns `()` unless the type says otherwise, which is the right answer for a
component with no such field. An extension type whose constraints are written
conditionally needs a method here, or the answers [`same_structure`](@ref) gives
about it will be wrong.

The methods in this package correspond one for one to the guards in the model:
the `isfinite` tests in `constraint_edge_rating!`, `constraint_linear_limits!`,
`_variable_generator_power`, `_variable_generator_active` and the flexible load,
and the `±π/2` test in `constraint_edge_angle_difference!`.
"""
structure_gates(::AbstractComponent) = ()

"""
    structure_varies(net)

Whether anything that decides the *structure* of a model varies over the network
index.

`false` is the strong answer and the common one: no status varies, so every
network index has one topology, and no [`structure_gates`](@ref) field varies, so
every index writes the same constraints. One model shape then serves the whole
problem, and [`same_structure`](@ref) is `true` everywhere without being asked.

Costs one pass over the components, once, rather than anything per network
index — which is why it is worth asking before asking anything else.
"""
function structure_varies(net::Network)
    isempty(switchable(net)) || return true

    for family in (net.node, net.edge, net.unit), (_, c) in family
        has_nw_data(c) || continue
        any(is_nw_varying(getfield(c, f)) for f in structure_gates(c)) && return true
    end

    return false
end

structure_varies(data::NetworkData) = structure_varies(network(data))

"""
    same_structure(net, a, b)

Whether network indices `a` and `b` produce a model of the same shape: the same
variables, and the same constraints holding between them.

Two things have to agree, and the second is the one that is easy to miss:

1. the [`Topology`](@ref), i.e. which components are in service — see
   [`same_topology`](@ref);
2. every [`structure_gates`](@ref) field, because a `rate_a` that is finite at
   one index and `Inf` at another writes a rating at one and not at the other
   while the topology sits perfectly still.

The test is **conservative**: it compares whether each gate bounds anything at
all, so it may call two indices different where the model would in fact have
come out the same. It never calls them the same where the model would differ,
which is the direction that matters for anything built on top of it.

# Examples
A rolling horizon reuses a model between two windows only where the whole window
agrees, and its windows are offset by `step`, so what it needs is not that the
structure is *constant* but that it survives a shift:

```julia
stable = [same_structure(net, n, n + step) for n in 1:steps-step]
breaks = cumsum(.!stable)            # then any window is answered in O(1)
```

Ask [`structure_varies`](@ref) first: where it is `false` this is `true` for
every pair and neither loop is needed.
"""
function same_structure(net::Network, a::Int, b::Int)
    a == b && return true
    same_topology(net, a, b) || return false

    for family in (net.node, net.edge, net.unit), (_, c) in family
        has_nw_data(c) || continue
        for f in structure_gates(c)
            x = getfield(c, f)
            is_nw_varying(x) || continue
            _gate(nw_value(net.dim, x, a)) == _gate(nw_value(net.dim, x, b)) || return false
        end
    end

    return true
end

same_structure(data::NetworkData, a::Int, b::Int) = same_structure(network(data), a, b)

"""
    _gate(x)

What a [`structure_gates`](@ref) value means structurally: whether it bounds
anything at all, and whether it lies inside `(-π/2, π/2)`.

The pair covers both kinds of guard the package writes — `isfinite` for a rating
or an operating limit, `±π/2` for an angle difference — without the caller
having to know which kind a given field is.
"""
_gate(x::Real) = (isfinite(x), -pi / 2 < x < pi / 2)
_gate(x::AbstractVector) = map(_gate, x)
