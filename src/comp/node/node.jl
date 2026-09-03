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
# Node — data                                                                  #
################################################################################

"""
    NodeType

The role a node plays in a load flow: `PQ` (active and reactive power fixed by
its units), `PV` (voltage magnitude and generator active power fixed), `REF`
(complex voltage fixed, generator power free) or `ISOLATED`.
"""
@enum NodeType PQ = 1 PV = 2 REF = 3 ISOLATED = 4

"""
    Node <: AbstractNode

A node `i ∈ I` of the extended graph, i.e., an electrical busbar.

# Fields
- `id`: the identifier of the node.
- `name`: a human readable label.
- `type`: the [`NodeType`](@ref).
- `vm`, `va`: the voltage magnitude [pu] and angle [rad] setpoint, used by `REF`
  and `PV` nodes and as a solution report reference elsewhere.
- every field but `id`, `name`, `base_kv`, `area`, `zone` and `ext` may be given
  as a [`NetworkVector`](@ref) to make it vary over the network index.
- `vmin`, `vmax`: the voltage magnitude limits [pu].
- `base_kv`: the voltage base [kV].
- `area`, `zone`: bookkeeping identifiers carried through from the input data.
- `status`: whether the node is in service.
- `ext`: free-form storage; `:vr_start` and `:vi_start` override the flat start.
"""
Base.@kwdef struct Node <: AbstractNode
    id     ::Int
    name   ::String                    = ""
    type   ::NetworkQuantity{NodeType} = PQ
    vm     ::NetworkQuantity{Float64}  = 1.0
    va     ::NetworkQuantity{Float64}  = 0.0
    vmin   ::NetworkQuantity{Float64}  = 0.9
    vmax   ::NetworkQuantity{Float64}  = 1.1
    base_kv::Float64                   = 1.0
    area   ::Int                       = 1
    zone   ::Int                       = 1
    status ::NetworkQuantity{Bool}     = true
    ext    ::Dict{Symbol,Any}          = Dict{Symbol,Any}()
end

"sorted identifiers of the in-service reference nodes at network index `nw`"
reference_nodes(nm::NetworkModel; nw::Int = nw_id_default(nm)) =
    [i for i in ids(nm, Node; nw) if node(nm, i; nw).type == REF]

################################################################################
# Node — variables                                                             #
################################################################################

"""
    variable_node_voltage(nm; nw)

The node voltage variables at network index `nw`.

In an [`IVRFormulation`](@ref) the voltage is written in rectangular
coordinates, `vr` and `vi`. Whether they are bounded is decided by the problem
type: a load flow has a determinate solution and is left unbounded so that the
solver is not steered away from it, whereas a dispatch problem bounds each
component by the voltage magnitude limit of its node and adds the magnitude
limits themselves in [`constraint_node_voltage_limits`](@ref).
"""
function variable_node_voltage end

variable_node_voltage(nm::NetworkModel{P,F}; nw::Int = nw_id_default(nm)
                     ) where {P<:AbstractPowerFlowProblem,F<:IVRFormulation} =
    _variable_node_voltage_rectangular(nm, nw, false)

variable_node_voltage(nm::NetworkModel{P,F}; nw::Int = nw_id_default(nm)
                     ) where {P<:AbstractDispatchProblem,F<:IVRFormulation} =
    _variable_node_voltage_rectangular(nm, nw, true)

function _variable_node_voltage_rectangular(nm::NetworkModel, nw::Int, bounded::Bool)
    I = ids(nm, Node; nw)

    vr = variables!(nm, :vr, I; nw, base_name = "$(nw)_vr",
                    start = i -> get(node(nm, i; nw).ext, :vr_start, 1.0))
    vi = variables!(nm, :vi, I; nw, base_name = "$(nw)_vi",
                    start = i -> get(node(nm, i; nw).ext, :vi_start, 0.0))

    for i in I
        vmax = bounded ? node(nm, i; nw).vmax : nothing
        bound!(vr[i]; lower = bounded ? -vmax : nothing, upper = vmax)
        bound!(vi[i]; lower = bounded ? -vmax : nothing, upper = vmax)
    end

    return nothing
end

################################################################################
# Node — constraints                                                           #
################################################################################

"""
    constraint_node_balance(nm; nw)

Kirchhoff's current law at every in-service node `i ∈ I`,

```math
\\sum_{a \\in A(i)} c_{a} = \\sum_{u \\in U(i)} c_{u},
```

where `A(i)` are the arcs incident to node `i`, `c_a` is the current flowing
from the node into the corresponding edge terminal, and `c_u` is the current
injected into the node by unit `u`.

Every unit — generator, load or shunt — contributes to the same sum through the
shared `:cru` and `:ciu` variables, so the balance does not need to know which
kinds of unit exist. This is what makes the extended graph worth having.
"""
function constraint_node_balance(nm::NetworkModel{P,F}; nw::Int = nw_id_default(nm)
                                ) where {P<:AbstractProblemType,F<:IVRFormulation}
    cr,  ci  = var(nm, :cr;  nw), var(nm, :ci;  nw)
    cru, ciu = var(nm, :cru; nw), var(nm, :ciu; nw)

    real = get!(() -> Dict{Int,Any}(), con(nm; nw), :node_balance_real)
    imag = get!(() -> Dict{Int,Any}(), con(nm; nw), :node_balance_imag)

    for i in ids(nm, Node; nw)
        A, U = node_arcs(nm, i; nw), node_units(nm, i; nw)

        real[i] = constrain!(nm, :node_balance, (i, :real), JuMP.@build_constraint(
            sum(cr[a] for a in A; init = 0.0) == sum(cru[u] for u in U; init = 0.0)); nw)
        imag[i] = constrain!(nm, :node_balance, (i, :imag), JuMP.@build_constraint(
            sum(ci[a] for a in A; init = 0.0) == sum(ciu[u] for u in U; init = 0.0)); nw)
    end

    return nothing
end

"""
    constraint_node_voltage_reference(nm; nw)

Anchor the voltage at every reference node.

A load flow fixes the complex voltage outright, `v_i = v^{\\text{m}}_i
\\angle v^{\\text{a}}_i`, since the reference generator absorbs the mismatch. A
dispatch problem fixes the angle only, leaving the magnitude free within its
limits.
"""
function constraint_node_voltage_reference end

function constraint_node_voltage_reference(nm::NetworkModel{P,F}; nw::Int = nw_id_default(nm)
                                          ) where {P<:AbstractPowerFlowProblem,F<:IVRFormulation}
    vr, vi = var(nm, :vr; nw), var(nm, :vi; nw)

    reference = get!(() -> Dict{Int,Any}(), con(nm; nw), :node_voltage_reference)
    for i in reference_nodes(nm; nw)
        nd = node(nm, i; nw)
        reference[i] = (
            constrain!(nm, :node_reference, (i, :real),
                       JuMP.@build_constraint(vr[i] == nd.vm * cos(nd.va)); nw),
            constrain!(nm, :node_reference, (i, :imag),
                       JuMP.@build_constraint(vi[i] == nd.vm * sin(nd.va)); nw))
    end

    return nothing
end

function constraint_node_voltage_reference(nm::NetworkModel{P,F}; nw::Int = nw_id_default(nm)
                                          ) where {P<:AbstractDispatchProblem,F<:IVRFormulation}
    vr, vi = var(nm, :vr; nw), var(nm, :vi; nw)

    reference = get!(() -> Dict{Int,Any}(), con(nm; nw), :node_voltage_reference)
    for i in reference_nodes(nm; nw)
        va = node(nm, i; nw).va
        reference[i] = (
            constrain!(nm, :node_reference, (i, :angle),
                       JuMP.@build_constraint(sin(va) * vr[i] - cos(va) * vi[i] == 0.0); nw),
            constrain!(nm, :node_reference, (i, :side),
                       JuMP.@build_constraint(cos(va) * vr[i] + sin(va) * vi[i] >= 0.0); nw))
    end

    return nothing
end

"""
    constraint_node_voltage_setpoint(nm; nw)

Fix the voltage magnitude of every `PV` node, `(v^{\\text{r}}_i)^2 +
(v^{\\text{i}}_i)^2 = (v^{\\text{m}}_i)^2`. Only a load flow has such a
setpoint; a dispatch problem lets the magnitude float within its limits.
"""
function constraint_node_voltage_setpoint(nm::NetworkModel{P,F}; nw::Int = nw_id_default(nm)
                                         ) where {P<:AbstractPowerFlowProblem,F<:IVRFormulation}
    vr, vi = var(nm, :vr; nw), var(nm, :vi; nw)

    setpoint = get!(() -> Dict{Int,Any}(), con(nm; nw), :node_voltage_setpoint)
    for i in ids(nm, Node; nw)
        nd = node(nm, i; nw)
        nd.type == PV || continue
        setpoint[i] = constrain!(nm, :node_setpoint, i,
                       JuMP.@build_constraint(vr[i]^2 + vi[i]^2 == nd.vm^2); nw)
    end

    return nothing
end

"""
    constraint_node_voltage_limits(nm; nw)

Bound the voltage magnitude of every node between `vmin` and `vmax`.
"""
function constraint_node_voltage_limits(nm::NetworkModel{P,F}; nw::Int = nw_id_default(nm)
                                       ) where {P<:AbstractDispatchProblem,F<:IVRFormulation}
    vr, vi = var(nm, :vr; nw), var(nm, :vi; nw)

    limits = get!(() -> Dict{Int,Any}(), con(nm; nw), :node_voltage_limits)
    for i in ids(nm, Node; nw)
        nd = node(nm, i; nw)
        limits[i] = (
            constrain!(nm, :node_limits, (i, :min),
                       JuMP.@build_constraint(vr[i]^2 + vi[i]^2 >= nd.vmin^2); nw),
            constrain!(nm, :node_limits, (i, :max),
                       JuMP.@build_constraint(vr[i]^2 + vi[i]^2 <= nd.vmax^2); nw))
    end

    return nothing
end

################################################################################
# Node — the linearized formulation                                            #
################################################################################

"""
    variable_node_voltage(nm; nw)

Under a [`LPFFormulation`](@ref) the voltage magnitude is one by assumption, so
the only voltage variable a node has is its angle.

The angle is left unbounded whatever the problem: there is no magnitude to
limit, and the angle differences that matter are bounded on the edges that span
them.
"""
function variable_node_voltage(nm::NetworkModel{P,F}; nw::Int = nw_id_default(nm)
                              ) where {P<:AbstractProblemType,F<:LPFFormulation}
    I = ids(nm, Node; nw)

    variables!(nm, :va, I; nw, base_name = "$(nw)_va",
               start = i -> get(node(nm, i; nw).ext, :va_start, 0.0))

    return nothing
end

"""
    constraint_node_balance(nm; nw)

Active power balance at every in-service node,

```math
\\sum_{a \\in A(i)} p_{a} = \\sum_{u \\in U(i)} p_{u} .
```

The same statement as in the current based formulation, in active power alone:
the arcs incident to a node against the units connected to it, with neither side
needing to know what the other contains.
"""
function constraint_node_balance(nm::NetworkModel{P,F}; nw::Int = nw_id_default(nm)
                                ) where {P<:AbstractProblemType,F<:LPFFormulation}
    p, pu = var(nm, :p; nw), var(nm, :pu; nw)

    balance = get!(() -> Dict{Int,Any}(), con(nm; nw), :node_balance)
    for i in ids(nm, Node; nw)
        A, U = node_arcs(nm, i; nw), node_units(nm, i; nw)

        balance[i] = constrain!(nm, :node_balance, i, JuMP.@build_constraint(
            sum(p[a] for a in A; init = 0.0) == sum(pu[u] for u in U; init = 0.0)); nw)
    end

    return nothing
end

"""
    constraint_node_voltage_reference(nm; nw)

Fix the angle of every reference node, `v^{\\text{a}}_{i} = v^{\\text{a,set}}_{i}`.

Unlike the current based formulation this does not depend on the problem: the
angle is the only thing a reference node has to give, so a power flow and a
dispatch problem anchor it the same way.
"""
function constraint_node_voltage_reference(nm::NetworkModel{P,F}; nw::Int = nw_id_default(nm)
                                          ) where {P<:AbstractProblemType,F<:LPFFormulation}
    va = var(nm, :va; nw)

    reference = get!(() -> Dict{Int,Any}(), con(nm; nw), :node_voltage_reference)
    for i in reference_nodes(nm; nw)
        reference[i] = constrain!(nm, :node_reference, i,
            JuMP.@build_constraint(va[i] == node(nm, i; nw).va); nw)
    end

    return nothing
end

"""
    constraint_node_voltage_setpoint(nm; nw)
    constraint_node_voltage_limits(nm; nw)

Nothing to do: a linearized formulation has no voltage magnitude to hold at a
setpoint or between limits. The methods exist so that a problem builder can call
them without asking which formulation it is building.
"""
constraint_node_voltage_setpoint(::NetworkModel{P,F}; nw::Int = 0
                                ) where {P<:AbstractPowerFlowProblem,F<:LPFFormulation} = nothing

constraint_node_voltage_limits(::NetworkModel{P,F}; nw::Int = 0
                              ) where {P<:AbstractDispatchProblem,F<:LPFFormulation} = nothing

################################################################################
# Node — the price of a node                                                   #
################################################################################

"""
    nodal_price(nm, i; nw)

The marginal cost of one more per unit **withdrawn** at node `i` at network
index `nw` [currency/pu/h], or `nothing` where the solve provided no duals.

This is the nodal price — the locational marginal price of an
[`OptimalPowerFlowProblem`](@ref), and under a [`RedispatchProblem`](@ref) the
marginal cost of relieving one more per unit of withdrawal with the measures
that problem is allowed to take. Both are the same question asked of a different
objective, which is why this reads the objective's dual rather than knowing
anything about either.

# The sign

[`constraint_node_balance`](@ref) is written as *what leaves the node equals
what its units inject into it*, so raising the right hand side of that row by one
is one more per unit **injected** at the node — and an extra per unit injected
*lowers* the cost by the price of the node. The dual the solver reports is
therefore the negative of the price an operator means, and the negation is here
rather than left to the caller.

# Where the balance is in current

Under an [`IVRFormulation`](@ref) the balance is Kirchhoff's current law, so its
two duals price a per unit of **current** rather than of energy — see
[`current_prices`](@ref) for how the active and reactive price are recovered from
them. `nodal_price` returns the active one either way, so it means the same thing
in both formulations, and [`reactive_price`](@ref) returns the other half, which
a linearized formulation cannot produce at all.

# When there is none

`nothing` where [`JuMP.has_duals`](https://jump.dev/JuMP.jl/stable/api/JuMP/#JuMP.has_duals)
is false: a model that has not been solved, a solve that failed, or a problem
whose relaxation is not what was solved — a mixed integer program has no duals
at all, and returning a number there would be inventing one. `dual_status` in
the result of [`build_solution`](@ref) says which case a result is in.

Note that a [`LoadFlowProblem`](@ref) has a zero objective, so every price in one
is zero. That is correct and says only that nothing was being minimized.
"""
function nodal_price end

function nodal_price(nm::NetworkModel{P,F}, i::Int; nw::Int = nw_id_default(nm)
                    ) where {P,F<:LPFFormulation}
    JuMP.has_duals(nm.model) || return nothing

    balance = get(con(nm; nw), :node_balance, nothing)
    (balance === nothing || !haskey(balance, i)) && return nothing

    return _balance_price(balance[i])
end

function nodal_price(nm::NetworkModel{P,F}, i::Int; nw::Int = nw_id_default(nm)
                    ) where {P,F<:IVRFormulation}
    λ = current_prices(nm, i; nw)

    return λ === nothing ? nothing : first(λ)
end

function nodal_price(::NetworkModel{P,F}, ::Int; nw::Int = 0) where {P,F}
    error("`nodal_price` is not defined for formulation `$F`; it needs a node balance " *
          "whose duals can be resolved into a price for active power, and `$F` writes none.")
end

"""
    reactive_price(nm, i; nw)

The marginal cost of one more per unit of **reactive** power withdrawn at node
`i` at network index `nw`, or `nothing` where the solve provided no duals.

The other half of [`current_prices`](@ref), and something only a formulation
that carries reactive power has: a [`LPFFormulation`](@ref) drops it, so there is
nothing there to price and asking says so rather than answering zero.
"""
function reactive_price end

function reactive_price(nm::NetworkModel{P,F}, i::Int; nw::Int = nw_id_default(nm)
                       ) where {P,F<:IVRFormulation}
    λ = current_prices(nm, i; nw)

    return λ === nothing ? nothing : last(λ)
end

reactive_price(::NetworkModel{P,F}, ::Int; nw::Int = 0
              ) where {P,F<:AbstractLinearizedFormulation} =
    error("reactive power plays no part in a linearized formulation, so a node has no " *
          "reactive price in one; `nodal_price` gives the active price it does have.")

reactive_price(::NetworkModel{P,F}, ::Int; nw::Int = 0) where {P,F} =
    error("`reactive_price` is not defined for formulation `$F`; it needs a node balance " *
          "in which reactive power appears.")

"""
    current_prices(nm, i; nw)

The active and reactive price at node `i` as a pair, recovered from the two duals
of the current balance, or `nothing` where they cannot be.

The balance of an [`IVRFormulation`](@ref) is in current, so what its rows price
is a per unit of real and of imaginary **current**. Those are not nodal prices
and are one rotation away from being them. A unit injecting a current
``c^{\\text{r}} + j c^{\\text{i}}`` at a node holding
``v^{\\text{r}} + j v^{\\text{i}}`` injects

```math
p = v^{\\text{r}} c^{\\text{r}} + v^{\\text{i}} c^{\\text{i}},
\\qquad
q = v^{\\text{i}} c^{\\text{r}} - v^{\\text{r}} c^{\\text{i}},
```

see [`constraint_unit_power!`](@ref), so the two current prices are the two power
prices projected onto the current axes,

```math
\\lambda^{\\text{r}} = v^{\\text{r}} \\lambda^{\\text{p}} + v^{\\text{i}} \\lambda^{\\text{q}},
\\qquad
\\lambda^{\\text{i}} = v^{\\text{i}} \\lambda^{\\text{p}} - v^{\\text{r}} \\lambda^{\\text{q}} ,
```

and inverting that rotation gives both back:

```math
\\lambda^{\\text{p}} = \\frac{v^{\\text{r}} \\lambda^{\\text{r}} + v^{\\text{i}} \\lambda^{\\text{i}}}{|v|^{2}},
\\qquad
\\lambda^{\\text{q}} = \\frac{v^{\\text{i}} \\lambda^{\\text{r}} - v^{\\text{r}} \\lambda^{\\text{i}}}{|v|^{2}} .
```

Reading ``\\lambda^{\\text{r}}`` as the nodal price is the mistake this exists to
prevent, and it is a plausible looking one: it is the price scaled by
``v^{\\text{r}}`` with a bleed of the reactive price, so at a magnitude near one
it lands near the right answer without being it.

It needs the solved **voltage** as well as the duals, so it is `nothing` wherever
either is missing, and at a node whose voltage solved to zero, where the rotation
has nothing to rotate about.
"""
function current_prices(nm::NetworkModel{P,F}, i::Int; nw::Int = nw_id_default(nm)
                       ) where {P,F<:IVRFormulation}
    (JuMP.has_duals(nm.model) && JuMP.has_values(nm.model)) || return nothing

    real = get(con(nm; nw), :node_balance_real, nothing)
    imag = get(con(nm; nw), :node_balance_imag, nothing)
    (real === nothing || imag === nothing) && return nothing
    (haskey(real, i) && haskey(imag, i)) || return nothing

    return _rotate_price(_balance_price(real[i]), _balance_price(imag[i]),
                         JuMP.value(var(nm, :vr, i; nw)), JuMP.value(var(nm, :vi, i; nw)))
end

"""
    _balance_price(ref)

The price a node balance row carries, which is minus the dual reported for it.

One place for the sign, so that [`nodal_price`](@ref) and
[`solution_node`](@ref) cannot drift apart on it.
"""
_balance_price(ref) = -JuMP.dual(ref)

"""
    _rotate_price(lr, li, vr, vi)

The active and reactive price behind the real and imaginary current prices `lr`
and `li` at a node holding the voltage `vr + j vi`, or `nothing` where that
voltage is zero.

One place for the rotation, so that [`current_prices`](@ref) and
[`solution_node`](@ref) cannot drift apart on it.
"""
function _rotate_price(lr, li, vr, vi)
    vm2 = vr^2 + vi^2
    iszero(vm2) && return nothing

    return ((vr * lr + vi * li) / vm2, (vi * lr - vr * li) / vm2)
end

################################################################################
# Node — solution                                                              #
################################################################################

"the node part of the solution at network index `nw`"
function solution_node(nm::NetworkModel{P,F}, nw::Int) where {P<:AbstractProblemType,F<:IVRFormulation}
    sol   = Dict{String,Any}()
    real  = get(con(nm; nw), :node_balance_real, nothing)
    imag  = get(con(nm; nw), :node_balance_imag, nothing)
    duals = JuMP.has_duals(nm.model) && real !== nothing && imag !== nothing

    for i in ids(nm, Node; nw)
        vr = JuMP.value(var(nm, :vr, i; nw))
        vi = JuMP.value(var(nm, :vi, i; nw))
        sol["$i"] = Dict{String,Any}("vr" => vr, "vi" => vi,
                                     "vm" => hypot(vr, vi), "va" => atan(vi, vr))

        # the balance is in current here, so `lambda_real` and `lambda_imag` price
        # a per unit of current; `lambda` and `lambda_q` are the power prices
        # behind them, see `current_prices`
        duals && haskey(real, i) || continue
        lr, li = _balance_price(real[i]), _balance_price(imag[i])
        sol["$i"]["lambda_real"] = lr
        sol["$i"]["lambda_imag"] = li

        λ = _rotate_price(lr, li, vr, vi)
        λ === nothing && continue
        sol["$i"]["lambda"]   = first(λ)
        sol["$i"]["lambda_q"] = last(λ)
    end

    return sol
end

"the node part of the solution under a linearized formulation"
function solution_node(nm::NetworkModel{P,F}, nw::Int) where {P<:AbstractProblemType,F<:LPFFormulation}
    sol     = Dict{String,Any}()
    balance = get(con(nm; nw), :node_balance, nothing)
    duals   = JuMP.has_duals(nm.model) && balance !== nothing

    for i in ids(nm, Node; nw)
        va = JuMP.value(var(nm, :va, i; nw))
        sol["$i"] = Dict{String,Any}("va" => va, "vm" => 1.0)

        duals && haskey(balance, i) || continue
        sol["$i"]["lambda"] = _balance_price(balance[i])
    end

    return sol
end
