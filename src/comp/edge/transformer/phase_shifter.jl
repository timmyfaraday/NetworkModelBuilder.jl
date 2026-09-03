################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.3.0 - component hierarchy                                                 #
# v0.8.0 - moving one may be priced                                            #
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
- `cost`: what moving the angle one radian away from `ta` costs
  [currency/rad], zero — free — by default. See [`redispatch_cost`](@ref).
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
    cost     ::NetworkQuantity{Float64} = 0.0
    rate_a   ::NetworkQuantity{Float64} = Inf
    angmin   ::NetworkQuantity{Float64} = -pi / 3
    angmax   ::NetworkQuantity{Float64} =  pi / 3
    status   ::NetworkQuantity{Bool}    = true
    ext      ::Dict{Symbol,Any}         = Dict{Symbol,Any}()

    function PhaseShifter(id, name, terminals, r, x, g_fr, b_fr, g_to, b_to, tm, ta,
                          ta_min, ta_max, cost, rate_a, angmin, angmax, status, ext)
        _check_transformer(id, terminals, tm, angmin, angmax)
        all_nw(<=, ta_min, ta_max) ||
            throw(ArgumentError("phase shifter $id has ta_min above ta_max"))
        all_nw(x -> -pi / 2 < x < pi / 2, ta_min) && all_nw(x -> -pi / 2 < x < pi / 2, ta_max) ||
            throw(ArgumentError("phase shifter $id has a ratio angle limit outside (-π/2, π/2)"))
        all_nw(>=(0), cost) ||
            throw(ArgumentError("phase shifter $id has a negative cost, which pays the problem to move it"))
        return new(id, name, terminals, r, x, g_fr, b_fr, g_to, b_to, tm, ta,
                   ta_min, ta_max, cost, rate_a, angmin, angmax, status, ext)
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

    variable_container!(nm, :tr, :ti; nw)

    for e in ids(nm, PhaseShifter; nw)
        ps = edge(nm, e; nw)::PhaseShifter
        variable!(nm, :tr, e; nw, base_name = "$(nw)_tr[$e]", start = ps.tm * cos(ps.ta),
                  lower = ps.tm * cos(max(abs(ps.ta_min), abs(ps.ta_max))), upper = ps.tm)
        variable!(nm, :ti, e; nw, base_name = "$(nw)_ti[$e]", start = ps.tm * sin(ps.ta),
                  lower = ps.tm * sin(ps.ta_min), upper = ps.tm * sin(ps.ta_max))
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
            constrain!(nm, :tap_setting, (e, :magnitude),
                       JuMP.@build_constraint(tr[e]^2 + ti[e]^2 == ps.tm^2); nw),
            constrain!(nm, :tap_setting, (e, :max),
                       JuMP.@build_constraint(ti[e] <= tan(ps.ta_max) * tr[e]); nw),
            constrain!(nm, :tap_setting, (e, :min),
                       JuMP.@build_constraint(ti[e] >= tan(ps.ta_min) * tr[e]); nw))
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
variable_edge(nm::NetworkModel{P,F}, ::Type{PhaseShifter}; nw::Int = nw_id_default(nm)
             ) where {P<:AbstractDispatchProblem,F<:LPFFormulation} =
    _variable_phase_shifter_angle(nm, nw)

"the ratio angle of every in-service phase shifter, held between its limits"
function _variable_phase_shifter_angle(nm::NetworkModel, nw::Int)
    variable_container!(nm, :ta; nw)

    for e in ids(nm, PhaseShifter; nw)
        ps = edge(nm, e; nw)::PhaseShifter
        variable!(nm, :ta, e; nw, base_name = "$(nw)_ta[$e]",
                  start = clamp(ps.ta, ps.ta_min, ps.ta_max),
                  lower = ps.ta_min, upper = ps.ta_max)
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

"""
    variable_edge(nm, PhaseShifter; nw)

The ratio angle of every in-service phase shifter, plus the angle it moved away
from its setpoint, up and down.

`ta` is the setpoint the device was left at by whatever decided the schedule,
and the two volumes are what the redispatch asks of it on top of that — the same
split a [`Generator`](@ref) makes between its market dispatch and the power it
was moved, and a [`DCLink`](@ref) between its scheduled transfer and the one it
was asked for. Each is bounded by the room left in its direction, so an angle
already at `ta_max` can still be brought back down.

The volumes are written whatever the price, as a link's are: they are what the
solution reports as *the intervention*, and an unpriced phase shifter that swung
half its range is still worth being able to see.
"""
function variable_edge(nm::NetworkModel{P,F}, ::Type{PhaseShifter}; nw::Int = nw_id_default(nm)
                      ) where {P<:RedispatchProblem,F<:LPFFormulation}
    _variable_phase_shifter_angle(nm, nw)

    variable_container!(nm, :taup, :tadn; nw)

    for e in ids(nm, PhaseShifter; nw)
        ps = edge(nm, e; nw)::PhaseShifter

        variable!(nm, :taup, e; nw, base_name = "$(nw)_taup[$e]", start = 0.0,
                  lower = 0.0, upper = max(ps.ta_max - ps.ta, 0.0))
        variable!(nm, :tadn, e; nw, base_name = "$(nw)_tadn[$e]", start = 0.0,
                  lower = 0.0, upper = max(ps.ta - ps.ta_min, 0.0))
    end

    return nothing
end

"""
    constraint_edge(nm, PhaseShifter; nw)

The linearized flow of every in-service phase shifter, and the split of its
angle into the setpoint and the volumes moved away from it,

```math
ta_{e} = ta^{\\text{set}}_{e} + ta^{\\uparrow}_{e} - ta^{\\downarrow}_{e} .
```

The physics are those of any two-winding transformer, see
[`constraint_two_winding_flow!`](@ref); what a redispatch adds is the second
equation, which is what makes the angle a *deviation* that can be priced rather
than a free control.
"""
function constraint_edge(nm::NetworkModel{P,F}, ::Type{PhaseShifter}; nw::Int = nw_id_default(nm)
                        ) where {P<:RedispatchProblem,F<:LPFFormulation}
    constraint_two_winding_flow!(nm, PhaseShifter; nw)

    ta, taup, tadn = var(nm, :ta; nw), var(nm, :taup; nw), var(nm, :tadn; nw)
    split = get!(() -> Dict{Int,Any}(), con(nm; nw), :phase_shifter_redispatch)

    for e in ids(nm, PhaseShifter; nw)
        ps = edge(nm, e; nw)::PhaseShifter
        split[e] = constrain!(nm, :phase_shifter_redispatch, e,
            JuMP.@build_constraint(ta[e] == ps.ta + taup[e] - tadn[e]); nw)
    end

    return nothing
end

"""
    redispatch_cost(nm, PhaseShifter, e; nw)

What moving phase shifter `e` away from its setpoint costs at network index
`nw`, `c_{e} (ta^{\\uparrow}_{e} + ta^{\\downarrow}_{e})` [currency].

One price for both directions, as a [`DCLink`](@ref) has: swinging a tap either
way is the same intervention on the same equipment. A phase shifter whose `cost`
is zero — the default — is a **non-costly** measure and is taken before anything
that is priced, which is the usual model of a device the operator already owns
and can move within its range.

Note what the price is *per*: a radian of angle, not a per-unit of power. It is
a charge on the movement itself, which is what a tap changer's wear is, and it
does not become an energy price by being multiplied by the duration of a step.
"""
function redispatch_cost(nm::NetworkModel{P,F}, ::Type{PhaseShifter}, e::Int; nw::Int
                        ) where {P<:AbstractProblemType,F<:LPFFormulation}
    ps = edge(nm, e; nw)::PhaseShifter

    return JuMP.@expression(nm.model,
        ps.cost * (var(nm, :taup, e; nw) + var(nm, :tadn, e; nw)))
end

"""
    redispatch_cost(nm, PhaseShifter, e; nw)

Zero, and an error where the phase shifter carries a price.

The price is on the *angle*, and a current based formulation does not carry one:
it holds the ratio as `tr + j·ti` precisely so that the equations stay
polynomial, and asking what a radian of it costs would put a transcendental into
the objective. A priced phase shifter is therefore linearized-only, the same call
[`DCLink`](@ref) makes, and saying so here is better than dropping a term of the
objective in silence.
"""
function redispatch_cost(nm::NetworkModel{P,F}, ::Type{PhaseShifter}, e::Int; nw::Int
                        ) where {P<:AbstractProblemType,F<:IVRFormulation}
    ps = edge(nm, e; nw)::PhaseShifter
    iszero(ps.cost) && return 0.0

    error("phase shifter $e carries a cost of $(ps.cost) per radian, and a priced phase " *
          "shifter has no model under formulation `$F`: the price is on the ratio angle, " *
          "which this formulation carries as `tr + j*ti` rather than as an angle. Pose the " *
          "problem in a `LPFFormulation`, or leave the price at zero.")
end

################################################################################
# PhaseShifter — solution                                                      #
################################################################################

"""
    solution_edge!(entry, nm, PhaseShifter, e, nw)

The tap setting of a phase shifter in a redispatch, and the angle it moved away
from its setpoint.

`ta` is where the device ended up and `ta_market` where it started, so the two
volumes are the answer to *what was this asked to do*, reported whether they were
priced or not.
"""
function solution_edge!(entry::Dict{String,Any}, nm::NetworkModel{P,F},
                        ::Type{PhaseShifter}, e::Int, nw::Int
                       ) where {P<:RedispatchProblem,F<:LPFFormulation}
    ps  = edge(nm, e; nw)::PhaseShifter
    tap = Dict{String,Any}("tm" => ps.tm, "ta" => _value(phase_shift(nm, ps, e; nw)),
                           "ta_market" => ps.ta,
                           "taup" => JuMP.value(var(nm, :taup, e; nw)),
                           "tadn" => JuMP.value(var(nm, :tadn, e; nw)))
    entry["tap"] = tap

    return nothing
end
