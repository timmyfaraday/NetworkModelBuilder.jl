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
# Node — solution                                                              #
################################################################################

"the node part of the solution at network index `nw`"
function solution_node(nm::NetworkModel{P,F}, nw::Int) where {P<:AbstractProblemType,F<:IVRFormulation}
    sol = Dict{String,Any}()
    for i in ids(nm, Node; nw)
        vr = JuMP.value(var(nm, :vr, i; nw))
        vi = JuMP.value(var(nm, :vi, i; nw))
        sol["$i"] = Dict{String,Any}("vr" => vr, "vi" => vi,
                                     "vm" => hypot(vr, vi), "va" => atan(vi, vr))
    end

    return sol
end

"the node part of the solution under a linearized formulation"
function solution_node(nm::NetworkModel{P,F}, nw::Int) where {P<:AbstractProblemType,F<:LPFFormulation}
    sol = Dict{String,Any}()
    for i in ids(nm, Node; nw)
        va = JuMP.value(var(nm, :va, i; nw))
        sol["$i"] = Dict{String,Any}("va" => va, "vm" => 1.0)
    end

    return sol
end
