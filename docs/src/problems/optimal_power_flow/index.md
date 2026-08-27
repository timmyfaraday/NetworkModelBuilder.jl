# Optimal power flow

An optimal power flow asks for the cheapest dispatch the network admits. Where a
[Load flow](@ref) has one answer, this has a best one, and the constraints that a
load flow leaves out are exactly what makes the question non-trivial.

```@docs
OptimalPowerFlowProblem
```

## What changes from a load flow

The builder is almost the same. The difference lives in the methods those calls
resolve to.

| | load flow | optimal power flow |
|:-|:----------|:-------------------|
| reference node | complex voltage fixed | angle fixed, magnitude free |
| `PV` node | magnitude at its setpoint | no setpoint |
| voltage magnitude | unbounded | between `vmin` and `vmax` |
| generator | holds its setpoint | free within its capability |
| edge | physics only | physics, rating, angle difference |
| controls | hold their setpoints | free within their limits |
| objective | zero | the generation cost |

Two calls appear in this builder that do not appear in a load flow —
[`constraint_node_voltage_limits`](@ref) and
[`constraint_edge_limits`](@ref) — and one disappears,
[`constraint_node_voltage_setpoint`](@ref).

## Everything controllable becomes a decision

| component | in an optimal power flow |
|:----------|:-------------------------|
| [`PhaseShifter`](@ref) | its ratio angle is free between `ta_min` and `ta_max` |
| [`TapChanger`](@ref) | its ratio magnitude is free between `tm_min` and `tm_max` — in the IVR formulation only, see below |
| [`FlexibleLoad`](@ref) | its demand is free between `pd_min` and `pd_max`, subject to an energy balance |
| [`Storage`](@ref) | it charges and discharges within its ratings, subject to its state of charge |

!!! note "A tap changer is inert in the linearized formulation"
    With every voltage magnitude equal to one there is nothing for a ratio
    magnitude to change, so a [`TapChanger`](@ref) is solved as an ordinary
    transformer under [`LPFFormulation`](@ref). A phase shifter is unaffected —
    the ratio *angle* survives the linearization.

## Constraints that span network indices

A [`Storage`](@ref) unit and a [`FlexibleLoad`](@ref) tie one network index to
another, so an optimal power flow over a horizon is genuinely one problem rather
than a stack of independent ones. Both require the problem to have a `:time`
dimension and say so when it has none.

Without them, and without any other coupling, the objective over ``\mathcal{N}``
is simply the sum of the separate problems — which the test suite checks.

## The objective

```math
\min \quad \sum_{n \in \mathcal{N}} w_{n}
           \sum_{u \in U^{\text{g}}} \sum_{k} c_{u,k} \, (p^{\text{g}}_{u,n})^{k-1}
```

with ``w_{n}`` the weight of network index ``n``, see [`network_weight`](@ref).
Setting it to the duration of a time step turns the objective into an energy
cost; to the probability of a scenario, into an expected cost; to the product,
into both.

The cost is a polynomial in the active power alone. Where its coefficients are
zero above the quadratic term — which is what a Matpower file writes for a
quadratic cost — the objective is quadratic, and the model stays in the class its
constraints put it in.

## In each formulation

- [In the IVR formulation](@ref "Optimal power flow in the IVR formulation") — exact, nonconvex
- [In the LPF formulation](@ref "Optimal power flow in the LPF formulation") — linearized, a quadratic program

```@docs
solve_opf
```
