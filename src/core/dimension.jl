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
# v0.6.0 - periods group the coordinates of a dimension                        #
################################################################################

################################################################################
# Network index                                                                #
################################################################################

"""
    Dimension{N}

The dimensions of an optimization problem, aggregated under a single *network
index* `n`.

A power system model is rarely built for a single operating point. It is built
for a set of time steps, a set of contingencies, a set of harmonics, a set of
scenarios, or any combination thereof. `Dimension` holds the names and sizes of
those axes and provides the bijection between a tuple of coordinates and the
scalar network index `n` that labels the variables and constraints of the JuMP
model.

# Fields
- `names::NTuple{N,Symbol}`: the ordered dimension names. The first dimension
  varies fastest, i.e., the network index is column-major in the coordinates.
- `prop`: per-coordinate properties, one dictionary per coordinate of each
  dimension, e.g., the duration of an hour or the probability of a scenario. A
  dimension given as a plain size stores its size instead, since a dictionary
  per coordinate of a dimension that has no properties would be the one thing
  here that grows with the number of network indices.
- `meta::Dict{Symbol,Dict{Symbol,Any}}`: properties of a dimension as a whole.
- `li::LinearIndices{N}`: the network index of every coordinate tuple, computed
  arithmetically rather than tabulated. Add `offset` to what it returns.
- `offset::Int`: the network index of the first coordinate tuple is
  `offset + 1`.

Nothing in a `Dimension` is stored per network index: a `Dimension(:time =>
8760)` is the same handful of bytes as a `Dimension(:time => 2)`.

# Examples
```julia
julia> dim = Dimension(:time => 24, :contingency => 3);

julia> nw_ids(dim; contingency = 1)
24-element Vector{Int64}:
  1
  ⋮
 24

julia> coordinates(dim, 25)
(time = 1, contingency = 2)
```

A `Dimension()` without arguments describes a single-network problem whose only
network index is `1`.
"""
const _Properties = Union{Int,Vector{Dict{Symbol,Any}}}

struct Dimension{N}
    names ::NTuple{N,Symbol}
    prop  ::Dict{Symbol,_Properties}
    meta  ::Dict{Symbol,Dict{Symbol,Any}}
    li    ::LinearIndices{N,NTuple{N,Base.OneTo{Int}}}
    offset::Int
end

"""
    Dimension(pairs...; offset = 0)

Construct a [`Dimension`](@ref) from `name => size` or `name => properties`
pairs, where `size` is an `Int` and `properties` is a vector of dictionaries,
one per coordinate.

# Examples
```julia
julia> Dimension(:time => 24)

julia> Dimension(:hour => 24, :scenario => [Dict{Symbol,Any}(:probability => 1/4) for _ in 1:4])
```
"""
function Dimension(pairs::Pair{Symbol,<:Any}...; offset::Int = 0)
    names = Tuple(first(p) for p in pairs)
    length(unique(names)) == length(names) ||
        throw(ArgumentError("duplicate dimension name in $(names)"))

    prop = Dict{Symbol,_Properties}()
    for p in pairs
        nm, val = first(p), last(p)
        if val isa Integer
            val > 0 || throw(ArgumentError("dimension `$nm` must have a positive size, got $val"))
            prop[nm] = Int(val)
        elseif val isa AbstractVector
            isempty(val) && throw(ArgumentError("dimension `$nm` must have a positive size, got 0"))
            prop[nm] = [Dict{Symbol,Any}(d) for d in val]
        else
            throw(ArgumentError("dimension `$nm` must be given as a size or as a vector of property dictionaries, got a $(typeof(val))"))
        end
    end

    meta = Dict{Symbol,Dict{Symbol,Any}}(nm => Dict{Symbol,Any}() for nm in names)
    li   = LinearIndices(Tuple(Base.OneTo(_size(prop[nm])) for nm in names))

    return Dimension{length(names)}(names, prop, meta, li, offset)
end

Dimension(; offset::Int = 0) = Dimension{0}((), Dict{Symbol,_Properties}(),
                                            Dict{Symbol,Dict{Symbol,Any}}(),
                                            LinearIndices(()), offset)

"the number of coordinates a `prop` entry describes"
_size(p::Int) = p
_size(p::Vector{Dict{Symbol,Any}}) = length(p)

"""
    add_dimension(dim, name, size; properties, metadata)

Return a new [`Dimension`](@ref) with `name` appended as the slowest varying
dimension. `dim` is left untouched.
"""
function add_dimension(dim::Dimension, name::Symbol, size::Integer;
                       properties::Union{Nothing,Vector{Dict{Symbol,Any}}} = nothing,
                       metadata::Dict{Symbol,Any} = Dict{Symbol,Any}())
    has_dim(dim, name) && throw(ArgumentError("dimension `$name` is already present"))
    properties === nothing || length(properties) == size ||
        throw(ArgumentError("`properties` has $(length(properties)) entries but `size` is $size"))

    new = Dimension((Pair{Symbol,Any}(nm, dim.prop[nm]) for nm in dim.names)...,
                    Pair{Symbol,Any}(name, properties === nothing ? Int(size) : properties);
                    offset = dim.offset)
    merge!(new.meta, dim.meta)
    new.meta[name] = metadata

    return new
end

################################################################################
# Queries                                                                      #
################################################################################

"the ordered dimension names of `dim`"
dim_names(dim::Dimension) = dim.names

"whether `dim` has a dimension named `name`"
has_dim(dim::Dimension, name::Symbol) = name in dim.names

"the number of network indices spanned by `dim`"
dim_length(dim::Dimension) = length(dim.li)

"the default network index of `dim`, i.e., its first one"
nw_id_default(dim::Dimension) = dim.offset + 1

"the number of coordinates along dimension `name`"
dim_length(dim::Dimension, name::Symbol) = _size(_prop(dim, name))

"the position of dimension `name` in the coordinate tuple"
function dim_position(dim::Dimension, name::Symbol)
    pos = findfirst(isequal(name), dim.names)
    pos === nothing && _no_dim(dim, name)
    return pos
end

"the coordinate tuple of network index `n`, as a `NamedTuple`"
function coordinates(dim::Dimension{N}, n::Int) where N
    ci = CartesianIndices(dim.li)[n - dim.offset]
    return NamedTuple{dim.names}(Tuple(ci))
end

"""
    dim_prop(dim, name, id[, key[, default]])
    dim_prop(dim, n::Int, name[, key[, default]])

Properties of coordinate `id` along dimension `name`, or of the coordinate that
network index `n` has along dimension `name`.

The three-argument form returns the whole dictionary, and a fresh empty one for
a dimension that was given as a plain size. Prefer the form with a `key`, and
with a `default` where the property is optional: neither builds a dictionary.
"""
function dim_prop end

dim_prop(dim::Dimension, name::Symbol, id::Int) = _properties(_prop(dim, name), id)
dim_prop(dim::Dimension, name::Symbol, id::Int, key::Symbol) =
    _property(_prop(dim, name), id, key)
dim_prop(dim::Dimension, name::Symbol, id::Int, key::Symbol, default) =
    _property(_prop(dim, name), id, key, default)
dim_prop(dim::Dimension, n::Int, name::Symbol) =
    dim_prop(dim, name, coordinates(dim, n)[name])
dim_prop(dim::Dimension, n::Int, name::Symbol, key::Symbol) =
    dim_prop(dim, name, coordinates(dim, n)[name], key)
dim_prop(dim::Dimension, n::Int, name::Symbol, key::Symbol, default) =
    dim_prop(dim, name, coordinates(dim, n)[name], key, default)

_properties(::Int, ::Int) = Dict{Symbol,Any}()
_properties(p::Vector{Dict{Symbol,Any}}, id::Int) = p[id]

_property(::Int, ::Int, key::Symbol) = throw(KeyError(key))
_property(p::Vector{Dict{Symbol,Any}}, id::Int, key::Symbol) = p[id][key]
_property(::Int, ::Int, ::Symbol, default) = default
_property(p::Vector{Dict{Symbol,Any}}, id::Int, key::Symbol, default) = get(p[id], key, default)

"""
    dim_meta(dim, name[, key])

Metadata of dimension `name` as a whole.
"""
dim_meta(dim::Dimension, name::Symbol) = (has_dim(dim, name) || _no_dim(dim, name); dim.meta[name])
dim_meta(dim::Dimension, name::Symbol, key::Symbol) = dim_meta(dim, name)[key]

################################################################################
# Network index arithmetic                                                     #
################################################################################

"""
    nw_ids(dim; kwargs...)

Sorted vector of network indices of `dim`, optionally filtered by the
coordinates of one or more dimensions.

Each keyword must be the name of a dimension of `dim`; its value may be a single
coordinate, a range, or any vector of coordinates.

# Examples
```julia
julia> nw_ids(dim)
julia> nw_ids(dim; time = 24)
julia> nw_ids(dim; time = 13:24, contingency = [1, 4])
```
"""
function nw_ids(dim::Dimension{N}; kwargs...)::Vector{Int} where N
    _check_kwargs(dim, kwargs)
    idx = ntuple(i -> get(kwargs, dim.names[i], axes(dim.li, i)), N)
    return _collect_ids(_at(dim, idx))
end

"""
    similar_ids(dim, n; kwargs...)

Sorted vector of network indices sharing the coordinates of `n` along every
dimension except those given in `kwargs`.
"""
function similar_ids(dim::Dimension{N}, n::Int; kwargs...)::Vector{Int} where N
    _check_kwargs(dim, kwargs)
    ci = CartesianIndices(dim.li)[n - dim.offset]
    idx = ntuple(i -> get(kwargs, dim.names[i], ci[i]), N)
    return _collect_ids(_at(dim, idx))
end

"""
    similar_id(dim, n; kwargs...)

The single network index sharing the coordinates of `n` along every dimension
except those given in `kwargs`, which must each be a single coordinate.
"""
function similar_id(dim::Dimension{N}, n::Int; kwargs...)::Int where N
    _check_kwargs(dim, kwargs)
    ci = CartesianIndices(dim.li)[n - dim.offset]
    idx = ntuple(i -> get(kwargs, dim.names[i], ci[i])::Int, N)
    return _at(dim, idx)
end

"the first network index along `names`, holding the other coordinates of `n` fixed"
first_id(dim::Dimension, n::Int, names::Symbol...) = _edge_id(dim, n, names, first)

"the last network index along `names`, holding the other coordinates of `n` fixed"
last_id(dim::Dimension, n::Int, names::Symbol...) = _edge_id(dim, n, names, last)

"whether `n` is the first network index along dimension `name`"
is_first_id(dim::Dimension, n::Int, name::Symbol) = n == first_id(dim, n, name)

"whether `n` is the last network index along dimension `name`"
is_last_id(dim::Dimension, n::Int, name::Symbol) = n == last_id(dim, n, name)

"the previous network index along dimension `name`, holding the other coordinates of `n` fixed"
prev_id(dim::Dimension, n::Int, name::Symbol) = _step_id(dim, n, name, -1)

"the next network index along dimension `name`, holding the other coordinates of `n` fixed"
next_id(dim::Dimension, n::Int, name::Symbol) = _step_id(dim, n, name, +1)

"all preceding network indices along dimension `name`, holding the other coordinates of `n` fixed"
prev_ids(dim::Dimension, n::Int, name::Symbol) = _range_ids(dim, n, name, :before)

"all subsequent network indices along dimension `name`, holding the other coordinates of `n` fixed"
next_ids(dim::Dimension, n::Int, name::Symbol) = _range_ids(dim, n, name, :after)

################################################################################
# Periods                                                                      #
################################################################################

# A *period* groups the coordinates of one dimension into sub-horizons: the days
# of a year of hours, the weeks of a season. It is what a constraint that holds
# once per day rather than once per horizon is written against — a daily energy
# limit, a storage cycle limit, the worst overload of a day.
#
# There are two ways to say what the periods are, and they answer different
# questions. A **regular** grouping is one number on the dimension as a whole,
# `dim_meta(dim, :time)[:period_length] = 24`, and the period of a coordinate is
# then arithmetic. An **irregular** grouping is a `:period` property on each
# coordinate, which is the only way to say that the periods have unequal length.
# The property wins where both are given, being the more specific statement.
#
# Saying nothing gives one period spanning the whole dimension, which is the
# right answer for a problem with no daily structure: every helper here then
# reduces to the horizon, and a constraint written per period is written once.
#
# What makes this worth having over a table from time step to day is not the
# storage — a `:period` property per coordinate *is* that table — but that the
# grouping composes. `period_ids` holds every other coordinate of the network
# index fixed, so a problem posed over contingencies as well as time gets one
# constraint per period *per contingency* without a second table and without the
# component asking whether a contingency dimension exists.

"""
    period_id(dim, n[, name])

The period the network index `n` belongs to along dimension `name`, defaulting
to `:time`.

See [`period_ids`](@ref) for the indices that share it, and the source of this
file for how a grouping is declared.
"""
period_id(dim::Dimension, n::Int, name::Symbol = :time) =
    _period_of(dim, name, coordinates(dim, n)[name])

"""
    period_ids(dim, n[, name])

Sorted network indices sharing the period of `n` along dimension `name`, with
every other coordinate of `n` held fixed.

This is the window a constraint that holds once per period sums over. With no
grouping declared it is the whole horizon, so a component written against it
behaves the same way in a problem that has no periods.

# Examples
```julia
julia> dim = Dimension(:time => 96, :contingency => 3);

julia> dim_meta(dim, :time)[:period_length] = 24;

julia> period_ids(dim, 30)   # the day holding index 30, in its own contingency
24-element Vector{Int64}:
 25
  ⋮
 48
```
"""
period_ids(dim::Dimension, n::Int, name::Symbol = :time) =
    similar_ids(dim, n; (name => _period_coordinates(dim, name, period_id(dim, n, name)),)...)

"whether `n` is the first network index of its period along dimension `name`"
is_first_period_id(dim::Dimension, n::Int, name::Symbol = :time) =
    coordinates(dim, n)[name] == first(_period_coordinates(dim, name, period_id(dim, n, name)))

"whether `n` is the last network index of its period along dimension `name`"
is_last_period_id(dim::Dimension, n::Int, name::Symbol = :time) =
    coordinates(dim, n)[name] == last(_period_coordinates(dim, name, period_id(dim, n, name)))

"""
    period_count(dim[, name])

The number of periods dimension `name` is grouped into, which is `1` where no
grouping is declared.
"""
period_count(dim::Dimension, name::Symbol = :time) =
    maximum(_period_of(dim, name, id) for id in 1:dim_length(dim, name))

################################################################################
# Network dependent data                                                       #
################################################################################

"""
    NetworkVector{T}

A quantity that takes a different value at every network index.

Data that does not change over the network index is stored as a plain value; a
load whose active power is the same in every hour holds a `Float64`. Data that
does change is wrapped in a `NetworkVector`, whose `data` has one entry per
network index, in network index order. That is the whole distinction: a scalar
is constant, a `NetworkVector` is not.

The wrapper exists because a bare `Vector` is ambiguous. The terminals of an
edge and the cost coefficients of a generator are vectors too, and nothing about
their type says whether the second entry means "the second terminal" or "the
second hour". Wrapping only the network dependent case removes the guess.

Read one with [`nw_value`](@ref), build one with [`nw_vector`](@ref).
"""
struct NetworkVector{T}
    data::Vector{T}
end

"""
    NetworkQuantity{T}

The type of a component field that may or may not vary over the network index,
i.e., `Union{T,NetworkVector{T}}`.

A component declares every field whose value the network index can change as a
`NetworkQuantity`, and both cases are then read through [`nw_value`](@ref).
"""
const NetworkQuantity{T} = Union{T,NetworkVector{T}}

Base.length(x::NetworkVector) = length(x.data)
Base.eltype(::NetworkVector{T}) where T = T
Base.getindex(x::NetworkVector, k::Int) = x.data[k]
Base.iterate(x::NetworkVector, args...) = iterate(x.data, args...)
Base.show(io::IO, x::NetworkVector{T}) where T =
    print(io, "NetworkVector{$T}(", length(x), " values)")

"whether `x` varies over the network index"
is_nw_varying(x) = x isa NetworkVector

"whether any field of the component `c` varies over the network index"
has_nw_data(c) = any(is_nw_varying(getfield(c, k)) for k in 1:nfields(c))

################################################################################
# The generalized getters                                                      #
################################################################################

"""
    nw_value(dim, x, n)

The value of `x` at network index `n`.

This is the one getter every piece of component data goes through. A constant is
returned as it is, whatever its type — an `Int`, a `Vector{Float64}` of cost
coefficients, a `String` — and a [`NetworkVector`](@ref) is indexed at `n`.
Calling code therefore never has to ask which of the two it is holding.

# Examples
```julia
julia> nw_value(dim, 0.4, 7)                       # constant
0.4

julia> nw_value(dim, nw_vector(dim, :time, p), 7)  # varying
```
"""
function nw_value end

nw_value(::Dimension, x, ::Int) = x

function nw_value(dim::Dimension, x::NetworkVector, n::Int)
    k = n - dim.offset
    checkbounds(Bool, x.data, k) ||
        throw(ArgumentError("network index $n is outside this NetworkVector, which holds $(length(x)) value(s) for the $(dim_length(dim)) network index(es) of the problem"))

    return x.data[k]
end

"""
    nw_values(dim, x)

The value of `x` at every network index, as a vector of length
`dim_length(dim)`. A constant is repeated.
"""
nw_values(dim::Dimension, x) = [nw_value(dim, x, n) for n in nw_ids(dim)]

"""
    nw_component(dim, c, n)

The component `c` with every one of its [`NetworkVector`](@ref) fields replaced
by its value at network index `n`.

The result is the same concrete type as `c`, so the code that writes variables
and constraints reads plain fields — `br.r`, `ld.pd` — and never has to know
that the stored component holds a profile. A component with no network dependent
field is returned untouched, without allocating.

The component type must accept its fields positionally, in declaration order,
which is what `Base.@kwdef` generates.
"""
function nw_component(dim::Dimension, c::T, n::Int) where T
    has_nw_data(c) || return c

    return T((nw_value(dim, getfield(c, k), n) for k in 1:fieldcount(T))...)
end

################################################################################
# Building network dependent data                                              #
################################################################################

"""
    all_nw(f, xs...)

Whether `f` holds for `xs` at every network index.

Constants are broadcast against the [`NetworkVector`](@ref)s, so this is what a
component constructor uses to validate a field that may or may not vary:
`all_nw(>(0), tm)` accepts a constant tap ratio and a profile of them alike.
"""
function all_nw(f, xs...)
    lengths = [length(x.data) for x in xs if x isa NetworkVector]
    isempty(lengths) && return f(xs...)
    allequal(lengths) ||
        throw(ArgumentError("NetworkVectors of unequal length, $(join(sort(unique(lengths)), " and ")), cannot describe the same network index"))

    return all(f((x isa NetworkVector ? x.data[k] : x for x in xs)...) for k in 1:first(lengths))
end

"""
    nw_vector(dim, values)
    nw_vector(dim, f)
    nw_vector(dim, name, values)

Build a [`NetworkVector`](@ref) over the network indices of `dim`.

- `values` is a vector holding one entry per network index, in network index
  order;
- `f` is called as `f(n, coordinates)` for every network index `n`, with
  `coordinates` the `NamedTuple` returned by [`coordinates`](@ref);
- `name, values` spreads a vector given along the single dimension `name` over
  every network index, which is what a daily profile in a problem that also has
  contingencies needs.

# Examples
```julia
julia> dim = Dimension(:time => 24, :contingency => 3);

julia> nw_vector(dim, :time, profile)                       # 24 values, spread over 72
julia> nw_vector(dim, (n, c) -> base * profile[c.time])     # the same, written out
```
"""
function nw_vector end

function nw_vector(dim::Dimension, values::AbstractVector)
    length(values) == dim_length(dim) ||
        throw(ArgumentError("`values` holds $(length(values)) entries but this problem has $(dim_length(dim)) network indices"))

    return NetworkVector(collect(values))
end

nw_vector(dim::Dimension, f::Function) =
    NetworkVector([f(n, coordinates(dim, n)) for n in nw_ids(dim)])

function nw_vector(dim::Dimension, name::Symbol, values::AbstractVector)
    has_dim(dim, name) || _no_dim(dim, name)
    length(values) == dim_length(dim, name) ||
        throw(ArgumentError("`values` holds $(length(values)) entries but dimension `$name` has $(dim_length(dim, name)) coordinates"))

    return NetworkVector([values[coordinates(dim, n)[name]] for n in nw_ids(dim)])
end

################################################################################
# Internals                                                                    #
################################################################################

_no_dim(dim::Dimension, name::Symbol) =
    throw(ArgumentError("`$name` is not a dimension of this network, available dimensions are $(dim.names)"))

function _prop(dim::Dimension, name::Symbol)
    has_dim(dim, name) || _no_dim(dim, name)
    return dim.prop[name]
end

_check_kwargs(dim::Dimension, kwargs) =
    for name in keys(kwargs)
        has_dim(dim, name) || _no_dim(dim, name)
    end

"the declared regular period length of dimension `name`, or `nothing`"
function _period_length(dim::Dimension, name::Symbol)
    len = get(dim_meta(dim, name), :period_length, nothing)
    len === nothing && return nothing
    len isa Integer && len > 0 ||
        throw(ArgumentError("the `:period_length` of dimension `$name` must be a positive integer, got $(repr(len))"))

    return Int(len)
end

"the period of coordinate `id` along dimension `name`"
function _period_of(dim::Dimension, name::Symbol, id::Int)
    p = dim_prop(dim, name, id, :period, nothing)
    p === nothing || return p::Int

    len = _period_length(dim, name)

    return len === nothing ? 1 : (id - 1) ÷ len + 1
end

"""
    _period_coordinates(dim, name, p)

The coordinates of dimension `name` in period `p`.

A dimension given as a plain size cannot carry a `:period` property, so its
periods are contiguous and known arithmetically. One given as properties has to
be scanned, which is the same order of work as holding it.
"""
function _period_coordinates(dim::Dimension, name::Symbol, p::Int)
    if _prop(dim, name) isa Int
        len = _period_length(dim, name)
        len === nothing && return 1:dim_length(dim, name)
        return ((p - 1) * len + 1):min(p * len, dim_length(dim, name))
    end

    return [id for id in 1:dim_length(dim, name) if _period_of(dim, name, id) == p]
end

"the network index or indices at the coordinates `idx`, offset included"
_at(dim::Dimension, idx::Tuple) = dim.li[idx...] .+ dim.offset

_collect_ids(ids::AbstractArray) = sort!(vec(collect(ids)))
_collect_ids(id::Int) = [id]

function _edge_id(dim::Dimension{N}, n::Int, names::NTuple{<:Any,Symbol}, which) where N
    for name in names
        has_dim(dim, name) || _no_dim(dim, name)
    end
    ci = CartesianIndices(dim.li)[n - dim.offset]
    idx = ntuple(i -> dim.names[i] in names ? which(axes(dim.li, i)) : ci[i], N)
    return _at(dim, idx)
end

function _step_id(dim::Dimension{N}, n::Int, name::Symbol, step::Int) where N
    pos = dim_position(dim, name)
    ci  = CartesianIndices(dim.li)[n - dim.offset]
    idx = ntuple(i -> i == pos ? ci[i] + step : ci[i], N)
    checkbounds(Bool, dim.li, idx...) ||
        throw(ArgumentError("network index $n has no $(step < 0 ? "previous" : "next") index along dimension `$name`"))
    return _at(dim, idx)
end

function _range_ids(dim::Dimension{N}, n::Int, name::Symbol, side::Symbol) where N
    pos = dim_position(dim, name)
    ci  = CartesianIndices(dim.li)[n - dim.offset]
    rng = side === :before ? (1:ci[pos]-1) : (ci[pos]+1:size(dim.li, pos))
    idx = ntuple(i -> i == pos ? rng : ci[i]:ci[i], N)
    return _collect_ids(_at(dim, idx))
end
