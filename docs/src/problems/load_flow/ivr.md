# Load flow in the IVR formulation

The complete problem built by
`NetworkModel{LoadFlowProblem, IVRFormulation}`. It is a system of quadratic
equalities: nonconvex, exact, and solved as a feasibility problem.

## Variables

| symbol | key | index set | bounds |
|:-------|:----|:----------|:-------|
| ``v^{\text{r}}_{i}, v^{\text{i}}_{i}`` | `:vr`, `:vi` | ``i \in I`` | free |
| ``c^{\text{r}}_{a}, c^{\text{i}}_{a}`` | `:cr`, `:ci` | ``a \in A`` | free |
| ``c^{\text{sr}}_{e}, c^{\text{si}}_{e}`` | `:csr`, `:csi` | ``e \in E^{\text{br}}`` | free |
| ``v^{\text{sr}}_{e}, v^{\text{si}}_{e}`` | `:vsr`, `:vsi` | ``e \in E^{\text{tf}}`` | free |
| ``c^{\text{r}}_{u}, c^{\text{i}}_{u}`` | `:cru`, `:ciu` | ``u \in U`` | free |
| ``p^{\text{g}}_{u}, q^{\text{g}}_{u}`` | `:pg`, `:qg` | ``u \in U^{\text{g}}`` | free |

Nothing is bounded. A load flow has a determinate answer, and bounding a variable
can only steer the solver away from it.

## Objective

```math
\min \quad 0
```

## Constraints

### At the nodes

Reference voltage, ``\forall i \in I^{\text{ref}}``:

```math
v^{\text{r}}_{i} = v^{\text{m}}_{i} \cos v^{\text{a}}_{i},
\qquad
v^{\text{i}}_{i} = v^{\text{m}}_{i} \sin v^{\text{a}}_{i}
```

Voltage magnitude setpoint, ``\forall i \in I^{\text{pv}}``:

```math
(v^{\text{r}}_{i})^2 + (v^{\text{i}}_{i})^2 = (v^{\text{m}}_{i})^2
```

Current balance, ``\forall i \in I``:

```math
\sum_{a \in A(i)} c^{\text{r}}_{a} = \sum_{u \in U(i)} c^{\text{r}}_{u},
\qquad
\sum_{a \in A(i)} c^{\text{i}}_{a} = \sum_{u \in U(i)} c^{\text{i}}_{u}
```

### At the edges

Branch, ``\forall e \in E^{\text{br}}`` with arcs ``a^{\text{f}}_{e}`` at ``i``
and ``a^{\text{t}}_{e}`` at ``j``:

```math
\begin{aligned}
c^{\text{r}}_{a^{\text{f}}_{e}} &= g^{\text{sh}}_{e,\text{fr}} v^{\text{r}}_{i} - b^{\text{sh}}_{e,\text{fr}} v^{\text{i}}_{i} + c^{\text{sr}}_{e} \\
c^{\text{i}}_{a^{\text{f}}_{e}} &= g^{\text{sh}}_{e,\text{fr}} v^{\text{i}}_{i} + b^{\text{sh}}_{e,\text{fr}} v^{\text{r}}_{i} + c^{\text{si}}_{e} \\
c^{\text{r}}_{a^{\text{t}}_{e}} &= -c^{\text{sr}}_{e} + g^{\text{sh}}_{e,\text{to}} v^{\text{r}}_{j} - b^{\text{sh}}_{e,\text{to}} v^{\text{i}}_{j} \\
c^{\text{i}}_{a^{\text{t}}_{e}} &= -c^{\text{si}}_{e} + g^{\text{sh}}_{e,\text{to}} v^{\text{i}}_{j} + b^{\text{sh}}_{e,\text{to}} v^{\text{r}}_{j} \\
v^{\text{r}}_{i} - v^{\text{r}}_{j} &= r_{e} c^{\text{sr}}_{e} - x_{e} c^{\text{si}}_{e} \\
v^{\text{i}}_{i} - v^{\text{i}}_{j} &= r_{e} c^{\text{si}}_{e} + x_{e} c^{\text{sr}}_{e}
\end{aligned}
```

Transformer, ``\forall e \in E^{\text{tf}}``, for every winding ``k`` at node
``i_k``. A load flow holds the ratio ``T_{e,k} = tm_{e,k} \exp(j \, ta_{e,k})`` at
its setpoint, so the voltage and the current behind it are expressions, not
variables,

```math
v^{\text{t}}_{e,k} = \overline{T_{e,k}} \, v_{i_k} / |T_{e,k}|^2,
\qquad
c^{\text{t}}_{e,k} = \overline{T_{e,k}} \, c_{a_{e,k}} ,
```

and what is left is the star, with ``z_{e,k}`` the impedance and
``y^{\text{sh}}_{e,k}`` the shunt of winding ``k``:

```math
v^{\text{t}}_{e,k} - v^{\text{s}}_{e} = z_{e,k} \left( c^{\text{t}}_{e,k} -
y^{\text{sh}}_{e,k} \, v^{\text{t}}_{e,k} \right),
\qquad
\sum_{k} \left( c^{\text{t}}_{e,k} - y^{\text{sh}}_{e,k} \, v^{\text{t}}_{e,k} \right)
= y^{\text{m}}_{e} \, v^{\text{s}}_{e}
```

A unit ratio is an alias: ``v^{\text{t}}_{e,k} = v_{i_k}`` and
``c^{\text{t}}_{e,k} = c_{a_{e,k}}``.

### At the units

Generator, ``\forall u \in U^{\text{g}}`` at node ``i``:

```math
p^{\text{g}}_{u} = v^{\text{r}}_{i} c^{\text{r}}_{u} + v^{\text{i}}_{i} c^{\text{i}}_{u},
\qquad
q^{\text{g}}_{u} = v^{\text{i}}_{i} c^{\text{r}}_{u} - v^{\text{r}}_{i} c^{\text{i}}_{u}
```

together with the setpoints

```math
p^{\text{g}}_{u} = p^{\text{g,set}}_{u} \quad \forall u \text{ at } i \notin I^{\text{ref}},
\qquad
q^{\text{g}}_{u} = q^{\text{g,set}}_{u} \quad \forall u \text{ at } i \in I^{\text{pq}}
```

Load, ``\forall u \in U^{\text{d}}``, where a [`FlexibleLoad`](@ref) takes its
nominal demand:

```math
v^{\text{r}}_{i} c^{\text{r}}_{u} + v^{\text{i}}_{i} c^{\text{i}}_{u} = -p^{\text{d}}_{u},
\qquad
v^{\text{i}}_{i} c^{\text{r}}_{u} - v^{\text{r}}_{i} c^{\text{i}}_{u} = -q^{\text{d}}_{u}
```

Storage, ``\forall u \in U^{\text{s}}``, holding its setpoint:

```math
v^{\text{r}}_{i} c^{\text{r}}_{u} + v^{\text{i}}_{i} c^{\text{i}}_{u} = p^{\text{s,set}}_{u},
\qquad
v^{\text{i}}_{i} c^{\text{r}}_{u} - v^{\text{r}}_{i} c^{\text{i}}_{u} = q^{\text{s,set}}_{u}
```

Shunt, ``\forall u \in U^{\text{sh}}``:

```math
c^{\text{r}}_{u} = -\left(g^{\text{s}}_{u} v^{\text{r}}_{i} - b^{\text{s}}_{u} v^{\text{i}}_{i}\right),
\qquad
c^{\text{i}}_{u} = -\left(g^{\text{s}}_{u} v^{\text{i}}_{i} + b^{\text{s}}_{u} v^{\text{r}}_{i}\right)
```

## Model class and size

Quadratic equality constraints throughout, hence nonconvex; it needs a nonlinear
solver. On case14, which has 14 nodes, 20 edges and 17 units:

| | variables | constraints |
|:--|----------:|------------:|
| case14 | 192 | 192 |

Square, as a determinate problem should be.

## Validation

Reproduces the AC power flow solution of PowerModels.jl v0.21 on case14 and
case5, every voltage magnitude to `1e-6` and every angle to `1e-5` degrees.
