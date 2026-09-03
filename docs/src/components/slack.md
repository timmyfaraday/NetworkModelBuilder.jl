# Slack units

A slack unit is a unit ``(u, i)`` that relaxes the balance of its node at a
price. Where a generator says what it can deliver and a load says what it takes,
a slack unit says what it costs to leave the two unmatched.

```@docs
AbstractSlackUnit
EnergyNotServed
Spill
slack_sign
```

!!! note "They are instantiated, not conjured"
    Some tools create a slack unit at every node implicitly, from a global price
    with per-node overrides. Here they are ordinary units, put in the network by
    whatever builds it. Two reasons: the solution has to report what was not
    served separately from what was, and a unit that appears without anything
    asking for it is exactly the hidden state the package keeps out of its data
    model. A helper that decorates a network with a slack unit at every node is a
    convention rather than physics, and belongs in whatever adapter has that
    convention.

## Parameters

| symbol | field | description | unit |
|:-------|:------|:------------|:-----|
| | `id`, `name`, `node` | identifier, label, node | |
| ``p^{\text{sl,max}}_{u}`` | `pmax` | the most that may be relaxed | pu |
| ``c_{u}`` | `cost` | the price of one per unit **injected** | currency/pu/h |
| | `status` | in service | |

``\sigma_{u}``, the sign of the unit, is not a field: it is
[`slack_sign`](@ref), ``+1`` for an [`EnergyNotServed`](@ref) and ``-1`` for a
[`Spill`](@ref).

## The sign of the price

Both types price the *injection*, which is what makes the two comparable.
Running an [`EnergyNotServed`](@ref) and a [`Spill`](@ref) at the same node by
the same amount leaves the balance where it was and costs
``c^{\text{ens}} - c^{\text{sp}}`` per per unit; where that is negative the pair
is a money pump and the dispatch is unbounded. The invariant is therefore

```math
c^{\text{ens}}_{u} \ge c^{\text{sp}}_{u}
```

at every node — and neither constructor can check it, since neither unit knows
about the other. Factoring it through zero puts the check back where the package
puts this kind of check: an `EnergyNotServed` must have ``c_{u} \ge 0`` and a
`Spill` must have ``c_{u} \le 0``, and the pair is then arbitrage free at every
node without a single node ever being looked at.

Read against the volume rather than the injection, the defaults are a charge of
``5000`` per per unit unserved and of ``500`` per per unit spilled.

## Variables

### In dispatch problems, both formulations

| symbol | key | index | description | unit |
|:-------|:----|:------|:------------|:-----|
| ``p^{\text{sl}}_{u}`` | `:psl` | unit | the volume relaxed, ``\ge 0`` | pu |

One variable serves both types, and it is always the *amount* of the relaxation
rather than a signed injection. A power flow creates none: there is nothing to
relax in a problem that decides nothing, and the unit sits idle at zero.

A slack unit exchanges no reactive power in either formulation. What it stands
for is energy that was not served or not placed, and neither has a reactive
counterpart.

## Constraints

The injection, against the current:

```math
v^{\text{r}}_{i} c^{\text{r}}_{u} + v^{\text{i}}_{i} c^{\text{i}}_{u}
= \sigma_{u} p^{\text{sl}}_{u},
\qquad
v^{\text{i}}_{i} c^{\text{r}}_{u} - v^{\text{r}}_{i} c^{\text{i}}_{u} = 0 .
```

### In the `LPFFormulation`

```math
p_{u} = \sigma_{u} p^{\text{sl}}_{u} .
```

## Cost

```@docs
slack_cost
```

```math
c_{u} \, \sigma_{u} \, p^{\text{sl}}_{u}
```

which is a non-negative charge per unit of volume for both types. It enters an
[`OptimalPowerFlowProblem`](@ref) through [`dispatch_cost`](@ref) and a
[`RedispatchProblem`](@ref) through [`redispatch_cost`](@ref), with the same
expression in both: a slack unit has no market schedule to move away from, so
every per unit it takes is the intervention itself.

## What they replace

A bounded, priced slack on the node balance is what these are, whatever else it
is called. A "wiggle room" on the balance, a per-node curtailment variable, a
penalty term added to the objective by hand — all of them are an
`EnergyNotServed` with a tight `pmax` and a price, and none of them needs a
mechanism of its own.
