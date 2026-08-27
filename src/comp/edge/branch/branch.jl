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
# Branch — data                                                                #
################################################################################

"""
    AbstractBranch <: AbstractEdge

An edge that transports electrical power between its two nodes without
transforming it: a π-equivalent with no turns ratio.

Every branch type shares the same equations. What separates [`Cable`](@ref) from
[`OverheadLine`](@ref) is the data each carries, not the physics: in a
steady-state model both are a series impedance between two shunt admittances.
The types exist so that a problem can address one kind — a rating that depends
on wind speed applies to a line and not to a cable — and so that a planning
problem can cost them differently.

A concrete branch carries `id`, `name`, `terminals` (exactly two), `r`, `x`,
`g_fr`, `b_fr`, `g_to`, `b_to`, `rate_a`, `angmin`, `angmax`, `status` and
`ext`. Every field but `id`, `name`, `terminals` and `ext` may be a
[`NetworkVector`](@ref).
"""
abstract type AbstractBranch <: AbstractEdge end

"""
    Branch <: AbstractBranch

A two-terminal edge `(e, i, j)` of unspecified construction, modelled as a
π-equivalent.

This is what a Matpower branch without a turns ratio becomes. Where the
construction is known, prefer [`Cable`](@ref) or [`OverheadLine`](@ref); where
the edge has a turns ratio it is a [`Transformer`](@ref), not a branch.

# Fields
- `id`, `name`: the identifier and a human readable label.
- `terminals`: `[i, j]`, the from and to node.
- `r`, `x`: the series resistance and reactance [pu].
- `g_fr`, `b_fr`, `g_to`, `b_to`: the shunt admittance at the from and to
  terminal [pu]. A line with total charging susceptance `b` has
  `b_fr = b_to = b/2`.
- `rate_a`: the apparent power rating [pu], `Inf` when unlimited.
- `angmin`, `angmax`: the limits on the voltage angle difference [rad].
- `status`: whether the branch is in service.
- `ext`: free-form storage.
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
    status   ::NetworkQuantity{Bool}    = true
    ext      ::Dict{Symbol,Any}         = Dict{Symbol,Any}()

    function Branch(id, name, terminals, r, x, g_fr, b_fr, g_to, b_to,
                    rate_a, angmin, angmax, status, ext)
        _check_branch(id, terminals, angmin, angmax)
        return new(id, name, terminals, r, x, g_fr, b_fr, g_to, b_to,
                   rate_a, angmin, angmax, status, ext)
    end
end

function _check_branch(id, terminals, angmin, angmax)
    length(terminals) == 2 ||
        throw(ArgumentError("branch $id has $(length(terminals)) terminals, a branch has exactly two"))
    all_nw(<=, angmin, angmax) ||
        throw(ArgumentError("branch $id has angmin above angmax"))

    return nothing
end

register_edge_type!(Branch)

"the series impedance of a branch resolved at one network index"
impedance(br::AbstractBranch) = (br.r, br.x)

"the from and to shunt admittance of a branch resolved at one network index"
shunt_admittance(br::AbstractBranch) = ((br.g_fr, br.b_fr), (br.g_to, br.b_to))

################################################################################
# Branch — variables                                                           #
################################################################################

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
