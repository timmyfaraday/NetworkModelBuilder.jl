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
property of the coordinate `n` has along that dimension, defaulting to one where
the property is absent. Setting `:weight` to the duration of a time step, to the
probability of a scenario, or to the product of both, is what turns a
single-index objective into an energy or an expected cost.
"""
function network_weight(nm::NetworkModel, n::Int)
    dim = dimension(nm)
    w   = 1.0
    for name in dim_names(dim)
        w *= dim_prop(dim, n, name, :weight, 1.0)
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
