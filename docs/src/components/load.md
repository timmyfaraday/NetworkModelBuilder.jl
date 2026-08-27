# Load

A load is a unit ``(u, i)`` that withdraws power from its node. What separates a
load from a [Generator](@ref) is not the sign of the power — a load may well have
a negative reactive demand — but where the number comes from.

```@docs
AbstractLoad
FixedLoad
FlexibleLoad
demand
```

Both load types are constant **power**: at any voltage they take the same ``p``
and ``q``. The constant impedance case is a [Shunt](@ref).

## Parameters

### `FixedLoad`

| symbol | field | description | unit |
|:-------|:------|:------------|:-----|
| | `id`, `name`, `node` | identifier, label, node | |
| ``p^{\text{d}}_{u}`` | `pd` | active power withdrawn | pu |
| ``q^{\text{d}}_{u}`` | `qd` | reactive power withdrawn | pu |
| | `status` | in service | |

A demand that follows a profile is still a fixed load: give `pd` and `qd` a
[`NetworkVector`](@ref) and each network index gets its own number. What makes a
load *flexible* is that the **model** chooses the number.

### `FlexibleLoad`

| symbol | field | description | unit |
|:-------|:------|:------------|:-----|
| ``p^{\text{d,nom}}_{u}`` | `pd_nominal` | demand without flexibility | pu |
| ``q^{\text{d,nom}}_{u}`` | `qd_nominal` | reactive demand at the nominal point | pu |
| ``p^{\text{d,min}}_{u}``, ``p^{\text{d,max}}_{u}`` | `pd_min`, `pd_max` | limits on the shifted demand | pu |
| ``E_{u}`` | `energy` | energy it must receive over the horizon | pu·h |
| | `status` | in service | |

`energy` defaults to `NaN`, which means the energy the nominal profile would have
taken.

## Variables

### In the `IVRFormulation`

| symbol | key | index | description | unit | when |
|:-------|:----|:------|:------------|:-----|:-----|
| ``c^{\text{r}}_{u}``, ``c^{\text{i}}_{u}`` | `:cru`, `:ciu` | unit | injected current | pu | all |
| ``p^{\text{d}}_{u}`` | `:pdf` | unit | active demand | pu | [`FlexibleLoad`](@ref), dispatch |

## Constraints

Both load types share one constraint, and differ only in what [`demand`](@ref)
returns:

```math
v^{\text{r}}_{i} c^{\text{r}}_{u} + v^{\text{i}}_{i} c^{\text{i}}_{u} = -p^{\text{d}}_{u},
\qquad
v^{\text{i}}_{i} c^{\text{r}}_{u} - v^{\text{r}}_{i} c^{\text{i}}_{u} = -q^{\text{d}}_{u} .
```

For a [`FixedLoad`](@ref) the right-hand sides are data. For a
[`FlexibleLoad`](@ref) in a dispatch problem ``p^{\text{d}}_{u}`` is the variable
`:pdf`, and the reactive demand follows it at the power factor of the nominal
point, ``q^{\text{d}}_{u} = (q^{\text{d,nom}}_{u} / p^{\text{d,nom}}_{u}) \,
p^{\text{d}}_{u}``, so that shifting a load does not silently change what it does
to voltages. In a power flow a flexible load has no freedom and sits at its
nominal value.

### Across network indices

A flexible load adds one energy balance per horizon:

```math
\sum_{n \in \mathcal{T}} \Delta t_{n} \, p^{\text{d}}_{u,n} = E_{u}
```

where ``\mathcal{T}`` runs over the `:time` coordinates while every other
coordinate of the network index is held fixed. A problem with a contingency
dimension therefore gets one balance per contingency, which makes each
contingency a self-contained day rather than a shared one.

!!! note "It needs a time dimension"
    A flexible load couples network indices along `:time`, so the problem must
    have such a dimension. Without one the model is not built and the error says
    so. See [The network index](@ref).

```@docs
power_factor_ratio
constraint_unit_coupling
time_step
require_time_dimension
```
