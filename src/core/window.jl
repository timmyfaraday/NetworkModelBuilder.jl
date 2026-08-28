################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.5.0 - the redispatch problem                                              #
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

"the dimension a window over `coord` along `name` is posed on"
function _window_dimension(dim::Dimension, name::Symbol, coord::Vector{Int})
    pairs = map(dim_names(dim)) do nm
        prop = dim.prop[nm]
        nm === name || return Pair{Symbol,Any}(nm, prop)
        return Pair{Symbol,Any}(nm, prop isa Int ? length(coord) : prop[coord])
    end

    sub = Dimension(pairs...)
    merge!(sub.meta, dim.meta)

    return sub
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
