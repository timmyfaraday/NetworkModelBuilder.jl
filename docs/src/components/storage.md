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
| ``e^{\text{f}}_{u}`` | `e_fin` | energy required after the last step, or `NaN`: a [`Pin`](@ref) | pu·h |
| | `terminal` | what the end of the horizon asks: one [`AbstractTerminal`](@ref) or a list of them, none by default | |
| ``p^{\text{sc,max}}_{u}`` | `p_chg_max` | charge power limit | pu |
| ``p^{\text{sd,max}}_{u}`` | `p_dch_max` | discharge power limit | pu |
| ``\eta^{\text{c}}_{u}`` | `η_chg` | one-way charge efficiency, in ``(0,1]`` | |
| ``\eta^{\text{d}}_{u}`` | `η_dch` | one-way discharge efficiency, in ``(0,1]`` | |
| | `exact` | how charging and discharging at once is kept out, an [`Exclusion`](@ref) or a `Bool`; `EXACT` and `FROZEN` need finite ratings | |
| ``k^{\text{max}}_{u}`` | `k_cycl_max` | equivalent full cycles allowed over any 24 hours, both sides of the store counted | |
| ``\hat{e}_{u}`` | `e_cycl_init` | what the unit counted in the 24 hours before the first step, as `(hours, energy)` per step, oldest first; empty by default | h, pu·h |
| ``c^{\text{c}}_{u}`` | `c_chg` | price of one per unit charged | currency/pu/h |
| ``c^{\text{d}}_{u}`` | `c_dch` | price of one per unit discharged | currency/pu/h |
| ``c^{\text{cyc}}_{u}`` | `c_cycl` | price of one equivalent full cycle, on the same count and charged at every step | currency/cycle |
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
| ``e^{\text{up}}_{u}``, ``e^{\text{dn}}_{u}`` | `:e_stor_up`, `:e_stor_dn` | unit | the energy above and below the target of a `Soft` end, ``\ge 0``, at the last step only | pu·h |
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

with ``\lambda`` the lowest price a generator or a slack unit sets at any network index, 500 there and the
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

Without a condition the horizon ends wherever the dispatch leaves a unit, which is empty
where the last prices are dear. What a unit can be asked instead is a list, `terminal`, of
conditions on its energy ``e_{u,n}`` after the last time step ``n``, along `:time` with every
other coordinate held fixed, so a problem with a contingency dimension asks each contingency to
arrive at the same place:

| condition | what it asks | where it is written |
|:----------|:-------------|:--------------------|
| [`Pin`](@ref) | the energy is ``e`` | a row |
| [`Cyclic`](@ref) | the energy is the one the unit started with | a row, as a `Pin` |
| [`Floor`](@ref) | the energy is at least ``e`` | a row |
| [`Value`](@ref) | each unit of energy left is worth ``c`` | the objective |
| [`Soft`](@ref) | the energy is ``e``, or the miss is paid for | a row and the objective |
| [`Quad`](@ref) | the squared miss from ``e`` is paid for | the objective |

```math
e_{u,n} = e \;\; (\texttt{Pin}), \qquad e_{u,n} \ge e \;\; (\texttt{Floor}), \qquad
e_{u,n} - e = e^{\text{up}}_{u,n} - e^{\text{dn}}_{u,n} \;\; (\texttt{Soft}),
```

```math
-c \, e_{u,n} \;\; (\texttt{Value}), \qquad
c^{\uparrow} e^{\text{up}}_{u,n} + c^{\downarrow} e^{\text{dn}}_{u,n} \;\; (\texttt{Soft}), \qquad
w \left( e_{u,n} - e \right)^{2} \;\; (\texttt{Quad}).
```

A target ``e`` is a number or a profile over the network index, read at the last time step, and
[`scheduled_energy`](@ref) is one: a redispatch that is asked to leave a unit where the market
schedule leaves it ends on `Pin(scheduled_energy(data, u))`. `e_fin` is a `Pin` and stays as it was.
A `Cyclic` end is a `Pin` on `e_init`, taken when the unit is made so that a window of a roll, which
starts from another energy, does not move it. A unit has at most one end, `e_fin`, `Pin` or `Cyclic`,
and at most one price on it, `Value`, `Soft` or `Quad`; a price on a pinned energy has nothing to
price. A pin is a pin and not a floor: a target the ratings cannot reach makes the problem
infeasible, which is the honest answer to a question that has none. A `Floor` costs nothing below what
the unit would hold anyway. A condition that is not given writes nothing.

On the three steps with prices 10, 100 and 50 that a unit starting on 0.2 pu·h of its 0.5 sells in
the last two, the free unit ends empty at a cost of 4.0. A `Pin`, a `Cyclic` end or a `Floor` of 0.2
holds it to 0.2 for 14.0, a `Floor` of 0.1 for 9.0. A `Value` of 40 changes nothing and one of 60
keeps the 0.2 and charges 0.2 more at the price of 50, since it is worth more than it costs. A `Soft`
end with a price of 30 below its target of 0.2 lets the unit sell it, at 10.0 with the price in it, and
one of 80 does not, at 14.0.

```@docs
AbstractTerminal
Pin
Cyclic
Floor
Value
Soft
Quad
fnct_stor_final_energy!
variable_stor_terminal!
interior_state
```

!!! note "What a rolling horizon does with it"
    The last time step of a window is the last time step of the problem only for the window that
    closes it, so a roll releases a `Pin`, a `Cyclic` end and a `Floor` everywhere else, see
    [`interior_state`](@ref). Asking every window to arrive at one is stitching batches together
    by pinning both their ends to a guessed profile, which is what `initial_state` exists so as
    not to need.

    The trade is real: a lookahead too short to see why the energy is being kept will spend it.
    Eight steps with ten five times and a hundred three times, a unit that charges at ten and sells
    at a hundred, and a roll with no condition pay 26.2, 10.1 and 8.4 above perfect foresight at
    horizons 2, 3 and 4, and nothing at 5. A price on the end stays in every window, which is what
    it is for. Below what the peak pays after the losses it does not hold the unit back, and a
    `Value` of 90 here costs nothing at any of the four. Above it the unit keeps its energy to the
    end, and the roll pays for the steps it did not sell.

!!! note "A price on the end is not a cost"
    It shapes a decision and nobody pays it, so it is in the `"objective"` of a problem solved whole
    and not in what a rolling horizon reports, which is the cost of the steps it commits and of the
    periods it closes. A unit that keeps its energy at the end of a roll for a value is not credited
    for it. See [`terminal_cost`](@ref).

### Out of service

A storage unit is taken out of service with its `status`, which may vary over `:time` or over
`:contingency`, and not with a rating of zero. A unit out of service at a network index has no
variables, no rows and no entry in the solution there, and it holds the energy it had at the
last step it was in service, with no self-discharge:

```math
e_{u,n} = e_{u,n-1}, \qquad e_{u,n} = e^{0}_{u} \;\; \text{before the first step it is in service}
```

[`energy_at`](@ref) reads that. The balance of the step after a gap starts from it, and so do the
conditions on the end of the horizon, which are asked of the energy the unit holds at the last
step whether it is in service there or not: a `Pin` on a unit that is out at the last step is a pin
on what it left. A unit that is out for the whole of a trajectory, as when a contingency loses
it, has no state of charge there and is asked nothing. A step a unit is out of service at counts
nothing toward its cycle limit. A rolling horizon carries the
energy a unit holds at the last step a window commits, in service or not, so that a unit that is out
when a window ends is not refilled by the next.

On five steps with prices 10, 10, 100, 10 and 100, a unit that is out at steps 2 and 3 costs 28.216
against 10.432 in service, which is what ratings of zero over the two steps cost. A preventive unit
that is lost in a contingency is refused by a redispatch, since the setting it takes in the base case is
one it cannot take there; a redispatch that loses a storage unit poses the unit corrective, with an
`exception` of the [`Redispatch`](@ref) setup.

```@docs
energy_at
```

### The cycle limit

A unit that carries a finite `k_cycl_max` gets a row at every network index, over the time steps up to it
that fit in 24 hours:

```math
\sum_{m \in \mathcal{W}_{n}} \frac{\Delta t_{m}}{2}
    \left( \eta^{\text{c}}_{u} p^{\text{sc}}_{u,m} + p^{\text{sd}}_{u,m} / \eta^{\text{d}}_{u} \right)
    \le k^{\text{max}}_{u} \, e^{\text{max}}_{u,n} - \hat{e}_{u,n}
```

with the window ``\mathcal{W}_{n}`` running along `:time` back from ``n``, ``n`` included, for as long as the
steps fit in 24 hours, and every other coordinate held fixed. ``\hat{e}_{u,n}`` is what `e_cycl_init` counted of
the hours that reach back before the first step, which is nothing unless it was given or a rolling horizon
filled it. The limit holds over any 24 hours and not over a calendar day, which a unit could turn twice over
across midnight, so a grouping of `:time` into periods does not apply to it.

The right hand side is the energy the unit may count, `k_cycl_max` capacities, and a step counts half of
what goes into the store and half of what comes out of it: one capacity charged and discharged counts
one cycle, in a lossless unit and in a lossy one. A step the unit is out of service at counts nothing. In a
redispatch a preventive unit holds its schedule across the contingencies and has the rows of the base case
only; a corrective one has them in every contingency, see [`is_held`](@ref).

An infinite limit — the default — is the **absence** of a row rather than a row with an infinite right
hand side. A right hand side that the energy already counted has used up is taken as zero.

```@docs
fnct_stor_cycle!
```

!!! note "Why both sides"
    A unit that discharges what it holds draws `k_cycl_max · e_max / η_dch` out of its store, more than the
    limit says it delivers, and the same unit charging draws it from the grid before the loss. Counting
    both sides, half of each, is the one count that sees all of that and keeps a lossless cycle at one. It
    is also what makes charging and discharging in the same step, which the relaxation allows, spend the
    allowance twice. Charging and discharging are priced apart for the same reason.

!!! note "A roll carries what it has counted"
    [`solve_rolling_horizon`](@ref) hands the trailing 24 hours of the count from one window to the next
    through [`initial_state`](@ref), so that a unit does not get its allowance back at every window. A
    full unit with a limit of 0.1 pu·h that sells at 100 in the first of four steps sells 0.2 in all, rolled
    two steps at a time as well as whole, and not 0.2 again in the next window. Independent problems, such
    as the chunks of a pipeline run in separate processes, start with nothing counted unless `e_cycl_init`
    is given.

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
| turning a cycle | `c_cycl` | [`dispatch_cost`](@ref) and [`redispatch_cost`](@ref), once per network index |
| leaving a market schedule | `c_up`, `c_dn` | [`redispatch_cost`](@ref), once per network index |

The first two measure different wear and a unit may carry either or both: a
battery that discharges half its capacity twice pays for one cycle, while the
throughput price charges it for the whole of what it moved either way. All three
are also in `redispatch_cost`, because degradation does not care
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
