################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.3.0 - component hierarchy                                                 #
################################################################################

################################################################################
# Transformer — data                                                           #
################################################################################

"""
    AbstractTransformer <: AbstractEdge

An edge that transforms electrical power between its nodes, i.e., an edge with a
turns ratio.

The ratio is complex, `T = tm · exp(j·ta)`: its magnitude `tm` scales the
voltage and its angle `ta` shifts it. A [`Transformer`](@ref) holds both fixed, a
[`TapChanger`](@ref) makes `tm` a decision variable and a
[`PhaseShifter`](@ref) makes `ta` one. A [`MultiWindingTransformer`](@ref) has
three or more terminals.
"""
abstract type AbstractTransformer <: AbstractEdge end

"""
    AbstractTwoWindingTransformer <: AbstractTransformer

A transformer between exactly two nodes: an ideal ratio on the from side in
series with a π-equivalent.

Rather than substitute the ratio into the π-equations, the voltage behind the
ratio is carried as an *edge* variable, `vtr` and `vti`. Two consequences follow.
The ideal transformer and the impedance are then written separately, each in its
own form, so the same code serves a fixed ratio and a ratio that the optimizer
chooses. And the equations stay polynomial when the ratio is a variable, where
substituting would have divided by it.

The internal point is not a node. It never enters `I`, gets no identifier, and
carries no balance of its own; it is a variable belonging to the edge. See
[`MultiWindingTransformer`](@ref) for the same idea with more terminals.
"""
abstract type AbstractTwoWindingTransformer <: AbstractTransformer end

"""
    Transformer <: AbstractTwoWindingTransformer

A two-winding transformer whose turns ratio is fixed.

This is what a Matpower branch with a non-unit ratio or a non-zero angle
becomes. Where the ratio is a control the optimizer should choose, use
[`TapChanger`](@ref) or [`PhaseShifter`](@ref).

# Fields
- `id`, `name`: the identifier and a human readable label.
- `terminals`: `[i, j]`, the from and to node. The ratio sits on the from side.
- `r`, `x`: the series resistance and reactance [pu], referred to the to side.
- `g_fr`, `b_fr`, `g_to`, `b_to`: the shunt admittance behind the ratio and at
  the to terminal [pu].
- `tm`, `ta`: the magnitude [pu] and angle [rad] of the turns ratio.
- `rate_a`: the apparent power rating [pu], `Inf` when unlimited.
- `angmin`, `angmax`: the limits on the voltage angle difference [rad].
- `status`: whether the transformer is in service.
- `ext`: free-form storage.
"""
Base.@kwdef struct Transformer <: AbstractTwoWindingTransformer
    id       ::Int
    name     ::String                   = ""
    terminals::Vector{Int}
    r        ::NetworkQuantity{Float64}
    x        ::NetworkQuantity{Float64}
    g_fr     ::NetworkQuantity{Float64} = 0.0
    b_fr     ::NetworkQuantity{Float64} = 0.0
    g_to     ::NetworkQuantity{Float64} = 0.0
    b_to     ::NetworkQuantity{Float64} = 0.0
    tm       ::NetworkQuantity{Float64} = 1.0
    ta       ::NetworkQuantity{Float64} = 0.0
    rate_a   ::NetworkQuantity{Float64} = Inf
    angmin   ::NetworkQuantity{Float64} = -pi / 3
    angmax   ::NetworkQuantity{Float64} =  pi / 3
    status   ::NetworkQuantity{Bool}    = true
    ext      ::Dict{Symbol,Any}         = Dict{Symbol,Any}()

    function Transformer(id, name, terminals, r, x, g_fr, b_fr, g_to, b_to, tm, ta,
                         rate_a, angmin, angmax, status, ext)
        _check_transformer(id, terminals, tm, angmin, angmax)
        return new(id, name, terminals, r, x, g_fr, b_fr, g_to, b_to, tm, ta,
                   rate_a, angmin, angmax, status, ext)
    end
end

function _check_transformer(id, terminals, tm, angmin, angmax)
    length(terminals) == 2 ||
        throw(ArgumentError("transformer $id has $(length(terminals)) terminals, a two-winding transformer has exactly two"))
    all_nw(>(0), tm) ||
        throw(ArgumentError("transformer $id has a non-positive tap magnitude"))
    all_nw(<=, angmin, angmax) ||
        throw(ArgumentError("transformer $id has angmin above angmax"))

    return nothing
end

register_edge_type!(Transformer)

"a two-winding transformer gates on the same three fields a branch does"
structure_gates(::AbstractTwoWindingTransformer) = (:rate_a, :angmin, :angmax)

"the series impedance of a transformer resolved at one network index"
impedance(tf::AbstractTransformer) = (tf.r, tf.x)

"the shunt admittance behind the ratio and at the to terminal"
shunt_admittance(tf::AbstractTwoWindingTransformer) =
    ((tf.g_fr, tf.b_fr), (tf.g_to, tf.b_to))

"""
    tap_ratio(nm, tf, e; nw)

The real and imaginary part of the turns ratio `T = tm · exp(j·ta)` of
transformer `e`.

This is the single point at which the three two-winding transformer types
differ. A [`Transformer`](@ref) returns two numbers whatever the problem. A
[`PhaseShifter`](@ref) and a [`TapChanger`](@ref) return numbers in a power flow,
where their setting is a given, and the variables the optimizer chooses in a
dispatch problem.
"""
function tap_ratio end

tap_ratio(::NetworkModel, tf::AbstractTwoWindingTransformer, ::Int; nw::Int) =
    (tf.tm * cos(tf.ta), tf.tm * sin(tf.ta))

################################################################################
# Transformer — variables                                                      #
################################################################################

"""
    variable_edge(nm, T; nw)

The series current of every in-service two-winding transformer and the complex
voltage behind its ratio.
"""
variable_edge(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
             ) where {P<:AbstractProblemType,F<:IVRFormulation,
                      T<:AbstractTwoWindingTransformer} =
    variable_two_winding!(nm, T; nw)

"the variables every two-winding transformer has, whatever its tap is"
function variable_two_winding!(nm::NetworkModel, ::Type{T}; nw::Int) where {T<:AbstractTwoWindingTransformer}
    variable_edge_series_current(nm, T; nw)



    variable_container!(nm, :vtr, :vti; nw)

    for e in ids(nm, T; nw)
        variable!(nm, :vtr, e; nw, base_name = "$(nw)_vtr[$e]", start = 1.0)
        variable!(nm, :vti, e; nw, base_name = "$(nw)_vti[$e]", start = 0.0)
    end

    return nothing
end

################################################################################
# Transformer — constraints                                                    #
################################################################################

"""
    constraint_edge(nm, T; nw)

The physics of every in-service two-winding transformer: the ideal ratio, and
the π-equivalent behind it.

With `T = tr + j·ti` the ratio, `v^{\\text{t}}` the voltage behind it and
`c_{a^{\\text{f}}}` the current at the from terminal,

```math
v_{i} = T \\, v^{\\text{t}}, \\qquad c^{\\text{t}} = \\overline{T} \\, c_{a^{\\text{f}}},
```

which conserves complex power across the ideal part, and `v^{\\text{t}}` and
`c^{\\text{t}}` then meet the π-equivalent exactly as a branch's own voltage and
current do.
"""
function constraint_edge(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractProblemType,F<:IVRFormulation,
                                 T<:AbstractTwoWindingTransformer}
    vr,  vi  = var(nm, :vr;  nw), var(nm, :vi;  nw)
    cr,  ci  = var(nm, :cr;  nw), var(nm, :ci;  nw)
    vtr, vti = var(nm, :vtr; nw), var(nm, :vti; nw)

    ratio  = get!(() -> Dict{Int,Any}(), con(nm; nw), :transformer_ratio)
    branch = get!(() -> Dict{Int,Any}(), con(nm; nw), :branch)

    for e in ids(nm, T; nw)
        tf         = edge(nm, e; nw)::T
        a_fr, a_to = edge_arcs(nm, e; nw)
        i          = a_fr.node
        tr, ti     = tap_ratio(nm, tf, e; nw)

        ratio[e] = (
            constrain!(nm, :transformer_ratio, (e, :real),
                       JuMP.@build_constraint(vr[i] == tr * vtr[e] - ti * vti[e]); nw),
            constrain!(nm, :transformer_ratio, (e, :imag),
                       JuMP.@build_constraint(vi[i] == tr * vti[e] + ti * vtr[e]); nw))

        ctr = JuMP.@expression(nm.model, tr * cr[a_fr] + ti * ci[a_fr])
        cti = JuMP.@expression(nm.model, tr * ci[a_fr] - ti * cr[a_fr])

        branch[e] = constraint_pi_section!(nm, ctr, cti, vtr[e], vti[e], a_to, e,
                                           impedance(tf), shunt_admittance(tf)...; nw)
    end

    return nothing
end

"""
    constraint_edge_limits(nm, T; nw)

The apparent power rating at every terminal of a two-winding transformer and the
limits on the voltage angle difference across it.
"""
constraint_edge_limits(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                      ) where {P<:AbstractDispatchProblem,F<:IVRFormulation,
                               T<:AbstractTwoWindingTransformer} =
    constraint_two_winding_limits!(nm, T; nw)

"the limits every two-winding transformer has, whatever its tap is"
function constraint_two_winding_limits!(nm::NetworkModel, ::Type{T}; nw::Int
                                       ) where {T<:AbstractTwoWindingTransformer}
    rating = get!(() -> Dict{Int,Any}(), con(nm; nw), :edge_rating)
    angle  = get!(() -> Dict{Int,Any}(), con(nm; nw), :edge_angle_difference)

    for e in ids(nm, T; nw)
        tf         = edge(nm, e; nw)::T
        a_fr, a_to = edge_arcs(nm, e; nw)

        rating[e] = constraint_edge_rating!(nm, e, tf.rate_a; nw)
        angle[e]  = constraint_edge_angle_difference!(nm, a_fr, a_to,
                                                      tf.angmin, tf.angmax; nw)
    end

    return nothing
end

################################################################################
# Transformer — solution                                                       #
################################################################################

"the tap setting of a two-winding transformer at network index `nw`"
function solution_tap(nm::NetworkModel, tf::AbstractTwoWindingTransformer, e::Int, nw::Int)
    tr, ti = tap_ratio(nm, tf, e; nw)
    tr, ti = _value(tr), _value(ti)

    return Dict{String,Any}("tr" => tr, "ti" => ti,
                            "tm" => hypot(tr, ti), "ta" => atan(ti, tr))
end

"""
    solution_edge!(entry, nm, T, e, nw)

Add the tap setting of a two-winding transformer to its solution. For a
[`Transformer`](@ref) this reports back what was given; for a
[`PhaseShifter`](@ref) or a [`TapChanger`](@ref) in a dispatch problem it is what
the optimizer chose.
"""
function solution_edge!(entry::Dict{String,Any}, nm::NetworkModel, ::Type{T}, e::Int, nw::Int
                       ) where {T<:AbstractTwoWindingTransformer}
    entry["tap"] = solution_tap(nm, edge(nm, e; nw)::T, e, nw)

    return nothing
end

################################################################################
# Transformer — the linearized formulation                                     #
################################################################################

"""
    phase_shift(nm, tf, e; nw)

The angle a transformer shifts, `ta_{e}`.

This is the counterpart of [`tap_ratio`](@ref) for a linearized formulation, and
the single point at which the two-winding transformer types differ there. A
[`Transformer`](@ref) and a [`TapChanger`](@ref) return a number; a
[`PhaseShifter`](@ref) returns a number in a power flow and the variable the
optimizer chooses in a dispatch problem.
"""
phase_shift(::NetworkModel, tf::AbstractTwoWindingTransformer, ::Int; nw::Int) = tf.ta

"""
    variable_edge(nm, T; nw)

A two-winding transformer with a fixed ratio needs no variables of its own under
a [`LPFFormulation`](@ref).

!!! note "The tap magnitude does nothing here"
    With every voltage magnitude equal to one there is nothing for a ratio
    magnitude to change, so `tm` does not appear in the linearized equations at
    all — for a [`Transformer`](@ref) or a [`TapChanger`](@ref) alike. A tap
    changer is therefore **inert** in this formulation: it is built and solved as
    an ordinary transformer at its fixed phase angle, and the control it offers
    an alternating current model is simply absent. Use an
    [`IVRFormulation`](@ref) where that control is the point.
"""
variable_edge(::NetworkModel{P,F}, ::Type{T}; nw::Int = 0
             ) where {P<:AbstractProblemType,F<:LPFFormulation,
                      T<:AbstractTwoWindingTransformer} = nothing

"""
    constraint_edge(nm, T; nw)

The linearized flow of every in-service two-winding transformer,

```math
p_{a^{\\text{f}}} = -b_{e} \\left(v^{\\text{a}}_{i} - v^{\\text{a}}_{j} - ta_{e}\\right),
\\qquad
p_{a^{\\text{t}}} = -p_{a^{\\text{f}}} .
```

The phase shift survives the approximations and the ratio magnitude does not,
which is what makes a [`PhaseShifter`](@ref) a real control in this formulation
and a [`TapChanger`](@ref) an inert one.
"""
constraint_edge(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
               ) where {P<:AbstractProblemType,F<:LPFFormulation,
                        T<:AbstractTwoWindingTransformer} =
    constraint_two_winding_flow!(nm, T; nw)

"""
    constraint_two_winding_flow!(nm, T; nw)

The linearized flow of every in-service two-winding transformer of type `T`,
written through [`constraint_linear_flow!`](@ref).

The body of the method above, factored out so that a type which adds something
to a redispatch — a priced [`PhaseShifter`](@ref) — can write the physics it
shares with every other transformer rather than a second copy of it. The
counterpart of [`constraint_two_winding_limits!`](@ref) in the current based
formulation.
"""
function constraint_two_winding_flow!(nm::NetworkModel, ::Type{T}; nw::Int
                                     ) where {T<:AbstractTwoWindingTransformer}
    branch = get!(() -> Dict{Int,Any}(), con(nm; nw), :branch)

    for e in ids(nm, T; nw)
        tf         = edge(nm, e; nw)::T
        a_fr, a_to = edge_arcs(nm, e; nw)

        branch[e] = constraint_linear_flow!(nm, e, a_fr, a_to, susceptance(tf.r, tf.x),
                                            phase_shift(nm, tf, e; nw); nw)
    end

    return nothing
end

"""
    constraint_edge_limits(nm, T; nw)

The rating and the angle difference limits of every in-service two-winding
transformer.
"""
function constraint_edge_limits(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                               ) where {P<:AbstractDispatchProblem,F<:LPFFormulation,
                                        T<:AbstractTwoWindingTransformer}
    limits = get!(() -> Dict{Int,Any}(), con(nm; nw), :edge_limits)

    for e in ids(nm, T; nw)
        tf         = edge(nm, e; nw)::T
        a_fr, a_to = edge_arcs(nm, e; nw)

        limits[e] = constraint_linear_limits!(nm, e, a_fr, a_to,
                                              tf.rate_a, tf.angmin, tf.angmax; nw)
    end

    return nothing
end

"the tap setting of a two-winding transformer under a linearized formulation"
function solution_edge!(entry::Dict{String,Any}, nm::NetworkModel{P,F}, ::Type{T},
                        e::Int, nw::Int) where {P<:AbstractProblemType,F<:LPFFormulation,
                                                T<:AbstractTwoWindingTransformer}
    tf = edge(nm, e; nw)::T
    entry["tap"] = Dict{String,Any}("tm" => tf.tm, "ta" => _value(phase_shift(nm, tf, e; nw)))

    return nothing
end
