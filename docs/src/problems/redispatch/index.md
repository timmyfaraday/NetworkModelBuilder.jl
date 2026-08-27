# Redispatch

A redispatch problem asks for the cheapest *deviation* from a dispatch already
decided — typically one a market cleared without regard to the network — that
the network can actually carry.

```@docs
RedispatchProblem
```

!!! warning "Not implemented"
    [`RedispatchProblem`](@ref) is declared, and `src/prob/rd.jl` sketches its
    builder, but no method exists for it in either formulation. Asking for one
    reports what is available rather than building something wrong:

    ```
    ERROR: NetworkModelBuilder has no model builder for
        problem type     : RedispatchProblem
        formulation type : IVRFormulation
    Implemented combinations are:
        LoadFlowProblem with IVRFormulation
        LoadFlowProblem with LPFFormulation
        OptimalPowerFlowProblem with IVRFormulation
        OptimalPowerFlowProblem with LPFFormulation
    ```

## What it would be

The physics and the limits are those of an [Optimal power flow](@ref) — the
builder is the same list of calls. What differs is the objective and one extra
pair of variables per generator.

Split the active power of each generator into the market dispatch it was given
and the volumes moved away from it:

```math
p^{\text{g}}_{u} = p^{\text{g,mkt}}_{u} + p^{\uparrow}_{u} - p^{\downarrow}_{u},
\qquad
p^{\uparrow}_{u}, p^{\downarrow}_{u} \ge 0
```

and price those volumes rather than the dispatch itself:

```math
\min \quad \sum_{n \in \mathcal{N}} w_{n} \sum_{u \in U^{\text{g}}}
           \left( c^{\uparrow}_{u} p^{\uparrow}_{u} + c^{\downarrow}_{u} p^{\downarrow}_{u} \right)
```

The upward and downward volumes are separate non-negative variables because they
are priced differently; nothing forbids both from being non-zero at once, and
with positive prices on both it is never worth doing.

## What adding it needs

Three things, and no change to any component file or to either formulation:

1. **Somewhere to put the market dispatch.** Either a `pg_market` field on
   [`Generator`](@ref) — which is a change to one component file — or an entry in
   its `ext`, written by whatever reads the market result.
2. **The volumes and their split.** A [`variable_unit`](@ref) method for
   `Generator` dispatching on `P <: RedispatchProblem`, and a
   [`constraint_unit`](@ref) method adding the equation above. Both go in
   `src/comp/unit/generator/generator.jl`, beside the methods that already
   dispatch on the other problem types.
3. **The objective.** An [`objective`](@ref) method dispatching on
   `P <: RedispatchProblem`.

Then register the builder for both formulations:

```julia
build_model!(nm::NetworkModel{P,F}) where {P<:RedispatchProblem,F<:IVRFormulation} = _build_redispatch!(nm)
build_model!(nm::NetworkModel{P,F}) where {P<:RedispatchProblem,F<:LPFFormulation} = _build_redispatch!(nm)

register_model!(RedispatchProblem, IVRFormulation)
register_model!(RedispatchProblem, LPFFormulation)
```

Because the volumes and their pricing are the only new things, and neither
mentions a voltage or a current, the problem comes out in both formulations at
once — the same way [`Storage`](@ref) and [`FlexibleLoad`](@ref) did.

## A security constrained variant

`src/core/types.jl` shows the natural extension:

```julia
abstract type SecurityConstrainedRedispatchProblem <: RedispatchProblem end
```

which would inherit everything above and differ only in that its network index
carries a `:contingency` dimension, with the outages expressed as a `status` that
varies over it. See [The network index](@ref).
