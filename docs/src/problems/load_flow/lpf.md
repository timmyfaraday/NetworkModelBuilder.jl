# Load flow in the LPF formulation

The complete problem built by
`NetworkModel{LoadFlowProblem, LPFFormulation}`. Every constraint is affine, so
this is a square linear system dressed as an optimization problem.

See [The linearized formulation](@ref) for what the approximations discard.

## Variables

| symbol | key | index set | bounds |
|:-------|:----|:----------|:-------|
| ``v^{\text{a}}_{i}`` | `:va` | ``i \in I`` | free |
| ``p_{a}`` | `:p` | ``a \in A`` | free |
| ``v^{\text{as}}_{e}`` | `:vas` | ``e \in E^{\text{mw}}`` | free |
| ``p_{u}`` | `:pu` | ``u \in U`` | free |
| ``p^{\text{g}}_{u}`` | `:pg` | ``u \in U^{\text{g}}`` | free |

There is no magnitude variable, no current, and no reactive power.

## Objective

```math
\min \quad 0
```

## Constraints

### At the nodes

Reference angle, ``\forall i \in I^{\text{ref}}``:

```math
v^{\text{a}}_{i} = v^{\text{a,set}}_{i}
```

Active power balance, ``\forall i \in I``:

```math
\sum_{a \in A(i)} p_{a} = \sum_{u \in U(i)} p_{u}
```

There is no magnitude setpoint at a `PV` node: there is no magnitude.

### At the edges

Branch, ``\forall e \in E^{\text{br}}``, and two-winding transformer,
``\forall e \in E^{\text{tf}}``, differing only in the shift:

```math
p_{a^{\text{f}}_{e}} = -b_{e} \left(v^{\text{a}}_{i} - v^{\text{a}}_{j} - ta_{e}\right),
\qquad
p_{a^{\text{t}}_{e}} = -p_{a^{\text{f}}_{e}}
```

with ``b_{e} = -x_{e}/(r_{e}^2 + x_{e}^2)`` and ``ta_{e} = 0`` for a branch. The
second equation is what makes the model lossless. The ratio *magnitude* does not
appear, so a [`TapChanger`](@ref) is indistinguishable from a
[`Transformer`](@ref) here.

Multi-winding transformer, ``\forall e \in E^{\text{mw}}``:

```math
p_{a_{e,k}} = -b_{e,k} \left(v^{\text{a}}_{i_k} - ta_{e,k} - v^{\text{as}}_{e}\right)
\quad \forall k,
\qquad
\sum_{k} p_{a_{e,k}} = 0
```

### At the units

```math
\begin{aligned}
p_{u} &= p^{\text{g}}_{u}          &&\forall u \in U^{\text{g}} \\
p_{u} &= -p^{\text{d}}_{u}         &&\forall u \in U^{\text{d}} \\
p_{u} &= p^{\text{s,set}}_{u}      &&\forall u \in U^{\text{s}} \\
p_{u} &= -g^{\text{s}}_{u}         &&\forall u \in U^{\text{sh}}
\end{aligned}
```

together with the generator setpoints

```math
p^{\text{g}}_{u} = p^{\text{g,set}}_{u} \quad \forall u \text{ at } i \notin I^{\text{ref}}
```

The `PV` and `PQ` distinction disappears: with no reactive power and no voltage
magnitude, every generator away from the reference node holds its active
setpoint and nothing else. A shunt becomes a constant withdrawal of its
conductance.

## Model class and size

Affine constraints and a constant objective, so any LP solver will do. On case14:

| | variables | constraints |
|:-|----------:|------------:|
| case14 | 76 | 76 |

Against 198 and 198 for the same problem in the IVR formulation.

## Validation

Reproduces PowerModels.jl v0.21 `DCPPowerModel` on case14 and case3, every angle
to `1e-5` degrees. case5 differs, for the reasons set out in
[The linearized formulation](@ref).
