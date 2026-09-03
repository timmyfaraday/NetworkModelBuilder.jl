# Storage

A storage unit ``(u, i)`` can both inject and withdraw active power, subject to
the energy it holds. What makes it its own kind of unit is not that it does both
— a generator with a negative lower bound does too — but that what it can do at
one network index depends on what it did at the others.

```@docs
AbstractStorage
Storage
```

## Parameters

| symbol | field | description | unit |
|:-------|:------|:------------|:-----|
| | `id`, `name`, `node` | identifier, label, node | |
| ``p^{\text{s,set}}_{u}``, ``q^{\text{s,set}}_{u}`` | `ps`, `qs` | injection setpoint, used by a power flow | pu |
| ``e^{\text{max}}_{u}`` | `energy_capacity` | usable energy capacity | pu·h |
| ``e^{0}_{u}`` | `energy_initial` | energy held before the first step | pu·h |
| ``e^{\text{f}}_{u}`` | `energy_final` | energy required after the last step, or `NaN` | pu·h |
| ``p^{\text{sc,max}}_{u}`` | `charge_rating` | charge power limit | pu |
| ``p^{\text{sd,max}}_{u}`` | `discharge_rating` | discharge power limit | pu |
| ``\eta^{\text{c}}_{u}`` | `charge_efficiency` | one-way charge efficiency, in ``(0,1]`` | |
| ``\eta^{\text{d}}_{u}`` | `discharge_efficiency` | one-way discharge efficiency, in ``(0,1]`` | |
| ``k^{\text{max}}_{u}`` | `max_cycles_per_period` | equivalent full cycles allowed per period | |
| ``c^{\text{tp}}_{u}`` | `cost_throughput` | price of one per unit discharged | currency/pu/h |
| ``c^{\text{cyc}}_{u}`` | `cost_cycle` | price of one equivalent full cycle | currency/cycle |
| ``q^{\text{min}}_{u}``, ``q^{\text{max}}_{u}`` | `qmin`, `qmax` | reactive power limits | pu |
| | `status` | in service | |

## Variables

### In the `IVRFormulation`, dispatch problems

| symbol | key | index | description | unit |
|:-------|:----|:------|:------------|:-----|
| ``c^{\text{r}}_{u}``, ``c^{\text{i}}_{u}`` | `:cru`, `:ciu` | unit | injected current | pu |
| ``p^{\text{sc}}_{u}`` | `:psc` | unit | charge power, ``\ge 0`` | pu |
| ``p^{\text{sd}}_{u}`` | `:psd` | unit | discharge power, ``\ge 0`` | pu |
| ``e_{u}`` | `:es` | unit | state of charge | pu·h |
| ``q^{\text{s}}_{u}`` | `:qs` | unit | reactive power | pu |

A power flow creates none of these: there the unit holds its setpoint.

### In the `LPFFormulation`

As above but without ``q^{\text{s}}_{u}``: the charge, discharge and state of
charge variables are shared between the formulations, and only the reactive
power is dropped. The state of charge constraint is unchanged, for the same
reason a flexible load's energy balance is.

## Constraints

The injection, against the current:

```math
v^{\text{r}}_{i} c^{\text{r}}_{u} + v^{\text{i}}_{i} c^{\text{i}}_{u}
= p^{\text{sd}}_{u} - p^{\text{sc}}_{u},
\qquad
v^{\text{i}}_{i} c^{\text{r}}_{u} - v^{\text{r}}_{i} c^{\text{i}}_{u} = q^{\text{s}}_{u} .
```

### Across network indices

The state of charge, carried from one time step to the next:

```math
e_{u,n} = e_{u,n-1} + \Delta t_{n}
          \left( \eta^{\text{c}}_{u} p^{\text{sc}}_{u,n}
                 - p^{\text{sd}}_{u,n} / \eta^{\text{d}}_{u}
                 + p^{\text{in}}_{u,n} \right)
```

with the first step of each horizon starting from ``e^{0}_{u}``. The horizon runs
along `:time` with every other coordinate held fixed, so a problem with a
contingency dimension gives each contingency its own trajectory from the same
starting energy.

``p^{\text{in}}`` is [`inflow`](@ref) and is zero for a `Storage`. It is in the
balance rather than absent from it so that a unit whose energy comes partly from
outside the model — a reservoir fed by rain — overrides one method rather than the whole loop. A coupling constraint
duplicated to add one term is a coupling constraint that will drift.

```@docs
inflow
```

### The end of the horizon

A unit that carries an `energy_final` is pinned at the last `:time` coordinate:

```math
e_{u,n} = e^{\text{f}}_{u} \quad \text{at the last } n \text{ along } \texttt{:time}
```

with every other coordinate held fixed, so a problem with a contingency
dimension asks each contingency to arrive at the same place. It is a **pin**,
not a floor: a target the ratings cannot reach makes the problem infeasible,
which is the honest answer to a question that has none. `NaN`, the default, is
the absence of a row rather than a row against `NaN`.

```@docs
constraint_storage_final_energy!
interior_state
```

!!! note "What a rolling horizon does with it"
    The last time step of a window is the last time step of the problem only for
    the window that closes it, so a roll releases the target everywhere else, see
    [`interior_state`](@ref). The alternative — asking every window to arrive at
    the target — is stitching batches together by pinning both their ends to a
    guessed profile, which is what `initial_state` exists so as not to need.

    The trade is real and worth knowing: a lookahead too short to see why the
    energy is being kept will spend it, and the window that does carry the target
    is then asked for energy that is gone. The fix is a longer `horizon`.

### The cycle limit

A unit that carries a finite `max_cycles_per_period` gets one row per period:

```math
\sum_{n \in \mathcal{P}} \Delta t_{n} \, p^{\text{sd}}_{u,n}
    \le k^{\text{max}}_{u} \, e^{\text{max}}_{u}
```

with the period ``\mathcal{P}`` running over the `:time` coordinates grouped
with the index, see [`period_ids`](@ref), and every other coordinate held fixed.
A `:time` dimension with no grouping gives one period spanning the horizon, and
the limit is then a limit over the whole problem.

An infinite limit — the default — is the **absence** of a row rather than a row
with an infinite right hand side.

```@docs
storage_cycles
constraint_storage_cycles!
```

!!! note "Why the discharge side"
    One cycle is one energy capacity delivered. Counting the charge side instead
    would make a lossy unit appear to cycle more than it did, and counting both
    would count every cycle twice. This is also the definition a warranty is
    written in, and the one that makes the count independent of the capacity.

!!! warning "A battery that is free to cycle"
    A unit with no cycle limit and no price on what it moves, in a problem where
    some generation is priced below zero, will charge and discharge as often as
    its ratings allow — and the trajectory it returns is then an artefact of the
    solver rather than an answer. The package warns when it finds that
    combination. Give the unit a limit or a price; either settles it.

## Cost

| what | field | where it is paid |
|:-----|:------|:-----------------|
| moving energy | `cost_throughput` | [`dispatch_cost`](@ref), once per network index |
| turning a cycle | `cost_cycle` | [`period_cost`](@ref), once per period |
| leaving a market schedule | `cost_up`, `cost_dn` | [`redispatch_cost`](@ref), once per network index |

The first two measure different wear and a unit may carry either or both: a
battery that discharges half its capacity twice pays for one cycle, while the
throughput price charges it for the whole of what it moved either way. The
throughput price is also in `redispatch_cost`, because degradation does not care
why the energy moved — a battery asked to relieve a congestion wears exactly as
much as one following a schedule, and `cost_up` and `cost_dn` price the
*deviation* rather than the movement.

!!! note "Charging and discharging at once"
    Nothing forbids ``p^{\text{sc}}_{u}`` and ``p^{\text{sd}}_{u}`` from both
    being non-zero. Where the efficiencies are below one that is never worth
    doing, and forbidding it outright would need a binary variable and hence a
    different class of solver.

!!! note "It needs a time dimension"
    Like a [`FlexibleLoad`](@ref), a storage unit couples network indices along
    `:time` and says so when the problem has no such dimension.
