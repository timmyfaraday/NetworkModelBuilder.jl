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
# TapChanger — data                                                            #
################################################################################

"""
    TapChanger <: AbstractTwoWindingTransformer

A two-winding transformer whose ratio magnitude is a control: an on-load tap
changer, which raises or lowers the voltage on one side of itself and so steers
reactive power and holds voltages within their limits.

The magnitude is a *decision variable* in a dispatch problem, held between
`tm_min` and `tm_max`, and is fixed at the setpoint `tm` in a power flow. The tap
is treated as continuous; a real tap changer moves in steps, and modelling that
faithfully would make the problem an integer one, which is a different class of
model and a different solver.

# Fields
As [`Transformer`](@ref), where `tm` is the setpoint, plus:
- `tm_min`, `tm_max`: the limits of the ratio magnitude [pu].
"""
Base.@kwdef struct TapChanger <: AbstractTwoWindingTransformer
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
    tm_min   ::NetworkQuantity{Float64} = 0.9
    tm_max   ::NetworkQuantity{Float64} = 1.1
    rate_a   ::NetworkQuantity{Float64} = Inf
    angmin   ::NetworkQuantity{Float64} = -pi / 3
    angmax   ::NetworkQuantity{Float64} =  pi / 3
    status   ::NetworkQuantity{Bool}    = true
    ext      ::Dict{Symbol,Any}         = Dict{Symbol,Any}()

    function TapChanger(id, name, terminals, r, x, g_fr, b_fr, g_to, b_to, tm, ta,
                        tm_min, tm_max, rate_a, angmin, angmax, status, ext)
        _check_transformer(id, terminals, tm, angmin, angmax)
        all_nw(<=, tm_min, tm_max) ||
            throw(ArgumentError("tap changer $id has tm_min above tm_max"))
        all_nw(>(0), tm_min) ||
            throw(ArgumentError("tap changer $id has a non-positive tm_min"))
        return new(id, name, terminals, r, x, g_fr, b_fr, g_to, b_to, tm, ta,
                   tm_min, tm_max, rate_a, angmin, angmax, status, ext)
    end
end

register_edge_type!(TapChanger)

################################################################################
# TapChanger — variables                                                       #
################################################################################

"""
    variable_edge(nm, TapChanger; nw)

The two-winding transformer variables, plus the ratio magnitude.

Only the magnitude is a variable; the ratio angle stays at its fixed `ta`, so
`tr` and `ti` are the magnitude scaled by a constant cosine and sine and the
whole model stays polynomial in it. There is one tap variable per transformer
rather than two.
"""
function variable_edge(nm::NetworkModel{P,F}, ::Type{TapChanger}; nw::Int = nw_id_default(nm)
                      ) where {P<:AbstractDispatchProblem,F<:IVRFormulation}
    variable_two_winding!(nm, TapChanger; nw)

    tm = get!(() -> Dict{Int,JuMP.VariableRef}(), var(nm; nw), :tm)

    for e in ids(nm, TapChanger; nw)
        tc = edge(nm, e; nw)::TapChanger
        tm[e] = JuMP.@variable(nm.model, base_name = "$(nw)_tm[$e]",
                               lower_bound = tc.tm_min, upper_bound = tc.tm_max,
                               start = clamp(tc.tm, tc.tm_min, tc.tm_max))
    end

    return nothing
end

function tap_ratio(nm::NetworkModel{P,F}, tc::TapChanger, e::Int; nw::Int
                  ) where {P<:AbstractDispatchProblem,F<:IVRFormulation}
    tm = var(nm, :tm, e; nw)

    return (JuMP.@expression(nm.model, cos(tc.ta) * tm),
            JuMP.@expression(nm.model, sin(tc.ta) * tm))
end
