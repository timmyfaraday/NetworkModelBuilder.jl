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
    objective_generation_cost(nm)

Minimize the total generation cost,

```math
\\min\\quad \\sum_{n} w_{n} \\sum_{u \\in U^{\\text{g}}_{n}} \\sum_{k} c_{u,k} \\, (p^{\\text{g}}_{u,n})^{k},
```

with `w_n` the weight of network index `n`, see [`network_weight`](@ref).
"""
function objective_generation_cost(nm::NetworkModel)
    pg = Dict(n => var(nm, :pg; nw = n) for n in nw_ids(nm))

    return JuMP.@objective(nm.model, Min,
        sum(network_weight(nm, n) *
            sum(generation_cost(unit(nm, u; nw = n)::Generator, pg[n][u])
                for u in ids(nm, Generator; nw = n); init = 0.0)
            for n in nw_ids(nm); init = 0.0))
end
