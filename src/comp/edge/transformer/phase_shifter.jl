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
# PhaseShifter — data                                                          #
################################################################################

"""
    PhaseShifter <: AbstractTwoWindingTransformer

A two-winding transformer whose ratio angle is a control: it shifts the phase
between its nodes without changing the voltage magnitude, and so steers active
power around a meshed network.

The angle is a *decision variable* in a dispatch problem, held between `ta_min`
and `ta_max`, and is fixed at the setpoint `ta` in a power flow, where the
setting of the device is a given rather than something to choose. That is the
whole difference from a [`Transformer`](@ref); use one of those where the angle
is fixed data.

# Fields
As [`Transformer`](@ref), where `ta` is the setpoint, plus:
- `ta_min`, `ta_max`: the limits of the ratio angle [rad].
"""
Base.@kwdef struct PhaseShifter <: AbstractTwoWindingTransformer
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
    ta_min   ::NetworkQuantity{Float64} = -pi / 12
    ta_max   ::NetworkQuantity{Float64} =  pi / 12
    rate_a   ::NetworkQuantity{Float64} = Inf
    angmin   ::NetworkQuantity{Float64} = -pi / 3
    angmax   ::NetworkQuantity{Float64} =  pi / 3
    status   ::NetworkQuantity{Bool}    = true
    ext      ::Dict{Symbol,Any}         = Dict{Symbol,Any}()

    function PhaseShifter(id, name, terminals, r, x, g_fr, b_fr, g_to, b_to, tm, ta,
                          ta_min, ta_max, rate_a, angmin, angmax, status, ext)
        _check_transformer(id, terminals, tm, angmin, angmax)
        all_nw(<=, ta_min, ta_max) ||
            throw(ArgumentError("phase shifter $id has ta_min above ta_max"))
        all_nw(x -> -pi / 2 < x < pi / 2, ta_min) && all_nw(x -> -pi / 2 < x < pi / 2, ta_max) ||
            throw(ArgumentError("phase shifter $id has a ratio angle limit outside (-π/2, π/2)"))
        return new(id, name, terminals, r, x, g_fr, b_fr, g_to, b_to, tm, ta,
                   ta_min, ta_max, rate_a, angmin, angmax, status, ext)
    end
end

register_edge_type!(PhaseShifter)

################################################################################
# PhaseShifter — variables                                                     #
################################################################################

"""
    variable_edge(nm, PhaseShifter; nw)

The two-winding transformer variables, plus the ratio itself.

The ratio is carried as its real and imaginary part rather than as its angle, so
that the equations it enters stay polynomial: the angle appears only through
`tr² + ti² = tm²` and a pair of bounds on `ti/tr`, in place of a sine and a
cosine of a variable.
"""
function variable_edge(nm::NetworkModel{P,F}, ::Type{PhaseShifter}; nw::Int = nw_id_default(nm)
                      ) where {P<:AbstractDispatchProblem,F<:IVRFormulation}
    variable_two_winding!(nm, PhaseShifter; nw)

    tr = get!(() -> Dict{Int,JuMP.VariableRef}(), var(nm; nw), :tr)
    ti = get!(() -> Dict{Int,JuMP.VariableRef}(), var(nm; nw), :ti)

    for e in ids(nm, PhaseShifter; nw)
        ps = edge(nm, e; nw)::PhaseShifter
        tr[e] = JuMP.@variable(nm.model, base_name = "$(nw)_tr[$e]",
                               lower_bound = ps.tm * cos(max(abs(ps.ta_min), abs(ps.ta_max))),
                               upper_bound = ps.tm,
                               start = ps.tm * cos(ps.ta))
        ti[e] = JuMP.@variable(nm.model, base_name = "$(nw)_ti[$e]",
                               lower_bound = ps.tm * sin(ps.ta_min),
                               upper_bound = ps.tm * sin(ps.ta_max),
                               start = ps.tm * sin(ps.ta))
    end

    return nothing
end

tap_ratio(nm::NetworkModel{P,F}, ::PhaseShifter, e::Int; nw::Int
         ) where {P<:AbstractDispatchProblem,F<:IVRFormulation} =
    (var(nm, :tr, e; nw), var(nm, :ti, e; nw))

################################################################################
# PhaseShifter — constraints                                                   #
################################################################################

"""
    constraint_edge_limits(nm, PhaseShifter; nw)

The limits of every in-service phase shifter, on top of those every two-winding
transformer has: the ratio keeps its magnitude, `tr² + ti² = tm²`, and its angle
stays between `ta_min` and `ta_max`.
"""
function constraint_edge_limits(nm::NetworkModel{P,F}, ::Type{PhaseShifter}; nw::Int = nw_id_default(nm)
                               ) where {P<:AbstractDispatchProblem,F<:IVRFormulation}
    constraint_two_winding_limits!(nm, PhaseShifter; nw)

    tr, ti = var(nm, :tr; nw), var(nm, :ti; nw)
    tap    = get!(() -> Dict{Int,Any}(), con(nm; nw), :tap_setting)

    for e in ids(nm, PhaseShifter; nw)
        ps = edge(nm, e; nw)::PhaseShifter
        tap[e] = (
            JuMP.@constraint(nm.model, tr[e]^2 + ti[e]^2 == ps.tm^2),
            JuMP.@constraint(nm.model, ti[e] <= tan(ps.ta_max) * tr[e]),
            JuMP.@constraint(nm.model, ti[e] >= tan(ps.ta_min) * tr[e]))
    end

    return nothing
end

################################################################################
# PhaseShifter — the linearized formulation                                    #
################################################################################

"""
    variable_edge(nm, PhaseShifter; nw)

The ratio angle of every in-service phase shifter, held between `ta_min` and
`ta_max`.

Where the current based formulation has to carry the ratio as a real and an
imaginary part to stay polynomial, here the angle is the variable itself and
enters the flow linearly. A phase shifter is the one transformer control that
survives the linearization, and it is the classic use for one.
"""
function variable_edge(nm::NetworkModel{P,F}, ::Type{PhaseShifter}; nw::Int = nw_id_default(nm)
                      ) where {P<:AbstractDispatchProblem,F<:LPFFormulation}
    ta = get!(() -> Dict{Int,JuMP.VariableRef}(), var(nm; nw), :ta)

    for e in ids(nm, PhaseShifter; nw)
        ps = edge(nm, e; nw)::PhaseShifter
        ta[e] = JuMP.@variable(nm.model, base_name = "$(nw)_ta[$e]",
                               lower_bound = ps.ta_min, upper_bound = ps.ta_max,
                               start = clamp(ps.ta, ps.ta_min, ps.ta_max))
    end

    return nothing
end

phase_shift(nm::NetworkModel{P,F}, ::PhaseShifter, e::Int; nw::Int
           ) where {P<:AbstractDispatchProblem,F<:LPFFormulation} = var(nm, :ta, e; nw)

################################################################################
# PhaseShifter — the redispatch problem                                        #
################################################################################

"""
    redispatch_controls(nm, PhaseShifter)

The ratio of a preventive phase shifter, held equal across the contingencies.

Which variables that is depends on the formulation: the current based one
carries the ratio as `(:tr, :ti)` to stay polynomial, the linearized one as the
angle `(:ta,)` itself. A phase shifter is a **non-costly** measure — it has no
[`redispatch_cost`](@ref) method, so it moves for free — and it is the one
transformer control that survives the linearization.
"""
redispatch_controls(::NetworkModel{P,F}, ::Type{PhaseShifter}
                   ) where {P<:AbstractProblemType,F<:IVRFormulation} = (:tr, :ti)

redispatch_controls(::NetworkModel{P,F}, ::Type{PhaseShifter}
                   ) where {P<:AbstractProblemType,F<:LPFFormulation} = (:ta,)
