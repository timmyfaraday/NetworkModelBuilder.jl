################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.6.0 - initial implementation                                              #
################################################################################

################################################################################
# Tabular input                                                                #
################################################################################

# A network as four tables — nodes, edges, units, and the profiles of whatever
# varies over the network index — plus a fifth describing the dimensions
# themselves. It is the shape a dataframe library already holds a grid in, so a
# caller in another language writes it without knowing anything about this
# package beyond the column names.
#
# Nothing here knows what a table *is*. A table is anything whose columns can be
# reached by name, which is true of an `Arrow.Table`, a `DataFrame` and a plain
# `NamedTuple` of vectors alike. That is deliberate: the package takes no
# dependency to read one, a test writes a fixture as a `NamedTuple` without a
# file anywhere near it, and the Arrow reader is a thin extension on top rather
# than the thing itself. See [`parse_arrow`](@ref).

"the column names of a table"
_columns(tbl) = collect(Symbol, propertynames(tbl))

"the column `c` of a table"
_column(tbl, c::Symbol) = getproperty(tbl, c)

"the number of rows of a table"
_nrows(tbl) = (cols = _columns(tbl); isempty(cols) ? 0 : length(_column(tbl, first(cols))))

"whether a cell holds nothing, which is how a table says *take the default*"
_blank(x) = x === missing || x === nothing
_blank(x::AbstractString) = isempty(x)

"""
    component_types()

The component types [`parse_tables`](@ref) knows by name, as a
`Dict{String,Type}`.

Read off the registries, so an edge or unit type an extension package registers
through [`register_edge_type!`](@ref) or [`register_unit_type!`](@ref) is
readable from a table the moment it exists, with no reader to update.
"""
function component_types()
    types = Dict{String,Type}("Node" => Node)
    for T in edge_types()
        types[string(nameof(T))] = T
    end
    for T in unit_types()
        types[string(nameof(T))] = T
    end

    return types
end

"""
    parse_tables(; node, edge, unit, profile, dimension, dim, name, baseMVA, types)

Build a [`NetworkData`](@ref) from tables.

# The tables

`node`, `edge` and `unit` hold one row per component. Two columns are read by
this function and every other is a **field of the component**, matched by name:

- `id`: the identifier, and the key the other tables refer to it by.
- `component`: the name of the concrete type, e.g. `"Branch"`, `"DCLink"`,
  `"Generator"`. Optional in the `node` table, which defaults to `Node`. See
  [`component_types`](@ref) for what is known.

A cell that is `missing` is *not given*, and the component takes its default for
that field. This is what lets one flat table hold several component types: a
`Branch` row simply leaves the columns belonging to a `DCLink` empty, which is
also what a dataframe library produces when it stacks two frames.

`profile` is optional and holds the data that varies over the network index, one
row per value, in columns `family` (`"node"`, `"edge"` or `"unit"`), `id`,
`field`, `nw` and `value`. Each `(family, id, field)` group must give every
network index exactly once, and becomes a [`NetworkVector`](@ref) on that
component — which is how an outage, a load profile or a rating that follows the
weather arrives. A profile overrides the constant given in the component's own
table.

`dimension` is optional and describes the network index, one row per coordinate,
in columns `name`, `coordinate`, and one further column per coordinate property
(`duration`, `weight`, `period`, …). A dimension whose properties are all blank
is stored as a plain size rather than a dictionary per coordinate, so saying
nothing about 8760 hours costs nothing. Pass `dim` instead to give a
[`Dimension`](@ref) directly; it wins over the table.

# Keywords

- `dim`: a [`Dimension`](@ref), overriding the `dimension` table.
- `name`, `baseMVA`: as [`NetworkData`](@ref) takes them.
- `types`: extra `name => type` pairs, merged over [`component_types`](@ref),
  for a type that is not registered.

# Examples

A table is anything whose columns can be reached by name, so a fixture needs no
file and no package:

```julia
data = parse_tables(
    node = (id        = [1, 2],
            type      = ["REF", "PQ"]),
    edge = (id        = [1],
            component = ["Branch"],
            terminals = [[1, 2]],
            r         = [0.0],
            x         = [0.1],
            rate_a    = [0.5]),
    unit = (id        = [1, 2],
            component = ["Generator", "FixedLoad"],
            node      = [1, 2],
            pmax      = [5.0, missing],
            pd        = [missing, 1.0]))
```
"""
function parse_tables(; node, edge, unit,
                        profile = nothing, dimension = nothing,
                        dim::Union{Nothing,Dimension} = nothing,
                        name::String = "unnamed", baseMVA::Real = 100.0,
                        types::AbstractDict{String,<:Type} = Dict{String,Type}())
    lookup = merge(component_types(), Dict{String,Type}(types))
    d      = dim === nothing ? _parse_dimension(dimension) : dim
    fields = _parse_profiles(profile, d)

    I = _parse_components(node, :node, AbstractNode, lookup, fields, d, "Node")
    E = _parse_components(edge, :edge, AbstractEdge, lookup, fields, d, nothing)
    U = _parse_components(unit, :unit, AbstractUnit, lookup, fields, d, nothing)

    _unused_profiles(fields)

    return NetworkData(Network(I, E, U; dim = d); name, baseMVA = Float64(baseMVA))
end

################################################################################
# Tabular input — the components                                               #
################################################################################

"one row per component of `family`, as a `Dict{Int,S}`"
function _parse_components(tbl, family::Symbol, ::Type{S}, lookup, fields,
                           dim::Dimension, default) where {S}
    cols = _columns(tbl)
    :id in cols || throw(ArgumentError("the `$family` table has no `id` column"))
    ids = _column(tbl, :id)

    kind = :component in cols ? _column(tbl, :component) : nothing
    kind === nothing && default === nothing &&
        throw(ArgumentError("the `$family` table has no `component` column, which is what names the type of each row"))

    out  = Dict{Int,S}()
    data = [c for c in cols if c !== :id && c !== :component]

    for r in 1:_nrows(tbl)
        id = Int(ids[r])
        nm = kind === nothing || _blank(kind[r]) ? default : String(kind[r])
        nm === nothing &&
            throw(ArgumentError("row $r of the `$family` table names no component"))

        T = get(lookup, nm, nothing)
        T === nothing &&
            throw(ArgumentError("`$nm` is not a component type this reader knows; " *
                                "it knows $(join(sort!(collect(keys(lookup))), ", ")). " *
                                "Register it, or pass it through the `types` keyword."))
        T <: S ||
            throw(ArgumentError("`$nm` is not a $(nameof(S)), so it does not belong in the `$family` table"))

        haskey(out, id) &&
            throw(ArgumentError("the `$family` table has two rows with id $id"))

        out[id] = _build(T, tbl, data, r, family, id, fields, dim)
    end

    return out
end

"the component of type `T` described by row `r`"
function _build(::Type{T}, tbl, data, r::Int, family::Symbol, id::Int,
                fields, dim::Dimension) where {T}
    known  = fieldnames(T)
    kwargs = Dict{Symbol,Any}(:id => id)

    for c in data
        c === :ext && continue
        value = _column(tbl, c)[r]
        _blank(value) && continue
        c in known ||
            throw(ArgumentError("`$c` is not a field of `$(nameof(T))`, which the " *
                                "`$family` table gives for id $id; its fields are " *
                                "$(join(known, ", "))"))
        kwargs[c] = _coerce(_base_type(fieldtype(T, c)), value, c, T)
    end

    for (c, values) in pop!(fields, (family, id), Dict{Symbol,Vector}())
        c in known ||
            throw(ArgumentError("`$c` is not a field of `$(nameof(T))`, which the " *
                                "`profile` table gives for $family $id"))
        base      = _base_type(fieldtype(T, c))
        kwargs[c] = NetworkVector([_coerce(base, v, c, T) for v in values])
    end

    return T(; kwargs...)
end

"""
    _base_type(ft)

The type a column holds for a field declared `ft`.

A field that may vary over the network index is a
[`NetworkQuantity{X}`](@ref NetworkQuantity), i.e. `Union{X,NetworkVector{X}}`,
and what a table gives for it — one cell, or one row of a profile — is an `X`
either way.
"""
_base_type(ft::Type) = ft

function _base_type(ft::Union)
    scalar = filter(t -> !(t <: NetworkVector), Base.uniontypes(ft))
    length(scalar) == 1 || return ft

    return only(scalar)
end

"the value a table cell takes as a `T`"
function _coerce(::Type{T}, value, field::Symbol, owner) where {T}
    value isa T && return value

    T <: Base.Enum && value isa AbstractString && return _enum(T, value, field, owner)
    T <: AbstractVector && return _collect(T, value, field, owner)
    T === String && return String(value)

    try
        return convert(T, value)
    catch
        throw(ArgumentError("`$(repr(value))` is not a valid `$field` for a " *
                            "`$(nameof(owner))`, which takes a `$T`"))
    end
end

function _enum(::Type{T}, value::AbstractString, field::Symbol, owner) where {T<:Base.Enum}
    for t in instances(T)
        string(t) == value && return t
    end

    throw(ArgumentError("`$value` is not a `$(nameof(T))`, which the `$field` of a " *
                        "`$(nameof(owner))` takes; it is one of " *
                        "$(join(string.(instances(T)), ", "))"))
end

function _collect(::Type{T}, value, field::Symbol, owner) where {T<:AbstractVector}
    value isa AbstractVector ||
        throw(ArgumentError("the `$field` of a `$(nameof(owner))` is a list, but the " *
                            "table gives $(repr(value))"))

    return collect(eltype(T), value)
end

################################################################################
# Tabular input — the profiles                                                 #
################################################################################

"""
    _parse_profiles(tbl, dim)

The profile table as `Dict{Tuple{Symbol,Int},Dict{Symbol,Vector}}`, i.e. the
values of every field that varies, per component, in network index order.

Every group has to give every network index exactly once. A profile that is
short is far more likely to be a filter that dropped rows than a deliberate
statement, and a profile in the wrong order would be read as a different one
without ever failing, so both are refused here rather than reaching a component.
"""
_parse_profiles(::Nothing, ::Dimension) = Dict{Tuple{Symbol,Int},Dict{Symbol,Vector}}()

function _parse_profiles(tbl, dim::Dimension)
    cols = _columns(tbl)
    for c in (:family, :id, :field, :nw, :value)
        c in cols ||
            throw(ArgumentError("the `profile` table has no `$c` column; it needs " *
                                "`family`, `id`, `field`, `nw` and `value`"))
    end

    family = _column(tbl, :family)
    ids    = _column(tbl, :id)
    fld    = _column(tbl, :field)
    nws    = _column(tbl, :nw)
    values = _column(tbl, :value)

    seen = Dict{Tuple{Symbol,Int},Dict{Symbol,Dict{Int,Any}}}()
    for r in 1:_nrows(tbl)
        f = Symbol(family[r])
        f in (:node, :edge, :unit) ||
            throw(ArgumentError("`$f` is not a component family in row $r of the " *
                                "`profile` table, expected `node`, `edge` or `unit`"))
        n = Int(nws[r])
        n in nw_ids(dim) ||
            throw(ArgumentError("row $r of the `profile` table is at network index $n, " *
                                "which this problem does not have"))

        per = get!(() -> Dict{Symbol,Dict{Int,Any}}(), seen, (f, Int(ids[r])))
        at  = get!(() -> Dict{Int,Any}(), per, Symbol(fld[r]))
        haskey(at, n) &&
            throw(ArgumentError("the `profile` table gives the `$(fld[r])` of $f " *
                                "$(ids[r]) twice at network index $n"))
        at[n] = values[r]
    end

    out = Dict{Tuple{Symbol,Int},Dict{Symbol,Vector}}()
    for (key, per) in seen, (field, at) in per
        length(at) == dim_length(dim) ||
            throw(ArgumentError("the `profile` table gives the `$field` of $(key[1]) " *
                                "$(key[2]) at $(length(at)) of the $(dim_length(dim)) " *
                                "network indices; a profile has to give every one"))
        get!(() -> Dict{Symbol,Vector}(), out, key)[field] = [at[n] for n in nw_ids(dim)]
    end

    return out
end

"refuse a profile for a component no table declared, rather than dropping it"
function _unused_profiles(fields)
    isempty(fields) && return nothing

    (family, id), per = first(sort!(collect(fields), by = first))

    throw(ArgumentError("the `profile` table gives the " *
                        "$(join(sort!(collect(keys(per))), ", ")) of $family $id, " *
                        "which is not in the `$family` table"))
end

################################################################################
# Tabular input — the dimension                                                #
################################################################################

"""
    _parse_dimension(tbl)

The `dimension` table as a [`Dimension`](@ref), one row per coordinate.

A dimension none of whose coordinates carry a property is stored as a plain
size, which is the whole point of that representation: a year of hours that says
nothing about itself must not cost a dictionary per hour to describe.
"""
_parse_dimension(::Nothing) = Dimension()

function _parse_dimension(tbl)
    cols = _columns(tbl)
    for c in (:name, :coordinate)
        c in cols ||
            throw(ArgumentError("the `dimension` table has no `$c` column"))
    end

    names  = _column(tbl, :name)
    coords = _column(tbl, :coordinate)
    props  = [c for c in cols if c !== :name && c !== :coordinate]

    order = Symbol[]
    seen  = Dict{Symbol,Dict{Int,Dict{Symbol,Any}}}()
    for r in 1:_nrows(tbl)
        nm = Symbol(names[r])
        nm in order || push!(order, nm)
        c = Int(coords[r])
        c > 0 || throw(ArgumentError("the `dimension` table has coordinate $c of `$nm`, " *
                                     "and a coordinate is numbered from one"))

        at = get!(() -> Dict{Int,Dict{Symbol,Any}}(), seen, nm)
        haskey(at, c) &&
            throw(ArgumentError("the `dimension` table gives coordinate $c of `$nm` twice"))
        at[c] = Dict{Symbol,Any}(p => _column(tbl, p)[r]
                                 for p in props if !_blank(_column(tbl, p)[r]))
    end

    pairs = Pair{Symbol,Any}[]
    for nm in order
        at   = seen[nm]
        size = maximum(keys(at))
        length(at) == size ||
            throw(ArgumentError("the `dimension` table gives $(length(at)) of the $size " *
                                "coordinates of `$nm`, which has to be all of them"))

        # a dimension that says nothing about its coordinates keeps the cheap
        # representation, which is the invariant the memory story rests on
        all(isempty, values(at)) && (push!(pairs, Pair{Symbol,Any}(nm, size)); continue)
        push!(pairs, Pair{Symbol,Any}(nm, [at[c] for c in 1:size]))
    end

    return isempty(pairs) ? Dimension() : Dimension(pairs...)
end
