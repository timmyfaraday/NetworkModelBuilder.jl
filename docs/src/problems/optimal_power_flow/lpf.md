# Optimal power flow in the LPF formulation

The complete problem built by
`NetworkModel{OptimalPowerFlowProblem, LPFFormulation}`. Every constraint is
affine and the objective is the cost polynomial, so this is a linear program
where that polynomial is linear and a quadratic program where it is quadratic.

See [The linearized formulation](@ref) for what the approximations discard.

## Variables

| symbol | key | index set | bounds |
|:-------|:----|:----------|:-------|
| ``v^{\text{a}}_{i}`` | `:va` | ``i \in I`` | free |
| ``p_{a}`` | `:p` | ``a \in A`` | free |
| ``v^{\text{as}}_{e}`` | `:vas` | ``e \in E^{\text{mw}}`` | free |
| ``ta_{e}`` | `:ta` | ``e \in E^{\text{ps}}`` | ``[ta^{\text{min}}_{e}, ta^{\text{max}}_{e}]`` |
| ``p_{u}`` | `:pu` | ``u \in U`` | free |
| ``p^{\text{g}}_{u}`` | `:pg` | ``u \in U^{\text{g}}`` | ``[p^{\text{min}}_{u}, p^{\text{max}}_{u}]`` |
| ``p^{\text{d}}_{u}`` | `:pdf` | ``u \in U^{\text{fl}}`` | ``[p^{\text{d,min}}_{u}, p^{\text{d,max}}_{u}]`` |
| ``p^{\text{sc}}_{u}, p^{\text{sd}}_{u}`` | `:psc`, `:psd` | ``u \in U^{\text{s}}`` | ``[0, \cdot^{\text{max}}_{u}]`` |
| ``e_{u}`` | `:es` | ``u \in U^{\text{s}}`` | ``[0, e^{\text{max}}_{u}]`` |

No voltage magnitude, no reactive power, no current — and no ``tm_{e}``: a
[`TapChanger`](@ref) has no control to exercise here. A [`PhaseShifter`](@ref)
does, and here its angle is the variable itself, where the IVR formulation has to
carry the ratio as a real and an imaginary part.

## Objective

```math
\min \quad \sum_{n \in \mathcal{N}} w_{n}
           \sum_{u \in U^{\text{g}}} \sum_{k} c_{u,k} \, (p^{\text{g}}_{u,n})^{k-1}
```

## Constraints

### At the nodes

```math
v^{\text{a}}_{i} = v^{\text{a,set}}_{i} \quad \forall i \in I^{\text{ref}},
\qquad
\sum_{a \in A(i)} p_{a} = \sum_{u \in U(i)} p_{u} \quad \forall i \in I
```

There are no voltage magnitude limits, because there is no magnitude. This is the
approximation's sharpest cost: a linearized optimal power flow cannot see a
voltage violation, and cannot use reactive support to avoid one.

### At the edges

Flow, ``\forall e \in E^{\text{br}} \cup E^{\text{tf}}``:

```math
p_{a^{\text{f}}_{e}} = -b_{e} \left(v^{\text{a}}_{i} - v^{\text{a}}_{j} - ta_{e}\right),
\qquad
p_{a^{\text{t}}_{e}} = -p_{a^{\text{f}}_{e}}
```

and ``\forall e \in E^{\text{mw}}``:

```math
p_{a_{e,k}} = -b_{e,k} \left(v^{\text{a}}_{i_k} - ta_{e,k} - v^{\text{as}}_{e}\right) \quad \forall k,
\qquad
\sum_{k} p_{a_{e,k}} = 0
```

Limits, per terminal and per two-terminal edge:

```math
-s^{\text{max}}_{e} \le p_{a} \le s^{\text{max}}_{e},
\qquad
\theta^{\text{min}}_{e} \le v^{\text{a}}_{i} - v^{\text{a}}_{j} \le \theta^{\text{max}}_{e}
```

With no reactive power in the model, apparent power *is* active power, so the
rating applies to it directly. Both limits are already linear — no relaxation is
involved, unlike their IVR counterparts.

### At the units

```math
\begin{aligned}
p_{u} &= p^{\text{g}}_{u}                        &&\forall u \in U^{\text{g}} \\
p_{u} &= -p^{\text{d}}_{u}                       &&\forall u \in U^{\text{d}} \\
p_{u} &= p^{\text{sd}}_{u} - p^{\text{sc}}_{u}   &&\forall u \in U^{\text{s}} \\
p_{u} &= -g^{\text{s}}_{u}                       &&\forall u \in U^{\text{sh}}
\end{aligned}
```

### Across network indices

Identical to the [IVR formulation](@ref "Optimal power flow in the IVR formulation"):
the state of charge of a storage unit and the energy balance of a flexible load.
Neither mentions a voltage or a current, so both are shared between the
formulations rather than written twice — an energy balance is about time, not
about how the physics are written.

## Model class and size

Affine constraints with a quadratic objective, so a QP solver suffices, and an LP
solver where every cost is linear. On case14:

| | variables | constraints |
|:--|----------:|------------:|
| case14 | 76 | 82 |

Against 198 and 294 for the same problem in the IVR formulation.

```julia
using NetworkModelBuilder, HiGHS

result = solve_opf("case14.m", LPFFormulation, HiGHS.Optimizer)
```

## Validation

Reproduces PowerModels.jl v0.21 `DCPPowerModel` on case14 and case3, on the
objective to `1e-7` and on every angle to `1e-5` degrees. The model class is
asserted directly in the test suite rather than inferred from a solver accepting
it.
