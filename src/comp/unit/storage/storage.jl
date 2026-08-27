################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.3.0 - component hierarchy                                                 #
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
- `ps`, `qs`: the injection setpoint [pu], used by a power flow.
- `energy_capacity`: the usable energy capacity [pu·h].
- `energy_initial`: the energy held before the first time step [pu·h].
- `charge_rating`, `discharge_rating`: the power limits [pu].
- `charge_efficiency`, `discharge_efficiency`: the one-way efficiencies, in
  `(0, 1]`.
- `qmin`, `qmax`: the reactive power limits [pu].
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
    status              ::NetworkQuantity{Bool}     = true
    ext                 ::Dict{Symbol,Any}          = Dict{Symbol,Any}()

    function Storage(id, name, node, ps, qs, energy_capacity, energy_initial,
                     charge_rating, discharge_rating, charge_efficiency,
                     discharge_efficiency, qmin, qmax, status, ext)
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
                   discharge_efficiency, qmin, qmax, status, ext)
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
function variable_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                      ) where {P<:AbstractDispatchProblem,F<:IVRFormulation,T<:AbstractStorage}
    isempty(ids(nm, T; nw)) && return nothing
    require_time_dimension(nm, T)

    psc = get!(() -> Dict{Int,JuMP.VariableRef}(), var(nm; nw), :psc)
    psd = get!(() -> Dict{Int,JuMP.VariableRef}(), var(nm; nw), :psd)
    es  = get!(() -> Dict{Int,JuMP.VariableRef}(), var(nm; nw), :es)
    qs  = get!(() -> Dict{Int,JuMP.VariableRef}(), var(nm; nw), :qs)

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
        qs[u]  = JuMP.@variable(nm.model, base_name = "$(nw)_qs[$u]",
                                lower_bound = st.qmin, upper_bound = st.qmax,
                                start = 0.0)
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

function constraint_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractDispatchProblem,F<:IVRFormulation,T<:AbstractStorage}
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
                                 ) where {P<:AbstractDispatchProblem,F<:IVRFormulation,
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
    else
        st = unit(nm, u; nw)::T
        sol["psc"] = max(-st.ps, 0.0)
        sol["psd"] = max(st.ps, 0.0)
        sol["es"]  = st.energy_initial
    end

    return nothing
end
