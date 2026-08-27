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
# OverheadLine — data                                                                    #
################################################################################

"""
    OverheadLine <: AbstractBranch

A two-terminal edge whose conductors are bare and suspended in air.

Electrically this is the same π-equivalent as every other
[`AbstractBranch`](@ref), and it shares every variable and constraint with
them: in a steady-state model the construction of a branch changes its
parameters, not its equations. The type is here so that a problem can address
one kind of branch — a rating that follows the wind applies to a line and not to
a cable, a planning problem costs them differently — and so that the data that
does distinguish them has somewhere to live.

# Fields
As [`Branch`](@ref), plus:
- `length_km`: the route length [km], `0.0` where it is unknown.
"""
Base.@kwdef struct OverheadLine <: AbstractBranch
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
    length_km::Float64                  = 0.0
    status   ::NetworkQuantity{Bool}    = true
    ext      ::Dict{Symbol,Any}         = Dict{Symbol,Any}()

    function OverheadLine(id, name, terminals, r, x, g_fr, b_fr, g_to, b_to,
                          rate_a, angmin, angmax, length_km, status, ext)
        _check_branch(id, terminals, angmin, angmax)
        return new(id, name, terminals, r, x, g_fr, b_fr, g_to, b_to,
                   rate_a, angmin, angmax, length_km, status, ext)
    end
end

register_edge_type!(OverheadLine)

"""
A rating that follows the ambient conditions belongs here: give `rate_a` a
[`NetworkVector`](@ref) over the `:time` dimension and the thermal limit of the
line becomes a profile without any change to the constraint that enforces it.
"""
dynamic_rating(ohl::OverheadLine) = ohl.rate_a
