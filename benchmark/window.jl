################################################################################
# benchmark/window.jl                                                          #
# What one window of a rolling redispatch costs, stage by stage, on case14     #
# with an outage per branch. Run by hand, not in CI:                           #
#                                                                              #
#   julia --project=benchmark benchmark/window.jl                              #
#                                                                              #
# Numbers belong to one machine and one day, so compare two versions of the    #
# package side by side: put the other one in a worktree, copy                  #
# benchmark/Manifest.toml into it and run the same command there.              #
#                                                                              #
#   git worktree add --detach <dir> <rev>                                      #
#   Copy-Item benchmark\Manifest.toml <dir>\benchmark\                         #
#                                                                              #
# The ratings are a share of the base case flows, so that they bind and the    #
# redispatch has something to do. Each stage is its own benchmark: a fresh     #
# model per sample where the stage changes the model, one solved model where   #
# it only reads it. The roll is the whole thing, windows and all.              #
################################################################################

using BenchmarkTools
using HiGHS
using JuMP
using Logging
using Printf
using NetworkModelBuilder

const HOURS    = 12       # time steps of the problem
const HORIZON  = 4        # time steps a window sees
const OUTAGES  = 12       # branches taken out in turn, one network index each
const SHARE    = 0.75     # a branch is rated at this share of its base case flow
const FLOOR    = 0.15     # per unit, the lowest rating given

const CASE = joinpath(pkgdir(NetworkModelBuilder), "test", "data", "matpower", "case14.m")

"`c`'s fields as a `NamedTuple`, so `T(; fields(c)..., field = value)` copies `c` with one field changed"
fields(c::T) where {T} = NamedTuple{fieldnames(T)}(map(f -> getfield(c, f), fieldnames(T)))

"the flow into the first terminal of every edge at the market dispatch the case carries"
function base_flows(data)
    lf = solve_lf(data, LPFFormulation, optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false))

    return Dict(parse(Int, e) => entry["terminal"]["1"]["p"] for (e, entry) in nw_solution(lf)["edge"])
end

"""
    synthetic(data, flows)

`data` over `:time` and `:contingency`: every branch rated, the first `OUTAGES`
branches whose loss does not island the network each out of service at a
contingency of its own, and the loads following a daily profile. Returns the data,
the rated edges and the outaged ones.
"""
function synthetic(data, flows)
    net     = network(data)
    outable = [e for e in sort(collect(keys(edges(net)))) if length(islands(net; without = (e,))) == 1]
    out     = outable[1:min(OUTAGES, length(outable))]
    dim     = Dimension(:time => HOURS, :contingency => length(out) + 1)
    profile = [1 + 0.15 * sin(2pi * h / HOURS) for h in 1:HOURS]
    rated   = Int[]

    mn = set_dimension(data, dim; apply! = function (net, dim)
        for (e, c) in net.edge
            c isa Branch || continue
            push!(rated, e)
            k      = findfirst(==(e), out)
            status = k === nothing ? c.status : nw_vector(dim, (n, coord) -> coord.contingency != k + 1)
            net.edge[e] = Branch(; fields(c)..., rate_a = max(SHARE * abs(flows[e]), FLOOR), status)
        end
        for (u, c) in net.unit
            c isa FixedLoad || continue
            net.unit[u] = FixedLoad(; fields(c)..., pd = nw_vector(dim, :time, c.pd .* profile),
                                    qd = nw_vector(dim, :time, c.qd .* profile))
        end
    end)

    return mn, sort(rated), out
end

data       = Logging.with_logger(() -> parse_file(CASE), Logging.NullLogger())
mn, rated, out = synthetic(data, base_flows(data))
ext        = Dict{Symbol,Any}(:redispatch => Redispatch(; monitored = rated, control = :preventive,
                                                         overload = OverloadPrice(; per_energy = 1.0e3)))
newmodel   = () -> (m = JuMP.direct_model(HiGHS.Optimizer()); JuMP.set_silent(m); m)
generators = ids(network(mn), Generator)
lean       = (; node = false, edge = rated, unit = generators)

w1 = window(mn, :time, 1:HORIZON)
w2 = window(mn, :time, 2:HORIZON+1)
instantiate() = instantiate_model(w1, RedispatchProblem, LPFFormulation; jump_model = newmodel(), ext)
roll(report = (;)) = solve_rolling_horizon(mn, RedispatchProblem, LPFFormulation, HiGHS.Optimizer;
                                           horizon = HORIZON, step = 1, reuse = true,
                                           new_model = newmodel, ext, report)

# the problem has to be the one it claims to be: solved, and with something to relieve
result = roll()
result["termination_status"] == JuMP.OPTIMAL ||
    error("the roll finished $(result["termination_status"]), the benchmark means nothing")
overloaded = count(entry -> get(entry, "overload", 0.0) > 1e-6, [entry for s in values(result["solution"]["nw"])
                                                                   for entry in values(s["edge"])])
@printf("case14, %d time steps, windows of %d; %d outages, %d network indices a window; %d rated edges\n",
        HOURS, HORIZON, length(out), dim_length(w1), length(rated))
@printf("the roll: %d windows, %d model built, %d (index, edge) rows overloaded, objective %.1f\n\n",
        length(result["horizon"]["window"]), result["horizon"]["built"], overloaded, result["objective"])

solved = instantiate()
JuMP.optimize!(solved.model)

stages = (
    ("window (cut a window)",         @benchmark window($mn, :time, 1:$HORIZON)),
    ("instantiate_model",             @benchmark $instantiate()),
    ("update_model! to the next",     @benchmark update_model!(nm, $w2) setup = (nm = $instantiate()) evals = 1),
    ("solve",                         @benchmark JuMP.optimize!(nm.model) setup = (nm = $instantiate()) evals = 1),
    ("build_solution, whole",         @benchmark build_solution($solved)),
    ("build_solution, with a report", @benchmark build_solution($solved; report = $lean)),
    ("solve_rolling_horizon, whole",  @benchmark $roll() samples = 10 evals = 1 seconds = 60),
    ("solve_rolling_horizon, report", @benchmark $roll($lean) samples = 10 evals = 1 seconds = 60),
)

@printf("%-31s %10s %10s %9s %9s %6s\n", "stage", "min ms", "median ms", "MB", "allocs", "GC %")
for (name, trial) in stages
    lo, mid = minimum(trial), median(trial)
    @printf("%-31s %10.2f %10.2f %9.2f %9d %5.1f%%\n", name, lo.time / 1e6, mid.time / 1e6,
            lo.memory / 2^20, lo.allocs, 100 * mid.gctime / mid.time)
end
