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
# v0.12.8 - a branch refuses an impedance or a rating no model can use         #
# v0.13.0 - one Branch: a cable and an overhead line are its length_km         #
# v0.13.0 - the pi-section and the series current of a branch are here         #
# v0.13.0 - a branch is limited by its ratings and its angle limit, apart      #
################################################################################

export AbstractBranch, Branch, impedance, shunt_admittance, dynamic_rating
export constraint_pi_section!, variable_edge_series_current

################################################################################
# Branch — data                                                                #
################################################################################

"""
    AbstractBranch <: AbstractEdge

An edge that transports electrical power between its two nodes without
transforming it: a π-equivalent with no turns ratio.

Every branch type shares the same equations. A cable and an overhead line are not
types of their own: in a steady-state model both are a series impedance between
two shunt admittances, so each is a [`Branch`](@ref) with its own data.

A concrete branch carries `id`, `name`, `terminals` (exactly two), `r`, `x`,
`g_fr`, `b_fr`, `g_to`, `b_to`, `rate_a`, `angmin`, `angmax`, `length_km`,
`status` and `ext`. Every field but `id`, `name`, `terminals`, `length_km` and
`ext` may be a [`NetworkVector`](@ref).
"""
abstract type AbstractBranch <: AbstractEdge end

"""
    Branch <: AbstractBranch

A two-terminal edge `(e, i, j)` modelled as a π-equivalent.

This is what a Matpower branch without a turns ratio becomes, and what a cable or
an overhead line is: they differ in `length_km` and in a rating that may follow
the weather, not in the equations. Where the edge has a turns ratio it is a
[`Transformer`](@ref), not a branch.

# Fields
- `id`, `name`: the identifier and a human readable label.
- `terminals`: `[i, j]`, the from and to node.
- `r`, `x`: the series resistance and reactance [pu].
- `g_fr`, `b_fr`, `g_to`, `b_to`: the shunt admittance at the from and to
  terminal [pu]. A line with total charging susceptance `b` has
  `b_fr = b_to = b/2`.
- `rate_a`: the apparent power rating [pu], `Inf` when unlimited.
- `angmin`, `angmax`: the limits on the voltage angle difference [rad].
- `length_km`: the route length [km], `NaN` where it is not known.
- `status`: whether the branch is in service.
- `ext`: free-form storage.

A branch is refused when its `r` or `x` is not finite, when both are 0, when a
shunt admittance is not finite, when `rate_a` is negative or NaN, when its angle
limits are out of order, or when its `length_km` is negative or infinite. A bus
coupler has no impedance to give: it is a [`Switch`](@ref).
"""
Base.@kwdef struct Branch <: AbstractBranch
    id       ::Int
    name     ::String                   = ""
    terminals::Vector{Int}
    r        ::NetworkQuantity{Float64}
    x        ::NetworkQuantity{Float64}
    g_fr     ::NetworkQuantity{Float64} = 0.0
    b_fr     ::NetworkQuantity{Float64} = 0.0
    g_to     ::NetworkQuantity{Float64} = 0.0
    b_to     ::NetworkQuantity{Float64} = 0.0
    rate_a   ::NetworkQuantity{Float64} = Inf
    angmin   ::NetworkQuantity{Float64} = -pi / 3
    angmax   ::NetworkQuantity{Float64} =  pi / 3
    length_km::Float64                  = NaN
    status   ::NetworkQuantity{Bool}    = true
    ext      ::Dict{Symbol,Any}         = Dict{Symbol,Any}()

    function Branch(id, name, terminals, r, x, g_fr, b_fr, g_to, b_to,
                    rate_a, angmin, angmax, length_km, status, ext)
        _check_branch(id, terminals, r, x, g_fr, b_fr, g_to, b_to, rate_a, angmin, angmax)
        _check_length(id, length_km)
        return new(id, name, terminals, r, x, g_fr, b_fr, g_to, b_to,
                   rate_a, angmin, angmax, length_km, status, ext)
    end
end

function _check_branch(id, terminals, r, x, g_fr, b_fr, g_to, b_to, rate_a, angmin, angmax)
    length(terminals) == 2 ||
        throw(ArgumentError("branch $id has $(length(terminals)) terminals, a branch has exactly two"))
    all_nw(isfinite, r) && all_nw(isfinite, x) ||
        throw(ArgumentError("branch $id has an impedance that is not finite"))
    all_nw((r, x) -> r^2 + x^2 > 0, r, x) ||
        throw(ArgumentError("branch $id has no impedance, r and x are both 0: " *
                            "a bus coupler is a Switch"))
    all(y -> all_nw(isfinite, y), (g_fr, b_fr, g_to, b_to)) ||
        throw(ArgumentError("branch $id has a shunt admittance that is not finite"))
    all_nw(>=(0), rate_a) ||
        throw(ArgumentError("branch $id has a rating that is negative or NaN"))
    all_nw(<=, angmin, angmax) ||
        throw(ArgumentError("branch $id has angmin above angmax"))

    return nothing
end

"refuse a route length that is negative or infinite; NaN says it is not known"
function _check_length(id, length_km)
    isnan(length_km) || (isfinite(length_km) && length_km >= 0) ||
        throw(ArgumentError("branch $id has a length that is negative or infinite"))

    return nothing
end

register_edge_type!(Branch)

"""
    structure_gates(br)

A branch writes its rating only where `rate_a` is finite and its angle limits
only where they fall inside `(-π/2, π/2)`, so those three decide the shape of
its model rather than a number in it. See [`structure_gates`](@ref).
"""
structure_gates(::AbstractBranch) = (:rate_a, :angmin, :angmax)

"the series impedance of a branch resolved at one network index"
impedance(br::AbstractBranch) = (br.r, br.x)

"the from and to shunt admittance of a branch resolved at one network index"
shunt_admittance(br::AbstractBranch) = ((br.g_fr, br.b_fr), (br.g_to, br.b_to))

"""
    dynamic_rating(br)

The rating of a branch at one network index. Give `rate_a` a
[`NetworkVector`](@ref) over the `:time` dimension and the thermal limit of the
branch becomes a profile, a rating that follows the ambient conditions, without
any change to the constraint that enforces it.
"""
dynamic_rating(br::AbstractBranch) = br.rate_a

################################################################################
# Branch — variables                                                           #
################################################################################

"""
    variable_edge_series_current(nm, T; nw)

The series current of every in-service edge of type `T`, added to the `:csr` and
`:csi` containers shared by every edge type that has one.

The container is a `Dict` rather than a JuMP array because several edge types
contribute to it: the dispatcher visits one concrete type at a time, and each
adds its own edges to the same two containers.
"""
function variable_edge_series_current(nm::NetworkModel, ::Type{T}; nw::Int) where {T<:AbstractEdge}
    variable_container!(nm, :csr, :csi; nw)

    for e in ids(nm, T; nw)
        variable!(nm, :csr, e; nw, base_name = "$(nw)_csr[$e]", start = 0.0)
        variable!(nm, :csi, e; nw, base_name = "$(nw)_csi[$e]", start = 0.0)
    end

    return nothing
end

"""
    variable_edge(nm, T; nw)

The series current of every in-service branch, `csr` and `csi`. Together with
the terminal currents shared by every edge type these close the branch model.
"""
variable_edge(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
             ) where {P<:AbstractProblemType,F<:IVRFormulation,T<:AbstractBranch} =
    variable_edge_series_current(nm, T; nw)

################################################################################
# Branch — constraints                                                         #
################################################################################

# A branch is a π-equivalent: a series impedance `z = r + jx` between two shunt
# admittances `y = g + jb`. `csr, csi` is the series current, defined positive
# from the from side to the to side.

"""
    constraint_pi_section!(nm, ctr, cti, vtr, vti, a_to, e, z, y_fr, y_to; nw)

Add the equations of a π-equivalent whose from side sees the current
`ctr + j·cti` at the voltage `vtr + j·vti`, and whose to side is the arc `a_to`.

`ctr`, `cti`, `vtr` and `vti` may be variables or expressions, which is what lets
a transformer hand in the quantities behind its ideal ratio.

```math
\\begin{aligned}
c^{\\text{t}} &= y^{\\text{sh}}_{\\text{fr}} v^{\\text{t}} + c^{\\text{s}}, \\\\
c_{a^{\\text{t}}} &= -c^{\\text{s}} + y^{\\text{sh}}_{\\text{to}} v_{j}, \\\\
v^{\\text{t}} - v_{j} &= z \\, c^{\\text{s}}.
\\end{aligned}
```
"""
function constraint_pi_section!(nm::NetworkModel, ctr, cti, vtr, vti, a_to::Arc, e::Int,
                                z::Tuple{<:Real,<:Real},
                                y_fr::Tuple{<:Real,<:Real},
                                y_to::Tuple{<:Real,<:Real}; nw::Int)
    r, x         = z
    g_fr, b_fr   = y_fr
    g_to, b_to   = y_to
    j            = a_to.node

    vr, vi   = var(nm, :vr;  nw), var(nm, :vi;  nw)
    cr, ci   = var(nm, :cr;  nw), var(nm, :ci;  nw)
    csr, csi = var(nm, :csr; nw), var(nm, :csi; nw)

    return (
        constrain!(nm, :pi_section, (e, :cr_fr),
                   JuMP.@build_constraint(ctr == g_fr * vtr - b_fr * vti + csr[e]); nw),
        constrain!(nm, :pi_section, (e, :ci_fr),
                   JuMP.@build_constraint(cti == g_fr * vti + b_fr * vtr + csi[e]); nw),
        constrain!(nm, :pi_section, (e, :cr_to),
                   JuMP.@build_constraint(cr[a_to] == -csr[e] + g_to * vr[j] - b_to * vi[j]); nw),
        constrain!(nm, :pi_section, (e, :ci_to),
                   JuMP.@build_constraint(ci[a_to] == -csi[e] + g_to * vi[j] + b_to * vr[j]); nw),
        constrain!(nm, :pi_section, (e, :vr),
                   JuMP.@build_constraint(vtr - vr[j] == r * csr[e] - x * csi[e]); nw),
        constrain!(nm, :pi_section, (e, :vi),
                   JuMP.@build_constraint(vti - vi[j] == r * csi[e] + x * csr[e]); nw),
    )
end

"""
    constraint_edge(nm, T; nw)

The physics of every in-service branch: how the terminal currents split over the
series and shunt admittances of the π-equivalent, and the voltage drop that
links the two terminals.

```math
\\begin{aligned}
c_{a^{\\text{f}}} &= y^{\\text{sh}}_{\\text{fr}} v_{i} + c^{\\text{s}}_{e}, \\\\
c_{a^{\\text{t}}} &= -c^{\\text{s}}_{e} + y^{\\text{sh}}_{\\text{to}} v_{j}, \\\\
v_{i} - v_{j} &= (r + j x) \\, c^{\\text{s}}_{e}.
\\end{aligned}
```
"""
function constraint_edge(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractProblemType,F<:IVRFormulation,T<:AbstractBranch}
    vr, vi = var(nm, :vr; nw), var(nm, :vi; nw)
    cr, ci = var(nm, :cr; nw), var(nm, :ci; nw)

    branch = get!(() -> Dict{Int,Any}(), con(nm; nw), :branch)

    for e in ids(nm, T; nw)
        br         = edge(nm, e; nw)::T
        a_fr, a_to = edge_arcs(nm, e; nw)
        i          = a_fr.node

        branch[e] = constraint_pi_section!(nm, cr[a_fr], ci[a_fr], vr[i], vi[i],
                                           a_to, e, impedance(br),
                                           shunt_admittance(br)...; nw)
    end

    return nothing
end

"""
    constraint_edge_limits(nm, T; nw)

The apparent power rating at every terminal of a branch and the limits on the
voltage angle difference across it. Only a dispatch problem imposes them.
"""
function constraint_edge_limits(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                               ) where {P<:AbstractDispatchProblem,F<:IVRFormulation,T<:AbstractBranch}
    rating = get!(() -> Dict{Int,Any}(), con(nm; nw), :edge_rating)
    angle  = get!(() -> Dict{Int,Any}(), con(nm; nw), :edge_angle_difference)

    for e in ids(nm, T; nw)
        br         = edge(nm, e; nw)::T
        a_fr, a_to = edge_arcs(nm, e; nw)

        rating[e] = constraint_edge_rating!(nm, e, br.rate_a; nw)
        angle[e]  = constraint_edge_angle_difference!(nm, a_fr, a_to,
                                                      br.angmin, br.angmax; nw)
    end

    return nothing
end

################################################################################
# Branch — the linearized formulation                                          #
################################################################################

"""
    variable_edge(nm, T; nw)

A branch needs no variables of its own under a [`LPFFormulation`](@ref): its
flow is the terminal power every edge already has, and there is no series
current left to carry once the model is lossless.
"""
variable_edge(::NetworkModel{P,F}, ::Type{T}; nw::Int = 0
             ) where {P<:AbstractProblemType,F<:LPFFormulation,T<:AbstractBranch} = nothing

"""
    constraint_edge(nm, T; nw)

The linearized flow of every in-service branch,

```math
p_{a^{\\text{f}}} = -b_{e} \\left(v^{\\text{a}}_{i} - v^{\\text{a}}_{j}\\right),
\\qquad
p_{a^{\\text{t}}} = -p_{a^{\\text{f}}} ,
```

with `b_e` the series susceptance, see [`susceptance`](@ref). The shunt
admittance of the branch plays no part: its susceptance is reactive, and its
conductance would draw a constant power that the same three approximations
discard along with the rest of the loss.
"""
function constraint_edge(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractProblemType,F<:LPFFormulation,T<:AbstractBranch}
    branch = get!(() -> Dict{Int,Any}(), con(nm; nw), :branch)

    for e in ids(nm, T; nw)
        br         = edge(nm, e; nw)::T
        a_fr, a_to = edge_arcs(nm, e; nw)

        branch[e] = constraint_linear_flow!(nm, e, a_fr, a_to,
                                            susceptance(br.r, br.x), 0.0; nw)
    end

    return nothing
end

"""
    constraint_edge_limits(nm, T; nw)

The rating at every terminal and the angle difference limit of every in-service
branch, see [`constraint_linear_ratings!`](@ref) and
[`constraint_linear_angle_difference!`](@ref).
"""
function constraint_edge_limits(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                               ) where {P<:AbstractDispatchProblem,F<:LPFFormulation,T<:AbstractBranch}
    limits = get!(() -> Dict{Int,Any}(), con(nm; nw), :edge_limits)

    for e in ids(nm, T; nw)
        br = edge(nm, e; nw)::T
        A  = edge_arcs(nm, e; nw)

        limits[e] = (constraint_linear_ratings!(nm, e, A, br.rate_a; nw),
                     constraint_linear_angle_difference!(nm, A[1], A[2], br.angmin, br.angmax; nw))
    end

    return nothing
end
