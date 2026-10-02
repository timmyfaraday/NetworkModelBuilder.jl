################################################################################
# NMinusOneScreen.jl                                                          #
# Which hours need a redispatch at all: the flows of a linearized load flow,  #
# for the base case and for every outage, solved for every hour at once, set  #
# against the ratings of the monitored edges. An hour that overloads nothing  #
# in any case is already optimal at zero redispatch, so leaving it out of the #
# redispatch is exact.                                                        #
################################################################################

module NMinusOneScreen

using LinearAlgebra
using NetworkModelBuilder
using ..SteeringPlanData: hour_ids

export screen_hours

"whether the graph on nodes `1:n` with edges `from[k] -- to[k]` is connected"
function _connected(n::Int, from::Vector{Int}, to::Vector{Int})
    parent = collect(1:n)
    find(x) = (while parent[x] != x
                   parent[x] = parent[parent[x]]
                   x = parent[x]
               end; x)
    for (i, j) in zip(from, to)
        ri, rj = find(i), find(j)
        ri == rj || (parent[ri] = rj)
    end

    return count(k -> find(k) == k, 1:n) == 1
end

"""
    screen_hours(data, outages, monitored; margin = 0.01, on_case = nothing)

The loading of the `monitored` edges at every hour of `data`, in the base case
and with each of `outages` — a vector of the edge identifiers that go out
together — taken one at a time.

The flows are those of the linearized load flow the redispatch is built on: with
`B` the series susceptance of an edge and `ta` its phase shift,

```math
p_{e} = B_{e}\\left(\\theta_{i} - \\theta_{j} - ta_{e}\\right),
\\qquad
\\sum_{e \\ni k} p_{e} = P_{k},
```

with the angle of the reference node fixed. The dispatch of `data` is taken as
it stands — a generator at `pg`, a storage unit at `ps`, a fixed load at `-pd` —
and left unchanged by an outage, which is what a redispatch that has not moved
anything looks like. One factorization per case serves every hour.

Returns a `NamedTuple` with, for each hour, whether it is `flagged` — some
monitored edge carries more than `1 - margin` of its rating in some case — the
largest `max_loading` (flow over rating), and the `worst_edge` and `worst_case`
(`0` the base case, `k` the `k`-th of `outages`) that set it.

`on_case(k, edge_ids, flows)` is called for every case with the signed flow in
every hour of each monitored edge still in service, for checking against another
solve.

The screen models branches and phase shifters and the generators, storage units
and fixed loads that go with them; anything else is refused rather than left
out. So is a data set whose dispatch does not balance, or any case that
disconnects the network, since neither has a flow to report.
"""
function screen_hours(data::NetworkData, outages::AbstractVector{<:AbstractVector{Int}},
                      monitored::AbstractVector{Int}; margin::Float64 = 0.01, on_case = nothing)
    net = network(data)
    dim = dimension(data)
    dim_length(dim) == dim_length(dim, :time) ||
        throw(ArgumentError("the screen takes data posed over :time alone"))
    T = dim_length(dim)

    node_ids = sort!(collect(keys(nodes(net))))
    npos     = Dict(i => k for (k, i) in enumerate(node_ids))
    n        = length(node_ids)
    ref      = findfirst(i -> nodes(net)[i].type == REF, node_ids)
    ref === nothing && throw(ArgumentError("the network has no reference node"))

    edge_ids = sort!(collect(keys(edges(net))))
    epos     = Dict(e => k for (k, e) in enumerate(edge_ids))
    m        = length(edge_ids)
    from, to = zeros(Int, m), zeros(Int, m)
    B, rate  = zeros(m), fill(Inf, m)
    TA       = zeros(m, T)
    for (k, e) in enumerate(edge_ids)
        c = edges(net)[e]
        c isa Union{Branch,PhaseShifter} ||
            throw(ArgumentError("edge $e is a $(nameof(typeof(c))), which the screen does not model"))
        all(nw_values(dim, c.status)) ||
            throw(ArgumentError("edge $e is out of service in the base case, which the screen does not model"))
        c.rate_a isa NetworkVector &&
            throw(ArgumentError("edge $e has a rating that varies over the hours, which the screen does not model"))
        i, j        = terminals(c)
        from[k], to[k] = npos[i], npos[j]
        B[k]        = -NetworkModelBuilder.susceptance(c.r, c.x)
        rate[k]     = c.rate_a
        c isa PhaseShifter && (TA[k, :] = nw_values(dim, c.ta))
    end
    shifting = [k for k in 1:m if any(!iszero, view(TA, k, :))]

    P = zeros(n, T)
    for (u, c) in units(net)
        inject = c isa Generator ? nw_values(dim, c.pg) :
                 c isa FixedLoad ? -nw_values(dim, c.pd) :
                 c isa Storage   ? nw_values(dim, c.ps) :
                 throw(ArgumentError("unit $u is a $(nameof(typeof(c))), which the screen does not model"))
        P[npos[c.node], :] .+= ifelse.(nw_values(dim, c.status), inject, 0.0)
    end
    (any(isnan, P) || any(isnan, TA)) &&
        throw(ArgumentError("the dispatch has missing values, which would pass the screen unseen"))
    imbalance = maximum(abs, sum(P; dims = 1))
    imbalance < 1e-5 ||
        throw(ArgumentError("the dispatch does not balance (largest imbalance $(imbalance) pu)"))

    mon = Int[]
    for e in monitored
        haskey(epos, e) || throw(ArgumentError("monitored edge $e is not in the network"))
        isfinite(rate[epos[e]]) && push!(mon, epos[e])
    end

    free  = [1:ref-1; ref+1:n]
    cases = vcat([Int[]], [[epos[e] for e in o] for o in outages])

    max_loading = zeros(T)
    worst_edge  = zeros(Int, T)
    worst_case  = zeros(Int, T)

    for (k, removed) in enumerate(cases)
        gone = Set(removed)
        kept = [e for e in 1:m if !(e in gone)]
        _connected(n, from[kept], to[kept]) ||
            throw(ArgumentError("case $(k - 1) disconnects the network"))

        L = zeros(n, n)
        S = zeros(n, T)
        for e in kept
            i, j, b = from[e], to[e], B[e]
            L[i, i] += b; L[j, j] += b; L[i, j] -= b; L[j, i] -= b
        end
        for e in shifting
            e in gone && continue
            S[from[e], :] .+= B[e] .* view(TA, e, :)
            S[to[e], :]   .-= B[e] .* view(TA, e, :)
        end

        theta = zeros(n, T)
        theta[free, :] = lu(L[free, free]) \ (P .+ S)[free, :]

        watched = [e for e in mon if !(e in gone)]
        flows   = B[watched] .* (theta[from[watched], :] .- theta[to[watched], :] .- TA[watched, :])
        on_case === nothing || on_case(k - 1, edge_ids[watched], flows)

        isempty(watched) && continue
        loading = abs.(flows) ./ rate[watched]
        for t in 1:T
            l, w = findmax(view(loading, :, t))
            if l > max_loading[t]
                max_loading[t] = l
                worst_edge[t]  = edge_ids[watched[w]]
                worst_case[t]  = k - 1
            end
        end
    end

    return (hours = hour_ids(data), flagged = max_loading .> 1 - margin,
            max_loading = max_loading, worst_edge = worst_edge, worst_case = worst_case)
end

end # module
