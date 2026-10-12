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
# v0.15.1 - e_min, c_chg and c_dch, the checks made before the build           #
# v0.15.2 - s_max, the converter rating of a storage unit                      #
# v0.15.3 - s_max is positive, never zero                                      #
# v0.15.3 - exact keeps charging and discharging at once out                   #
################################################################################

export AbstractStorage, Storage, inflow, storage_cycles
export Exclusion, RELAXED, EXACT, FROZEN
export check_storage, scheduled_energy
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
| `e_max`, `e_min`, `e_init`, `e_fin` | the state of charge, its bounds and its ends |
| `p_chg_max`, `p_dch_max` | the bounds on the charge and discharge |
| `η_chg`, `η_dch` | the balance |
| `exact` | [`refine!`](@ref), which keeps charging and discharging at once out |
| `k_cycl_max` | [`fnct_stor_cycle!`](@ref) |
| `c_chg`, `c_dch`, `c_cycl` | [`dispatch_cost`](@ref), [`period_cost`](@ref) |
| `c_up`, `c_dn` | [`redispatch_cost`](@ref) |
| `q_min`, `q_max` | the reactive power, where the formulation has any |
| `s_max` | the converter limit, a row where it is finite |

What a subtype adds on top is its own, and the one thing it is expected to
override is [`inflow`](@ref), for energy that reaches the unit from outside the
model.
"""
abstract type AbstractStorage <: AbstractUnit end

"""
    Exclusion

How a [`Storage`](@ref) unit is kept from charging and discharging at once, which
nothing in its constraints forbids:

- `RELAXED`: not at all, and no integers. This is exact where the unit's own prices
  cover what a node pays to take a unit off the network, `η_chg c_dch + c_chg / η_dch >=
  (1 / η_dch - η_chg) |λ|`, and a unit that falls short of it is warned about.
- `EXACT`: the optimum. The model is solved, every unit-step that charges and
  discharges at once gets a binary `z_stor` and two rows, `p_chg <= p_chg_max z`
  and `p_dch <= p_dch_max (1 - z)`, and it is solved again, until none is left.
  A model that did this is mixed-integer: it has no duals, and in the current based
  formulation it needs a solver for nonconvex mixed-integer programs.
- `FROZEN`: feasible, not optimal. The direction of each such unit-step is fixed, the
  smaller of the two sides to zero, and the model is solved again, until none is left.
  It is the same kind of problem as before and keeps its duals.

A `Bool` is accepted where an `Exclusion` is, as it is for a [`TapMode`](@ref):
`false` is `RELAXED` and `true` is `EXACT`. `EXACT` and `FROZEN` need finite ratings,
which what is excluded is measured against.

What is solved is a problem with losses on both sides and a price on moving energy: with
losses, a unit in a step that charges and discharges at once burns what it holds, and
where a node pays to have a unit taken — a [`Spill`](@ref) that charges for spilling,
a generator that pays to run — the relaxation is paid to do it.
"""
@enum Exclusion RELAXED EXACT FROZEN

"a `Bool` or an `Exclusion` as an `Exclusion`"
_exclusion(x::Exclusion) = x
_exclusion(b::Bool) = b ? EXACT : RELAXED

"""
    Storage <: AbstractStorage

A unit `(u, i)` that charges and discharges within a rating and an energy
capacity.

In a dispatch problem the charge and discharge power at each network index are
decisions, and the state of charge follows them from step to step. In a power
flow there is nothing to decide and the unit holds the setpoint `p_set`, `q_set`.

Charging and discharging are separate non-negative variables, so a round trip
loses energy through both efficiencies. Nothing in the constraints forbids the two
from being non-zero at once, and where a node pays to take energy off the network a
unit with losses is paid to do it, by burning what it holds. `exact` says what is
done about that, see [`Exclusion`](@ref).

What a constructor cannot see is [`check_storage`](@ref)'s: an energy held above
the capacity at the first time step, a target outside the bounds at the last, a
market schedule that runs the unit out. A model runs it before it builds.

# Fields
- `id`, `name`: the identifier and a human readable label.
- `node`: the node the storage is connected to.
- `p_set`, `q_set`: the injection setpoint [pu], used by a power flow, and the
  **market schedule** a [`RedispatchProblem`](@ref) moves away from.
- `e_max`: the usable energy capacity [pu·h].
- `e_min`: the energy the unit keeps in reserve [pu·h], the lower bound of its
  state of charge. `0` by default.
- `e_init`: the energy held before the first time step [pu·h].
- `e_fin`: the energy the unit must hold after the last time step [pu·h].
  `NaN`, the default, means *no target*, and the horizon ends wherever the
  dispatch leaves it.
- `p_chg_max`, `p_dch_max`: the power limits [pu].
- `η_chg`, `η_dch`: the one-way efficiencies, in
  `(0, 1]`.
- `exact`: an [`Exclusion`](@ref), how charging and discharging at once is kept out,
  or a `Bool`, `true` being `EXACT`. `RELAXED` by default. `EXACT` and `FROZEN` need
  finite `p_chg_max` and `p_dch_max`.
- `k_cycl_max`: the equivalent full cycles the unit may turn in one
  period [-], see [`storage_cycles`](@ref). `Inf`, the default, leaves it free to
  cycle as often as the ratings allow.
- `c_chg`, `c_dch`: the price of moving one per unit into and out of the unit
  [currency/pu/h], each on its own side. This is degradation, so it is paid in a
  dispatch and in a redispatch alike and whatever the reason the energy moved.
- `c_cycl`: the price of one equivalent full cycle [currency/cycle], charged
  once per period rather than once per network index — a cost that spans network
  indices, see [`period_cost`](@ref).
- `q_min`, `q_max`: the reactive power limits [pu].
- `s_max`: the rating of the converter the unit sits behind [pu], positive. `Inf`, the
  default, writes no row; a unit that cannot inject is out of service, which `status`
  says. A current based formulation keeps the net injection
  and the reactive power inside a circle, `(p^{sd} - p^{sc})^2 + q^2 <= s_max^2`;
  a linearized one, which has no reactive power, limits the net active
  injection, `|p^{sd} - p^{sc}| <= s_max`. The charge and discharge ratings still
  bound each side; this bounds what the unit puts on the node.
- `c_up`, `c_dn`: the price of injecting one per unit more and one per
  unit less than the market schedule, in a [`RedispatchProblem`](@ref)
  [currency/pu/h]. Both default to zero, which makes the unit a free measure;
  set them where storage is meant to be a costly one. Note that at a price of
  zero only the *difference* of the two volumes is determined — nothing then
  stops the solver from adding the same amount to both — so read the deviation
  of a free measure as `psup - psdn` rather than as either one. Either price may
  be negative, a payback, but a pair that sums below zero is refused: it would
  pay the solver to raise both volumes by the same amount.
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
    e_min     ::NetworkQuantity{Float64} = 0.0
    e_init    ::Float64                  = 0.0
    e_fin     ::Float64                  = NaN
    p_chg_max ::NetworkQuantity{Float64} = 0.0
    p_dch_max ::NetworkQuantity{Float64} = 0.0
    η_chg     ::Float64                  = 1.0
    η_dch     ::Float64                  = 1.0
    exact     ::Exclusion                = RELAXED
    k_cycl_max::Float64                  = Inf
    c_chg     ::NetworkQuantity{Float64} = 0.0
    c_dch     ::NetworkQuantity{Float64} = 0.0
    c_cycl    ::Float64                  = 0.0
    q_min     ::NetworkQuantity{Float64} = 0.0
    q_max     ::NetworkQuantity{Float64} = 0.0
    s_max     ::NetworkQuantity{Float64} = Inf
    c_up      ::NetworkQuantity{Float64} = 0.0
    c_dn      ::NetworkQuantity{Float64} = 0.0
    status    ::NetworkQuantity{Bool}    = true
    ext       ::Dict{Symbol,Any}         = Dict{Symbol,Any}()

    function Storage(id, name, node, p_set, q_set, e_max, e_min, e_init, e_fin,
                     p_chg_max, p_dch_max, η_chg, η_dch, exact, k_cycl_max, c_chg, c_dch,
                     c_cycl, q_min, q_max, s_max, c_up, c_dn, status, ext)
        exact = _exclusion(exact)
        _check_storage(id, e_max, e_min, e_init, e_fin, p_chg_max, p_dch_max, η_chg,
                       η_dch, exact, k_cycl_max, c_chg, c_dch, c_cycl, q_min, q_max, s_max, c_up, c_dn)

        return new(id, name, node, p_set, q_set, e_max, e_min, e_init, e_fin,
                   p_chg_max, p_dch_max, η_chg, η_dch, exact, k_cycl_max, c_chg, c_dch,
                   c_cycl, q_min, q_max, s_max, c_up, c_dn, status, ext)
    end
end

# What can be refused without knowing where the energy is read. The constructor runs
# again at every network index, with that index's values, so a start or a target is
# compared with its bounds in `check_storage`, at the first and the last index only.
# A window starts from what a solver returned, a digit below zero included, so `e_init` is not refused here.
function _check_storage(id, e_max, e_min, e_init, e_fin, p_chg_max, p_dch_max, η_chg, η_dch,
                        exact, k_cycl_max, c_chg, c_dch, c_cycl, q_min, q_max, s_max, c_up, c_dn)
    0 < η_chg <= 1 ||
        throw(ArgumentError("storage $id has a charge efficiency outside (0, 1]"))
    0 < η_dch <= 1 ||
        throw(ArgumentError("storage $id has a discharge efficiency outside (0, 1]"))
    all_nw(>=(0), p_chg_max) && all_nw(>=(0), p_dch_max) ||
        throw(ArgumentError("storage $id has a negative or undefined charge or discharge rating"))
    exact === RELAXED || all_nw(isfinite, p_chg_max) && all_nw(isfinite, p_dch_max) ||
        throw(ArgumentError("storage $id has an `exact` of $exact and a charge or discharge rating that is not finite, which what it excludes is measured against"))
    all_nw(>=(0), e_max) ||
        throw(ArgumentError("storage $id has a negative energy capacity"))
    all_nw(>=(0), e_min) ||
        throw(ArgumentError("storage $id has a negative energy floor `e_min`"))
    all_nw(<=, e_min, e_max) ||
        throw(ArgumentError("storage $id has an energy floor `e_min` above its capacity `e_max`"))
    isfinite(e_init) ||
        throw(ArgumentError("storage $id holds an undefined energy before the first step"))
    isnan(e_fin) || e_fin >= 0 ||
        throw(ArgumentError("storage $id has a negative energy target"))
    k_cycl_max >= 0 ||
        throw(ArgumentError("storage $id has a negative cycle limit"))
    all_nw(x -> isfinite(x) && x >= 0, c_chg) ||
        throw(ArgumentError("storage $id has a `c_chg` that is negative or not finite, which pays the problem to cycle it"))
    all_nw(x -> isfinite(x) && x >= 0, c_dch) ||
        throw(ArgumentError("storage $id has a `c_dch` that is negative or not finite, which pays the problem to cycle it"))
    isfinite(c_cycl) && c_cycl >= 0 ||
        throw(ArgumentError("storage $id has a cycle cost that is negative or not finite, which pays the problem to cycle it"))
    all_nw(<=, q_min, q_max) ||
        throw(ArgumentError("storage $id has q_min above q_max"))
    all_nw(>(0), s_max) ||
        throw(ArgumentError("storage $id has a converter rating `s_max` that is not positive; a unit that cannot inject is out of service, which `status` says"))
    all_nw(isfinite, c_up) && all_nw(isfinite, c_dn) ||
        throw(ArgumentError("storage $id has a `c_up` or a `c_dn` that is not finite"))
    all_nw((up, dn) -> up + dn >= 0, c_up, c_dn) ||
        throw(ArgumentError("storage $id has a `c_up` and a `c_dn` that sum below zero, which pays the problem to move it up and down at once"))

    return nothing
end

register_unit_type!(Storage)

"""
    structure_gates(st)

A converter rating is written only where it is finite, so it decides the shape of
a storage unit's model. See [`structure_gates`](@ref).
"""
structure_gates(::AbstractStorage) = (:s_max,)

################################################################################
# Storage — what is checked before the build                                   #
################################################################################

"how far an energy may sit outside its bounds before it is refused [pu·h]: what a solver hands back carries digits"
const _ENERGY_TOLERANCE = 1e-6

"the length of the window a cycle limit holds over [h]"
const _CYCLE_WINDOW = 24.0

"the hours of the time step at network index `n`, an hour unless the dimension says otherwise"
_hours(dim::Dimension, n::Int) = dim_prop(dim, n, :time, :duration, 1.0)

"""
    scheduled_energy(data, u)

The energy storage unit `u` holds after every network index when it follows its
market schedule `p_set` and nothing else, as a [`NetworkVector`](@ref).

A positive `p_set` is a discharge and a negative one a charge, so the energy
moves by

```math
\\Delta t_{n} \\left( \\eta^{\\text{c}}_{u} \\max(-p^{\\text{s}}_{u,n}, 0)
    - \\max(p^{\\text{s}}_{u,n}, 0) / \\eta^{\\text{d}}_{u} \\right)
```

from `e_init` at the first step of each horizon, along `:time` with every other
coordinate held fixed. A unit out of service holds what it has. An inflow, which a
subtype brings from outside the model, is not counted, and the helper is for a
[`Storage`](@ref) for that reason.

It is what a redispatch should leave a unit holding, the target a schedule
implies, and what [`check_storage`](@ref) compares with the bounds.
"""
function scheduled_energy(data::NetworkData, u::Int)
    net = network(data)
    dim = dimension(data)

    has_dim(dim, :time) ||
        throw(ArgumentError("a schedule is followed along `:time`, but this problem has no such dimension"))
    haskey(units(net), u) ||
        throw(ArgumentError("there is no unit $u"))
    units(net)[u] isa Storage ||
        throw(ArgumentError("unit $u is not a `Storage`, so it has no scheduled energy"))

    ids    = nw_ids(dim)
    at(n)  = n - first(ids) + 1
    energy = Vector{Float64}(undef, length(ids))
    for n in ids
        st     = unit(net, u; nw = n)::Storage
        p      = st.status ? st.p_set : 0.0
        before = is_first_id(dim, n, :time) ? st.e_init : energy[at(prev_id(dim, n, :time))]
        energy[at(n)] = before + _hours(dim, n) * (st.η_chg * max(-p, 0.0) - max(p, 0.0) / st.η_dch)
    end

    return NetworkVector(energy)
end

"""
    check_storage(data; dispatch = true, schedule = true)

Refuse storage data that cannot pose a sensible problem, with an `ArgumentError`
that names the unit and the network index; [`instantiate_model`](@ref) calls it
before it builds. What a constructor cannot see is read here, at the network
index the energy is read at:

- with `dispatch`, an `e_init` outside `[e_min, e_max]` at the first time step and
  an `e_fin` outside it at the last, each against the bounds of that index. A
  power flow holds a setpoint and has no state of charge to bound.
- with `schedule`, a market schedule `p_set` that leaves the energy outside the
  bounds, see [`scheduled_energy`](@ref), or that counts more than the cycle limit
  allows over any 24 hours. A redispatch repairs such a schedule at the price of
  its volumes and books the bill as redispatch, with no congestion behind it.

A cycle counts half of what goes into the store and what comes out of it,
`Δt (η_chg max(-p_set, 0) + max(p_set, 0)/η_dch) / 2` over `e_max`, so that a
lossless full cycle counts one. The budget is `k_cycl_max · e_max` over any run of
time steps that spans 24 hours or less, not over a calendar day.

Nothing is checked without a `:time` dimension: nothing then couples, and a
dispatch problem asks for one when it builds. An energy is allowed
$(_ENERGY_TOLERANCE) outside a bound, since what a solver hands to the next window
carries digits.
"""
function check_storage(data::NetworkData; dispatch::Bool = true, schedule::Bool = true)
    dim = dimension(data)
    has_dim(dim, :time) || return nothing

    net = network(data)
    for u in sort!(collect(keys(units(net))))
        c = units(net)[u]
        c isa AbstractStorage || continue

        dispatch && _check_energy(net, dim, u)
        schedule && c isa Storage && _check_schedule(data, net, dim, u)
    end

    return nothing
end

"the start and the end of storage unit `u`, against the bounds at the index they are read at"
function _check_energy(net::Network, dim::Dimension, u::Int)
    tol = _ENERGY_TOLERANCE

    for n in nw_ids(dim)
        at_start, at_end = is_first_id(dim, n, :time), is_last_id(dim, n, :time)
        (at_start || at_end) || continue

        st = unit(net, u; nw = n)
        if at_start && !(st.e_min - tol <= st.e_init <= st.e_max + tol)
            throw(ArgumentError(
                "storage $u holds `e_init` = $(st.e_init) before the first step, at network index $n " *
                "outside its bounds [$(st.e_min), $(st.e_max)]"))
        end
        if at_end && !isnan(st.e_fin) && !(st.e_min - tol <= st.e_fin <= st.e_max + tol)
            throw(ArgumentError(
                "storage $u is asked for `e_fin` = $(st.e_fin) after the last step, at network index $n " *
                "outside its bounds [$(st.e_min), $(st.e_max)]"))
        end
    end

    return nothing
end

"the energy and the cycle budget of the market schedule of storage unit `u`"
function _check_schedule(data::NetworkData, net::Network, dim::Dimension, u::Int)
    tol    = _ENERGY_TOLERANCE
    energy = scheduled_energy(data, u).data
    ids    = nw_ids(dim)

    for n in ids
        st = unit(net, u; nw = n)
        e  = energy[n - first(ids) + 1]
        st.e_min - tol <= e <= st.e_max + tol && continue

        throw(ArgumentError(
            "the market schedule of storage $u leaves its energy at $(round(e; digits = 6)) at network " *
            "index $n, outside its bounds [$(st.e_min), $(st.e_max)]; a redispatch would repair it at " *
            "the price of its volumes and book that as redispatch"))
    end

    isfinite(units(net)[u].k_cycl_max) && _check_budget(net, dim, u)

    return nothing
end

"the cycles storage unit `u` is scheduled to turn over any 24 hours, against its limit"
function _check_budget(net::Network, dim::Dimension, u::Int)
    tol   = _ENERGY_TOLERANCE
    steps = dim_length(dim, :time)

    for n0 in nw_ids(dim; time = 1)
        path  = similar_ids(dim, n0; time = 1:steps)
        st    = [unit(net, u; nw = n) for n in path]
        hours = [_hours(dim, n) for n in path]
        count = map(st, hours) do s, h
            p = s.status ? s.p_set : 0.0
            h * (s.η_chg * max(-p, 0.0) + max(p, 0.0) / s.η_dch) / 2
        end

        window, span, total = 1, 0.0, 0.0
        for j in 1:steps
            span  += hours[j]
            total += count[j]
            while span > _CYCLE_WINDOW + 1e-9
                span  -= hours[window]
                total -= count[window]
                window += 1
            end

            budget = st[j].k_cycl_max * st[j].e_max
            total <= budget + tol && continue

            throw(ArgumentError(
                "the market schedule of storage $u counts $(round(total; digits = 6)) pu·h over the " *
                "24 hours up to network index $(path[j]), above the $(round(budget; digits = 6)) its " *
                "`k_cycl_max` of $(st[j].k_cycl_max) allows over its capacity of $(st[j].e_max)"))
        end
    end

    return nothing
end

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
                  lower = st.e_min, upper = st.e_max)
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

"link what every storage unit charges and discharges to the current it injects, within the rating of its converter"
function _constraint_storage_power(nm::NetworkModel, ::Type{T}, nw::Int) where {T<:AbstractStorage}
    isempty(ids(nm, T; nw)) && return nothing

    p_chg, p_dch, q_stor = var(nm, :p_chg; nw), var(nm, :p_dch; nw), var(nm, :q_stor; nw)
    power                = get!(() -> Dict{Int,Any}(), con(nm; nw), :cstr_unit_power)

    for u in ids(nm, T; nw)
        st = unit(nm, u; nw)::T
        p  = JuMP.@expression(nm.model, p_dch[u] - p_chg[u])
        power[u] = fnct_unit_power!(nm, u, p, q_stor[u]; nw)

        isfinite(st.s_max) || continue
        constrain!(nm, :cstr_stor_rating, u,
                   JuMP.@build_constraint(p^2 + q_stor[u]^2 <= st.s_max^2); nw)
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
    _warn_inexact_relaxation(nm, T)

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
    _warn_inexact_relaxation(nm, T)

Warn where the relaxation may let a storage unit charge and discharge at once.

With losses, a unit that charges and discharges at once burns `x (1 / η_dch - η_chg)` of
what it holds for every `x` it moves each way. Where a node pays to have a unit taken off
the network, by what a [`Spill`](@ref) charges for spilling or by a generator that pays to
run, the burn is worth that price to the problem, and a unit whose own prices fall below it,

```math
\\eta_{c} c^{\\text{d}} + c^{\\text{c}} / \\eta_{d} < (1 / \\eta_{d} - \\eta_{c}) |\\lambda| ,
```

is paid to do it. A cycle limit bounds how often and does not remove it. What is
warned about is a unit that leaves it `RELAXED`; `EXACT` and `FROZEN` are the ways out, and a price at
the line is the third. The price of the node is read at the first network index.

A warning rather than an error because the model is well posed, and because what
counts as a price below zero is a property of the data, which the package does not
otherwise legislate about.
"""
function _warn_inexact_relaxation(nm::NetworkModel, ::Type{T}) where {T<:AbstractStorage}
    n    = nw_id_default(nm)
    open = [u for u in ids(nm, T; nw = n) if (unit(nm, u; nw = n)::T).exact === RELAXED]
    isempty(open) && return nothing

    lowest = _price_floor(nm, n)
    lowest < 0 || return nothing

    for u in open
        st    = unit(nm, u; nw = n)::T
        burn  = (1 / st.η_dch - st.η_chg) * abs(lowest)
        price = st.η_chg * st.c_dch + st.c_chg / st.η_dch
        price >= burn - 1e-9 && continue

        @warn "storage $u may charge and discharge at once: its prices come to " *
              "$(round(price; digits = 4)), and a node that pays $(abs(lowest)) to take a unit " *
              "off the network makes burning energy worth $(round(burn; digits = 4)). Give it " *
              "`exact`, or a price that reaches that; a cycle limit bounds the artefact and " *
              "does not remove it"
    end

    return nothing
end

"the lowest price a generator or a slack unit sets at network index `n`, or zero"
function _price_floor(nm::NetworkModel, n::Int)
    lowest = 0.0
    for T in unit_types(), u in ids(nm, T; nw = n)
        if T <: AbstractGenerator
            c     = (unit(nm, u; nw = n)::T).c
            lowest = min(lowest, minimum(@view c[2:end]; init = 0.0))
        elseif T <: AbstractSlackUnit
            lowest = min(lowest, (unit(nm, u; nw = n)::T).c)
        end
    end

    return lowest
end

################################################################################
# Storage — keeping charging and discharging at once out                       #
################################################################################

"""
    refine!(nm, T)

Where a storage unit of type `T` charges and discharges at once in the solution of
`nm` and asks not to, `exact`, keep it from doing so, and return whether `nm`
changed. See [`Exclusion`](@ref) and [`refine!`](@ref).

A step counts when `p^{sc} p^{sd} / (p^{sc}_{max} p^{sd}_{max})` is above `1e-5`: a solver
leaves a few digits on a side that is meant to be zero. `EXACT` adds a binary and two rows
to each such step of the unit; `FROZEN` fixes the smaller side to zero.
"""
function refine!(nm::NetworkModel{P}, ::Type{T}
                ) where {P<:AbstractDispatchProblem,T<:AbstractStorage}
    asked = [u for (u, c) in units(network(nm.data)) if c isa T && c.exact !== RELAXED]
    isempty(asked) && return false

    # read every step before writing to the model: a model that has been written to has no solution
    found = Tuple{Int,Int,Float64,Float64}[]
    for n in nw_ids(nm)
        p_chg, p_dch = var(nm, :p_chg; nw = n), var(nm, :p_dch; nw = n)

        for u in asked
            haskey(p_chg, u) || continue
            chg, dch = JuMP.value(p_chg[u]), JuMP.value(p_dch[u])
            _both(unit(nm, u; nw = n)::T, chg, dch) && push!(found, (n, u, chg, dch))
        end
    end
    isempty(found) && return false

    for (n, u, chg, dch) in found
        st           = unit(nm, u; nw = n)::T
        p_chg, p_dch = var(nm, :p_chg; nw = n), var(nm, :p_dch; nw = n)

        if st.exact === EXACT
            z = variable!(nm, :z_stor, u; nw = n, start = chg > dch ? 1.0 : 0.0, binary = true)
            constrain!(nm, :cstr_stor_exclusion, (u, :chg),
                       JuMP.@build_constraint(p_chg[u] <= st.p_chg_max * z); nw = n)
            constrain!(nm, :cstr_stor_exclusion, (u, :dch),
                       JuMP.@build_constraint(p_dch[u] <= st.p_dch_max * (1 - z)); nw = n)
        else
            bound!(chg > dch ? p_dch[u] : p_chg[u]; fix = 0.0)
        end
    end
    nm.ext[:refined] = true

    return true
end

"whether a storage unit with these two sides charges and discharges at once, which a rating of zero rules out"
_both(st::AbstractStorage, chg, dch) =
    st.p_chg_max > 0 && st.p_dch_max > 0 && chg * dch / (st.p_chg_max * st.p_dch_max) > 1e-5

################################################################################
# Storage — cost                                                               #
################################################################################

"""
    dispatch_cost(nm, T, u; nw)

What storage unit `u` costs at network index `nw`,
`c^{\\text{c}}_{u} p^{\\text{sc}}_{u} + c^{\\text{d}}_{u} p^{\\text{sd}}_{u}`.

Degradation, priced on what the unit moves, each side at its own price. It is a
per-index cost like any other, so the objective weights it by the weight of its
index — with a `:weight` of the step duration, a price per per unit becomes a
price per per-unit-hour without this having to know it. Zero unless `c_chg` or
`c_dch` was given.
"""
function dispatch_cost(nm::NetworkModel, ::Type{T}, u::Int; nw::Int) where {T<:AbstractStorage}
    haskey(var(nm; nw), :p_dch) || return 0.0
    st = unit(nm, u; nw)::T
    iszero(st.c_chg) && iszero(st.c_dch) && return 0.0

    return JuMP.@expression(nm.model,
        st.c_chg * var(nm, :p_chg, u; nw) + st.c_dch * var(nm, :p_dch, u; nw))
end

"""
    period_cost(nm, T, u; nw)

What storage unit `u` costs over the period beginning at network index `nw`,
`c^{\\text{cyc}}_{u}` times the [`storage_cycles`](@ref) it turns in it.

A charge per cycle is not a charge per unit of energy in different units. It
prices the *turning* rather than the moving, so a unit that discharges half its
capacity twice pays for one cycle while `c_chg` and `c_dch` charge it for the
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

"link what every storage unit charges and discharges to the active power it injects, within the rating of its converter"
function _constraint_storage_injection(nm::NetworkModel, ::Type{T}, nw::Int) where {T<:AbstractStorage}
    isempty(ids(nm, T; nw)) && return nothing

    p_chg, p_dch = var(nm, :p_chg; nw), var(nm, :p_dch; nw)
    power        = get!(() -> Dict{Int,Any}(), con(nm; nw), :cstr_unit_injection)

    for u in ids(nm, T; nw)
        st = unit(nm, u; nw)::T
        p  = JuMP.@expression(nm.model, p_dch[u] - p_chg[u])
        power[u] = fnct_unit_injection!(nm, u, p; nw)

        # a unit that is held has the net injection of the base case, which that case's row bounds
        isfinite(st.s_max) && !is_held(nm, :unit, u; nw) || continue
        constrain!(nm, :cstr_stor_rating, (u, :max),
                   JuMP.@build_constraint(p <= st.s_max); nw)
        constrain!(nm, :cstr_stor_rating, (u, :min),
                   JuMP.@build_constraint(p >= -st.s_max); nw)
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
plus its throughput, see [`dispatch_cost`](@ref). Zero unless one of the four
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
        st.c_chg * var(nm, :p_chg, u; nw) + st.c_dch * var(nm, :p_dch, u; nw))
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
    _with(st; kwargs...)

The storage unit `st` with the fields in `kwargs` replaced and every other field
copied by name, so that a field added to [`Storage`](@ref) travels through a
rolling horizon without a list that names it being changed.
"""
function _with(st::Storage; kwargs...)
    names  = fieldnames(Storage)
    fields = NamedTuple{names}(Tuple(getfield(st, f) for f in names))

    return Storage(; merge(fields, NamedTuple(kwargs))...)
end

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
interior_state(st::Storage) = isnan(st.e_fin) ? st : _with(st; e_fin = NaN)

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

    return _with(st; e_init = JuMP.value(var(nm, :e_stor, st.id; nw = n)))
end
