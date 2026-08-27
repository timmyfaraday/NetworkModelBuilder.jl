# The linearized formulation

[`LPFFormulation`](@ref) is the classical linearized model of active power flow —
what the literature usually calls the *DC power flow*, a name this package avoids
because nothing about the model involves direct current. It is a linearization of
the alternating current equations around a flat voltage profile.

It rests on three approximations:

1. every voltage magnitude is one per unit, ``|v_{i}| = 1``;
2. reactive power is omitted;
3. angle differences are small, so ``\sin \theta \approx \theta`` and
   ``\cos \theta \approx 1``.

Applying them to the exact flow of a π-equivalent leaves

```math
p_{a^{\text{f}}} = -b_{e} \left(v^{\text{a}}_{i} - v^{\text{a}}_{j} - ta_{e}\right),
\qquad
p_{a^{\text{t}}} = -p_{a^{\text{f}}} ,
```

with ``b_{e}`` the series susceptance. The result is a **linear program**, or a
quadratic one where the generation cost is quadratic.

## What survives, and what does not

| in the exact model | here |
|:-------------------|:-----|
| voltage magnitude ``v^{\text{m}}_{i}`` | gone — it is one everywhere |
| voltage angle ``v^{\text{a}}_{i}`` | the only node variable |
| reactive power | gone |
| series resistance | kept, in ``b_{e}`` — see below |
| losses | gone — the model is lossless by construction |
| the turns ratio magnitude ``tm_{e}`` | gone — there is no magnitude for it to change |
| the turns ratio angle ``ta_{e}`` | kept, and still a control |
| a shunt's susceptance ``b^{\text{s}}_{u}`` | gone |
| a shunt's conductance ``g^{\text{s}}_{u}`` | kept, as a constant withdrawal |

The two entries worth dwelling on are the transformer ratio and the resistance.

### The resistance is kept

The susceptance is [`susceptance`](@ref)`(r, x)` ``= -x / (r^2 + x^2)``.

Dropping the resistance as well, ``b = -1/x``, is the other common convention and
is what Matpower's DC model does. None of the three approximations above
requires it, so it is not done here. The difference is small on a transmission
network, where ``r \ll x``, and grows as that stops being true.

### A phase shifter is a control, a tap changer is not

The ratio *angle* survives the linearization and the ratio *magnitude* does not.
That is not an implementation choice — with every magnitude fixed at one there
is nothing for ``tm`` to act on.

So a [`PhaseShifter`](@ref) is a genuine control in this formulation, and a
linear one: its angle enters the flow directly, where the current based
formulation has to carry the ratio as a real and an imaginary part to stay
polynomial. Steering active power with a phase shifter is the classic use of a
linearized model.

A [`TapChanger`](@ref), by contrast, is **inert** here. It is built and solved as
an ordinary transformer at its fixed phase angle, and the voltage control it
offers an alternating current model is simply absent. It does not error, because
the model is still a valid one; but a study whose point is the tap belongs in an
[`IVRFormulation`](@ref).

## The problem definition does not change

The two problem builders are shared between the formulations:

```julia
build_model!(nm::NetworkModel{P,F}) where {P<:LoadFlowProblem,F<:IVRFormulation} = _build_load_flow!(nm)
build_model!(nm::NetworkModel{P,F}) where {P<:LoadFlowProblem,F<:LPFFormulation} = _build_load_flow!(nm)
```

Every call inside `_build_load_flow!` is a dispatch point, so the definition of
the problem says nothing about the formulation it is being built in. Swapping
one for the other changes which methods those names resolve to, and nothing
else — which is the property the two type hierarchies exist to give.

## Validation

The model is checked against PowerModels.jl v0.21's `DCPPowerModel`:

| case | objective | angles |
|:-----|:----------|:-------|
| case14, optimal power flow | matches to `1e-7` | all 14 match to `1e-5` deg |
| case14, load flow | — | all 14 match to `1e-5` deg |
| case3, optimal power flow | matches to `1e-7` | all 3 match |
| case3, load flow | — | all 3 match |

!!! note "Why case5 differs"
    case5 is the one case in the test set with a phase shifting transformer, and
    there the two models part company for two separate reasons.

    First, `DCPPowerModel` drops the phase shift and this model keeps it.

    Second, and more subtly, case5 connects nodes 3 and 4 twice with the same
    impedance, oriented oppositely. PowerModels' parser normalizes the second one
    to the first one's direction, and in doing so refers its impedance across the
    tap, turning ``b`` into ``b/tm^2``. Only *then* does it drop the tap. This
    package drops the tap on the data as given.

    Neither is wrong. Once ``tm`` is discarded, a transformer's impedance is no
    longer referable from one side to the other, so a linearized model is
    sensitive to which side the input data referred it to — a real limitation of
    the approximation rather than of either implementation. What this model does
    guarantee is internal consistency: two identical impedances between one node
    pair carry exactly equal and opposite flows, which the test suite checks.

## Solving one

A linearized model needs no nonlinear solver. Any LP solver will do for a load
flow or a linear cost, and a QP solver for a quadratic one:

```julia
using NetworkModelBuilder, HiGHS

result = solve_opf("case14.m", LPFFormulation, HiGHS.Optimizer)
```

The test suite asserts the model class directly rather than relying on a
particular solver accepting it: every constraint is an affine expression or a
variable, and the objective is affine for a load flow and quadratic for an
optimal power flow.
