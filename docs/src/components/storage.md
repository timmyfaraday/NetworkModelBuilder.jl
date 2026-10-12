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

| symbol | code name | description | unit |
|:-------|:------|:------------|:-----|
| | `id`, `name`, `node` | identifier, label, node | |
| ``p^{\text{s,set}}_{u}``, ``q^{\text{s,set}}_{u}`` | `p_set`, `q_set` | injection setpoint, used by a power flow | pu |
| ``e^{\text{max}}_{u}`` | `e_max` | usable energy capacity | pu·h |
| ``e^{\text{min}}_{u}`` | `e_min` | energy kept in reserve, the lower bound of the state of charge | pu·h |
| ``e^{0}_{u}`` | `e_init` | energy held before the first step | pu·h |
| ``e^{\text{f}}_{u}`` | `e_fin` | energy required after the last step, or `NaN` | pu·h |
| ``p^{\text{sc,max}}_{u}`` | `p_chg_max` | charge power limit | pu |
| ``p^{\text{sd,max}}_{u}`` | `p_dch_max` | discharge power limit | pu |
| ``\eta^{\text{c}}_{u}`` | `η_chg` | one-way charge efficiency, in ``(0,1]`` | |
| ``\eta^{\text{d}}_{u}`` | `η_dch` | one-way discharge efficiency, in ``(0,1]`` | |
| | `exact` | how charging and discharging at once is kept out, an [`Exclusion`](@ref) or a `Bool`; `EXACT` and `FROZEN` need finite ratings | |
| ``k^{\text{max}}_{u}`` | `k_cycl_max` | equivalent full cycles allowed per period | |
| ``c^{\text{c}}_{u}`` | `c_chg` | price of one per unit charged | currency/pu/h |
| ``c^{\text{d}}_{u}`` | `c_dch` | price of one per unit discharged | currency/pu/h |
| ``c^{\text{cyc}}_{u}`` | `c_cycl` | price of one equivalent full cycle | currency/cycle |
| ``q^{\text{min}}_{u}``, ``q^{\text{max}}_{u}`` | `q_min`, `q_max` | reactive power limits | pu |
| ``s^{\text{max}}_{u}`` | `s_max` | rating of the converter the unit sits behind, positive, `Inf` for none | pu |
| ``c^{\uparrow}_{u}``, ``c^{\downarrow}_{u}`` | `c_up`, `c_dn` | price of injecting one per unit more and less than the market schedule in a redispatch, each finite and the pair summing to at least zero | currency/pu/h |
| | `status` | in service | |
| | `ext` | free-form storage, carried along and never read | |

## Variables

### In the `IVRFormulation`, dispatch problems

| symbol | code name | index | description | unit |
|:-------|:----|:------|:------------|:-----|
| ``i^{\text{r}}_{u}``, ``i^{\text{i}}_{u}`` | `:i_unit_real`, `:i_unit_imag` | unit | injected current | pu |
| ``p^{\text{sc}}_{u}`` | `:p_chg` | unit | charge power, ``\ge 0`` | pu |
| ``p^{\text{sd}}_{u}`` | `:p_dch` | unit | discharge power, ``\ge 0`` | pu |
| ``e_{u}`` | `:e_stor` | unit | state of charge, from `e_min` to `e_max` | pu·h |
| ``q^{\text{s}}_{u}`` | `:q_stor` | unit | reactive power | pu |
| ``z^{\text{s}}_{u}`` | `:z_stor` | unit | 1 where the unit charges, 0 where it discharges: a binary, written only for a step that charged and discharged at once and has `exact` set to `EXACT` | |
| ``p^{\uparrow}_{u}``, ``p^{\downarrow}_{u}`` | `:p_stor_up`, `:p_stor_dn` | unit | moved up and down from the market schedule, redispatch only | pu |

A power flow creates none of these: there the unit holds its setpoint.

### In the `LPFFormulation`

As above but without ``q^{\text{s}}_{u}``: the charge, discharge and state of
charge variables are shared between the formulations, and only the reactive
power is dropped. The state of charge constraint is unchanged, for the same
reason a flexible load's energy balance is.

## Constraints

The injection, against the current:

```math
v^{\text{r}}_{i} i^{\text{r}}_{u} + v^{\text{i}}_{i} i^{\text{i}}_{u}
= p^{\text{sd}}_{u} - p^{\text{sc}}_{u},
\qquad
v^{\text{i}}_{i} i^{\text{r}}_{u} - v^{\text{r}}_{i} i^{\text{i}}_{u} = q^{\text{s}}_{u} .
```

### The converter limit

A unit behind a converter cannot put more on its node than the converter carries,
whatever its charge and discharge ratings allow side by side. Where
``s^{\text{max}}_{u}`` is finite, the `IVRFormulation` keeps the net injection and
the reactive power inside a circle:

```math
\left( p^{\text{sd}}_{u} - p^{\text{sc}}_{u} \right)^{2} + \left( q^{\text{s}}_{u} \right)^{2}
\le \left( s^{\text{max}}_{u} \right)^{2} ,
```

and the `LPFFormulation`, which has no reactive power, limits the active power alone:

```math
- s^{\text{max}}_{u} \le p^{\text{sd}}_{u} - p^{\text{sc}}_{u} \le s^{\text{max}}_{u} .
```

The default `Inf` writes neither, and the two power ratings are then the whole limit.
A rating is positive: a unit that cannot inject is out of service, and `status` says so.
The limit is on the net, not on each side: where the efficiencies are one the unit may
charge and discharge at once, so either side can exceed ``s^{\text{max}}_{u}`` as long as
the difference does not. A rating that is finite at some network indices and `Inf` at
others changes the shape of the model, see [`structure_gates`](@ref).

In a [`RedispatchProblem`](@ref) a unit with a preventive setup holds the active power it
has at the base case in every contingency, so the linearized limit is written at the base
case only. The reactive power is not held, so the circle is written at every index.

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

### Charging and discharging at once

Charging and discharging are two non-negative variables, and nothing in the
constraints forbids both from being non-zero in the same step. With losses that is
not harmless: a unit that charges and discharges ``x`` at once burns
``x \left( 1 / \eta^{\text{d}}_{u} - \eta^{\text{c}}_{u} \right)`` of what it holds.
Where a node pays to have a unit taken off the network — a [`Spill`](@ref) that
charges for spilling, a generator that pays to run — the relaxation is paid to burn
energy, and a unit that is meant to hold it does not.

On three steps of a must-run surplus at a node that charges 500 to spill, a full
battery with losses of ten per cent each way earns 393.00 relaxed, where 426.54 is the
most it can earn and 450.00 is what the network pays without it. The relaxation is
exact where the unit's own prices reach what burning is worth,

```math
\eta^{\text{c}}_{u} c^{\text{d}}_{u} + c^{\text{c}}_{u} / \eta^{\text{d}}_{u}
\ge \left( 1 / \eta^{\text{d}}_{u} - \eta^{\text{c}}_{u} \right) \left| \lambda \right| ,
```

with ``\lambda`` the lowest price a generator or a slack unit sets, 500 there and the
right hand side 105.6: a ``c^{\text{d}}_{u}`` of 100 leaves the gap and one of 130 closes
it. A unit that falls short of it is warned about when the model is built. A cycle limit
does not settle it, since it bounds how often the unit burns and does not stop it.

`exact` says what is done about it, an [`Exclusion`](@ref):

| value | what it does | the model afterwards |
|:------|:-------------|:---------------------|
| `RELAXED` | nothing | linear, with duals |
| `EXACT` | a binary for each step that did it, then solved again | mixed-integer, no duals |
| `FROZEN` | the smaller side of each such step fixed to zero, then solved again | linear, with duals; feasible, not optimal |

`EXACT` writes, for each step ``n`` that the solution charged and discharged in at once,
a variable ``z^{\text{s}}_{u,n} \in \{0, 1\}`` and

```math
p^{\text{sc}}_{u,n} \le p^{\text{sc,max}}_{u,n} \, z^{\text{s}}_{u,n} , \qquad
p^{\text{sd}}_{u,n} \le p^{\text{sd,max}}_{u,n} \left( 1 - z^{\text{s}}_{u,n} \right) ,
```

and solves again until no step is left, at most eight rounds. Only the steps that need
a binary get one: where the relaxation is exact there are none and the model stays a
linear program. In the current based formulation the model needs a solver for nonconvex
mixed-integer programs, as a free switch does.

[`optimize_model!`](@ref) does this through [`refine!`](@ref), reports what the refined
objective is above the first one as `"relaxation_gap"`, and [`print_summary`](@ref)
shows it. [`solve_rolling_horizon`](@ref) builds the window after a refined one again
rather than updating it.

```@docs
Exclusion
```

### The end of the horizon

A unit that carries an `e_fin` is pinned at the last `:time` coordinate:

```math
e_{u,n} = e^{\text{f}}_{u} \quad \text{at the last } n \text{ along } \texttt{:time}
```

with every other coordinate held fixed, so a problem with a contingency
dimension asks each contingency to arrive at the same place. It is a **pin**,
not a floor: a target the ratings cannot reach makes the problem infeasible,
which is the honest answer to a question that has none. `NaN`, the default, is
the absence of a row rather than a row against `NaN`.

```@docs
fnct_stor_final_energy!
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

A unit that carries a finite `k_cycl_max` gets one row per period:

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
fnct_stor_cycle!
```

!!! note "Why the discharge side"
    One cycle is one energy capacity delivered. Counting the charge side instead
    would make a lossy unit appear to cycle more than it did, and counting both
    would count every cycle twice. This is also the definition a warranty is
    written in, and the one that makes the count independent of the capacity.

!!! warning "A cycle limit does not stop charging and discharging at once"
    Where a node pays to have energy taken off the network, a unit with losses is
    paid to burn what it holds by charging and discharging at once. A cycle limit
    bounds how often it does so and does not stop it; see
    [Charging and discharging at once](@ref).

### Before the build

A constructor refuses what is wrong with a unit on its own: a negative rating, an
energy floor above the capacity, a price that is negative or not finite, a pair
`c_up`, `c_dn` that sums below zero. What needs the dimension is checked before a
model builds, at the network index the energy is read at: the start against the
bounds at the first time step, the target against them at the last, and, in a
redispatch, whether the market schedule `p_set` can be followed at all.

A schedule that discharges more than the unit holds is not infeasible to a
redispatch. It moves the unit away from it at the price of its volumes, and the
bill shows as redispatch cost with no congestion behind it, which is why it is
refused instead.

```@docs
check_storage
scheduled_energy
```

## Cost

| what | code name | where it is paid |
|:-----|:------|:-----------------|
| moving energy | `c_chg`, `c_dch` | [`dispatch_cost`](@ref), once per network index |
| turning a cycle | `c_cycl` | [`period_cost`](@ref), once per period |
| leaving a market schedule | `c_up`, `c_dn` | [`redispatch_cost`](@ref), once per network index |

The first two measure different wear and a unit may carry either or both: a
battery that discharges half its capacity twice pays for one cycle, while the
throughput price charges it for the whole of what it moved either way. The
throughput price is also in `redispatch_cost`, because degradation does not care
why the energy moved — a battery asked to relieve a congestion wears exactly as
much as one following a schedule, and `c_up` and `c_dn` price the
*deviation* rather than the movement.

!!! note "It needs a time dimension"
    Like a [`FlexibleLoad`](@ref), a storage unit couples network indices along
    `:time` and says so when the problem has no such dimension.

!!! note "What a battery is not here"
    A battery is a constant efficiency on each side of one energy balance, priced
    by `c_chg`, `c_dch` and `c_cycl`. A loss that depends on the power, a rate
    capacity at short time steps and a degradation map convexified in power and
    energy are what [Fortenbacher2017](@citet) put inside the model, and a
    self-discharge rate is not here either.

```@bibliography
Pages = [@__FILE__]
Canonical = false
```
