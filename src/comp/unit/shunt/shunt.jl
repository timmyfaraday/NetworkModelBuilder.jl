################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.3.0 - component hierarchy                                                 #
# v0.10.1 - exports its own public names                                       #
# v0.12.8 - a shunt refuses an admittance that is not finite                   #
# v0.14.0 - variable and solution keys follow the nomenclature                 #
################################################################################

export AbstractShunt, Shunt

################################################################################
# Shunt — data                                                                 #
################################################################################

"""
    AbstractShunt <: AbstractUnit

A unit that draws a current proportional to the voltage of its node, i.e., a
constant impedance.

Constant impedance, not "reactive power", is what distinguishes a shunt. Its
admittance `y = g + jb` has a conductance as well as a susceptance, and that
conductance draws *active* power in proportion to the square of the voltage
magnitude. What makes a shunt cheap in a current based formulation is that
`c = -y v` is linear, where the constant power of a [`FixedLoad`](@ref) is not.
"""
abstract type AbstractShunt <: AbstractUnit end

"""
    Shunt <: AbstractShunt

A unit `(u, i)` of constant admittance.

# Fields
- `id`, `name`: the identifier and a human readable label.
- `node`: the node the shunt is connected to.
- `gs`, `bs`: the conductance and susceptance of the shunt admittance
  `y^{\\text{s}}_u = g^{\\text{s}}_u + j b^{\\text{s}}_u` [pu].
- `status`: whether the shunt is in service.
- `ext`: free-form storage.

`gs`, `bs` and `status` may be given as a [`NetworkVector`](@ref); a switched
capacitor bank is a `bs` that varies over the network index. An admittance that is
not finite is refused; a negative `bs` is an inductor, and is not.
"""
Base.@kwdef struct Shunt <: AbstractShunt
    id    ::Int
    name  ::String                    = ""
    node  ::Int
    gs    ::NetworkQuantity{Float64}  = 0.0
    bs    ::NetworkQuantity{Float64}  = 0.0
    status::NetworkQuantity{Bool}     = true
    ext   ::Dict{Symbol,Any}          = Dict{Symbol,Any}()

    function Shunt(id, name, node, gs, bs, status, ext)
        all_nw(isfinite, gs) && all_nw(isfinite, bs) ||
            throw(ArgumentError("shunt $id has an admittance that is not finite"))
        return new(id, name, node, gs, bs, status, ext)
    end
end

register_unit_type!(Shunt)

################################################################################
# Shunt — constraints                                                          #
################################################################################

"""
    constraint_unit(nm, T; nw)

Fix the current a shunt injects into its node at `c_u = -y^{\\text{s}}_u v_i`,
i.e.,

```math
c^{\\text{r}}_{u} = -\\left(g^{\\text{s}}_{u} v^{\\text{r}}_{i} - b^{\\text{s}}_{u} v^{\\text{i}}_{i}\\right),
\\qquad
c^{\\text{i}}_{u} = -\\left(g^{\\text{s}}_{u} v^{\\text{i}}_{i} + b^{\\text{s}}_{u} v^{\\text{r}}_{i}\\right).
```
"""
function constraint_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractProblemType,F<:IVRFormulation,T<:AbstractShunt}
    v_real, v_imag           = var(nm, :v_real;      nw), var(nm, :v_imag;      nw)
    i_unit_real, i_unit_imag = var(nm, :i_unit_real; nw), var(nm, :i_unit_imag; nw)
    current                  = get!(() -> Dict{Int,Any}(), con(nm; nw), :shunt_current)

    for u in ids(nm, T; nw)
        sh = unit(nm, u; nw)::T
        i  = sh.node
        current[u] = (
            constrain!(nm, :shunt_current, (u, :real),
                       JuMP.@build_constraint(i_unit_real[u] == -(sh.gs * v_real[i] - sh.bs * v_imag[i])); nw),
            constrain!(nm, :shunt_current, (u, :imag),
                       JuMP.@build_constraint(i_unit_imag[u] == -(sh.gs * v_imag[i] + sh.bs * v_real[i])); nw))
    end

    return nothing
end

################################################################################
# Shunt — solution                                                             #
################################################################################

function solution_unit!(sol::Dict{String,Any}, nm::NetworkModel, ::Type{T}, u::Int, nw::Int
                       ) where {T<:AbstractShunt}
    sh = unit(nm, u; nw)::T
    sol["g"] = sh.gs
    sol["b"] = sh.bs

    return nothing
end

################################################################################
# Shunt — the linearized formulation                                           #
################################################################################

"""
    constraint_unit(nm, T; nw)

A shunt withdraws a constant active power under a [`LPFFormulation`](@ref),

```math
p_{u} = -g^{\\text{s}}_{u} ,
```

because with the voltage magnitude fixed at one the current it draws is fixed
too. Its susceptance is reactive and plays no part.

The conductance is kept rather than dropped along with the susceptance: it is a
real active withdrawal, and keeping it costs nothing, since it is a constant in
the node balance. Note that `Gs` is zero throughout the Matpower cases in the
test suite, so this choice makes no difference there.
"""
function constraint_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractProblemType,F<:LPFFormulation,T<:AbstractShunt}
    current = get!(() -> Dict{Int,Any}(), con(nm; nw), :shunt_current)

    for u in ids(nm, T; nw)
        current[u] = constraint_unit_injection!(nm, u, -(unit(nm, u; nw)::T).gs; nw)
    end

    return nothing
end
