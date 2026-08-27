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
| ``p^{\text{sc,max}}_{u}`` | `charge_rating` | charge power limit | pu |
| ``p^{\text{sd,max}}_{u}`` | `discharge_rating` | discharge power limit | pu |
| ``\eta^{\text{c}}_{u}`` | `charge_efficiency` | one-way charge efficiency, in ``(0,1]`` | |
| ``\eta^{\text{d}}_{u}`` | `discharge_efficiency` | one-way discharge efficiency, in ``(0,1]`` | |
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
                 - p^{\text{sd}}_{u,n} / \eta^{\text{d}}_{u} \right)
```

with the first step of each horizon starting from ``e^{0}_{u}``. The horizon runs
along `:time` with every other coordinate held fixed, so a problem with a
contingency dimension gives each contingency its own trajectory from the same
starting energy.

!!! note "Charging and discharging at once"
    Nothing forbids ``p^{\text{sc}}_{u}`` and ``p^{\text{sd}}_{u}`` from both
    being non-zero. Where the efficiencies are below one that is never worth
    doing, and forbidding it outright would need a binary variable and hence a
    different class of solver.

!!! note "It needs a time dimension"
    Like a [`FlexibleLoad`](@ref), a storage unit couples network indices along
    `:time` and says so when the problem has no such dimension.
