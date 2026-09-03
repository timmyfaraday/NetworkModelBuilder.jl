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
# v0.7.0 - cycle limits, the throughput cost and the inflow hook               #
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
- `max_cycles_per_period`: the equivalent full cycles the unit may turn in one
  period [-], see [`storage_cycles`](@ref). `Inf`, the default, leaves it free to
  cycle as often as the ratings allow.
- `cost_throughput`: the price of moving one per unit through the unit
  [currency/pu/h], charged on what it discharges. This is degradation, so it is
  paid in a dispatch and in a redispatch alike and whatever the reason the
  energy moved.
- `cost_cycle`: the price of one equivalent full cycle [currency/cycle], charged
  once per period rather than once per network index — a cost that spans network
  indices, see [`period_cost`](@ref).
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
    id                   ::Int
    name                 ::String                    = ""
    node                 ::Int
    ps                   ::NetworkQuantity{Float64}  = 0.0
    qs                   ::NetworkQuantity{Float64}  = 0.0
    energy_capacity      ::NetworkQuantity{Float64}  = 0.0
    energy_initial       ::Float64                   = 0.0
    charge_rating        ::NetworkQuantity{Float64}  = 0.0
    discharge_rating     ::NetworkQuantity{Float64}  = 0.0
    charge_efficiency    ::Float64                   = 1.0
    discharge_efficiency ::Float64                   = 1.0
    max_cycles_per_period::Float64                   = Inf
    cost_throughput      ::NetworkQuantity{Float64}  = 0.0
    cost_cycle           ::Float64                   = 0.0
    qmin                 ::NetworkQuantity{Float64}  = 0.0
    qmax                 ::NetworkQuantity{Float64}  = 0.0
    cost_up              ::NetworkQuantity{Float64}  = 0.0
    cost_dn              ::NetworkQuantity{Float64}  = 0.0
    status               ::NetworkQuantity{Bool}     = true
    ext                  ::Dict{Symbol,Any}          = Dict{Symbol,Any}()

    function Storage(id, name, node, ps, qs, energy_capacity, energy_initial,
                     charge_rating, discharge_rating, charge_efficiency,
                     discharge_efficiency, max_cycles_per_period, cost_throughput,
                     cost_cycle, qmin, qmax, cost_up, cost_dn, status, ext)
        0 < charge_efficiency <= 1 ||
            throw(ArgumentError("storage $id has a charge efficiency outside (0, 1]"))
        0 < discharge_efficiency <= 1 ||
            throw(ArgumentError("storage $id has a discharge efficiency outside (0, 1]"))
        all_nw(>=(0), energy_capacity) ||
            throw(ArgumentError("storage $id has a negative energy capacity"))
        max_cycles_per_period >= 0 ||
            throw(ArgumentError("storage $id has a negative cycle limit"))
        all_nw(>=(0), cost_throughput) ||
            throw(ArgumentError("storage $id has a negative throughput cost, which pays the problem to cycle it"))
        cost_cycle >= 0 ||
            throw(ArgumentError("storage $id has a negative cycle cost, which pays the problem to cycle it"))
        all_nw(<=, qmin, qmax) ||
            throw(ArgumentError("storage $id has qmin above qmax"))
        return new(id, name, node, ps, qs, energy_capacity, energy_initial,
                   charge_rating, discharge_rating, charge_efficiency,
                   discharge_efficiency, max_cycles_per_period, cost_throughput,
                   cost_cycle, qmin, qmax, cost_up, cost_dn, status, ext)
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

    variable_container!(nm, :psc, :psd, :es; nw)

    for u in ids(nm, T; nw)
        st = unit(nm, u; nw)::T

        variable!(nm, :psc, u; nw, base_name = "$(nw)_psc[$u]", start = 0.0,
                  lower = 0.0, upper = st.charge_rating)
        variable!(nm, :psd, u; nw, base_name = "$(nw)_psd[$u]", start = 0.0,
                  lower = 0.0, upper = st.discharge_rating)
        variable!(nm, :es, u; nw, base_name = "$(nw)_es[$u]", start = st.energy_initial,
                  lower = 0.0, upper = st.energy_capacity)
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
    variable_container!(nm, :qs; nw)

    for u in ids(nm, T; nw)
        st = unit(nm, u; nw)::T
        variable!(nm, :qs, u; nw, base_name = "$(nw)_qs[$u]", start = 0.0,
                  lower = st.qmin, upper = st.qmax)
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

with the first step of each horizon starting from `energy_initial`, and
``p^{\\text{in}}`` whatever [`inflow`](@ref) arrives from outside the model. The
horizon runs along `:time` with every other coordinate of the network index held
fixed, so a problem with a contingency dimension gives each contingency its own
trajectory from the same starting energy.

The cycle limit of every unit that carries one is written here too, once per
period, see [`constraint_storage_cycles!`](@ref).
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

            balance[(u, n)] = constrain!(nm, :storage_balance, u, JuMP.@build_constraint(
                es[u] == start + dt * (st.charge_efficiency * psc[u] -
                                       psd[u] / st.discharge_efficiency +
                                       inflow(st, nm, n))); nw = n)
        end
    end

    nm.ext[:storage_balance] = balance

    constraint_storage_cycles!(nm, T)
    _warn_free_cycling(nm, T)

    return nothing
end

"""
    inflow(st, nm, n)

The power arriving in storage unit `st` from outside the model at network index
`n` [pu], and zero for a unit that has none.

A battery is filled by the grid and by nothing else, so the balance above is
complete without this. A reservoir is not: rain and rivers put energy into it
that no node balance ever sees, and a subtype whose energy comes partly from
outside overrides this one line rather than the whole balance. It is here rather
than on the subtype for exactly that reason — a coupling constraint duplicated
to add one term is a coupling constraint that will drift.

It is a **power**, entering the balance where the charge and discharge do and
weighted by the same time step, so an inflow given as a
[`NetworkVector`](@ref) over `:time` is a natural inflow profile.
"""
inflow(::AbstractStorage, ::NetworkModel, ::Int) = 0.0

"""
    storage_cycles(nm, st, u, window)

The equivalent full cycles storage unit `u` turns over `window`, as a JuMP
expression,

```math
\\frac{1}{e^{\\text{max}}_{u}} \\sum_{n \\in \\mathcal{P}} \\Delta t_{n} \\, p^{\\text{sd}}_{u,n} .
```

One cycle is one energy capacity **discharged**, which is the definition a
warranty is written in and the one that makes the count independent of the
capacity. The discharge side is what counts because it is what the unit
delivers: counting the charge side instead would make a lossy unit appear to
cycle more than it did, and counting both would count every cycle twice.

Zero for a unit with no capacity, which has no cycle to speak of.
"""
function storage_cycles(nm::NetworkModel, st::AbstractStorage, u::Int, window)
    capacity = nw_value(nm, st.energy_capacity, first(window))
    iszero(capacity) && return 0.0

    return JuMP.@expression(nm.model,
        sum(time_step(nm, m) * var(nm, :psd, u; nw = m) for m in window; init = 0.0) / capacity)
end

"""
    constraint_storage_cycles!(nm, T)

Hold every storage unit that carries one to its cycle limit, once per period,

```math
\\sum_{n \\in \\mathcal{P}} \\Delta t_{n} \\, p^{\\text{sd}}_{u,n}
    \\le k^{\\text{max}}_{u} \\, e^{\\text{max}}_{u} ,
```

with the period `𝒫` running over the `:time` coordinates grouped with the index,
see [`period_ids`](@ref), and every other coordinate held fixed — so a problem
posed over contingencies gets one limit per period *per contingency*, and a
`:time` dimension with no grouping gives one limit over the whole horizon.

Written only for a unit whose `max_cycles_per_period` is finite. A limit of
infinity is not a row with an infinite right hand side; it is the absence of a
row, and a solver handed the first would be given a constraint it can never use.
"""
function constraint_storage_cycles!(nm::NetworkModel, ::Type{T}) where {T<:AbstractStorage}
    limit = Dict{Tuple{Int,Int},Any}()

    for n in nw_ids(nm)
        is_first_period_id(nm, n, :time) || continue
        window = period_ids(nm, n, :time)

        for u in ids(nm, T; nw = n)
            st = unit(nm, u; nw = n)::T
            isfinite(st.max_cycles_per_period) || continue

            capacity = nw_value(nm, st.energy_capacity, n)
            limit[(u, n)] = constrain!(nm, :storage_cycles, u, JuMP.@build_constraint(
                sum(time_step(nm, m) * var(nm, :psd, u; nw = m) for m in window; init = 0.0) <=
                st.max_cycles_per_period * capacity); nw = n)
        end
    end

    isempty(limit) || (nm.ext[:storage_cycles] = limit)

    return nothing
end

"""
    _warn_free_cycling(nm, T)

Warn where a storage unit may cycle for nothing.

SmaLoadFlow makes a cycle limit mandatory as soon as negative prices are enabled,
and it is right to: a unit that pays nothing to move energy, in a problem where
some generation is cheaper than free, will charge and discharge as often as its
ratings allow, and the trajectory it returns is then an artefact of the solver
rather than an answer. The guard is a warning here rather than an error because
the model is still well posed — the cycling is bounded by the ratings — and
because what counts as a negative price is a property of the data, which the
package does not otherwise legislate about.

The scan over the generation costs runs only where a free-cycling unit was found
first, so a problem that priced its storage pays nothing for this.
"""
function _warn_free_cycling(nm::NetworkModel, ::Type{T}) where {T<:AbstractStorage}
    n = nw_id_default(nm)
    free = any(ids(nm, T; nw = n)) do u
        st = unit(nm, u; nw = n)::T
        return !isfinite(st.max_cycles_per_period) && iszero(st.cost_cycle) &&
               all_nw(iszero, st.cost_throughput)
    end
    free && _has_negative_price(nm, n) || return nothing

    @warn "a storage unit is free to cycle — no `max_cycles_per_period`, no " *
          "`cost_throughput` and no `cost_cycle` — in a problem where some generation is " *
          "priced below zero, so nothing stops it from charging and discharging as often " *
          "as its ratings allow; give it a cycle limit or a price"

    return nothing
end

"whether any generator of `nm` carries a negative cost coefficient"
function _has_negative_price(nm::NetworkModel, n::Int)
    for T in unit_types()
        T <: AbstractGenerator || continue
        for u in ids(nm, T; nw = n)
            g = unit(nm, u; nw = n)::T
            all_nw(c -> all(>=(0), @view c[2:end]), g.cost) || return true
        end
    end

    return false
end

################################################################################
# Storage — cost                                                               #
################################################################################

"""
    dispatch_cost(nm, T, u; nw)

What storage unit `u` costs at network index `nw`,
`c^{\\text{tp}}_{u} p^{\\text{sd}}_{u}`.

Degradation, priced on what the unit delivers. It is a per-index cost like any
other, so the objective weights it by the weight of its index — with a `:weight`
of the step duration, a price per per unit becomes a price per per-unit-hour
without this having to know it. Zero unless `cost_throughput` was given.
"""
function dispatch_cost(nm::NetworkModel, ::Type{T}, u::Int; nw::Int) where {T<:AbstractStorage}
    haskey(var(nm; nw), :psd) || return 0.0
    st = unit(nm, u; nw)::T
    iszero(st.cost_throughput) && return 0.0

    return JuMP.@expression(nm.model, st.cost_throughput * var(nm, :psd, u; nw))
end

"""
    period_cost(nm, T, u; nw)

What storage unit `u` costs over the period beginning at network index `nw`,
`c^{\\text{cyc}}_{u}` times the [`storage_cycles`](@ref) it turns in it.

A charge per cycle is not a charge per unit of energy in different units. It
prices the *turning* rather than the moving, so a unit that discharges half its
capacity twice pays for one cycle while `cost_throughput` charges it for the
whole of what it moved either way. Both are real, they measure different wear,
and a unit may carry either or both.
"""
function period_cost(nm::NetworkModel, ::Type{T}, u::Int; nw::Int) where {T<:AbstractStorage}
    haskey(var(nm; nw), :psd) || return 0.0
    st = unit(nm, u; nw)::T
    iszero(st.cost_cycle) && return 0.0

    return JuMP.@expression(nm.model,
        st.cost_cycle * storage_cycles(nm, st, u, period_ids(nm, nw, :time)))
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
    variable_container!(nm, :psup, :psdn; nw)

    for u in ids(nm, T; nw)
        st = unit(nm, u; nw)::T

        variable!(nm, :psup, u; nw, base_name = "$(nw)_psup[$u]", start = 0.0,
                  lower = 0.0, upper = max(st.discharge_rating - st.ps, 0.0))
        variable!(nm, :psdn, u; nw, base_name = "$(nw)_psdn[$u]", start = 0.0,
                  lower = 0.0, upper = max(st.ps + st.charge_rating, 0.0))
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
        split[u] = constrain!(nm, :storage_redispatch, u, JuMP.@build_constraint(
            psd[u] - psc[u] == st.ps + psup[u] - psdn[u]); nw)
    end

    return nothing
end

"""
    redispatch_cost(nm, T, u; nw)

What storage unit `u` costs at network index `nw`,
`c^{\\uparrow}_{u} p^{\\uparrow}_{u} + c^{\\downarrow}_{u} p^{\\downarrow}_{u}`
plus its throughput, see [`dispatch_cost`](@ref). Zero unless one of the three
prices was given.

The throughput is in both because degradation does not care why the energy
moved: a battery asked to relieve a congestion wears exactly as much as one
following a market schedule, and the volumes priced by `cost_up` and `cost_dn`
are the deviation rather than the movement.
"""
function redispatch_cost(nm::NetworkModel, ::Type{T}, u::Int; nw::Int) where {T<:AbstractStorage}
    haskey(var(nm; nw), :psup) || return 0.0
    st = unit(nm, u; nw)::T

    return JuMP.@expression(nm.model,
        st.cost_up * var(nm, :psup, u; nw) + st.cost_dn * var(nm, :psdn, u; nw) +
        st.cost_throughput * var(nm, :psd, u; nw))
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

################################################################################
# Storage — across windows                                                     #
################################################################################

"""
    initial_state(st, nm, n)

The storage unit `st` starting from the energy it holds at network index `n` of
the solved model `nm`.

This is the one thing a rolling horizon carries: everything else a window
decided it decides again, but the energy left in a battery at the end of a
committed step is a fact the next window inherits rather than a choice it makes.
Without it each window would start from `energy_initial` again and the unit
would appear to refill itself for free between them.

The unit is returned untouched where the model has no state of charge to read,
i.e. where it was built for a power flow rather than a dispatch problem.
"""
function initial_state(st::Storage, nm::NetworkModel, n::Int)
    haskey(var(nm; nw = n), :es) || return st
    haskey(var(nm, :es; nw = n), st.id) || return st

    return Storage(; id = st.id, name = st.name, node = st.node, ps = st.ps, qs = st.qs,
                   energy_capacity = st.energy_capacity,
                   energy_initial = JuMP.value(var(nm, :es, st.id; nw = n)),
                   charge_rating = st.charge_rating, discharge_rating = st.discharge_rating,
                   charge_efficiency = st.charge_efficiency,
                   discharge_efficiency = st.discharge_efficiency,
                   max_cycles_per_period = st.max_cycles_per_period,
                   cost_throughput = st.cost_throughput, cost_cycle = st.cost_cycle,
                   qmin = st.qmin, qmax = st.qmax,
                   cost_up = st.cost_up, cost_dn = st.cost_dn,
                   status = st.status, ext = st.ext)
end
