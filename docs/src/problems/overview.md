# Problems

A problem type answers the question *which question is asked of the network*:
which degrees of freedom are free, which are fixed by a setpoint, and what is
being minimized. It is one half of what selects a model; the other half is the
[formulation](@ref "Problems and formulations").

| problem | asks | objective |
|:--------|:-----|:----------|
| [Load flow](@ref) | where does the network settle, with every injection given? | none — it is a feasibility problem |
| [Optimal power flow](@ref) | what is the cheapest dispatch the network admits? | the generation cost |
| [Redispatch](@ref) | what is the cheapest deviation from a given dispatch? | the cost of deviating |

Each has a page below stating what it fixes and what it frees, and one subpage
per formulation writing out the complete optimization problem — every variable,
every constraint, and the objective.

## The builder is shared between formulations

There is one builder per problem, and both formulations use it:

```julia
build_model!(nm::NetworkModel{P,F}) where {P<:LoadFlowProblem,F<:IVRFormulation} = _build_load_flow!(nm)
build_model!(nm::NetworkModel{P,F}) where {P<:LoadFlowProblem,F<:LPFFormulation} = _build_load_flow!(nm)
```

```julia
function _build_load_flow!(nm::NetworkModel)
    for n in nw_ids(nm)
        variable_node_voltage(nm; nw = n)
        variable_edge(nm; nw = n)
        variable_unit(nm; nw = n)

        constraint_node_voltage_reference(nm; nw = n)
        constraint_node_voltage_setpoint(nm; nw = n)
        constraint_node_balance(nm; nw = n)
        constraint_edge(nm; nw = n)
        constraint_unit(nm; nw = n)
    end

    constraint_edge_coupling(nm)
    constraint_unit_coupling(nm)
    objective(nm)
end
```

Every name in it is a dispatch point, so the definition of a problem says nothing
about the formulation it is being built in, and nothing about which component
types exist. The two loops that matter are implicit: `variable_edge` and
`constraint_edge` walk the registry of edge types, `variable_unit` and
`constraint_unit` the registry of unit types.

The two calls outside the loop over network indices are for constraints that
*span* indices — a storage state of charge, a flexible load's energy — which
cannot be written from inside it.

## Additional notation

Beyond the [symbols in the introduction](@ref "Notation"), these pages use:

| symbol | meaning |
|:-------|:--------|
| ``I^{\text{ref}}, I^{\text{pv}}, I^{\text{pq}}`` | the reference, `PV` and `PQ` nodes |
| ``E^{\text{br}}`` | the branches, any [`AbstractBranch`](@ref) |
| ``E^{\text{tf}}`` | the two-winding transformers, any [`AbstractTwoWindingTransformer`](@ref) |
| ``E^{\text{ps}} \subseteq E^{\text{tf}}`` | the phase shifters |
| ``E^{\text{mw}}`` | the multi-winding transformers |
| ``U^{\text{g}}, U^{\text{d}}, U^{\text{s}}, U^{\text{sh}}`` | the generators, loads, storage units and shunts |
| ``U^{\text{fl}} \subseteq U^{\text{d}}`` | the flexible loads |
| ``E^{\text{mon}} \subseteq E`` | the monitored edges of a redispatch |
| ``a^{\text{f}}_{e}, a^{\text{t}}_{e}`` | the from and to arc of a two-terminal edge `e` |
| ``a_{e,k}`` | the arc of winding `k` of a multi-winding transformer |
| ``\mathcal{N}`` | the network indices, ``\mathcal{T}`` a horizon along `:time` |
| ``p^{\uparrow}_{u}, p^{\downarrow}_{u}`` | the volumes a unit moved up and down from its market schedule |

Every variable and constraint below exists **once per network index**. The index
is written out only where a constraint relates one index to another; elsewhere it
is dropped to keep the equations readable.
