# Load flow

A load flow asks where the network settles when every injection is given. It has
no objective: either the network admits an operating point or it does not, and
there is nothing to choose between the points it admits.

```@docs
LoadFlowProblem
```

## What is fixed and what is free

The freedom is distributed by the role of each node.

| node | voltage | generator active power | generator reactive power |
|:-----|:--------|:-----------------------|:-------------------------|
| ``I^{\text{ref}}`` | fixed, magnitude and angle | free | free |
| ``I^{\text{pv}}`` | magnitude fixed | fixed at its setpoint | free |
| ``I^{\text{pq}}`` | free | fixed at its setpoint | fixed at its setpoint |

The reference node is what closes the system: it absorbs the mismatch between
what the rest of the network injects and what it consumes, losses included, which
is why its generator is free in both quantities and its voltage is not.

!!! note "Several generators at one node"
    Where a `PV` or reference node carries more than one generator, the split of
    the free quantity between them is not determined by the model. The solver
    returns one of the admissible splits; do not read meaning into which.

## Everything controllable holds its setpoint

A load flow has no freedom to give, so every component that is a *control*
elsewhere is a constant here:

| component | in a load flow |
|:----------|:---------------|
| [`PhaseShifter`](@ref) | holds `ta` |
| [`TapChanger`](@ref) | holds `tm` |
| [`FlexibleLoad`](@ref) | takes `pd_nominal`, exactly as a [`FixedLoad`](@ref) |
| [`Storage`](@ref) | holds the injection setpoint `ps`, `qs` |

Because nothing is free across network indices, the coupling constraints add
nothing: a load flow over 24 hours is 24 independent problems that happen to
share a JuMP model.

## Operating limits are not imposed

No voltage magnitude limit, no thermal rating, no generator capability. A load
flow reports where the network settles, and it is for the reader to notice that
the answer sits outside a limit — that is the point of running one. A problem
that must respect its limits is an [Optimal power flow](@ref).

## In each formulation

- [In the IVR formulation](@ref "Load flow in the IVR formulation") — exact, nonconvex, quadratic
- [In the LPF formulation](@ref "Load flow in the LPF formulation") — linearized, a linear system

```@docs
solve_lf
```
