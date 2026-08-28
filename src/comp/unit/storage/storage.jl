################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.3.0 - component hierarchy                                                 #
# v0.5.0 - the redispatch problem                                              #
################################################################################

################################################################################
# Storage — data                                                               #
################################################################################

"""
    AbstractStorage <: AbstractUnit

A unit that can both inject and withdraw active power, subject to the energy it
holds.

What makes storage its own kind of unit is not that it does both — a generator
with a negative lower bound does too — but that what it can do at one network
index depends on what it did at the others. Its state of charge is carried from
one time step to the next, which makes it the second component, with
[`FlexibleLoad`](@ref), whose constraints span network indices.
"""
abstract type AbstractStorage <: AbstractUnit end

"""
    Storage <: AbstractStorage

A unit `(u, i)` that charges and discharges within a rating and an energy
capacity.

In a dispatch problem the charge and discharge power at each network index are
decisions, and the state of charge follows them from step to step. In a power
flow there is nothing to decide and the unit holds the setpoint `ps`, `qs`.

Charging and discharging are separate non-negative variables, so a round trip
loses energy through both efficiencies. Nothing forbids the two from being
non-zero at once; where the efficiencies are below one that is never worth doing,
and forbidding it outright would need a binary.

# Fields
- `id`, `name`: the identifier and a human readable label.
- `node`: the node the storage is connected to.
- `ps`, `qs`: the injection setpoint [pu], used by a power flow, and the
  **market schedule** a [`RedispatchProblem`](@ref) moves away from.
- `energy_capacity`: the usable energy capacity [pu·h].
- `energy_initial`: the energy held before the first time step [pu·h].
- `charge_rating`, `discharge_rating`: the power limits [pu].
- `charge_efficiency`, `discharge_efficiency`: the one-way efficiencies, in
  `(0, 1]`.
- `qmin`, `qmax`: the reactive power limits [pu].
- `cost_up`, `cost_dn`: the price of injecting one per unit more and one per
  unit less than the market schedule, in a [`RedispatchProblem`](@ref)
  [currency/pu/h]. Both default to zero, which makes the unit a free measure;
  set them where storage is meant to be a costly one. Note that at a price of
  zero only the *difference* of the two volumes is determined — nothing then
  stops the solver from adding the same amount to both — so read the deviation
  of a free measure as `psup - psdn` rather than as either one.
- `status`: whether the storage is in service.
- `ext`: free-form storage.
"""
Base.@kwdef struct Storage <: AbstractStorage
    id                  ::Int
    name                ::String                    = ""
    node                ::Int
    ps                  ::NetworkQuantity{Float64}  = 0.0
    qs                  ::NetworkQuantity{Float64}  = 0.0
    energy_capacity     ::NetworkQuantity{Float64}  = 0.0
    energy_initial      ::Float64                   = 0.0
    charge_rating       ::NetworkQuantity{Float64}  = 0.0
    discharge_rating    ::NetworkQuantity{Float64}  = 0.0
    charge_efficiency   ::Float64                   = 1.0
    discharge_efficiency::Float64                   = 1.0
    qmin                ::NetworkQuantity{Float64}  = 0.0
    qmax                ::NetworkQuantity{Float64}  = 0.0
    cost_up             ::NetworkQuantity{Float64}  = 0.0
    cost_dn             ::NetworkQuantity{Float64}  = 0.0
    status              ::NetworkQuantity{Bool}     = true
    ext                 ::Dict{Symbol,Any}          = Dict{Symbol,Any}()

    function Storage(id, name, node, ps, qs, energy_capacity, energy_initial,
                     charge_rating, discharge_rating, charge_efficiency,
                     discharge_efficiency, qmin, qmax, cost_up, cost_dn, status, ext)
        0 < charge_efficiency <= 1 ||
            throw(ArgumentError("storage $id has a charge efficiency outside (0, 1]"))
        0 < discharge_efficiency <= 1 ||
            throw(ArgumentError("storage $id has a discharge efficiency outside (0, 1]"))
        all_nw(>=(0), energy_capacity) ||
            throw(ArgumentError("storage $id has a negative energy capacity"))
        all_nw(<=, qmin, qmax) ||
            throw(ArgumentError("storage $id has qmin above qmax"))
        return new(id, name, node, ps, qs, energy_capacity, energy_initial,
                   charge_rating, discharge_rating, charge_efficiency,
                   discharge_efficiency, qmin, qmax, cost_up, cost_dn, status, ext)
    end
end

register_unit_type!(Storage)

################################################################################
# Storage — variables                                                          #
################################################################################

"""
    variable_unit(nm, T; nw)

The charge and discharge power, the state of charge and the reactive power of
every in-service storage unit. A power flow creates nothing: there the unit
holds its setpoint.
"""
variable_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
             ) where {P<:AbstractDispatchProblem,F<:AbstractFormulationType,T<:AbstractStorage} =
    variable_storage_active!(nm, T; nw)

"the charge, discharge and state of charge of every storage unit, in any formulation"
function variable_storage_active!(nm::NetworkModel, ::Type{T}; nw::Int) where {T<:AbstractStorage}
    isempty(ids(nm, T; nw)) && return nothing
    require_time_dimension(nm, T)

    psc = get!(() -> Dict{Int,JuMP.VariableRef}(), var(nm; nw), :psc)
    psd = get!(() -> Dict{Int,JuMP.VariableRef}(), var(nm; nw), :psd)
    es  = get!(() -> Dict{Int,JuMP.VariableRef}(), var(nm; nw), :es)

    for u in ids(nm, T; nw)
        st = unit(nm, u; nw)::T

        psc[u] = JuMP.@variable(nm.model, base_name = "$(nw)_psc[$u]",
                                lower_bound = 0.0, upper_bound = st.charge_rating,
                                start = 0.0)
        psd[u] = JuMP.@variable(nm.model, base_name = "$(nw)_psd[$u]",
                                lower_bound = 0.0, upper_bound = st.discharge_rating,
                                start = 0.0)
        es[u]  = JuMP.@variable(nm.model, base_name = "$(nw)_es[$u]",
                                lower_bound = 0.0, upper_bound = st.energy_capacity,
                                start = st.energy_initial)
    end

    return nothing
end

"""
    variable_unit(nm, T; nw)

The charge, discharge and state of charge variables, plus the reactive power a
storage unit exchanges — the latter only where the formulation has reactive
power at all.
"""
function variable_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                      ) where {P<:AbstractDispatchProblem,F<:AbstractACFormulation,
                               T<:AbstractStorage}
    isempty(ids(nm, T; nw)) && return nothing
    variable_storage_active!(nm, T; nw)
    variable_storage_reactive!(nm, T; nw)

    return nothing
end

"the reactive power of every storage unit, in a formulation that has reactive power"
function variable_storage_reactive!(nm::NetworkModel, ::Type{T}; nw::Int) where {T<:AbstractStorage}
    qs = get!(() -> Dict{Int,JuMP.VariableRef}(), var(nm; nw), :qs)

    for u in ids(nm, T; nw)
        st = unit(nm, u; nw)::T
        qs[u] = JuMP.@variable(nm.model, base_name = "$(nw)_qs[$u]",
                               lower_bound = st.qmin, upper_bound = st.qmax, start = 0.0)
    end

    return nothing
end

################################################################################
# Storage — constraints                                                        #
################################################################################

"""
    constraint_unit(nm, T; nw)

Link the injection of every in-service storage unit to the current it injects.
In a dispatch problem the injection is `p^{\\text{sd}} - p^{\\text{sc}}`; in a
power flow it is the setpoint.
"""
function constraint_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractPowerFlowProblem,F<:IVRFormulation,T<:AbstractStorage}
    power = get!(() -> Dict{Int,Any}(), con(nm; nw), :storage_power)

    for u in ids(nm, T; nw)
        st = unit(nm, u; nw)::T
        power[u] = constraint_unit_power!(nm, u, st.ps, st.qs; nw)
    end

    return nothing
end

constraint_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
               ) where {P<:AbstractDispatchProblem,F<:IVRFormulation,T<:AbstractStorage} =
    _constraint_storage_power(nm, T, nw)

"link what every storage unit charges and discharges to the current it injects"
function _constraint_storage_power(nm::NetworkModel, ::Type{T}, nw::Int) where {T<:AbstractStorage}
    isempty(ids(nm, T; nw)) && return nothing

    psc, psd, qs = var(nm, :psc; nw), var(nm, :psd; nw), var(nm, :qs; nw)
    power        = get!(() -> Dict{Int,Any}(), con(nm; nw), :storage_power)

    for u in ids(nm, T; nw)
        p = JuMP.@expression(nm.model, psd[u] - psc[u])
        power[u] = constraint_unit_power!(nm, u, p, qs[u]; nw)
    end

    return nothing
end

"""
    constraint_unit_coupling(nm, T)

The state of charge of every storage unit, carried from one time step to the
next,

```math
e_{u,n} = e_{u,n-1} + \\Delta t_{n} \\left( \\eta^{\\text{c}}_{u} p^{\\text{sc}}_{u,n}
          - p^{\\text{sd}}_{u,n} / \\eta^{\\text{d}}_{u} \\right),
```

with the first step of each horizon starting from `energy_initial`. The horizon
runs along `:time` with every other coordinate of the network index held fixed,
so a problem with a contingency dimension gives each contingency its own
trajectory from the same starting energy.
"""
function constraint_unit_coupling(nm::NetworkModel{P,F}, ::Type{T}
                                 ) where {P<:AbstractDispatchProblem,F<:AbstractFormulationType,
                                          T<:AbstractStorage}
    isempty(ids(nm, T; nw = nw_id_default(nm))) && return nothing
    require_time_dimension(nm, T)

    balance = Dict{Tuple{Int,Int},Any}()

    for n in nw_ids(nm)
        psc, psd, es = var(nm, :psc; nw = n), var(nm, :psd; nw = n), var(nm, :es; nw = n)

        for u in ids(nm, T; nw = n)
            st    = unit(nm, u; nw = n)::T
            dt    = time_step(nm, n)
            start = is_first_id(nm, n, :time) ? st.energy_initial :
                                                var(nm, :es, u; nw = prev_id(nm, n, :time))

            balance[(u, n)] = JuMP.@constraint(nm.model,
                es[u] == start + dt * (st.charge_efficiency * psc[u] -
                                       psd[u] / st.discharge_efficiency))
        end
    end

    nm.ext[:storage_balance] = balance

    return nothing
end

################################################################################
# Storage — solution                                                           #
################################################################################

function solution_unit!(sol::Dict{String,Any}, nm::NetworkModel, ::Type{T}, u::Int, nw::Int
                       ) where {T<:AbstractStorage}
    if haskey(var(nm; nw), :es)
        sol["psc"] = JuMP.value(var(nm, :psc, u; nw))
        sol["psd"] = JuMP.value(var(nm, :psd, u; nw))
        sol["es"]  = JuMP.value(var(nm, :es,  u; nw))
        if haskey(var(nm; nw), :psup)
            sol["ps_market"] = unit(nm, u; nw).ps
            sol["psup"]      = JuMP.value(var(nm, :psup, u; nw))
            sol["psdn"]      = JuMP.value(var(nm, :psdn, u; nw))
        end
    else
        st = unit(nm, u; nw)::T
        sol["psc"] = max(-st.ps, 0.0)
        sol["psd"] = max(st.ps, 0.0)
        sol["es"]  = st.energy_initial
    end

    return nothing
end

################################################################################
# Storage — the linearized formulation                                         #
################################################################################

"""
    constraint_unit(nm, T; nw)

Link the injection of every in-service storage unit to what it charges and
discharges. Reactive power plays no part in a linearized formulation.
"""
function constraint_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractPowerFlowProblem,F<:LPFFormulation,T<:AbstractStorage}
    power = get!(() -> Dict{Int,Any}(), con(nm; nw), :storage_power)

    for u in ids(nm, T; nw)
        power[u] = constraint_unit_injection!(nm, u, unit(nm, u; nw).ps; nw)
    end

    return nothing
end

constraint_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
               ) where {P<:AbstractDispatchProblem,F<:LPFFormulation,T<:AbstractStorage} =
    _constraint_storage_injection(nm, T, nw)

"link what every storage unit charges and discharges to the active power it injects"
function _constraint_storage_injection(nm::NetworkModel, ::Type{T}, nw::Int) where {T<:AbstractStorage}
    isempty(ids(nm, T; nw)) && return nothing

    psc, psd = var(nm, :psc; nw), var(nm, :psd; nw)
    power    = get!(() -> Dict{Int,Any}(), con(nm; nw), :storage_power)

    for u in ids(nm, T; nw)
        power[u] = constraint_unit_injection!(nm, u,
                       JuMP.@expression(nm.model, psd[u] - psc[u]); nw)
    end

    return nothing
end

################################################################################
# Storage — the redispatch problem                                             #
################################################################################

"""
    variable_unit(nm, T; nw)

The charge, discharge and state of charge of every in-service storage unit, plus
the volumes it moved away from its market schedule — and its reactive power
where the formulation has any.

The volumes are bounded by the headroom the ratings leave in each direction,
`p^{\\uparrow}_{u} \\le p^{\\text{sd,max}}_{u} - p^{\\text{s}}_{u}` and
`p^{\\downarrow}_{u} \\le p^{\\text{s}}_{u} + p^{\\text{sc,max}}_{u}`, clipped at
zero so that a market schedule outside the ratings can still be brought back
inside them.
"""
function variable_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                      ) where {P<:RedispatchProblem,F<:AbstractFormulationType,T<:AbstractStorage}
    isempty(ids(nm, T; nw)) && return nothing
    variable_storage_active!(nm, T; nw)
    _variable_storage_redispatch(nm, T, nw)

    return nothing
end

function variable_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                      ) where {P<:RedispatchProblem,F<:AbstractACFormulation,T<:AbstractStorage}
    isempty(ids(nm, T; nw)) && return nothing
    variable_storage_active!(nm, T; nw)
    variable_storage_reactive!(nm, T; nw)
    _variable_storage_redispatch(nm, T, nw)

    return nothing
end

function _variable_storage_redispatch(nm::NetworkModel, ::Type{T}, nw::Int) where {T<:AbstractStorage}
    psup = get!(() -> Dict{Int,JuMP.VariableRef}(), var(nm; nw), :psup)
    psdn = get!(() -> Dict{Int,JuMP.VariableRef}(), var(nm; nw), :psdn)

    for u in ids(nm, T; nw)
        st = unit(nm, u; nw)::T

        psup[u] = JuMP.@variable(nm.model, base_name = "$(nw)_psup[$u]",
                                 lower_bound = 0.0, start = 0.0,
                                 upper_bound = max(st.discharge_rating - st.ps, 0.0))
        psdn[u] = JuMP.@variable(nm.model, base_name = "$(nw)_psdn[$u]",
                                 lower_bound = 0.0, start = 0.0,
                                 upper_bound = max(st.ps + st.charge_rating, 0.0))
    end

    return nothing
end

"""
    constraint_unit(nm, T; nw)

Link the injection of every in-service storage unit to what it injects, and
split that injection into the market schedule and the volumes moved away from
it,

```math
p^{\\text{sd}}_{u} - p^{\\text{sc}}_{u}
    = p^{\\text{s}}_{u} + p^{\\uparrow}_{u} - p^{\\downarrow}_{u} .
```

The market schedule is the setpoint `ps` the unit already carries. Where it
varies over `:time` it is a whole schedule; where it is a plain zero — the
default — the unit was not scheduled by the market at all and every per unit it
moves counts as redispatch.
"""
function constraint_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P<:RedispatchProblem,F<:IVRFormulation,T<:AbstractStorage}
    isempty(ids(nm, T; nw)) && return nothing
    _constraint_storage_power(nm, T, nw)
    _constraint_storage_redispatch(nm, T, nw)

    return nothing
end

function constraint_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P<:RedispatchProblem,F<:LPFFormulation,T<:AbstractStorage}
    isempty(ids(nm, T; nw)) && return nothing
    _constraint_storage_injection(nm, T, nw)
    _constraint_storage_redispatch(nm, T, nw)

    return nothing
end

function _constraint_storage_redispatch(nm::NetworkModel, ::Type{T}, nw::Int
                                       ) where {T<:AbstractStorage}
    psc,  psd  = var(nm, :psc;  nw), var(nm, :psd;  nw)
    psup, psdn = var(nm, :psup; nw), var(nm, :psdn; nw)
    split      = get!(() -> Dict{Int,Any}(), con(nm; nw), :storage_redispatch)

    for u in ids(nm, T; nw)
        st = unit(nm, u; nw)::T
        split[u] = JuMP.@constraint(nm.model,
            psd[u] - psc[u] == st.ps + psup[u] - psdn[u])
    end

    return nothing
end

"""
    redispatch_cost(nm, T, u; nw)

What storage unit `u` costs at network index `nw`,
`c^{\\uparrow}_{u} p^{\\uparrow}_{u} + c^{\\downarrow}_{u} p^{\\downarrow}_{u}`.
Zero unless `cost_up` and `cost_dn` were given.
"""
function redispatch_cost(nm::NetworkModel, ::Type{T}, u::Int; nw::Int) where {T<:AbstractStorage}
    haskey(var(nm; nw), :psup) || return 0.0
    st = unit(nm, u; nw)::T

    return JuMP.@expression(nm.model,
        st.cost_up * var(nm, :psup, u; nw) + st.cost_dn * var(nm, :psdn, u; nw))
end

"""
    redispatch_controls(nm, T)

A preventive storage unit holds its whole schedule across the contingencies:
what it charges and discharges, and so the trajectory of its state of charge
too. Tying only the net injection would leave the split between charging and
discharging free per contingency, and with it the energy the unit ends the
horizon on.
"""
redispatch_controls(::NetworkModel, ::Type{T}) where {T<:AbstractStorage} =
    (:psc, :psd, :psup, :psdn)
