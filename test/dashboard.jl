################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.10.0 - initial implementation                                             #
################################################################################

# `security_tables` is tested against a `result` built by hand, not solved: the
# reduction it does — the base case dropped, the worst case per edge and time
# picked out, an edge with no entry reported at rest — has nothing to do with
# any formulation, so nothing here needs a solver. The one exception proves the
# other half of the claim: that a study `parse_zorba` built needs no special
# case, checked against `zorba_tables` itself.

"a tiny two-edge network, no solve needed — `security_result` below is the `result` of one"
function security_network()
    dim = Dimension(:time => 2, :contingency => 3)
    I = Dict{Int,AbstractNode}(10 => Node(; id = 10, name = "bus-X", type = REF),
                               20 => Node(; id = 20, name = "bus-Y"),
                               30 => Node(; id = 30, name = "bus-Z"))
    E = Dict{Int,AbstractEdge}(
        5 => Branch(; id = 5, name = "line-A", terminals = [10, 20], r = 0.0, x = 0.1),
        6 => Branch(; id = 6, name = "line-B", terminals = [10, 30], r = 0.0, x = 0.1))
    U = Dict{Int,AbstractUnit}(1 => FixedLoad(; id = 1, node = 20, pd = 0.0, qd = 0.0))

    return NetworkData(Network(I, E, U; dim); name = "security", baseMVA = 100.0)
end

"an edge solution entry, the same nested `Dict{String,Any}` shape `build_solution` writes"
_entry(p::Float64) = Dict{String,Any}("terminal" => Dict{String,Any}(
                                      "1" => Dict{String,Any}("p" => p)))

"""
The solution `security_network()` would carry, in per unit on its 100 MVA base:
edge 5 is 9.99 (999.0 MW) in the base case — a sentinel that must never surface
— 0.10/-0.05 (10.0/-5.0 MW) under the first contingency and 0.30/-0.20
(30.0/-20.0 MW) under the second; edge 6 sits at 0.0025 (0.25 MW) unless the
second contingency takes it out, when it carries no entry at all.
"""
function security_result(dim::Dimension)
    flow5 = Dict((1, 1) => 9.99, (1, 2) => 9.99,
                (2, 1) => 0.10, (2, 2) => -0.05,
                (3, 1) => 0.30, (3, 2) => -0.20)

    nw = Dict{String,Any}()
    for c in 1:3, t in 1:2
        n     = similar_id(dim, nw_id_default(dim); time = t, contingency = c)
        entry = Dict{String,Any}("5" => _entry(flow5[(c, t)]))
        c == 3 || (entry["6"] = _entry(0.0025))
        nw["$n"] = Dict("edge" => entry, "node" => Dict{String,Any}(), "unit" => Dict{String,Any}())
    end

    return Dict{String,Any}("termination_status" => "hand-built", "solution" => Dict{String,Any}("nw" => nw))
end

"the row of `tbl` for edge `nm` at `t`, in `outage` — there is exactly one"
_row(tbl, nm, t, outage) = only(i for i in eachindex(tbl.Name)
                                 if tbl.Name[i] == nm && tbl.time_id[i] == t &&
                                    tbl.outage[i] == outage)

@testset "security tables" begin

    @testset "the base case never surfaces, and the shape is edges by times by contingencies" begin
        data   = security_network()
        result = security_result(dimension(data))
        tables = security_tables(data, result)

        @test length(tables.frank_safe_borders.Name) == 2 * 2 * 2   # 2 edges, 2 times, 2 contingencies
        @test length(tables.nm1_max_flows.Name) == 2 * 2            # 2 edges, 2 times
        @test length(tables.nm1_min_flows.Name) == 2 * 2

        @test 999.0 ∉ tables.frank_safe_borders.flow_mw
        @test Set(tables.frank_safe_borders.outage) == Set(["2", "3"])   # the default label, stringified

        # the names and the terminal order come straight from the network
        @test tables.frank_safe_borders.Name[_row(tables.frank_safe_borders, "line-A", 1, "2")] == "line-A"
        r = _row(tables.frank_safe_borders, "line-A", 1, "2")
        @test (tables.frank_safe_borders.from_node[r], tables.frank_safe_borders.to_node[r]) == ("bus-X", "bus-Y")
    end

    @testset "the worst case in either direction, and which contingency attains it" begin
        data   = security_network()
        result = security_result(dimension(data))
        tables = security_tables(data, result)

        r = _row(tables.frank_safe_borders, "line-A", 1, "2")
        @test tables.frank_safe_borders.flow_mw[r] ≈ 10.0
        r = _row(tables.frank_safe_borders, "line-A", 1, "3")
        @test tables.frank_safe_borders.flow_mw[r] ≈ 30.0

        # edge 5: contingency "3" carries the larger flow at t = 1, "2" at t = 2
        i1 = findfirst(i -> tables.nm1_max_flows.Name[i] == "line-A" && tables.nm1_max_flows.time_id[i] == 1,
                       eachindex(tables.nm1_max_flows.Name))
        i2 = findfirst(i -> tables.nm1_max_flows.Name[i] == "line-A" && tables.nm1_max_flows.time_id[i] == 2,
                       eachindex(tables.nm1_max_flows.Name))
        @test (tables.nm1_max_flows.flow_mw[i1], tables.nm1_max_flows.outage[i1]) == (30.0, "3")
        @test (tables.nm1_max_flows.flow_mw[i2], tables.nm1_max_flows.outage[i2]) == (-5.0, "2")

        j1 = findfirst(i -> tables.nm1_min_flows.Name[i] == "line-A" && tables.nm1_min_flows.time_id[i] == 1,
                       eachindex(tables.nm1_min_flows.Name))
        j2 = findfirst(i -> tables.nm1_min_flows.Name[i] == "line-A" && tables.nm1_min_flows.time_id[i] == 2,
                       eachindex(tables.nm1_min_flows.Name))
        @test (tables.nm1_min_flows.flow_mw[j1], tables.nm1_min_flows.outage[j1]) == (10.0, "2")
        @test (tables.nm1_min_flows.flow_mw[j2], tables.nm1_min_flows.outage[j2]) == (-20.0, "3")
    end

    @testset "an edge with no entry is reported at rest, not dropped" begin
        data   = security_network()
        result = security_result(dimension(data))
        tables = security_tables(data, result)

        # edge 6 is out of service under contingency "3": at rest, still a row
        r = _row(tables.frank_safe_borders, "line-B", 1, "3")
        @test tables.frank_safe_borders.flow_mw[r] == 0.0f0
        r = _row(tables.frank_safe_borders, "line-B", 1, "2")
        @test tables.frank_safe_borders.flow_mw[r] == 0.25f0

        k = findfirst(i -> tables.nm1_min_flows.Name[i] == "line-B" && tables.nm1_min_flows.time_id[i] == 1,
                      eachindex(tables.nm1_min_flows.Name))
        @test (tables.nm1_min_flows.flow_mw[k], tables.nm1_min_flows.outage[k]) == (0.0f0, "3")
    end

    @testset "every keyword narrows or relabels the sweep" begin
        data   = security_network()
        result = security_result(dimension(data))

        one = security_tables(data, result; edge_ids = [5], contingencies = [2],
                              outage = ["planned-maintenance"], time_id = [2024, 2025])
        @test length(one.frank_safe_borders.Name) == 1 * 1 * 2   # 1 edge, 1 contingency, 2 times
        @test all(==("planned-maintenance"), one.frank_safe_borders.outage)
        @test Set(one.frank_safe_borders.time_id) == Set([2024, 2025])

        @test_throws ArgumentError security_tables(data, result; outage = ["only one"])
        @test_throws ArgumentError security_tables(data, result; time_id = [1])
    end

    @testset "a network with no contingency dimension is refused" begin
        data = radial_network()   # from test/rd.jl, `Dimension()` only

        err = try security_tables(data, Dict{String,Any}("termination_status" => "n/a")) catch e; e end
        @test err isa ArgumentError
        @test occursin("`:time` and a `:contingency` dimension", err.msg)
    end

    @testset "reproduces the zorba adapter's own flows, by construction" begin
        # the general sweep and the zorba-specific one read the same solution,
        # so restricting the former to the contingencies the latter reports
        # under a real name has to agree with it exactly
        outage = (name = ["a - c", "b - c"], link = ["a - c", "b - c"])
        data   = parse_zorba(; grid = ref_grid(), net_position = ref_net_position(), outage,
                             overload_penalty = 1e3)
        result = quiet(() -> solve_zorba(data, OPTIMIZER))

        zs  = zorba_study(data)
        sec = security_tables(data, result; outage = zs.outage[2:end], time_id = zs.time_id)
        zt  = zorba_tables(data, result).grid_flows
        kept = [i for i in eachindex(zt.outage) if !ismissing(zt.outage[i])]

        got      = Set(zip(sec.frank_safe_borders.outage, sec.frank_safe_borders.Name,
                           sec.frank_safe_borders.time_id, sec.frank_safe_borders.flow_mw))
        expected = Set(zip(zt.outage[kept], zt.Name[kept], zt.time_id[kept], zt.flow_mw[kept]))
        @test got == expected
    end

    @testset "the parquet writer" begin
        data   = security_network()
        result = security_result(dimension(data))
        tables = security_tables(data, result)

        mktempdir() do dir
            paths = write_security_tables(dir, tables)

            @test length(paths) == 3
            @test all(isfile, paths)
            @test sort(basename.(paths)) == ["frank_safe_borders.parquet", "nm1_max_flows.parquet",
                                             "nm1_min_flows.parquet"]

            ds = Parquet2.Dataset(joinpath(dir, "nm1_max_flows.parquet"))
            @test collect(Parquet2.load(ds, "Name")) == tables.nm1_max_flows.Name
            @test collect(Parquet2.load(ds, "flow_mw")) ≈ tables.nm1_max_flows.flow_mw
        end
    end

end
