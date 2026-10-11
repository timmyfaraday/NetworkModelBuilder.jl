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
# v0.7.0 - cycle limits, the throughput cost, the inflow hook and the end target#
# v0.10.1 - exports its own public names                                       #
# v0.12.9 - the balance, cycle and end rows are registered by constrain! alone #
# v0.14.0 - a variable is named by the model, not at the call site             #
# v0.14.0 - variable and solution keys follow the nomenclature                 #
# v0.14.0 - the fields follow the nomenclature                                 #
# v0.15.0 - constraint keys and ids follow the nomenclature                    #
# v0.15.0 - functions that write rows, duals and letters follow the map        #
################################################################################

export AbstractStorage, Storage, inflow, storage_cycles
export variable_storage_active!, variable_storage_reactive!
export fnct_stor_cycle!, fnct_stor_final_energy!

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

# What a subtype has to carry

Everything but the state of charge balance is written against fields rather than
against [`Storage`](@ref), so a subtype gets the variables, the injection, the
cycle limit, the energy target, the costs, the redispatch split, the solution
and the rolling horizon by declaring them:

| field | what reads it |
|:------|:--------------|
| `id`, `name`, `node`, `status`, `ext` | every component |
| `p_set`, `q_set` | the power flow setpoint and the market schedule |
| `e_max`, `e_init`, `e_fin` | the state of charge and its ends |
| `p_chg_max`, `p_dch_max` | the bounds on the charge and discharge |
| `η_chg`, `η_dch` | the balance |
| `k_cycl_max` | [`fnct_stor_cycle!`](@ref) |
| `c_thru`, `c_cycl` | [`dispatch_cost`](@ref), [`period_cost`](@ref) |
| `c_up`, `c_dn` | [`redispatch_cost`](@ref) |
| `q_min`, `q_max` | the reactive power, where the formulation has any |

What a subtype adds on top is its own, and the one thing it is expected to
override is [`inflow`](@ref), for energy that reaches the unit from outside the
model.
"""
abstract type AbstractStorage <: AbstractUnit end

"""
    Storage <: AbstractStorage

A unit `(u, i)` that charges and discharges within a rating and an energy
capacity.

In a dispatch problem the charge and discharge power at each network index are
decisions, and the state of charge follows them from step to step. In a power
flow there is nothing to decide and the unit holds the setpoint `p_set`, `q_set`.

Charging and discharging are separate non-negative variables, so a round trip
loses energy through both efficiencies. Nothing forbids the two from being
non-zero at once; where the efficiencies are below one that is never worth doing,
and forbidding it outright would need a binary.

# Fields
- `id`, `name`: the identifier and a human readable label.
- `node`: the node the storage is connected to.
- `p_set`, `q_set`: the injection setpoint [pu], used by a power flow, and the
  **market schedule** a [`RedispatchProblem`](@ref) moves away from.
- `e_max`: the usable energy capacity [pu·h].
- `e_init`: the energy held before the first time step [pu·h].
- `e_fin`: the energy the unit must hold after the last time step [pu·h].
  `NaN`, the default, means *no target*, and the horizon ends wherever the
  dispatch leaves it.
- `p_chg_max`, `p_dch_max`: the power limits [pu].
- `η_chg`, `η_dch`: the one-way efficiencies, in
  `(0, 1]`.
- `k_cycl_max`: the equivalent full cycles the unit may turn in one
  period [-], see [`storage_cycles`](@ref). `Inf`, the default, leaves it free to
  cycle as often as the ratings allow.
- `c_thru`: the price of moving one per unit through the unit
  [currency/pu/h], charged on what it discharges. This is degradation, so it is
  paid in a dispatch and in a redispatch alike and whatever the reason the
  energy moved.
- `c_cycl`: the price of one equivalent full cycle [currency/cycle], charged
  once per period rather than once per network index — a cost that spans network
  indices, see [`period_cost`](@ref).
- `q_min`, `q_max`: the reactive power limits [pu].
- `c_up`, `c_dn`: the price of injecting one per unit more and one per
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
    id        ::Int
    name      ::String                   = ""
    node      ::Int
    p_set     ::NetworkQuantity{Float64} = 0.0
    q_set     ::NetworkQuantity{Float64} = 0.0
    e_max     ::NetworkQuantity{Float64} = 0.0
    e_init    ::Float64                  = 0.0
    e_fin     ::Float64                  = NaN
    p_chg_max ::NetworkQuantity{Float64} = 0.0
    p_dch_max ::NetworkQuantity{Float64} = 0.0
    η_chg     ::Float64                  = 1.0
    η_dch     ::Float64                  = 1.0
    k_cycl_max::Float64                  = Inf
    c_thru    ::NetworkQuantity{Float64} = 0.0
    c_cycl    ::Float64                  = 0.0
    q_min     ::NetworkQuantity{Float64} = 0.0
    q_max     ::NetworkQuantity{Float64} = 0.0
    c_up      ::NetworkQuantity{Float64} = 0.0
    c_dn      ::NetworkQuantity{Float64} = 0.0
    status    ::NetworkQuantity{Bool}    = true
    ext       ::Dict{Symbol,Any}         = Dict{Symbol,Any}()

    function Storage(id, name, node, p_set, q_set, e_max, e_init,
                     e_fin, p_chg_max, p_dch_max, η_chg,
                     η_dch, k_cycl_max, c_thru,
                     c_cycl, q_min, q_max, c_up, c_dn, status, ext)
        0 < η_chg <= 1 ||
            throw(ArgumentError("storage $id has a charge efficiency outside (0, 1]"))
        0 < η_dch <= 1 ||
            throw(ArgumentError("storage $id has a discharge efficiency outside (0, 1]"))
        all_nw(>=(0), e_max) ||
            throw(ArgumentError("storage $id has a negative energy capacity"))
        isnan(e_fin) || e_fin >= 0 ||
            throw(ArgumentError("storage $id has a negative energy target"))
        k_cycl_max >= 0 ||
            throw(ArgumentError("storage $id has a negative cycle limit"))
        all_nw(>=(0), c_thru) ||
            throw(ArgumentError("storage $id has a negative throughput cost, which pays the problem to cycle it"))
        c_cycl >= 0 ||
            throw(ArgumentError("storage $id has a negative cycle cost, which pays the problem to cycle it"))
        all_nw(<=, q_min, q_max) ||
            throw(ArgumentError("storage $id has q_min above q_max"))
        return new(id, name, node, p_set, q_set, e_max, e_init,
                   e_fin, p_chg_max, p_dch_max, η_chg,
                   η_dch, k_cycl_max, c_thru,
                   c_cycl, q_min, q_max, c_up, c_dn, status, ext)
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

    variable_container!(nm, :p_chg, :p_dch, :e_stor; nw)

    for u in ids(nm, T; nw)
        st = unit(nm, u; nw)::T

        variable!(nm, :p_chg, u; nw, start = 0.0,
                  lower = 0.0, upper = st.p_chg_max)
        variable!(nm, :p_dch, u; nw, start = 0.0,
                  lower = 0.0, upper = st.p_dch_max)
        variable!(nm, :e_stor, u; nw, start = st.e_init,
                  lower = 0.0, upper = st.e_max)
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
    variable_container!(nm, :q_stor; nw)

    for u in ids(nm, T; nw)
        st = unit(nm, u; nw)::T
        variable!(nm, :q_stor, u; nw, start = 0.0,
                  lower = st.q_min, upper = st.q_max)
    end

    return nothing
end

################################################################################
# Storage — constraints                                                        #
################################################################################

"""
    fnct_unit(nm, T; nw)

Link the injection of every in-service storage unit to the current it injects.
In a dispatch problem the injection is `p^{\\text{sd}} - p^{\\text{sc}}`; in a
power flow it is the setpoint.
"""
function fnct_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractPowerFlowProblem,F<:IVRFormulation,T<:AbstractStorage}
    power = get!(() -> Dict{Int,Any}(), con(nm; nw), :cstr_unit_power)

    for u in ids(nm, T; nw)
        st = unit(nm, u; nw)::T
        power[u] = fnct_unit_power!(nm, u, st.p_set, st.q_set; nw)
    end

    return nothing
end

fnct_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
               ) where {P<:AbstractDispatchProblem,F<:IVRFormulation,T<:AbstractStorage} =
    _constraint_storage_power(nm, T, nw)

"link what every storage unit charges and discharges to the current it injects"
function _constraint_storage_power(nm::NetworkModel, ::Type{T}, nw::Int) where {T<:AbstractStorage}
    isempty(ids(nm, T; nw)) && return nothing

    p_chg, p_dch, q_stor = var(nm, :p_chg; nw), var(nm, :p_dch; nw), var(nm, :q_stor; nw)
    power                = get!(() -> Dict{Int,Any}(), con(nm; nw), :cstr_unit_power)

    for u in ids(nm, T; nw)
        p = JuMP.@expression(nm.model, p_dch[u] - p_chg[u])
        power[u] = fnct_unit_power!(nm, u, p, q_stor[u]; nw)
    end

    return nothing
end

"""
    fnct_unit_coupling(nm, T)

The state of charge of every storage unit, carried from one time step to the
next,

```math
e_{u,n} = e_{u,n-1} + \\Delta t_{n} \\left( \\eta^{\\text{c}}_{u} p^{\\text{sc}}_{u,n}
          - p^{\\text{sd}}_{u,n} / \\eta^{\\text{d}}_{u} \\right),
```

with the first step of each horizon starting from `e_init`, and
``p^{\\text{in}}`` whatever [`inflow`](@ref) arrives from outside the model. The
horizon runs along `:time` with every other coordinate of the network index held
fixed, so a problem with a contingency dimension gives each contingency its own
trajectory from the same starting energy.

The cycle limit of every unit that carries one is written here too, once per
period, see [`fnct_stor_cycle!`](@ref).
"""
function fnct_unit_coupling(nm::NetworkModel{P,F}, ::Type{T}
                                 ) where {P<:AbstractDispatchProblem,F<:AbstractFormulationType,
                                          T<:AbstractStorage}
    isempty(ids(nm, T; nw = nw_id_default(nm))) && return nothing
    require_time_dimension(nm, T)

    for n in nw_ids(nm)
        p_chg, p_dch, e_stor = var(nm, :p_chg; nw = n), var(nm, :p_dch; nw = n), var(nm, :e_stor; nw = n)

        for u in ids(nm, T; nw = n)
            st    = unit(nm, u; nw = n)::T
            dt    = time_step(nm, n)
            start = is_first_id(nm, n, :time) ? st.e_init :
                                                var(nm, :e_stor, u; nw = prev_id(nm, n, :time))

            constrain!(nm, :cstr_stor_balance, u, JuMP.@build_constraint(
                e_stor[u] == start + dt * (st.η_chg * p_chg[u] -
                                       p_dch[u] / st.η_dch +
                                       inflow(st, nm, n))); nw = n)
        end
    end

    fnct_stor_cycle!(nm, T)
    fnct_stor_final_energy!(nm, T)
    _warn_free_cycling(nm, T)

    return nothing
end

"""
    fnct_stor_final_energy!(nm, T)

Pin every storage unit that carries an `e_fin` to it at the last `:time`
coordinate,

```math
e_{u,n} = e^{\\text{f}}_{u} \\quad \\text{at the last } n \\text{ along } \\texttt{:time},
```

with every other coordinate held fixed, so a problem with a contingency
dimension asks each contingency to arrive at the same place.

It is a **pin**, not a floor: a target the ratings cannot reach makes the problem
infeasible, which is the honest answer to a question that has none. A unit
without a target — `NaN`, the default — gets no row.
"""
function fnct_stor_final_energy!(nm::NetworkModel, ::Type{T}) where {T<:AbstractStorage}
    for n in nw_ids(nm)
        is_last_id(nm, n, :time) || continue

        for u in ids(nm, T; nw = n)
            st = unit(nm, u; nw = n)::T
            isnan(st.e_fin) && continue

            constrain!(nm, :cstr_stor_final_energy, u, JuMP.@build_constraint(
                var(nm, :e_stor, u; nw = n) == st.e_fin); nw = n)
        end
    end

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
    capacity = nw_value(nm, st.e_max, first(window))
    iszero(capacity) && return 0.0

    return JuMP.@expression(nm.model,
        sum(time_step(nm, m) * var(nm, :p_dch, u; nw = m)
            for m in window if haskey(var(nm, :p_dch; nw = m), u); init = 0.0) / capacity)
end

"""
    fnct_stor_cycle!(nm, T)

Hold every storage unit that carries one to its cycle limit, once per period,

```math
\\sum_{n \\in \\mathcal{P}} \\Delta t_{n} \\, p^{\\text{sd}}_{u,n}
    \\le k^{\\text{max}}_{u} \\, e^{\\text{max}}_{u} ,
```

with the period `𝒫` running over the `:time` coordinates grouped with the index,
see [`period_ids`](@ref), and every other coordinate held fixed — so a problem
posed over contingencies gets one limit per period *per contingency*, and a
`:time` dimension with no grouping gives one limit over the whole horizon.

Written only for a unit whose `k_cycl_max` is finite. A limit of
infinity is not a row with an infinite right hand side; it is the absence of a
row, and a solver handed the first would be given a constraint it can never use.
"""
function fnct_stor_cycle!(nm::NetworkModel, ::Type{T}) where {T<:AbstractStorage}
    for n in nw_ids(nm)
        is_first_period_id(nm, n, :time) || continue
        window = period_ids(nm, n, :time)

        for u in ids(nm, T; nw = n)
            st = unit(nm, u; nw = n)::T
            isfinite(st.k_cycl_max) || continue

            capacity = nw_value(nm, st.e_max, n)
            constrain!(nm, :cstr_stor_cycle, u, JuMP.@build_constraint(
                sum(time_step(nm, m) * var(nm, :p_dch, u; nw = m)
                    for m in window if haskey(var(nm, :p_dch; nw = m), u); init = 0.0) <=
                st.k_cycl_max * capacity); nw = n)
        end
    end

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
        return !isfinite(st.k_cycl_max) && iszero(st.c_cycl) &&
               all_nw(iszero, st.c_thru)
    end
    free && _has_negative_price(nm, n) || return nothing

    @warn "a storage unit is free to cycle — no `k_cycl_max`, no " *
          "`c_thru` and no `c_cycl` — in a problem where some generation is " *
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
            all_nw(c -> all(>=(0), @view c[2:end]), g.c) || return true
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
without this having to know it. Zero unless `c_thru` was given.
"""
function dispatch_cost(nm::NetworkModel, ::Type{T}, u::Int; nw::Int) where {T<:AbstractStorage}
    haskey(var(nm; nw), :p_dch) || return 0.0
    st = unit(nm, u; nw)::T
    iszero(st.c_thru) && return 0.0

    return JuMP.@expression(nm.model, st.c_thru * var(nm, :p_dch, u; nw))
end

"""
    period_cost(nm, T, u; nw)

What storage unit `u` costs over the period beginning at network index `nw`,
`c^{\\text{cyc}}_{u}` times the [`storage_cycles`](@ref) it turns in it.

A charge per cycle is not a charge per unit of energy in different units. It
prices the *turning* rather than the moving, so a unit that discharges half its
capacity twice pays for one cycle while `c_thru` charges it for the
whole of what it moved either way. Both are real, they measure different wear,
and a unit may carry either or both.
"""
function period_cost(nm::NetworkModel, ::Type{T}, u::Int; nw::Int) where {T<:AbstractStorage}
    haskey(var(nm; nw), :p_dch) || return 0.0
    st = unit(nm, u; nw)::T
    iszero(st.c_cycl) && return 0.0

    return JuMP.@expression(nm.model,
        st.c_cycl * storage_cycles(nm, st, u, period_ids(nm, nw, :time)))
end

################################################################################
# Storage — solution                                                           #
################################################################################

function solution_unit!(sol::Dict{String,Any}, nm::NetworkModel, ::Type{T}, u::Int, nw::Int
                       ) where {T<:AbstractStorage}
    if haskey(var(nm; nw), :e_stor)
        sol["p_chg"] = JuMP.value(var(nm, :p_chg, u; nw))
        sol["p_dch"] = JuMP.value(var(nm, :p_dch, u; nw))
        sol["e_stor"]  = JuMP.value(var(nm, :e_stor,  u; nw))
        if haskey(var(nm; nw), :p_stor_up)
            sol["p_stor_mkt"] = unit(nm, u; nw).p_set
            sol["p_stor_up"]      = JuMP.value(var(nm, :p_stor_up, u; nw))
            sol["p_stor_dn"]      = JuMP.value(var(nm, :p_stor_dn, u; nw))
        end
    else
        st = unit(nm, u; nw)::T
        sol["p_chg"] = max(-st.p_set, 0.0)
        sol["p_dch"] = max(st.p_set, 0.0)
        sol["e_stor"]  = st.e_init
    end

    return nothing
end

################################################################################
# Storage — the linearized formulation                                         #
################################################################################

"""
    fnct_unit(nm, T; nw)

Link the injection of every in-service storage unit to what it charges and
discharges. Reactive power plays no part in a linearized formulation.
"""
function fnct_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractPowerFlowProblem,F<:LPFFormulation,T<:AbstractStorage}
    power = get!(() -> Dict{Int,Any}(), con(nm; nw), :cstr_unit_injection)

    for u in ids(nm, T; nw)
        power[u] = fnct_unit_injection!(nm, u, unit(nm, u; nw).p_set; nw)
    end

    return nothing
end

fnct_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
               ) where {P<:AbstractDispatchProblem,F<:LPFFormulation,T<:AbstractStorage} =
    _constraint_storage_injection(nm, T, nw)

"link what every storage unit charges and discharges to the active power it injects"
function _constraint_storage_injection(nm::NetworkModel, ::Type{T}, nw::Int) where {T<:AbstractStorage}
    isempty(ids(nm, T; nw)) && return nothing

    p_chg, p_dch = var(nm, :p_chg; nw), var(nm, :p_dch; nw)
    power        = get!(() -> Dict{Int,Any}(), con(nm; nw), :cstr_unit_injection)

    for u in ids(nm, T; nw)
        power[u] = fnct_unit_injection!(nm, u,
                       JuMP.@expression(nm.model, p_dch[u] - p_chg[u]); nw)
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
    variable_container!(nm, :p_stor_up, :p_stor_dn; nw)

    for u in ids(nm, T; nw)
        st = unit(nm, u; nw)::T

        variable!(nm, :p_stor_up, u; nw, start = 0.0,
                  lower = 0.0, upper = max(st.p_dch_max - st.p_set, 0.0))
        variable!(nm, :p_stor_dn, u; nw, start = 0.0,
                  lower = 0.0, upper = max(st.p_set + st.p_chg_max, 0.0))
    end

    return nothing
end

"""
    fnct_unit(nm, T; nw)

Link the injection of every in-service storage unit to what it injects, and
split that injection into the market schedule and the volumes moved away from
it,

```math
p^{\\text{sd}}_{u} - p^{\\text{sc}}_{u}
    = p^{\\text{s}}_{u} + p^{\\uparrow}_{u} - p^{\\downarrow}_{u} .
```

The market schedule is the setpoint `p_set` the unit already carries. Where it
varies over `:time` it is a whole schedule; where it is a plain zero — the
default — the unit was not scheduled by the market at all and every per unit it
moves counts as redispatch.
"""
function fnct_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P<:RedispatchProblem,F<:IVRFormulation,T<:AbstractStorage}
    isempty(ids(nm, T; nw)) && return nothing
    _constraint_storage_power(nm, T, nw)
    _constraint_storage_redispatch(nm, T, nw)

    return nothing
end

function fnct_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P<:RedispatchProblem,F<:LPFFormulation,T<:AbstractStorage}
    isempty(ids(nm, T; nw)) && return nothing
    _constraint_storage_injection(nm, T, nw)
    _constraint_storage_redispatch(nm, T, nw)

    return nothing
end

function _constraint_storage_redispatch(nm::NetworkModel, ::Type{T}, nw::Int
                                       ) where {T<:AbstractStorage}
    p_chg, p_dch         = var(nm, :p_chg;     nw), var(nm, :p_dch;     nw)
    p_stor_up, p_stor_dn = var(nm, :p_stor_up; nw), var(nm, :p_stor_dn; nw)
    split                = get!(() -> Dict{Int,Any}(), con(nm; nw), :cstr_stor_redispatch)

    for u in ids(nm, T; nw)
        st = unit(nm, u; nw)::T
        split[u] = constrain!(nm, :cstr_stor_redispatch, u, JuMP.@build_constraint(
            p_dch[u] - p_chg[u] == st.p_set + p_stor_up[u] - p_stor_dn[u]); nw)
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
following a market schedule, and the volumes priced by `c_up` and `c_dn`
are the deviation rather than the movement.
"""
function redispatch_cost(nm::NetworkModel, ::Type{T}, u::Int; nw::Int) where {T<:AbstractStorage}
    haskey(var(nm; nw), :p_stor_up) || return 0.0
    st = unit(nm, u; nw)::T

    return JuMP.@expression(nm.model,
        st.c_up * var(nm, :p_stor_up, u; nw) + st.c_dn * var(nm, :p_stor_dn, u; nw) +
        st.c_thru * var(nm, :p_dch, u; nw))
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
    (:p_chg, :p_dch, :p_stor_up, :p_stor_dn)

################################################################################
# Storage — across windows                                                     #
################################################################################

"""
    interior_state(st)

The storage unit `st` with its end-of-horizon target released.

The counterpart of [`initial_state`](@ref), and the two are what make a rolling
horizon mean the same thing as the problem it is rolling. One carries the start
of a window forward from the window before it; this holds the *end* back, for a
window whose last time step is not the last time step of the problem.

Without it every window would be asked to arrive at `e_fin`, which is
[`EnergyGuide`-style stitching](@ref Storage) by another name: a target invented
for each batch because the batches do not talk to each other. They do talk here,
through `initial_state`, so only the window that actually reaches the end of the
horizon carries the target.
"""
interior_state(st::Storage) =
    isnan(st.e_fin) ? st :
    Storage(; id = st.id, name = st.name, node = st.node, p_set = st.p_set, q_set = st.q_set,
            e_max = st.e_max, e_init = st.e_init,
            e_fin = NaN,
            p_chg_max = st.p_chg_max, p_dch_max = st.p_dch_max,
            η_chg = st.η_chg,
            η_dch = st.η_dch,
            k_cycl_max = st.k_cycl_max,
            c_thru = st.c_thru, c_cycl = st.c_cycl,
            q_min = st.q_min, q_max = st.q_max,
            c_up = st.c_up, c_dn = st.c_dn,
            status = st.status, ext = st.ext)

"""
    initial_state(st, nm, n)

The storage unit `st` starting from the energy it holds at network index `n` of
the solved model `nm`.

This is the one thing a rolling horizon carries: everything else a window
decided it decides again, but the energy left in a battery at the end of a
committed step is a fact the next window inherits rather than a choice it makes.
Without it each window would start from `e_init` again and the unit
would appear to refill itself for free between them.

The unit is returned untouched where the model has no state of charge to read,
i.e. where it was built for a power flow rather than a dispatch problem.
"""
function initial_state(st::Storage, nm::NetworkModel, n::Int)
    haskey(var(nm; nw = n), :e_stor) || return st
    haskey(var(nm, :e_stor; nw = n), st.id) || return st

    return Storage(; id = st.id, name = st.name, node = st.node, p_set = st.p_set, q_set = st.q_set,
                   e_max = st.e_max,
                   e_init = JuMP.value(var(nm, :e_stor, st.id; nw = n)),
                   e_fin = st.e_fin,
                   p_chg_max = st.p_chg_max, p_dch_max = st.p_dch_max,
                   η_chg = st.η_chg,
                   η_dch = st.η_dch,
                   k_cycl_max = st.k_cycl_max,
                   c_thru = st.c_thru, c_cycl = st.c_cycl,
                   q_min = st.q_min, q_max = st.q_max,
                   c_up = st.c_up, c_dn = st.c_dn,
                   status = st.status, ext = st.ext)
end
