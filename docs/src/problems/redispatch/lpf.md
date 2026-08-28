# Redispatch in the LPF formulation

The complete problem built by `NetworkModel{RedispatchProblem, LPFFormulation}`.
Every constraint is affine and the objective is linear in the volumes, so this is
a **linear program** — where the
[optimal power flow](@ref "Optimal power flow in the LPF formulation") is a
quadratic one whenever a cost polynomial is quadratic.

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
| ``p^{\uparrow}_{u}, p^{\downarrow}_{u}`` | `:pgup`, `:pgdn` | ``u \in U^{\text{g}}`` | the headroom each way |
| ``p^{\text{d}}_{u}`` | `:pdf` | ``u \in U^{\text{fl}}`` | ``[p^{\text{d,min}}_{u}, p^{\text{d,max}}_{u}]`` |
| ``p^{\text{sc}}_{u}, p^{\text{sd}}_{u}`` | `:psc`, `:psd` | ``u \in U^{\text{s}}`` | ``[0, \cdot^{\text{max}}_{u}]`` |
| ``e_{u}`` | `:es` | ``u \in U^{\text{s}}`` | ``[0, e^{\text{max}}_{u}]`` |
| ``p^{\uparrow}_{u}, p^{\downarrow}_{u}`` | `:psup`, `:psdn` | ``u \in U^{\text{s}}`` | the headroom each way |

No voltage magnitude, no reactive power, no current — and no ``tm_{e}``, since a
[`TapChanger`](@ref) is inert here. A [`PhaseShifter`](@ref) is not, and it is
the free measure a redispatch reaches for first.

## Objective

```math
\min \quad \sum_{n \in \mathcal{N}} w_{n} \sum_{u \in U^{\text{g}} \cup U^{\text{s}}}
    \left( c^{\uparrow}_{u} p^{\uparrow}_{u,n} + c^{\downarrow}_{u} p^{\downarrow}_{u,n} \right)
```

## Constraints

### At the nodes

```math
v^{\text{a}}_{i} = v^{\text{a,set}}_{i} \quad \forall i \in I^{\text{ref}},
\qquad
\sum_{a \in A(i)} p_{a} = \sum_{u \in U(i)} p_{u} \quad \forall i \in I
```

### At the edges

Flow, ``\forall e \in E^{\text{br}} \cup E^{\text{tf}}``:

```math
p_{a^{\text{f}}_{e}} = -b_{e} \left(v^{\text{a}}_{i} - v^{\text{a}}_{j} - ta_{e}\right),
\qquad
p_{a^{\text{t}}_{e}} = -p_{a^{\text{f}}_{e}}
```

Rating, on the **monitored** edges only, ``\forall e \in E^{\text{mon}}``:

```math
-s^{\text{max}}_{e} \le p_{a} \le s^{\text{max}}_{e}
```

Angle difference, on **every** edge — it is a stability limit, not congestion:

```math
\theta^{\text{min}}_{e} \le v^{\text{a}}_{i} - v^{\text{a}}_{j} \le \theta^{\text{max}}_{e}
```

### At the units

```math
\begin{aligned}
p_{u} &= p^{\text{g}}_{u},
    & p^{\text{g}}_{u} &= p^{\text{g,mkt}}_{u} + p^{\uparrow}_{u} - p^{\downarrow}_{u}
    &&\forall u \in U^{\text{g}} \\
p_{u} &= -p^{\text{d}}_{u} & && \forall u \in U^{\text{d}} \\
p_{u} &= p^{\text{sd}}_{u} - p^{\text{sc}}_{u},
    & p^{\text{sd}}_{u} - p^{\text{sc}}_{u} &= p^{\text{s}}_{u} + p^{\uparrow}_{u} - p^{\downarrow}_{u}
    &&\forall u \in U^{\text{s}} \\
p_{u} &= -g^{\text{s}}_{u} & && \forall u \in U^{\text{sh}}
\end{aligned}
```

### Across network indices

The state of charge, the energy of a flexible load, and the preventive
equalities — identical to the
[IVR formulation](@ref "Redispatch in the IVR formulation") but for which
variables a phase shifter contributes: the angle ``ta_{e}`` here, the pair
``(t^{\text{r}}_{e}, t^{\text{i}}_{e})`` there.

## A worked example

A two-node radial network, a cheap generator at the far end of a branch rated
0.5, a load of 1.0 and an expensive generator behind the constraint. The market
ran the cheap unit to 1.0, which the branch cannot carry, so 0.5 has to be moved
from one side of it to the other:

```math
p^{\downarrow}_{1} = 0.5, \quad p^{\uparrow}_{2} = 0.5,
\qquad
\text{objective} = 0.5 \cdot 100 + 0.5 \cdot 10 = 55
```

at the marginal costs of 100 and 10 that stand in for the redispatch prices. The
test suite asserts exactly this, and the same network meshed with a phase
shifter in parallel gives an objective of **zero** — the free control clears the
corridor on its own.

```julia
using NetworkModelBuilder, HiGHS

result = solve_rd(data, LPFFormulation, HiGHS.Optimizer;
                  redispatch = Redispatch(; monitored = [1]))
```
