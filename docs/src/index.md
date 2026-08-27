# NetworkModelBuilder.jl

NetworkModelBuilder.jl builds optimization models for power system problems.

A model is a [`NetworkModel{P,F}`](@ref), parameterized by a **problem type**
`P` and a **formulation type** `F`. The problem type decides *which question is
asked of the network* — which degrees of freedom are free, which are fixed by a
setpoint, what is minimized. The formulation type decides *in which variables
the physics are written* — rectangular or polar voltage, current or power flow.
Every variable, constraint and objective in the package is a method that
dispatches on the pair.

The network itself is an **extended graph** `(I, E, U)` of nodes, edges and
units, where an edge connects an ordered list of nodes rather than exactly two,
and every unit injects through the same variable pair. All the dimensions of a
problem — time, contingencies, harmonics, scenarios — are aggregated under a
single **network index** `n`.

```julia
using NetworkModelBuilder, Ipopt

result = solve_lf("case14.m", IVRFormulation, Ipopt.Optimizer)
print_summary(result)
```

## Where to start

| If you want to know | Read |
|:--------------------|:-----|
| how a network is represented | [The extended graph](@ref) |
| how time, contingencies and scenarios fit together | [The network index](@ref) |
| what `P` and `F` select | [Problems and formulations](@ref) |
| what components exist and how they relate | [The hierarchy](@ref) |
| the parameters, variables and constraints of one component | its page under **Components** |
| how to add a component, a formulation or a problem | [Extending the package](@ref) |

## Notation

Throughout the documentation, a **subscript is an index** and a **superscript is
a descriptor**: ``v^{\text{r}}_{i}`` is the real part of the voltage at node
``i``, and ``p^{\text{g}}_{u,n}`` is the active power of generator ``u`` at
network index ``n``. Quantities are in per unit on the system power base unless
stated otherwise, and angles are in radians.

| symbol | meaning |
|:-------|:--------|
| ``i \in I`` | a node |
| ``e \in E`` | an edge |
| ``u \in U`` | a unit |
| ``a = (e, t, i)`` | an arc: terminal ``t`` of edge ``e``, at node ``i`` |
| ``A(i)`` | the arcs incident to node ``i`` |
| ``U(i)`` | the units connected to node ``i`` |
| ``n`` | a network index |
| ``\Delta t_{n}`` | the duration of the time step at network index ``n`` |

## License

BSD 3-Clause.
