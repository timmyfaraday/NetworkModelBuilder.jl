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
# Objective                                                                    #
################################################################################

"""
    network_weight(nm, n)

The weight of network index `n` in an objective that spans several network
indices.

The weight is the product, over the dimensions of the problem, of the `:weight`
property of the coordinate `n` has along that dimension, falling back on
[`default_weight`](@ref) where the property is absent. Setting `:weight` to the
duration of a time step, to the probability of a scenario, or to the product of
both, is what turns a single-index objective into an energy or an expected cost.
"""
function network_weight(nm::NetworkModel, n::Int)
    dim = dimension(nm)
    w   = 1.0
    for name in dim_names(dim)
        w *= dim_prop(dim, n, name, :weight, default_weight(dim, name))
    end

    return w
end

"""
    default_weight(dim, name)

The weight a coordinate of dimension `name` carries when the data gives it no
`:weight` property.

One, except along `:contingency`, where it is `1/N` with `N` the number of
contingencies. A set of contingencies is a set of *states of the world*, and a
weight that does not sum to one over them is not a probability: the objective
would then be the sum of the cost in every state rather than its expectation,
and a measure that has to serve every state — a preventive one, see
[`Redispatch`](@ref) — would be charged once per contingency while a corrective
one is charged once. Uniform probabilities are the least surprising default, and
give the two the same footing.

Give the coordinates an explicit `:weight` wherever the contingencies are not
equally likely, which is the usual case; it overrides this entirely.

```julia
Dimension(:contingency => [Dict{Symbol,Any}(:weight => p) for p in (0.97, 0.02, 0.01)])
```
"""
default_weight(dim::Dimension, name::Symbol) =
    name === :contingency ? 1 / dim_length(dim, :contingency) : 1.0

"""
    period_weight(nm, n[, name])

The weight a **period** of dimension `name` holding network index `n` carries:
the product of the `:weight` of every coordinate of `n` *except* the one along
`name`.

[`network_weight`](@ref) is the wrong weight for a cost that spans a period,
because the weight of a network index carries the duration of a time step and a
quantity that is not a rate has no business being multiplied by an hour. What
such a cost can and must carry is the weight of the *state of the world* it sits
in: a peak reached only in a contingency costs what it costs times the
probability of that contingency, for exactly the reason
[`default_weight`](@ref) gives. Leaving `name` out of the product is what
separates the two.
"""
function period_weight(nm::NetworkModel, n::Int, name::Symbol = :time)
    dim = dimension(nm)
    w   = 1.0
    for other in dim_names(dim)
        other === name && continue
        w *= dim_prop(dim, n, other, :weight, default_weight(dim, other))
    end

    return w
end

"""
    objective(nm)

Set the objective selected by the problem type of `nm`.

A power flow problem is a feasibility problem and gets a zero objective; a
dispatch problem minimizes a cost. Like every other part of the model this is a
dispatch point, so a new problem type only needs its own method here.
"""
function objective(nm::NetworkModel{P,F}) where {P,F}
    error("no objective is defined for problem `$P` with formulation `$F`")
end

"a power flow problem is a feasibility problem"
objective(nm::NetworkModel{P,F}) where {P<:AbstractPowerFlowProblem,F} =
    JuMP.@objective(nm.model, Min, 0.0)

"an optimal power flow minimizes the total generation cost"
objective(nm::NetworkModel{P,F}) where {P<:OptimalPowerFlowProblem,F} =
    objective_generation_cost(nm)

"""
    network_cost(nm, n)

The objective contribution of network index `n`, before its weight, as a JuMP
expression or a number.

Where [`objective`](@ref) says *what is minimized*, this says *what one network
index of it costs* — and the objective is nothing more than the weighted sum of
these, see [`minimize_network_cost`](@ref). Splitting the two apart is what lets
the cost of a **part** of a solved problem be read back: a rolling horizon
prices only the network indices each of its windows commits, and does it without
knowing which problem it is rolling.

Like [`objective`](@ref) this is a dispatch point, and a new problem type needs
a method here rather than an objective of its own.
"""
function network_cost(nm::NetworkModel{P,F}, n::Int) where {P,F}
    error("no per-index cost is defined for problem `$P` with formulation `$F`")
end

"a power flow problem is a feasibility problem, so every index of it is free"
network_cost(::NetworkModel{P,F}, ::Int) where {P<:AbstractPowerFlowProblem,F} = 0.0

"""
    dispatch_cost(nm, T, id; nw)

What component `id` of type `T` costs at network index `nw` in a dispatch
problem, as a JuMP expression or a number.

The counterpart of [`redispatch_cost`](@ref), and the difference between the two
is the difference between the problems: a redispatch prices the *deviation* from
a schedule, so a component that is already where the market put it costs
nothing, whereas a dispatch prices the *level*, so a generator pays for every per
unit it produces.

Zero for anything that does not say otherwise, which is what makes a component
free — a branch, a load whose demand is data — rather than what makes it
missing. A new component type that costs something in an optimal power flow adds
a method here and needs nothing else; see [`generation_cost`](@ref) and
[`slack_cost`](@ref) for the two the package ships.
"""
dispatch_cost(::NetworkModel, ::Type{T}, ::Int; nw::Int) where {T<:AbstractComponent} = 0.0

"""
    network_cost(nm, n)

The cost of what every component does at network index `n`, summed over every
registered edge and unit type through [`dispatch_cost`](@ref).

The generation cost is the bulk of it and, in a problem with no slack units and
no priced links, the whole of it — but it is reached through the same hook as
everything else, so that pricing a new kind of unit does not mean editing the
objective.
"""
function network_cost(nm::NetworkModel{P,F}, n::Int) where {P<:OptimalPowerFlowProblem,F}
    return sum(dispatch_cost(nm, T, id; nw = n)
               for T in (edge_types()..., unit_types()...)
               for id in ids(nm, T; nw = n); init = 0.0)
end

"""
    horizon_cost(nm)
    horizon_cost(nm, ids)

The objective contribution that belongs to no single network index, as a JuMP
expression or a number, and zero for a problem that has none.

[`network_cost`](@ref) prices one network index and
[`minimize_network_cost`](@ref) weights it by that index's weight. A cost over a
*period* — the worst overload of a day, a charge per storage cycle — has no
index to be attributed to and no weight that is right for it, because the
quantity is not a rate. This is where it goes instead, added to the objective
unweighted: what weighting a period-spanning cost does deserve is
[`period_weight`](@ref), and applying it is the business of whatever writes the
term, not of the sum that holds it.

The second form is what a **rolling horizon** reports. A window models more
network indices than it commits, so a period-spanning cost belongs to a
committed step only where the whole period is inside it: `ids` is the set of
network indices a caller is willing to pay for, and the answer is the part of
the horizon cost whose periods lie entirely within it. A period the roll never
closes is never charged, which is the honest answer rather than a prorated one —
a peak is not a rate and cannot be cut into hours.
"""
function horizon_cost end

horizon_cost(::NetworkModel{P,F}) where {P,F} = 0.0
horizon_cost(::NetworkModel{P,F}, ::AbstractVector{Int}) where {P,F} = 0.0

"a dispatch problem pays whatever its components charge per period"
horizon_cost(nm::NetworkModel{P,F}) where {P<:AbstractDispatchProblem,F} =
    component_period_cost(nm, nothing)

horizon_cost(nm::NetworkModel{P,F}, settled::AbstractVector{Int}
            ) where {P<:AbstractDispatchProblem,F} =
    component_period_cost(nm, settled)

"""
    period_cost(nm, T, id; nw)

What component `id` of type `T` costs over the **period** beginning at network
index `nw`, as a JuMP expression or a number.

The period counterpart of [`dispatch_cost`](@ref), and the reason both exist is
that some charges do not divide into indices. A price per unit of energy a
battery moves is per index and belongs on `dispatch_cost`; a price per *cycle*
is a charge on a quantity defined over a whole period and belongs here, where
[`horizon_cost`](@ref) pays it once per period rather than once per hour.

Called only at the first network index of each period, see
[`is_first_period_id`](@ref), and zero for anything that does not say otherwise.
"""
period_cost(::NetworkModel, ::Type{T}, ::Int; nw::Int) where {T<:AbstractComponent} = 0.0

"""
    component_period_cost(nm, settled)

The sum of [`period_cost`](@ref) over every registered edge and unit type and
every period of `nm`, each weighted by its [`period_weight`](@ref).

`settled` restricts the sum to the periods lying entirely within it, as
[`horizon_cost`](@ref) describes; `nothing` takes every period. A problem with no
`:time` dimension has no periods and pays nothing here.
"""
function component_period_cost(nm::NetworkModel, settled)
    has_dim(nm, :time) || return 0.0

    total = JuMP.AffExpr(0.0)

    for n in nw_ids(nm)
        is_first_period_id(nm, n, :time) || continue
        settled === nothing || all(in(settled), period_ids(nm, n, :time)) || continue

        w = period_weight(nm, n, :time)
        for T in edge_types(), id in ids(nm, T; nw = n)
            JuMP.add_to_expression!(total, w, period_cost(nm, T, id; nw = n))
        end
        for T in unit_types(), id in ids(nm, T; nw = n)
            JuMP.add_to_expression!(total, w, period_cost(nm, T, id; nw = n))
        end
    end

    return total
end

"""
    minimize_network_cost(nm)

Set the objective to the weighted sum of [`network_cost`](@ref) over every
network index, plus whatever [`horizon_cost`](@ref) spans them,

```math
\\min\\quad \\sum_{n \\in \\mathcal{N}} w_{n} \\, c_{n} + c^{\\text{h}} ,
```

with `w_n` the weight of network index `n`, see [`network_weight`](@ref). The
second term is zero for every problem that does not write one.
"""
minimize_network_cost(nm::NetworkModel) =
    JuMP.@objective(nm.model, Min,
        sum(network_weight(nm, n) * network_cost(nm, n) for n in nw_ids(nm); init = 0.0) +
        horizon_cost(nm))

"""
    objective_generation_cost(nm)

Minimize the total generation cost,

```math
\\min\\quad \\sum_{n} w_{n} \\sum_{u \\in U^{\\text{g}}_{n}} \\sum_{k} c_{u,k} \\, (p^{\\text{g}}_{u,n})^{k},
```

with `w_n` the weight of network index `n`, see [`network_weight`](@ref). This
is [`minimize_network_cost`](@ref) against the generation cost of one index.
"""
objective_generation_cost(nm::NetworkModel) = minimize_network_cost(nm)
