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
# NetworkModel                                                                 #
################################################################################

"""
    NetworkModel{P,F}

An optimization model of a power system, parameterized by a problem type
`P <: AbstractProblemType` and a formulation type `F <: AbstractFormulationType`.

The pair `(P, F)` is what selects the variables, the constraints and the
objective: every variable, constraint and objective function in this package is
a method that dispatches on `NetworkModel{P,F}`. `P` decides *which question is
asked* — which degrees of freedom are free and which are fixed, what is
minimized — and `F` decides *in which variables the physics are written*.

# Fields
- `data`: the [`NetworkData`](@ref) the model is built from.
- `model`: the `JuMP.Model`.
- `var`, `con`, `expr`: the variables, constraints and expressions of the model,
  keyed first by network index and then by name.
- `sol`: the solution, populated by [`optimize_model!`](@ref).
- `nws`: the sorted network indices of `data`.
- `ext`: free-form storage for extension packages.
"""
mutable struct NetworkModel{P<:AbstractProblemType,F<:AbstractFormulationType}
    data ::NetworkData
    model::JuMP.Model
    var  ::Dict{Int,Dict{Symbol,Any}}
    con  ::Dict{Int,Dict{Symbol,Any}}
    expr ::Dict{Int,Dict{Symbol,Any}}
    sol  ::Dict{String,Any}
    nws  ::Vector{Int}
    ext  ::Dict{Symbol,Any}
end

"the problem type of a network model"
problem_type(::NetworkModel{P,F}) where {P,F} = P

"the formulation type of a network model"
formulation_type(::NetworkModel{P,F}) where {P,F} = F

function Base.show(io::IO, nm::NetworkModel{P,F}) where {P,F}
    print(io, "NetworkModel{$P, $F}(", nm.data.name, ", ", length(nm.nws),
          " network ", length(nm.nws) == 1 ? "index" : "indices", ")")
end

################################################################################
# Model registry                                                               #
################################################################################

const _MODELS = Vector{Tuple{Any,Any}}()

"""
    register_model!(P, F)

Record that a [`build_model!`](@ref) method exists for problem type `P` and
formulation type `F`, so that an unsupported combination can report what is
available.
"""
function register_model!(P, F)
    (P, F) in _MODELS || push!(_MODELS, (P, F))
    return nothing
end

"the `(problem, formulation)` combinations that have a model builder"
implemented_models() = copy(_MODELS)

################################################################################
# Accessors                                                                    #
################################################################################

"the sorted network indices of a model, optionally filtered by coordinates"
nw_ids(nm::NetworkModel; kwargs...) = isempty(kwargs) ? nm.nws : nw_ids(nm.data; kwargs...)

"the default network index of a model, i.e., its first one"
nw_id_default(nm::NetworkModel) = first(nm.nws)

"the system power base, in MVA"
baseMVA(nm::NetworkModel) = nm.data.baseMVA

for f in (:dim_names, :has_dim, :dim_position, :coordinates, :dim_prop, :dim_meta,
          :similar_ids, :similar_id, :first_id, :last_id, :is_first_id, :is_last_id,
          :prev_id, :next_id, :prev_ids, :next_ids,
          :nw_value, :nw_values, :nw_vector, :nw_component)
    @eval $f(nm::NetworkModel, args...; kwargs...) = $f(dimension(nm), args...; kwargs...)
end
dim_length(nm::NetworkModel, args...) = dim_length(dimension(nm), args...)

"the extended graph of a model, of which there is one however many network indices"
network(nm::NetworkModel) = nm.data.net

"the [`Dimension`](@ref) of a model"
dimension(nm::NetworkModel) = nm.data.net.dim

"the components of a model, as stored, which may hold [`NetworkVector`](@ref) fields"
nodes(nm::NetworkModel) = nodes(network(nm))
edges(nm::NetworkModel) = edges(network(nm))
units(nm::NetworkModel) = units(network(nm))

# a component of the model, resolved at network index `nw`, see `node(net, i; nw)`
for f in (:node, :edge, :unit)
    @eval $f(nm::NetworkModel, i::Int; nw::Int = nw_id_default(nm)) = $f(network(nm), i; nw)
end

for f in (:node_arcs, :node_units, :edge_arcs)
    @eval $f(nm::NetworkModel, i::Int; nw::Int = nw_id_default(nm)) = $f(network(nm), i; nw)
end

"the [`Topology`](@ref) of a model at network index `nw`"
topology(nm::NetworkModel; nw::Int = nw_id_default(nm)) = topology(network(nm); nw)

"the arcs of a model at network index `nw`"
arcs(nm::NetworkModel; nw::Int = nw_id_default(nm)) = arcs(network(nm); nw)

"sorted identifiers of the in-service components of type `T` at network index `nw`"
ids(nm::NetworkModel, ::Type{T}; nw::Int = nw_id_default(nm)) where {T<:AbstractComponent} =
    ids(network(nm), T; nw)

"sorted arcs of the in-service edges of type `T` at network index `nw`"
arcs(nm::NetworkModel, ::Type{T}; nw::Int = nw_id_default(nm)) where {T<:AbstractEdge} =
    arcs(network(nm), T; nw)

"""
    var(nm[, key[, idx]]; nw)
    con(nm[, key[, idx]]; nw)
    expr(nm[, key[, idx]]; nw)

The variables, constraints and expressions of `nm` at network index `nw`: the
whole dictionary, the container registered under `key`, or a single entry of it.

Assign a container by writing into the dictionary, e.g.,
`var(nm; nw = n)[:vr] = ...`.
"""
function var end

"see [`var`](@ref)"
function con end

"see [`var`](@ref)"
function expr end

for (f, fld) in ((:var, :var), (:con, :con), (:expr, :expr))
    @eval begin
        $f(nm::NetworkModel; nw::Int = nw_id_default(nm)) = nm.$fld[nw]
        $f(nm::NetworkModel, key::Symbol; nw::Int = nw_id_default(nm)) = nm.$fld[nw][key]
        $f(nm::NetworkModel, key::Symbol, idx; nw::Int = nw_id_default(nm)) = nm.$fld[nw][key][idx]
    end
end

"the solution of a model, populated by [`optimize_model!`](@ref)"
solution(nm::NetworkModel) = nm.sol

################################################################################
# Pipeline                                                                     #
################################################################################

"""
    instantiate_model(data, P, F; jump_model = JuMP.Model(), build = true, ext = Dict{Symbol,Any}())

Create a [`NetworkModel`](@ref) for problem type `P` and formulation type `F`,
and build it unless `build = false`.

`data` may be a [`NetworkData`](@ref) or the path of a file that
[`parse_file`](@ref) understands.

# Examples
```julia
julia> nm = instantiate_model("case14.m", LoadFlowProblem, IVRFormulation);
```
"""
function instantiate_model(data::NetworkData, ::Type{P}, ::Type{F};
                           jump_model::JuMP.Model = JuMP.Model(),
                           build::Bool = true,
                           ext::Dict{Symbol,Any} = Dict{Symbol,Any}()
                          ) where {P<:AbstractProblemType,F<:AbstractFormulationType}
    nws = nw_ids(data)
    nm  = NetworkModel{P,F}(data, jump_model,
                            Dict(n => Dict{Symbol,Any}() for n in nws),
                            Dict(n => Dict{Symbol,Any}() for n in nws),
                            Dict(n => Dict{Symbol,Any}() for n in nws),
                            Dict{String,Any}(), nws, ext)
    build && build_model!(nm)

    return nm
end

instantiate_model(file::AbstractString, P::Type, F::Type; kwargs...) =
    instantiate_model(parse_file(file), P, F; kwargs...)

"""
    build_model!(nm)

Populate the JuMP model of `nm` with the variables, constraints and objective
selected by its problem type and formulation type.

Methods live in `src/prob/`, one per problem type, and are registered with
[`register_model!`](@ref).
"""
function build_model!(nm::NetworkModel{P,F}) where {P,F}
    available = isempty(_MODELS) ? "    (none)" :
        join(("    $p with $f" for (p, f) in _MODELS), "\n")
    error("""
          NetworkModelBuilder has no model builder for
              problem type     : $P
              formulation type : $F
          Implemented combinations are:
          $available
          """)
end

"""
    optimize_model!(nm, optimizer; solution_processors = [])

Attach `optimizer`, solve the model, and store the solution in `nm.sol`.

Each entry of `solution_processors` is called as `f(nm, nm.sol)` after the
solution has been assembled.
"""
function optimize_model!(nm::NetworkModel, optimizer; solution_processors = [])
    if JuMP.mode(nm.model) != JuMP.DIRECT && JuMP.backend(nm.model).optimizer === nothing
        JuMP.set_optimizer(nm.model, optimizer)
    end

    start = time()
    JuMP.optimize!(nm.model)
    elapsed = time() - start

    nm.sol = build_solution(nm)
    nm.sol["solve_time"] = elapsed
    for f in solution_processors
        f(nm, nm.sol)
    end

    return nm.sol
end

"""
    solve_model(data, P, F, optimizer; kwargs...)

Instantiate, build and solve a model in one call, and return its solution.

`data` may be a [`NetworkData`](@ref) or the path of a file that
[`parse_file`](@ref) understands. Keyword arguments are split between
[`instantiate_model`](@ref) and [`optimize_model!`](@ref).

# Examples
```julia
julia> using Ipopt

julia> result = solve_model("case14.m", LoadFlowProblem, IVRFormulation, Ipopt.Optimizer);
```
"""
function solve_model(data::NetworkData, ::Type{P}, ::Type{F}, optimizer;
                     solution_processors = [], kwargs...
                    ) where {P<:AbstractProblemType,F<:AbstractFormulationType}
    nm = instantiate_model(data, P, F; kwargs...)

    return optimize_model!(nm, optimizer; solution_processors)
end

solve_model(file::AbstractString, P::Type, F::Type, optimizer; kwargs...) =
    solve_model(parse_file(file), P, F, optimizer; kwargs...)
