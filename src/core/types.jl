################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.1.0 - initial implementation                                              #
################################################################################

################################################################################
# Problem types                                                                #
################################################################################

"""
    AbstractProblemType

Root of the problem type hierarchy. A problem type answers the question *which
question is being asked of the network*: which components are modelled, which
degrees of freedom are free, which are fixed by a setpoint, and what is being
optimized.

Together with an [`AbstractFormulationType`](@ref) it fully determines the
variables, constraints and objective of the resulting optimization problem
through multiple dispatch on [`NetworkModel{P,F}`](@ref).

All types in this hierarchy are abstract and are used purely as dispatch tags:
they are never instantiated. Extension packages specialise a problem by
subtyping an existing leaf, e.g.,

```julia
abstract type SecurityConstrainedRedispatchProblem <: RedispatchProblem end
```
"""
abstract type AbstractProblemType end

""
abstract type AbstractPowerFlowProblem <: AbstractProblemType end

"""
    LoadFlowProblem <: AbstractPowerFlowProblem

Determine the steady-state operating point of a network with all injections
fixed by their setpoints. The reference node fixes the complex voltage, PV nodes
fix the voltage magnitude and the active power of their generators, and PQ nodes
fix the active and reactive power of their units. The problem is a feasibility
problem: its objective is identically zero.
"""
abstract type LoadFlowProblem <: AbstractPowerFlowProblem end

""
abstract type AbstractDispatchProblem <: AbstractProblemType end

"""
    OptimalPowerFlowProblem <: AbstractDispatchProblem

Minimize the total generation cost subject to the network physics, the operating
limits of the units and the thermal and angular limits of the edges. Generator
active and reactive power are free within their bounds, node voltage magnitudes
are bounded, and the reference node fixes the voltage angle only.
"""
abstract type OptimalPowerFlowProblem <: AbstractDispatchProblem end

"""
    RedispatchProblem <: AbstractDispatchProblem

Minimize the price of the measures needed to relieve congestion on a dispatch
that has already been decided — typically one a market cleared without regard
to the network.

The network side is that of an [`OptimalPowerFlowProblem`](@ref); what makes it
a different question is what is minimized and what is watched. Each generator
and storage unit splits its dispatch into the market schedule it carries as a
setpoint and the volumes it moved away from it, and only those volumes are
priced. The rating is enforced on the edges the problem watches, which may be a
subset of them, and a control that costs nothing to move — a
[`PhaseShifter`](@ref), a [`TapChanger`](@ref) — is taken first because it is
free.

Posed over a `:contingency` dimension the problem asks the same question of
every state at once, with each measure either **preventive**, one setting that
has to serve every contingency, or **corrective**, free per contingency. Posed
over a `:time` dimension it is a horizon rather than a snapshot, which is what a
[`Storage`](@ref) unit needs to be a measure at all.

See [`Redispatch`](@ref) for the two choices it takes beyond the data, and
[`solve_rd`](@ref) for the entry point.
"""
abstract type RedispatchProblem <: AbstractDispatchProblem end

################################################################################
# Formulation types                                                            #
################################################################################

"""
    AbstractFormulationType

Root of the formulation type hierarchy. A formulation type answers the question
*in which variables are the network physics written*: rectangular or polar
voltage, current or power flow, exact or relaxed.

Together with an [`AbstractProblemType`](@ref) it fully determines the
variables, constraints and objective of the resulting optimization problem
through multiple dispatch on [`NetworkModel{P,F}`](@ref).

All types in this hierarchy are abstract and are used purely as dispatch tags:
they are never instantiated. Extension packages specialise a formulation by
subtyping an existing leaf, e.g.,

```julia
abstract type HarmonicIVRFormulation <: IVRFormulation end
```
"""
abstract type AbstractFormulationType end

""
abstract type AbstractACFormulation <: AbstractFormulationType end

"""
    AbstractCurrentFormulation <: AbstractACFormulation

Formulations whose edge and unit flow variables are currents.
"""
abstract type AbstractCurrentFormulation <: AbstractACFormulation end

"""
    IVRFormulation <: AbstractCurrentFormulation

Current-voltage formulation in rectangular coordinates. Node voltages are
represented by their real and imaginary part, and all flows by their real and
imaginary current. The network physics are quadratic, which keeps the
nonlinearity of the model low compared to the power based formulations.
"""
abstract type IVRFormulation <: AbstractCurrentFormulation end

"""
    AbstractPowerFormulation <: AbstractACFormulation

Formulations whose edge and unit flow variables are active and reactive power.
"""
abstract type AbstractPowerFormulation <: AbstractACFormulation end

"""
    ACPFormulation <: AbstractPowerFormulation

Power-voltage formulation in polar coordinates. Declared for completeness; no
variables or constraints are implemented yet.
"""
abstract type ACPFormulation <: AbstractPowerFormulation end

"""
    ACRFormulation <: AbstractPowerFormulation

Power-voltage formulation in rectangular coordinates. Declared for
completeness; no variables or constraints are implemented yet.
"""
abstract type ACRFormulation <: AbstractPowerFormulation end

"""
    AbstractLinearizedFormulation <: AbstractFormulationType

Formulations that linearize the network physics, giving up exactness for a model
an ordinary linear or quadratic programming solver can take.

These are deliberately not [`AbstractACFormulation`](@ref)s: a linearized model
has no voltage magnitude and no reactive power, so the methods that write those
must not apply to it.
"""
abstract type AbstractLinearizedFormulation <: AbstractFormulationType end

"""
    LPFFormulation <: AbstractLinearizedFormulation

Linearized power flow: active power only, in the voltage angles.

Three approximations get you here — every voltage magnitude is one per unit,
reactive power is omitted, and angle differences are small enough that
`sin θ ≈ θ` and `cos θ ≈ 1` — after which the flow of a two-terminal edge is

```math
p_{a^{\\text{f}}} = -b_{e} \\left(v^{\\text{a}}_{i} - v^{\\text{a}}_{j} - ta_{e}\\right),
\\qquad
p_{a^{\\text{t}}} = -p_{a^{\\text{f}}} ,
```

and the model is lossless, linear, and solvable without a nonlinear solver.

This is what the literature calls the DC power flow, a name this package avoids:
nothing about it involves direct current. It is a linearization of the
alternating current equations around a flat voltage profile.

See the manual for what survives the approximations and what does not — most
notably that a [`PhaseShifter`](@ref) remains a control here while a
[`TapChanger`](@ref) becomes inert.
"""
abstract type LPFFormulation <: AbstractLinearizedFormulation end
