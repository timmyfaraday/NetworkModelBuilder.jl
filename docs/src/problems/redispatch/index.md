# Redispatch

A redispatch asks the cheapest way to make a dispatch that has *already been
decided* — typically one a market cleared without looking at the network — one
the network can actually carry.

```@docs
RedispatchProblem
```

## What changes from an optimal power flow

Nothing on the network side. The physics, the operating limits and the ratings
are those of an [Optimal power flow](@ref), and the builder is the same list of
calls with one line added. A redispatch *is* a dispatch problem; the network
does not care why the dispatch is being chosen.

| | optimal power flow | redispatch |
|:--|:-------------------|:-----------|
| generator | free within its capability | free within its capability, split into the market dispatch and the volumes moved |
| storage | free within its ratings | the same, split against its market schedule |
| edge rating | on every edge | on the monitored edges |
| contingencies | each state solved on its own | each measure preventive or corrective |
| objective | the cost of the dispatch | the price of the volumes moved |

## The market dispatch is the setpoint

The dispatch a redispatch moves away from is the **setpoint the component
already carries** — `pg` on a [`Generator`](@ref), `ps` on a
[`Storage`](@ref). No second field holds it.

That is not a shortcut. `pg` has always meant *the operating point this unit was
given*: a [Load flow](@ref) holds a generator at it, and a redispatch prices the
distance from it. A Matpower case is therefore a redispatch problem as it
stands, against the dispatch the file was written with, and a market schedule
over a horizon is a `pg` that varies over `:time`:

```julia
mn = set_dimension(data, Dimension(:time => 24); apply! = function (net, dim)
    for (u, g) in net.unit
        g isa Generator || continue
        net.unit[u] = Generator(; id = g.id, node = g.node, pmin = g.pmin, pmax = g.pmax,
                                qmin = g.qmin, qmax = g.qmax, cost = g.cost,
                                pg = nw_vector(dim, :time, market_schedule[u]))
    end
end)
```

## The volumes, and what they cost

Each generator and storage unit splits its dispatch into the schedule it was
given and what it moved:

```math
p^{\text{g}}_{u} = p^{\text{g,mkt}}_{u} + p^{\uparrow}_{u} - p^{\downarrow}_{u},
\qquad
p^{\uparrow}_{u}, p^{\downarrow}_{u} \ge 0
```

and only the volumes are priced:

```math
\min \quad \sum_{n \in \mathcal{N}} w_{n} \sum_{u}
    \left( c^{\uparrow}_{u} p^{\uparrow}_{u} + c^{\downarrow}_{u} p^{\downarrow}_{u} \right)
```

The two are separate non-negative variables because they are priced separately.
Nothing forbids both from being non-zero at once, and with positive prices on
both it is never worth doing — but with a price of **zero** on both, only their
difference is determined, so read a free measure as ``p^{\uparrow} -
p^{\downarrow}`` rather than as either one.

```@docs
redispatch_price
marginal_cost
redispatch_cost
objective_redispatch_cost
```

## Costly and non-costly measures

A measure is non-costly exactly when it has no [`redispatch_cost`](@ref) method.
Nothing else marks it, and nothing has to.

| measure | costly? | what moves |
|:--------|:--------|:-----------|
| [`Generator`](@ref) | yes, at `cost_up` and `cost_dn` | its active power |
| [`Storage`](@ref) | yes, at `cost_up` and `cost_dn`, both zero by default | what it charges and discharges, over the whole window |
| [`PhaseShifter`](@ref) | no | its ratio angle, between `ta_min` and `ta_max` |
| [`TapChanger`](@ref) | no | its ratio magnitude — in the IVR formulation only |
| [`DCLink`](@ref) | at `cost`, zero by default | its transfer, within its rating |
| [`FlexibleLoad`](@ref) | no | its demand, subject to its energy balance |

A free control is taken first, because it is free: on a meshed network a phase
shifter that can steer flow off a congested corridor relieves it at no cost at
all, and the costly measures only start once the free ones run out. A
[`DCLink`](@ref) left at its default `cost` is the direct current counterpart —
it carries whatever the congested branch cannot, for nothing.

!!! note "A flexible load shifts for free"
    A [`FlexibleLoad`](@ref) behaves here as it does in an optimal power flow:
    its demand is a decision between `pd_min` and `pd_max`, tied together by an
    energy balance, and nothing prices the shift. Where load flexibility is
    meant to be procured rather than assumed, bound it through `pd_min` and
    `pd_max`, or give the type a [`redispatch_cost`](@ref) method of its own.

## Monitored edges

The rating is enforced on the edges the problem watches, which need not be all
of them:

```julia
solve_rd(data, LPFFormulation, HiGHS.Optimizer;
         redispatch = Redispatch(; monitored = [3, 7, 11]))
```

Only the *rating* follows the monitored set. The angle difference limits of an
edge hold whether it is watched or not: those are a stability limit, not
congestion.

```@docs
is_monitored
monitored_edges
```

!!! tip "An emergency rating needs no new field"
    Post-contingency limits are usually looser than the base case ones. There is
    no `rate_b` here, and none is needed: make `rate_a` a
    [`NetworkVector`](@ref) over the `:contingency` dimension and each state gets
    the rating it should have.

## A rating you can price

A rating is a bound the solver may not cross, which means a congestion nothing
can relieve has no answer at all — the solve fails, and the volume that could
not be relieved, which is usually the thing worth reporting, is not in the
result because there is no result.

Give the setup an [`OverloadPrice`](@ref) and the rating becomes a quantity the
problem pays for instead:

```julia
solve_rd(data, LPFFormulation, HiGHS.Optimizer;
         redispatch = Redispatch(; overload = 500.0))
```

Every monitored edge with a finite rating gets one non-negative overload
variable, `o_e`, shared by its terminals, and the objective pays `per_energy`
for it at every network index. An infeasible congestion becomes an expensive
one, and `solution["edge"]["e"]["overload"]` reports the excess on every edge
that was watched — including the ones the answer left at zero, since an edge
missing from the result reads as *not asked* rather than *asked and clear*.

| | hard rating | priced rating |
|:-------------------|:---------------------------------|:-----------------------------------|
| `overload`         | `nothing`, the default           | an [`OverloadPrice`](@ref)         |
| linearized         | `-sᵐᵃˣ ≤ pₐ ≤ sᵐᵃˣ`              | `pₐ - oₑ ≤ sᵐᵃˣ`, `-pₐ - oₑ ≤ sᵐᵃˣ` |
| current based      | `\|sₐ\|² ≤ (sᵐᵃˣ)²`                | `\|sₐ\|² ≤ (sᵐᵃˣ + oₑ)²`             |
| unrelievable       | infeasible                       | priced                             |

The two are different rows rather than one row relaxed, and they are written
under different keys. A range constraint takes constant bounds, so the
linearized rating cannot hold a variable and becomes the pair of one-sided rows
above — exact without a binary, because the objective pays for `oₑ` and so never
lifts it past what one of the two rows requires. This is also why there is no
"infinite price": a hard rating is a shape the model has, not a number a solver
can be handed.

The price is on the setup rather than on the edge for the same reason
`monitored` is. A conductor has a rating; what it costs to run past it is a
statement about how the question is being asked, and the same network priced two
ways is two questions about one set of data.

```@docs
OverloadPrice
overload_price
overload_cost
variable_edge_overload!
```

## A charge on the peak

`per_energy` prices every per unit of overload the same, whenever it happens. An
overload that is small and constant and one that is brief and severe then cost
the same, and they are not the same event: the second is what a rating exists to
prevent. `per_peak` is what says so — a charge on the **worst** overload of a
period rather than on each index of it.

```julia
dim = Dimension(:time => 8760)
dim_meta(dim, :time)[:period_length] = 24        # the periods are days

solve_rd(set_dimension(data, dim), LPFFormulation, HiGHS.Optimizer;
         redispatch = Redispatch(; overload = OverloadPrice(; per_energy = 500.0,
                                                              per_peak   = 15_000.0)))
```

Every monitored edge gets one non-negative peak per period, `ô_e`, bounded from
below by its overload at each index of that period and priced from above, so the
objective pulls it down onto the largest of them and no binary is needed to make
the maximum tight. The period is [`period_ids`](@ref): the `:time` coordinates
grouped with the index, every other coordinate held fixed, so a problem posed
over contingencies gets one peak per period *per contingency*. With no grouping
declared there is one period spanning the horizon, and the charge is on the
worst overload of the problem.

```@docs
constraint_overload_peak
solution_overload_peak
```

### Where the charge is paid

A peak belongs to no single network index, and [`network_cost`](@ref) has one
term per index. It is paid through [`horizon_cost`](@ref) instead, a second term
[`minimize_network_cost`](@ref) adds unweighted:

```math
\min\quad \sum_{n} w_{n} \, c_{n} \;+\; c^{\text{h}} .
```

The weight it does carry is [`period_weight`](@ref), which is
[`network_weight`](@ref) with `:time` left out. Both halves of that matter. The
duration of a step is dropped because a peak is a power and not an energy —
weighting it by an hour would make a day of quarter-hours cost a quarter of what
a day of hours costs for the same worst flow. The probability of a contingency
is kept because a peak reached only in a contingency is expected to cost what it
costs times how likely that contingency is, which is the same argument
[`default_weight`](@ref) makes for every other cost.

### What a roll reports

A window models more indices than it commits, so a peak over a period longer
than the commit step belongs to no window cleanly.
[`solve_rolling_horizon`](@ref) charges a period exactly when a window both
**saw it whole** and **committed it whole**, and charges it nothing otherwise:

| `horizon` | `step` | `period_length` | what the roll reports |
|:----------|:-------|:----------------|:----------------------|
| 48        | 24     | 24              | every day, once, exactly |
| 24        | 1      | 24              | nothing, with a warning  |
| 24        | 24     | 24              | every day, once, exactly |

Prorating the alternative would be inventing a number: a peak is not a rate and
does not divide into hours. Charging it in the window that closes the period
would be worse still, since that window may hold only the last hour of the
period and its "peak" would be that hour's overload. So a roll whose windows
never close a period reports the peak charge nowhere, says so once, and puts
`horizon["closed"]` — the number of periods it did charge — in the result. Give
it a `horizon` of at least one period and a `step` that closes one.

## Contingencies, preventively and correctively

Give the problem a `:contingency` dimension and it asks the same question of
every state at once. Each state is an outage expressed as a `status` that varies
over that dimension, which is all the extended graph needs to derive a different
topology per state — see [The network index](@ref).

What is then genuinely new is *when* a measure is decided:

- a **preventive** measure takes one setting that has to serve every
  contingency. It is set before anything happens and cannot be changed once it
  has, so it is paid for in states that never occur.
- a **corrective** measure is free per contingency. It is what the operator does
  *after* the outage, and it is the cheaper of the two precisely because it is
  only ever applied in the state it was chosen for.

The whole difference in the model is one family of equalities.

```@docs
Redispatch
redispatch_setup
constraint_redispatch_control
redispatch_controls
control_mode
is_preventive
is_corrective
```

The first `:contingency` coordinate is the base case, and every preventive
measure is tied back to it. A measure at a network index where its component is
out of service is skipped, so a generator that is itself the contingency
constrains nothing.

Every network index enters the objective, contingencies included, so the
objective is an **expectation** over the states rather than a sum of them. A
`:contingency` coordinate weighs `1/N` unless the data says otherwise — see
[`default_weight`](@ref) — which is what puts the two control modes on the same
footing: under uniform probabilities a preventive measure, being one setting
that serves all `N` states, is paid for exactly once, and a corrective one only
in the state it belongs to.

Contingencies are rarely equally likely, so give the coordinates the
probabilities you have:

```julia
Dimension(:time => 24,
          :contingency => [Dict{Symbol,Any}(:weight => p) for p in (0.97, 0.02, 0.01)])
```

Nothing requires them to sum to one — the objective is then scaled, not wrong —
but a set that does is what makes it an expected cost in the units the prices
are in.

## A time window

Storage is what makes the window necessary: what a battery can do in one hour
depends on what it did in the others, so a redispatch that uses storage is a
horizon rather than a snapshot. Give the problem a `:time` dimension and the
state of charge is carried from step to step, and a
[`FlexibleLoad`](@ref) keeps its energy over it; without one, both say so rather
than being silently wrong.

Each contingency gets its own trajectory from the same starting energy, because
the horizon runs along `:time` with every other coordinate held fixed. A
preventive battery then holds the same trajectory in every state, which is what
[`redispatch_controls`](@ref) ties for it.

## Rolling the window forward

An operator does not decide the day at once from a schedule known in full. The
day is decided step by step against a forecast that reaches only so far, and by
the time the far end of that forecast arrives it has changed. Give
[`solve_rd`](@ref) a `horizon` and that is what it does:

```julia
result = solve_rd(mn, LPFFormulation, HiGHS.Optimizer; horizon = 6, step = 1)
```

Each window is a complete redispatch over six steps — same physics, same limits,
same objective — of which the first step is **committed** and the rest is thrown
away. The next window starts one step later and sees one step further.

```@docs
solve_rolling_horizon
```

Two things make the sequence a single trajectory rather than a set of unrelated
problems:

```@docs
initial_state
```

[`window`](@ref) cuts one step's problem out of the whole, slicing the profile of
every component and re-deriving the topology, so a window is an ordinary
[`NetworkData`](@ref) that knows nothing about being one — see
[Cutting a window out](@ref). [`initial_state`](@ref) is what survives the cut:
it draws the line between a
*decision*, which each window makes afresh, and a *state*, which the previous
window already fixed. A [`Storage`](@ref) unit carries its state of charge and
has a method; nothing else in the package carries anything.

### What the lookahead buys

On a four-step problem whose expensive generator is priced `10, 10, 10, 200`,
with a battery holding `0.4` behind the constraint:

| lookahead | cost | what the battery does |
|:----------|-----:|:----------------------|
| one step | 131 | spends everything in the first, cheapest hour |
| two steps | 105 | |
| three steps | 81 | |
| four steps — full information | 55 | saves everything for the last, dear hour |

Seeing one step ahead is not wrong, it is *myopic*: the battery is free, so the
window spends it on the congestion it can see, and the expensive hour it cannot
see arrives with an empty battery. No window ever beats the full information
optimum, because none of them knows more. The test suite asserts both endpoints
and that the sequence never improves on the last.

### What is carried, and from where

The state is read at the last committed step of the **base case** — the first
coordinate of every dimension other than `:time`. The windows form one
trajectory through time, and only one of the contingencies is the world that
actually happened; a preventive measure leaves the same state behind in every
state of the world anyway, a corrective one does not, and the base case is the
one that is real.

!!! warning "A flexible load keeps its energy per window"
    The energy balance of a [`FlexibleLoad`](@ref) holds over the horizon it is
    posed on, so in a rolling solve it holds over each **window**. With the
    default `energy = NaN` that is right — the target is the nominal energy of
    the window itself — but an `energy` given explicitly is read as a per-window
    target, not a per-day one. A load that must hit a daily figure needs its own
    [`initial_state`](@ref) method to carry down what it has already taken.

### Making it fast

A year at `horizon = 24, step = 4` is 2190 windows. Three choices matter, and
together they are worth about a factor of three:

| | wall | what changed |
|:--|-----:|:--|
| Ipopt, cached model | 17.5 s | the starting point |
| HiGHS, cached model | 8.1 s | an LP solver for a linear program |
| HiGHS, direct model | 7.3 s | `new_model` skips the copy MOI keeps |
| **HiGHS, direct model, `reuse`** | **5.7 s** | one model, updated rather than rebuilt |

**Take an LP solver first.** Under a [`LPFFormulation`](@ref) a redispatch is a
linear program, and an interior point method is the wrong tool for one: it
halves the run to give it to HiGHS, and it converges cleanly where Ipopt left
one window in 2190 short of tolerance and dragged the status of the whole year
down with it.

**Then a direct model**, which skips the layer that keeps a copy of the problem
before handing it over — a copy a roll makes once per window and throws away
with it:

```julia
solve_rd(mn, LPFFormulation, HiGHS.Optimizer; horizon = 24, step = 4, reuse = true,
         new_model = () -> (m = JuMP.direct_model(HiGHS.Optimizer());
                            JuMP.set_silent(m); m))
```

`new_model` is a *constructor* rather than a model, because each window that is
built needs one of its own; handing the roll a `jump_model` would give them all
the same one and is refused rather than silently shared.

**Then `reuse`.** A window's model is very nearly the one the next window needs,
so it is built once and updated after that, wherever [`same_structure`](@ref)
says the two windows have the same shape. On the year above that is 2184 of the
2190 windows; the six that are built are the first and the short ones at the
end.

It saves the building and not the solving. Splitting the year's 5.5 s in two:

| | building | solving |
|:--|--:|--:|
| rebuilt every window | 5.7 s | 1.7 s |
| `reuse` | **3.8 s** | 1.7 s |

A solver does not carry a basis across rows that have been rewritten, so an
updated problem is re-solved much as a fresh one is. What addresses the solving
is `warm_start`, and it is a separate question.

### Should `warm_start` be on?

Handing the next window the overlap of the last window's answer takes 15–25% off
the solve, whichever formulation is being built. Whether that is worth the
bookkeeping depends on how much of the run the solve is:

| formulation | solver | `reuse` | `warm_start` | wall |
|:---|:---|:---|:---|---:|
| LPF | HiGHS | yes | no | **5.8 s** |
| LPF | HiGHS | yes | yes | 6.0 s |
| IVR | Ipopt | yes | no | 3.6 s |
| IVR | Ipopt | yes | yes | **2.9 s** |

Under a [`LPFFormulation`](@ref) the model is a linear program and an LP solver
disposes of it in well under a second per thousand windows, so gathering the
overlap still costs a little more than it saves — leave it off. Under an
[`IVRFormulation`](@ref) the solve is most of the run and the same hand-over is
worth about a fifth of the whole — turn it on.

With `reuse` the hand-over is much the cheaper of its two forms: the windows are
one model rather than two, so the variable the next window will call step `j` is
the variable this one called step `j + step`, and handing over is a shift within
the model rather than a dictionary carried between models.

The two compose: `warm_start` acts on the solving, `reuse` on the building, and
on the nonconvex formulation both together were both the fastest combination and
the one that reached the same solution a cold roll did, where `warm_start` alone
had settled on a slightly worse local optimum. Read the warning on
[`solve_rolling_horizon`](@ref) before relying on that.

### Reading the result

The result is shaped like any other and keyed by the network indices of the
original problem, so [`nw_solution`](@ref) reaches a step by the index it has
there. Its `"objective"` is the cost of the **committed** steps only; a window's
own objective prices its lookahead too, and is reported apart under
`"horizon"`, with what each window covered and committed.

The roll is not redispatch-specific — [`solve_rolling_horizon`](@ref) takes the
problem type as an argument and rolls an [Optimal power flow](@ref) just as
readily. All it needs from a problem is [`network_cost`](@ref), which is how it
prices a committed step without knowing what it is rolling.

## In each formulation

- [In the IVR formulation](@ref "Redispatch in the IVR formulation") — exact, nonconvex
- [In the LPF formulation](@ref "Redispatch in the LPF formulation") — linearized, a linear program

```@docs
solve_rd
```
