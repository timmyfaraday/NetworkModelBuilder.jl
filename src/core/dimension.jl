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
- `prop::Dict{Symbol,Vector{Dict{Symbol,Any}}}`: per-coordinate properties, one
  dictionary per coordinate of each dimension, e.g., the duration of an hour or
  the probability of a scenario.
- `meta::Dict{Symbol,Dict{Symbol,Any}}`: properties of a dimension as a whole.
- `li::Array{Int,N}`: the network index of every coordinate tuple.
- `offset::Int`: the network index of the first coordinate tuple is
  `offset + 1`.

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
struct Dimension{N}
    names ::NTuple{N,Symbol}
    prop  ::Dict{Symbol,Vector{Dict{Symbol,Any}}}
    meta  ::Dict{Symbol,Dict{Symbol,Any}}
    li    ::Array{Int,N}
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

    prop = Dict{Symbol,Vector{Dict{Symbol,Any}}}()
    for p in pairs
        nm, val = first(p), last(p)
        if val isa Integer
            val > 0 || throw(ArgumentError("dimension `$nm` must have a positive size, got $val"))
            prop[nm] = [Dict{Symbol,Any}() for _ in 1:val]
        elseif val isa AbstractVector
            prop[nm] = [Dict{Symbol,Any}(d) for d in val]
        else
            throw(ArgumentError("dimension `$nm` must be given as a size or as a vector of property dictionaries, got a $(typeof(val))"))
        end
    end

    meta = Dict{Symbol,Dict{Symbol,Any}}(nm => Dict{Symbol,Any}() for nm in names)
    li   = collect(LinearIndices(Tuple(length(prop[nm]) for nm in names))) .+ offset

    return Dimension{length(names)}(names, prop, meta, li, offset)
end

Dimension(; offset::Int = 0) = Dimension{0}((), Dict{Symbol,Vector{Dict{Symbol,Any}}}(),
                                            Dict{Symbol,Dict{Symbol,Any}}(),
                                            fill(offset + 1), offset)

"""
    add_dimension(dim, name, size; properties, metadata)

Return a new [`Dimension`](@ref) with `name` appended as the slowest varying
dimension. `dim` is left untouched.
"""
function add_dimension(dim::Dimension, name::Symbol, size::Integer;
                       properties::Vector{Dict{Symbol,Any}} = [Dict{Symbol,Any}() for _ in 1:size],
                       metadata::Dict{Symbol,Any} = Dict{Symbol,Any}())
    has_dim(dim, name) && throw(ArgumentError("dimension `$name` is already present"))
    length(properties) == size ||
        throw(ArgumentError("`properties` has $(length(properties)) entries but `size` is $size"))

    new = Dimension((Pair{Symbol,Any}(nm, dim.prop[nm]) for nm in dim.names)...,
                    Pair{Symbol,Any}(name, properties); offset = dim.offset)
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

"the number of coordinates along dimension `name`"
dim_length(dim::Dimension, name::Symbol) = length(_prop(dim, name))

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
    dim_prop(dim, name, id[, key])
    dim_prop(dim, n::Int, name[, key])

Properties of coordinate `id` along dimension `name`, or of the coordinate that
network index `n` has along dimension `name`.
"""
function dim_prop end

dim_prop(dim::Dimension, name::Symbol, id::Int) = _prop(dim, name)[id]
dim_prop(dim::Dimension, name::Symbol, id::Int, key::Symbol) = _prop(dim, name)[id][key]
dim_prop(dim::Dimension, n::Int, name::Symbol) =
    dim_prop(dim, name, coordinates(dim, n)[name])
dim_prop(dim::Dimension, n::Int, name::Symbol, key::Symbol) =
    dim_prop(dim, name, coordinates(dim, n)[name], key)

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
    return _collect_ids(dim.li[idx...])
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
    return _collect_ids(dim.li[idx...])
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
    return dim.li[idx...]
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

_collect_ids(ids::AbstractArray) = sort!(vec(collect(ids)))
_collect_ids(id::Int) = [id]

function _edge_id(dim::Dimension{N}, n::Int, names::NTuple{<:Any,Symbol}, which) where N
    for name in names
        has_dim(dim, name) || _no_dim(dim, name)
    end
    ci = CartesianIndices(dim.li)[n - dim.offset]
    idx = ntuple(i -> dim.names[i] in names ? which(axes(dim.li, i)) : ci[i], N)
    return dim.li[idx...]
end

function _step_id(dim::Dimension{N}, n::Int, name::Symbol, step::Int) where N
    pos = dim_position(dim, name)
    ci  = CartesianIndices(dim.li)[n - dim.offset]
    idx = ntuple(i -> i == pos ? ci[i] + step : ci[i], N)
    checkbounds(Bool, dim.li, idx...) ||
        throw(ArgumentError("network index $n has no $(step < 0 ? "previous" : "next") index along dimension `$name`"))
    return dim.li[idx...]
end

function _range_ids(dim::Dimension{N}, n::Int, name::Symbol, side::Symbol) where N
    pos = dim_position(dim, name)
    ci  = CartesianIndices(dim.li)[n - dim.offset]
    rng = side === :before ? (1:ci[pos]-1) : (ci[pos]+1:size(dim.li, pos))
    idx = ntuple(i -> i == pos ? rng : ci[i]:ci[i], N)
    return _collect_ids(dim.li[idx...])
end
