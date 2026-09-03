################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.5.0 - the redispatch problem                                              #
# v0.6.0 - a rating can be priced instead of enforced                          #
################################################################################

################################################################################
# Redispatch — the setup                                                       #
################################################################################

"""
    OverloadPrice(; per_energy)

What exceeding the rating of a monitored edge costs, per per-unit of excess at
one network index.

Giving a [`Redispatch`](@ref) one of these turns the rating from a bound the
problem may not cross into a quantity the problem pays for: an infeasible
congestion becomes an expensive one, and the volume of the overload becomes an
output rather than the reason a solve failed. Leaving it `nothing` keeps the
hard rating.

The price is on the setup rather than on the edge because it is not a property
of a line. A conductor has a rating; what it costs to run past it is a statement
about how the question is being asked, like `monitored`, and the same network
priced two ways is two questions about one set of data.

# Fields
- `per_energy`: the cost of one per-unit of overload at one network index, which
  the objective weights like any other per-index cost — so with a `:weight` of
  the step duration it is a cost per per-unit-hour.

A charge on the *worst* overload of a period rather than on each index is a cost
that spans network indices, which [`network_cost`](@ref) has no term for; it
waits on that hook rather than on this type.
"""
Base.@kwdef struct OverloadPrice
    per_energy::Float64

    function OverloadPrice(per_energy)
        per_energy >= 0 ||
            throw(ArgumentError("an overload price of $per_energy is negative, which pays the problem to overload an edge"))
        isfinite(per_energy) ||
            throw(ArgumentError("an overload price of $per_energy is not a way to write a hard rating, leave `overload` at `nothing` for that"))
        return new(per_energy)
    end
end

Base.show(io::IO, op::OverloadPrice) = print(io, "OverloadPrice(", op.per_energy, " per pu)")

"""
    Redispatch(; monitored, control, exception, overload)

The choices a [`RedispatchProblem`](@ref) needs beyond the data: *which edges
are watched for congestion*, *which measures have to be decided before the
contingency rather than after it*, and *whether a rating is a bound or a price*.

Neither is a property of a component, which is why neither is a field on one. A
line is monitored because the operator watches it, and a generator acts
preventively because of how the problem is posed; the same network, redispatched
against a different set of monitored edges or a different split of preventive and
corrective measures, is a different question about the same data.

# Fields
- `monitored`: the identifiers of the edges whose rating is enforced, or
  `nothing` — the default — for every edge. Only the *rating* is affected; the
  angle difference limits of an edge hold whether it is monitored or not, since
  those are not congestion.
- `control`: the control mode every measure has unless `exception` says
  otherwise, either `:preventive` or `:corrective`.
- `exception`: the control mode of individual components, keyed by the
  `(family, id)` pairs [`switchable`](@ref) also uses, e.g.
  `(:unit, 3) => :corrective`.
- `overload`: an [`OverloadPrice`](@ref) making the rating of every monitored
  edge a priced slack, or `nothing` — the default — for a hard rating.

A **preventive** measure takes one value that has to serve every contingency: it
is set before anything happens and cannot be changed once it has. A
**corrective** measure is free per contingency: it is what the operator would do
*after* the outage, and it is the cheaper of the two precisely because it never
has to pay for a contingency that does not occur. See
[`constraint_redispatch_control`](@ref) for what the distinction adds to the
model.

Both are silent in a problem without a `:contingency` dimension: with a single
state there is nothing to be preventive about.

# Examples
```julia
julia> Redispatch(; monitored = [3, 7, 11])

julia> Redispatch(; control = :corrective,
                    exception = Dict((:unit, 1) => :preventive))

julia> Redispatch(; monitored = [3, 7], overload = OverloadPrice(; per_energy = 500.0))
```
"""
struct Redispatch
    monitored::Union{Nothing,Vector{Int}}
    control  ::Symbol
    exception::Dict{Tuple{Symbol,Int},Symbol}
    overload ::Union{Nothing,OverloadPrice}
end

function Redispatch(; monitored::Union{Nothing,AbstractVector{<:Integer}} = nothing,
                      control::Symbol = :preventive,
                      exception::AbstractDict{Tuple{Symbol,Int},Symbol} =
                          Dict{Tuple{Symbol,Int},Symbol}(),
                      overload::Union{Nothing,OverloadPrice,Real} = nothing)
    _check_control(control)
    for ((family, id), mode) in exception
        family in (:node, :edge, :unit) ||
            throw(ArgumentError("`$family` is not a component family, expected `:node`, `:edge` or `:unit`"))
        _check_control(mode)
    end

    return Redispatch(monitored === nothing ? nothing : sort!(unique(Int.(monitored))),
                      control, Dict{Tuple{Symbol,Int},Symbol}(exception),
                      overload isa Real ? OverloadPrice(; per_energy = overload) : overload)
end

_check_control(mode::Symbol) =
    mode in (:preventive, :corrective) ||
        throw(ArgumentError("`$mode` is not a control mode, expected `:preventive` or `:corrective`"))

function Base.show(io::IO, rd::Redispatch)
    print(io, "Redispatch(", rd.monitored === nothing ? "every edge monitored" :
                             "$(length(rd.monitored)) edge(s) monitored",
          ", ", rd.control)
    isempty(rd.exception) || print(io, " with $(length(rd.exception)) exception(s)")
    rd.overload === nothing || print(io, ", overload at ", rd.overload.per_energy, " per pu")
    print(io, ")")
end

"""
    redispatch_setup(nm)

The [`Redispatch`](@ref) of a model, taken from `nm.ext[:redispatch]` and
defaulting to `Redispatch()`.

Put one there through the `ext` keyword of [`instantiate_model`](@ref), or hand
one to [`solve_rd`](@ref).
"""
redispatch_setup(nm::NetworkModel) = get!(() -> Redispatch(), nm.ext, :redispatch)::Redispatch

################################################################################
# Redispatch — monitored edges                                                 #
################################################################################

"""
    is_monitored(nm, e)

Whether the rating of edge `e` is enforced.

Every edge is monitored in every problem but a [`RedispatchProblem`](@ref), and
there too unless its [`Redispatch`](@ref) names a subset. This is the one hook
the shared rating helpers consult, so restricting the monitored set restricts it
for every edge type and both formulations at once.
"""
is_monitored(::NetworkModel, ::Int) = true

function is_monitored(nm::NetworkModel{P,F}, e::Int
                     ) where {P<:RedispatchProblem,F<:AbstractFormulationType}
    set = redispatch_setup(nm).monitored

    return set === nothing || insorted(e, set)
end

"the identifiers of the in-service edges of `nm` whose rating is enforced at network index `nw`"
monitored_edges(nm::NetworkModel; nw::Int = nw_id_default(nm)) =
    [e for e in topology(nm; nw).edge if is_monitored(nm, e)]

"""
    overload_price(nm)

The [`OverloadPrice`](@ref) the rating of a monitored edge is relaxed against,
or `nothing` where the rating is a hard bound.

The companion of [`is_monitored`](@ref): that one says *whether* a rating is
enforced, this one says *how*. Both are consulted by the shared rating helpers,
so a price set once applies to every edge type and both formulations.

A rating and a price are not two ways of writing the same constraint — one is a
bound the solver may not cross, the other is a variable it pays for — so a model
holds one shape or the other, chosen here rather than by making the price
infinite. There is no infinite price a solver can be handed.
"""
overload_price(::NetworkModel) = nothing

overload_price(nm::NetworkModel{P,F}) where {P<:RedispatchProblem,F<:AbstractFormulationType} =
    redispatch_setup(nm).overload

################################################################################
# Redispatch — preventive and corrective measures                              #
################################################################################

"""
    control_mode(nm, family, id)

The control mode of component `id` of `family`, either `:preventive` or
`:corrective`. See [`Redispatch`](@ref).
"""
function control_mode(nm::NetworkModel, family::Symbol, id::Int)
    rd = redispatch_setup(nm)

    return get(rd.exception, (family, id), rd.control)
end

"whether a component has to take one setting that serves every contingency"
is_preventive(nm::NetworkModel, family::Symbol, id::Int) =
    control_mode(nm, family, id) === :preventive

"whether a component may take a different setting per contingency"
is_corrective(nm::NetworkModel, family::Symbol, id::Int) =
    control_mode(nm, family, id) === :corrective

"""
    redispatch_controls(nm, T)

The variable keys of component type `T` that a **preventive** measure holds
equal across the contingencies, as a tuple of symbols, and `()` for a type that
is no measure at all.

This is the single dispatch point [`constraint_redispatch_control`](@ref) walks,
so an extension package that adds a controllable component gets it into the
preventive-corrective split by giving it one method. The keys depend on the
formulation as well as on the type: a [`PhaseShifter`](@ref) carries its ratio as
`(:tr, :ti)` in the current based formulation and as `(:ta,)` in the linearized
one.
"""
redispatch_controls(::NetworkModel, ::Type{T}) where {T<:AbstractComponent} = ()

################################################################################
# Redispatch — the price of a measure                                          #
################################################################################

"""
    redispatch_cost(nm, T, id; nw)

What moving component `id` of type `T` away from its market schedule costs at
network index `nw`, as a JuMP expression or a number.

Zero unless the type says otherwise, which is what makes a measure *non-costly*:
a [`PhaseShifter`](@ref) is free to move and simply has no method here, while an
[`AbstractGenerator`](@ref) and an [`AbstractStorage`](@ref) price the volumes
they moved. [`objective_redispatch_cost`](@ref) sums this over every registered
edge and unit type.
"""
redispatch_cost(::NetworkModel, ::Type{T}, ::Int; nw::Int) where {T<:AbstractComponent} = 0.0
