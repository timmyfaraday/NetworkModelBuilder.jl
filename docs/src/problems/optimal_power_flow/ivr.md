# Optimal power flow in the IVR formulation

The complete problem built by
`NetworkModel{OptimalPowerFlowProblem, IVRFormulation}`. It is a nonconvex
quadratically constrained program.

## Variables

Everything a [load flow](@ref "Load flow in the IVR formulation") has, now
bounded, plus the controls a load flow does not give.

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
| ``p^{\text{g}}_{u}`` | `:pg` | ``u \in U^{\text{g}}`` | ``[p^{\text{min}}_{u}, p^{\text{max}}_{u}]`` |
| ``q^{\text{g}}_{u}`` | `:qg` | ``u \in U^{\text{g}}`` | ``[q^{\text{min}}_{u}, q^{\text{max}}_{u}]`` |
| ``p^{\text{d}}_{u}`` | `:pdf` | ``u \in U^{\text{fl}}`` | ``[p^{\text{d,min}}_{u}, p^{\text{d,max}}_{u}]`` |
| ``p^{\text{sc}}_{u}, p^{\text{sd}}_{u}`` | `:psc`, `:psd` | ``u \in U^{\text{s}}`` | ``[0, \cdot^{\text{max}}_{u}]`` |
| ``e_{u}`` | `:es` | ``u \in U^{\text{s}}`` | ``[0, e^{\text{max}}_{u}]`` |
| ``q^{\text{s}}_{u}`` | `:qs` | ``u \in U^{\text{s}}`` | ``[q^{\text{min}}_{u}, q^{\text{max}}_{u}]`` |

## Objective

```math
\min \quad \sum_{n \in \mathcal{N}} w_{n}
           \sum_{u \in U^{\text{g}}} \sum_{k} c_{u,k} \, (p^{\text{g}}_{u,n})^{k-1}
```

## Constraints

### At the nodes

Reference **angle** only, ``\forall i \in I^{\text{ref}}``:

```math
\sin(v^{\text{a}}_{i}) \, v^{\text{r}}_{i} - \cos(v^{\text{a}}_{i}) \, v^{\text{i}}_{i} = 0,
\qquad
\cos(v^{\text{a}}_{i}) \, v^{\text{r}}_{i} + \sin(v^{\text{a}}_{i}) \, v^{\text{i}}_{i} \ge 0
```

The second keeps the voltage on the intended side of the origin, which the first
alone does not.

Voltage magnitude limits, ``\forall i \in I``:

```math
(v^{\text{min}}_{i})^2 \le (v^{\text{r}}_{i})^2 + (v^{\text{i}}_{i})^2 \le (v^{\text{max}}_{i})^2
```

Current balance, ``\forall i \in I``: as in the load flow.

### At the edges

The physics are **identical** to the [load flow](@ref "Load flow in the IVR formulation"):
the π-equivalent, the ideal ratio, the star. What a dispatch problem adds is the
limits, and what it changes is that the ratio of a phase shifter or a tap changer
is now a variable rather than a number.

Rating, ``\forall e``, per terminal ``a`` at node ``i``:

```math
\left((v^{\text{r}}_{i})^2 + (v^{\text{i}}_{i})^2\right)
\left((c^{\text{r}}_{a})^2 + (c^{\text{i}}_{a})^2\right) \le (s^{\text{max}}_{e})^2
```

Angle difference across a two-terminal edge:

```math
\tan(\theta^{\text{min}}_{e}) \left(v^{\text{r}}_{i} v^{\text{r}}_{j} + v^{\text{i}}_{i} v^{\text{i}}_{j}\right)
\le v^{\text{i}}_{i} v^{\text{r}}_{j} - v^{\text{r}}_{i} v^{\text{i}}_{j}
\le \tan(\theta^{\text{max}}_{e}) \left(v^{\text{r}}_{i} v^{\text{r}}_{j} + v^{\text{i}}_{i} v^{\text{i}}_{j}\right)
```

Phase shifter ratio, ``\forall e \in E^{\text{ps}}``:

```math
(t^{\text{r}}_{e})^2 + (t^{\text{i}}_{e})^2 = tm_{e}^2,
\qquad
\tan(ta^{\text{min}}_{e}) \, t^{\text{r}}_{e} \le t^{\text{i}}_{e} \le \tan(ta^{\text{max}}_{e}) \, t^{\text{r}}_{e}
```

The ratio is carried as a real and an imaginary part rather than as an angle so
that the equations it enters stay polynomial.

### At the units

The power-against-current relations are as in the load flow, with the setpoints
gone. A storage unit uses its own injection:

```math
v^{\text{r}}_{i} c^{\text{r}}_{u} + v^{\text{i}}_{i} c^{\text{i}}_{u} = p^{\text{sd}}_{u} - p^{\text{sc}}_{u},
\qquad
v^{\text{i}}_{i} c^{\text{r}}_{u} - v^{\text{r}}_{i} c^{\text{i}}_{u} = q^{\text{s}}_{u}
```

and a flexible load its variable demand, with the reactive part following at the
power factor of the nominal point.

### Across network indices

State of charge, ``\forall u \in U^{\text{s}}``, ``\forall n``:

```math
e_{u,n} = e_{u,n-1} + \Delta t_{n}
          \left( \eta^{\text{c}}_{u} p^{\text{sc}}_{u,n} - p^{\text{sd}}_{u,n} / \eta^{\text{d}}_{u} \right)
```

starting each horizon from ``e^{0}_{u}``. Energy of a flexible load,
``\forall u \in U^{\text{fl}}``, once per horizon:

```math
\sum_{n \in \mathcal{T}} \Delta t_{n} \, p^{\text{d}}_{u,n} = E_{u}
```

Both horizons run along `:time` with every other coordinate of the network index
held fixed.

## Model class and size

Nonconvex, quadratically constrained, with a quadratic objective. Needs a
nonlinear solver. On case14:

| | variables | constraints |
|:--|----------:|------------:|
| case14 | 198 | 294 |

The same 198 variables as the load flow — case14 carries no controls — against 96
more constraints, which are its limits.

## Validation

Reproduces the objective of PowerModels.jl v0.21 to a relative `1e-6` on case14,
case5 and case3.
