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
|:-|:-------------------|:-----------|
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
| [`FlexibleLoad`](@ref) | no | its demand, subject to its energy balance |

A free control is taken first, because it is free: on a meshed network a phase
shifter that can steer flow off a congested corridor relieves it at no cost at
all, and the costly measures only start once the free ones run out.

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

Rolling that window forward is the natural next step and is not implemented:
it would rebuild the problem per step from the previous step's `energy_initial`
and a shifted schedule, which needs nothing this problem does not already have.

## In each formulation

- [In the IVR formulation](@ref "Redispatch in the IVR formulation") — exact, nonconvex
- [In the LPF formulation](@ref "Redispatch in the LPF formulation") — linearized, a linear program

```@docs
solve_rd
```
