# Redispatch in the IVR formulation

The complete problem built by
`NetworkModel{RedispatchProblem, IVRFormulation}`. It is a nonconvex
quadratically constrained program, exactly as the
[optimal power flow](@ref "Optimal power flow in the IVR formulation") is:
nothing a redispatch adds is nonlinear.

## Variables

Everything an optimal power flow has, plus two non-negative volumes per
generator and per storage unit.

| symbol | key | index set | bounds |
|:-------|:----|:----------|:-------|
| ``v^{\text{r}}_{i}, v^{\text{i}}_{i}`` | `:vr`, `:vi` | ``i \in I`` | ``[-v^{\text{max}}_{i}, v^{\text{max}}_{i}]`` |
| ``c^{\text{r}}_{a}, c^{\text{i}}_{a}`` | `:cr`, `:ci` | ``a \in A`` | free |
| ``c^{\text{sr}}_{e}, c^{\text{si}}_{e}`` | `:csr`, `:csi` | ``e \in E^{\text{br}} \cup E^{\text{tf}}`` | free |
| ``v^{\text{tr}}_{e}, v^{\text{ti}}_{e}`` | `:vtr`, `:vti` | ``e \in E^{\text{tf}}`` | free |
| ``v^{\text{sr}}_{e}, v^{\text{si}}_{e}`` | `:vsr`, `:vsi` | ``e \in E^{\text{mw}}`` | free |
| ``t^{\text{r}}_{e}, t^{\text{i}}_{e}`` | `:tr`, `:ti` | ``e \in E^{\text{ps}}`` | from `ta_min`, `ta_max` |
| ``tm_{e}`` | `:tm` | tap changers | ``[tm^{\text{min}}_{e}, tm^{\text{max}}_{e}]`` |
| ``c^{\text{r}}_{u}, c^{\text{i}}_{u}`` | `:cru`, `:ciu` | ``u \in U`` | free |
| ``p^{\text{g}}_{u}, q^{\text{g}}_{u}`` | `:pg`, `:qg` | ``u \in U^{\text{g}}`` | the capability of the generator |
| ``p^{\uparrow}_{u}`` | `:pgup` | ``u \in U^{\text{g}}`` | ``[0, p^{\text{max}}_{u} - p^{\text{g,mkt}}_{u}]`` |
| ``p^{\downarrow}_{u}`` | `:pgdn` | ``u \in U^{\text{g}}`` | ``[0, p^{\text{g,mkt}}_{u} - p^{\text{min}}_{u}]`` |
| ``p^{\text{d}}_{u}`` | `:pdf` | ``u \in U^{\text{fl}}`` | ``[p^{\text{d,min}}_{u}, p^{\text{d,max}}_{u}]`` |
| ``p^{\text{sc}}_{u}, p^{\text{sd}}_{u}`` | `:psc`, `:psd` | ``u \in U^{\text{s}}`` | ``[0, \cdot^{\text{max}}_{u}]`` |
| ``e_{u}`` | `:es` | ``u \in U^{\text{s}}`` | ``[0, e^{\text{max}}_{u}]`` |
| ``q^{\text{s}}_{u}`` | `:qs` | ``u \in U^{\text{s}}`` | ``[q^{\text{min}}_{u}, q^{\text{max}}_{u}]`` |
| ``p^{\uparrow}_{u}`` | `:psup` | ``u \in U^{\text{s}}`` | ``[0, p^{\text{sd,max}}_{u} - p^{\text{s}}_{u}]`` |
| ``p^{\downarrow}_{u}`` | `:psdn` | ``u \in U^{\text{s}}`` | ``[0, p^{\text{s}}_{u} + p^{\text{sc,max}}_{u}]`` |

Each upper bound is clipped at zero, so a market schedule that lies outside the
capability can still be brought back into it rather than making the problem
infeasible.

## Objective

```math
\min \quad \sum_{n \in \mathcal{N}} w_{n} \sum_{u \in U^{\text{g}} \cup U^{\text{s}}}
    \left( c^{\uparrow}_{u} p^{\uparrow}_{u,n} + c^{\downarrow}_{u} p^{\downarrow}_{u,n} \right)
```

Linear in the volumes, whatever the degree of the generation cost polynomial:
that polynomial no longer enters the objective, only — through
[`redispatch_price`](@ref) — the prices it stands in for.

## Constraints

### At the nodes

Identical to the
[optimal power flow](@ref "Optimal power flow in the IVR formulation"): the
reference angle, the voltage magnitude limits, and the current balance.

### At the edges

The physics are identical, and so are the angle difference limits and the phase
shifter ratio. The **rating** is the one thing that changes, and only in where
it applies, ``\forall e \in E^{\text{mon}}``, per terminal ``a`` at node ``i``:

```math
\left((v^{\text{r}}_{i})^2 + (v^{\text{i}}_{i})^2\right)
\left((c^{\text{r}}_{a})^2 + (c^{\text{i}}_{a})^2\right) \le (s^{\text{max}}_{e})^2
```

with ``E^{\text{mon}} \subseteq E`` the monitored edges, every edge by default.

### At the units

The power-against-current relations are those of an optimal power flow, with the
split added on top, ``\forall u \in U^{\text{g}}``:

```math
p^{\text{g}}_{u} = p^{\text{g,mkt}}_{u} + p^{\uparrow}_{u} - p^{\downarrow}_{u}
```

and ``\forall u \in U^{\text{s}}``:

```math
p^{\text{sd}}_{u} - p^{\text{sc}}_{u} = p^{\text{s}}_{u} + p^{\uparrow}_{u} - p^{\downarrow}_{u}
```

Both are affine, which is why a redispatch is no harder to solve than the
optimal power flow underneath it.

### Across network indices

The state of charge of a storage unit and the energy of a flexible load, exactly
as in an optimal power flow, plus one equality per preventive measure per
contingency:

```math
x_{c,n} = x_{c,n^{0}} \quad \forall n, \; \forall x \in X^{\text{prev}}_{c}
```

with ``n^{0}`` the base case of ``n``. Here ``X^{\text{prev}}_{c}`` is
``(p^{\uparrow}, p^{\downarrow})`` for a generator,
``(p^{\text{sc}}, p^{\text{sd}}, p^{\uparrow}, p^{\downarrow})`` for a storage
unit, ``(t^{\text{r}}, t^{\text{i}})`` for a phase shifter and ``(tm)`` for a tap
changer — see [`redispatch_controls`](@ref).

## Model class and size

Nonconvex and quadratically constrained, as the optimal power flow is, with a
*linear* objective in place of a quadratic one. Needs a nonlinear solver.

```julia
using NetworkModelBuilder, Ipopt

result = solve_rd("case5.m", IVRFormulation, Ipopt.Optimizer;
                  redispatch = Redispatch(; monitored = [7]))
```
