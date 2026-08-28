################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.5.0 - initial implementation                                              #
################################################################################

################################################################################
# Redispatch                                                                   #
################################################################################

"""
    build_model!(nm::NetworkModel{<:RedispatchProblem,<:IVRFormulation})
    build_model!(nm::NetworkModel{<:RedispatchProblem,<:LPFFormulation})

Build a redispatch in either formulation.

Compare this builder with the one in `src/prob/opf.jl`: it is the same list of
calls with one line added. The physics, the operating limits and the ratings of
an optimal power flow are exactly what a redispatch needs — a redispatch *is* a
dispatch problem, and the network does not care why the dispatch is being
chosen. What differs lives in the methods those calls resolve to and in the two
lines that are new:

| stage       | what is added                                                    |
|:------------|:-----------------------------------------------------------------|
| variables   | as in an optimal power flow, plus the volumes each generator and storage unit moved away from its market schedule |
| constraints | as in an optimal power flow, with the rating enforced on the monitored edges only, plus the split of each dispatch into its market schedule and those volumes |
| coupling    | one setting per preventive measure, shared by every contingency  |
| objective   | the price of the volumes moved, not the cost of the dispatch     |
"""
build_model!(nm::NetworkModel{P,F}) where {P<:RedispatchProblem,F<:IVRFormulation} = _build_redispatch!(nm)
build_model!(nm::NetworkModel{P,F}) where {P<:RedispatchProblem,F<:LPFFormulation} = _build_redispatch!(nm)

"""
    _build_redispatch!(nm)

The body both formulations share, the optimal power flow builder plus
[`constraint_redispatch_control`](@ref).

Every call in it is a dispatch point, so the definition of the problem says
nothing about the formulation it is being built in, and nothing about which
component types exist: an extension package that registers a controllable edge
or a costly unit is picked up here without this file changing.
"""
function _build_redispatch!(nm::NetworkModel)
    for n in nw_ids(nm)
        variable_node_voltage(nm; nw = n)
        variable_edge(nm; nw = n)
        variable_unit(nm; nw = n)

        constraint_node_voltage_reference(nm; nw = n)
        constraint_node_voltage_limits(nm; nw = n)
        constraint_node_balance(nm; nw = n)
        constraint_edge(nm; nw = n)
        constraint_edge_limits(nm; nw = n)
        constraint_unit(nm; nw = n)
    end

    constraint_edge_coupling(nm)
    constraint_unit_coupling(nm)
    constraint_redispatch_control(nm)

    objective(nm)

    return nm
end

register_model!(RedispatchProblem, IVRFormulation)
register_model!(RedispatchProblem, LPFFormulation)

################################################################################
# Redispatch — preventive and corrective measures                              #
################################################################################

"""
    constraint_redispatch_control(nm)

Hold every **preventive** measure equal across the contingencies,

```math
x_{c,n} = x_{c,n^{0}} \\quad
\\forall n \\in \\mathcal{N}, \\; \\forall x \\in X^{\\text{prev}}_{c} ,
```

where ``n^{0}`` is the network index that shares every coordinate of ``n`` but
sits at the first `:contingency` coordinate — the base case — and
``X^{\\text{prev}}_{c}`` is what [`redispatch_controls`](@ref) says component
``c`` controls.

That single family of equalities is the whole difference between a preventive
and a corrective measure. A preventive one is decided before anything happens
and has to serve every state, so it pays for outages that never occur; a
corrective one is what the operator does *after* a given outage, and is free per
contingency because it is only ever applied in the state it was chosen for. See
[`Redispatch`](@ref) for how to say which is which.

A no-op in a problem without a `:contingency` dimension, or with one that has a
single coordinate: there is then only one state, and nothing to be preventive
about. A measure at a network index where the component is out of service is
skipped, so a generator that is itself the contingency constrains nothing.
"""
function constraint_redispatch_control(nm::NetworkModel)
    has_dim(nm, :contingency) || return nothing
    dim_length(nm, :contingency) > 1 || return nothing

    tie = Dict{Tuple{Symbol,Int,Symbol,Int},Any}()

    for n in nw_ids(nm)
        is_first_id(nm, n, :contingency) && continue
        base = first_id(nm, n, :contingency)

        for (family, types) in ((:edge, edge_types()), (:unit, unit_types())), T in types
            controls = redispatch_controls(nm, T)
            isempty(controls) && continue

            at_base = ids(nm, T; nw = base)
            for id in ids(nm, T; nw = n)
                insorted(id, at_base) || continue
                is_preventive(nm, family, id) || continue

                for key in controls
                    x = _control_variable(nm, key, id, n)
                    y = _control_variable(nm, key, id, base)
                    (x === nothing || y === nothing) && continue
                    tie[(family, id, key, n)] = JuMP.@constraint(nm.model, x == y)
                end
            end
        end
    end

    nm.ext[:redispatch_control] = tie

    return nothing
end

"the variable registered under `key` for component `id` at network index `n`, or `nothing`"
function _control_variable(nm::NetworkModel, key::Symbol, id::Int, n::Int)
    container = var(nm; nw = n)
    haskey(container, key) || return nothing
    entry = container[key]

    return haskey(entry, id) ? entry[id] : nothing
end

################################################################################
# Redispatch — the objective                                                   #
################################################################################

"a redispatch minimizes the price of the measures it takes"
objective(nm::NetworkModel{P,F}) where {P<:RedispatchProblem,F} = objective_redispatch_cost(nm)

"""
    objective_redispatch_cost(nm)

Minimize the price of the volumes moved away from the market schedule,

```math
\\min \\quad \\sum_{n \\in \\mathcal{N}} w_{n} \\sum_{c}
    \\left( c^{\\uparrow}_{c} p^{\\uparrow}_{c,n}
          + c^{\\downarrow}_{c} p^{\\downarrow}_{c,n} \\right) ,
```

with ``w_{n}`` the weight of network index ``n``, see [`network_weight`](@ref),
and the sum running over every registered edge and unit type through
[`redispatch_cost`](@ref). A component with no method there — a
[`PhaseShifter`](@ref), a [`TapChanger`](@ref) — contributes nothing, which is
exactly what makes it a non-costly measure.

Every network index enters this sum, contingencies included, which is what makes
it an **expected** cost: a `:contingency` coordinate carries a weight of `1/N`
unless the data gives it one, see [`default_weight`](@ref). Under uniform
probabilities a preventive measure — one setting serving all `N` states — is
therefore paid for exactly once, and a corrective one only in the state it
belongs to.

Give the coordinates an explicit `:weight` wherever the contingencies are not
equally likely:

```julia
Dimension(:time => 24,
          :contingency => [Dict{Symbol,Any}(:weight => p) for p in (0.97, 0.02, 0.01)])
```
"""
function objective_redispatch_cost(nm::NetworkModel)
    return JuMP.@objective(nm.model, Min,
        sum(network_weight(nm, n) * _redispatch_cost_at(nm, n)
            for n in nw_ids(nm); init = 0.0))
end

"the price of every measure taken at network index `n`"
function _redispatch_cost_at(nm::NetworkModel, n::Int)
    total = JuMP.AffExpr(0.0)

    for (T, id) in ((T, id) for T in edge_types() for id in ids(nm, T; nw = n))
        JuMP.add_to_expression!(total, redispatch_cost(nm, T, id; nw = n))
    end
    for (T, id) in ((T, id) for T in unit_types() for id in ids(nm, T; nw = n))
        JuMP.add_to_expression!(total, redispatch_cost(nm, T, id; nw = n))
    end

    return total
end

################################################################################
# Redispatch — the pipeline                                                    #
################################################################################

"""
    solve_rd(data, F, optimizer; redispatch = Redispatch(), kwargs...)

Solve a [`RedispatchProblem`](@ref) in formulation `F`.

`redispatch` is the [`Redispatch`](@ref) setup, i.e., the monitored edges and
the split between preventive and corrective measures. It is placed in the `ext`
of the model, so `instantiate_model(data, RedispatchProblem, F;
ext = Dict{Symbol,Any}(:redispatch => rd))` is the equivalent that stops before
the solve.

# Examples
```julia
julia> using HiGHS

julia> dim = Dimension(:time => 24, :contingency => 3);

julia> mn = set_dimension(data, dim; apply! = schedule!);

julia> result = solve_rd(mn, LPFFormulation, HiGHS.Optimizer;
                         redispatch = Redispatch(; monitored = [3, 7],
                                                   control   = :preventive));
```
"""
function solve_rd(data, ::Type{F}, optimizer; redispatch::Redispatch = Redispatch(),
                  ext::Dict{Symbol,Any} = Dict{Symbol,Any}(), kwargs...
                 ) where {F<:AbstractFormulationType}
    ext = merge(ext, Dict{Symbol,Any}(:redispatch => redispatch))

    return solve_model(data, RedispatchProblem, F, optimizer; ext, kwargs...)
end
