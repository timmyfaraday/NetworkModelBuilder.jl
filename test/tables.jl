################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.6.0 - initial implementation                                              #
################################################################################

# The radial network of `test/rd.jl` written as tables: the market ran generator
# 1 up to 1.0 behind a branch that carries 0.5, and relieving that costs
# 0.5(100) + 0.5(10) = 55. Reading it back has to reach the same number, which
# is what makes this a test of the reader rather than of its own fixture.

const TBL_NODE = (id        = [1, 2],
                  type      = ["REF", "PQ"],
                  vm        = [1.0, 1.0])

const TBL_EDGE = (id        = [1],
                  component = ["Branch"],
                  terminals = [[1, 2]],
                  r         = [0.0],
                  x         = [0.1],
                  rate_a    = [0.5])

const TBL_UNIT = (id        = [1, 2, 3],
                  component = ["Generator", "Generator", "FixedLoad"],
                  node      = [1, 2, 2],
                  pmax      = [5.0, 5.0, missing],
                  qmin      = [-5.0, -5.0, missing],
                  qmax      = [5.0, 5.0, missing],
                  pg        = [1.0, 0.0, missing],
                  cost      = [[0.0, 10.0], [0.0, 100.0], missing],
                  pd        = [missing, missing, 1.0],
                  qd        = [missing, missing, 0.0])

"the three tables of the radial network, as a keyword collection"
radial_tables() = (node = TBL_NODE, edge = TBL_EDGE, unit = TBL_UNIT)

@testset "tabular input" begin

    @testset "a table is anything with columns you can name" begin
        data = parse_tables(; radial_tables()...)

        @test data isa NetworkData
        net = network(data)
        @test sort(collect(keys(nodes(net)))) == [1, 2]
        @test sort(collect(keys(edges(net)))) == [1]
        @test sort(collect(keys(units(net)))) == [1, 2, 3]

        @test nodes(net)[1].type === REF
        @test nodes(net)[2].type === PQ
        @test edges(net)[1] isa Branch
        @test edges(net)[1].terminals == [1, 2]
        @test edges(net)[1].rate_a == 0.5
        @test units(net)[1] isa Generator
        @test units(net)[1].cost == [0.0, 10.0]
        @test units(net)[3] isa FixedLoad
        @test units(net)[3].pd == 1.0
    end

    @testset "what it reads solves to the answer worked out by hand" begin
        result = quiet(() -> solve_rd(parse_tables(; radial_tables()...),
                                      LPFFormulation, OPTIMIZER))

        @test result["termination_status"] == JuMP.LOCALLY_SOLVED
        @test result["objective"] ≈ 0.5 * 100.0 + 0.5 * 10.0 atol = 1e-5
    end

    @testset "a blank cell is a default, not a value" begin
        # this is what lets one flat table hold several component types: the
        # `FixedLoad` row leaves every generator column empty, which is also
        # what stacking two frames in a dataframe library produces
        net = network(parse_tables(; radial_tables()...))

        @test units(net)[3].pd == 1.0
        @test units(net)[3].status == true            # never given, so the default
        @test units(net)[1].name == ""
        @test nodes(net)[1].vmin == 0.9

        # an empty string is blank too, which is what a text column writes
        blank = parse_tables(node = (id = [1], type = ["REF"], name = [""]),
                             edge = (id = Int[], component = String[], terminals = Vector{Int}[]),
                             unit = (id = [1], component = ["Generator"], node = [1]))
        @test nodes(network(blank))[1].name == ""
    end

    @testset "the component column names the type" begin
        # the node table may leave it out, since there is one node type
        plain = parse_tables(node = (id = [1],  type = ["REF"]),
                             edge = (id = Int[], component = String[], terminals = Vector{Int}[]),
                             unit = (id = [1], component = ["Generator"], node = [1]))
        @test nodes(network(plain))[1] isa Node

        @test haskey(component_types(), "Branch")
        @test haskey(component_types(), "DCLink")      # registered, so readable
        @test haskey(component_types(), "Storage")
        @test component_types()["Node"] === Node
    end

    @testset "an edge type registered by anyone is readable" begin
        # the reader is built off the registries rather than a list of its own,
        # so the dc link needed no reader change to arrive
        data = parse_tables(
            node = (id = [1, 2], type = ["REF", "REF"]),
            edge = (id = [1], component = ["DCLink"], terminals = [[1, 2]],
                    rate_a = [2.0], loss_prop = [0.05], reverse = [false]),
            unit = (id = [1, 2], component = ["Generator", "FixedLoad"],
                    node = [1, 2], pmax = [5.0, missing], pd = [missing, 1.0]))

        dl = edges(network(data))[1]
        @test dl isa DCLink
        @test dl.loss_prop == 0.05
        @test dl.reverse == false
    end

    @testset "it says what it cannot read" begin
        base = radial_tables()

        # a type nobody registered
        err = try
            parse_tables(; base..., edge = (id = [1], component = ["Wormhole"],
                                            terminals = [[1, 2]]))
        catch e; e end
        @test err isa ArgumentError
        @test occursin("Wormhole", err.msg)
        @test occursin("Branch", err.msg)            # and what it does know

        # a type in the wrong table
        @test_throws ArgumentError parse_tables(; base...,
            unit = (id = [1], component = ["Branch"], node = [1]))

        # a column that is not a field
        err = try
            parse_tables(; base..., node = (id = [1], type = ["REF"], colour = ["red"]))
        catch e; e end
        @test err isa ArgumentError
        @test occursin("colour", err.msg)

        # a value the field cannot take
        @test_throws ArgumentError parse_tables(; base...,
            node = (id = [1], type = ["SLACK"]))

        # the columns the reader itself needs
        @test_throws ArgumentError parse_tables(; base..., node = (type = ["REF"],))
        @test_throws ArgumentError parse_tables(; base...,
            edge = (id = [1], terminals = [[1, 2]]))   # no `component`

        # and a repeated identifier, which would otherwise lose a component
        @test_throws ArgumentError parse_tables(; base...,
            node = (id = [1, 1], type = ["REF", "PQ"]))
    end

    @testset "a profile is what varies over the network index" begin
        data = parse_tables(; radial_tables()...,
            dimension = (name = fill("time", 3), coordinate = [1, 2, 3]),
            profile   = (family = fill("unit", 3), id = fill(3, 3),
                         field = fill("pd", 3), nw = [1, 2, 3],
                         value = [1.0, 2.0, 3.0]))

        dim = dimension(data)
        @test dim_length(dim) == 3
        ld = units(network(data))[3]
        @test ld.pd isa NetworkVector
        @test [nw_value(dim, ld.pd, n) for n in 1:3] == [1.0, 2.0, 3.0]

        # and it wins over the constant the component's own table gave
        @test ld.pd isa NetworkVector
    end

    @testset "an outage is a status that varies" begin
        data = parse_tables(; radial_tables()...,
            dimension = (name = fill("contingency", 2), coordinate = [1, 2]),
            profile   = (family = ["edge", "edge"], id = [1, 1],
                         field = ["status", "status"], nw = [1, 2],
                         value = [true, false]))

        dim = dimension(data)
        st  = edges(network(data))[1].status
        @test [nw_value(dim, st, n) for n in 1:2] == [true, false]

        # the topology followed it, which is the point of expressing it this way
        @test 1 in topology(network(data); nw = 1).edge
        @test 1 ∉ topology(network(data); nw = 2).edge
    end

    @testset "a profile has to give every network index" begin
        base = radial_tables()
        dimtbl = (name = fill("time", 3), coordinate = [1, 2, 3])

        # short, which is far more likely a filter that dropped rows
        err = try
            parse_tables(; base..., dimension = dimtbl,
                profile = (family = ["unit", "unit"], id = [3, 3], field = ["pd", "pd"],
                           nw = [1, 2], value = [1.0, 2.0]))
        catch e; e end
        @test err isa ArgumentError
        @test occursin("2 of the 3", err.msg)

        # given twice at one index
        @test_throws ArgumentError parse_tables(; base..., dimension = dimtbl,
            profile = (family = fill("unit", 3), id = fill(3, 3), field = fill("pd", 3),
                       nw = [1, 1, 2], value = [1.0, 2.0, 3.0]))

        # at an index the problem does not have
        @test_throws ArgumentError parse_tables(; base..., dimension = dimtbl,
            profile = (family = fill("unit", 3), id = fill(3, 3), field = fill("pd", 3),
                       nw = [1, 2, 9], value = [1.0, 2.0, 3.0]))

        # for a component no table declared, which would otherwise vanish
        err = try
            parse_tables(; base..., dimension = dimtbl,
                profile = (family = fill("unit", 3), id = fill(77, 3), field = fill("pd", 3),
                           nw = [1, 2, 3], value = [1.0, 2.0, 3.0]))
        catch e; e end
        @test err isa ArgumentError
        @test occursin("77", err.msg)

        # for a field the type does not have
        @test_throws ArgumentError parse_tables(; base..., dimension = dimtbl,
            profile = (family = fill("unit", 3), id = fill(3, 3), field = fill("torque", 3),
                       nw = [1, 2, 3], value = [1.0, 2.0, 3.0]))
    end

    @testset "the dimension table carries the coordinate properties" begin
        data = parse_tables(; radial_tables()...,
            dimension = (name       = fill("time", 4),
                         coordinate = [1, 2, 3, 4],
                         duration   = [0.25, 0.25, 0.25, 0.25],
                         period     = [1, 1, 2, 2]))

        dim = dimension(data)
        @test dim_length(dim, :time) == 4
        @test dim_prop(dim, 1, :time, :duration) == 0.25
        @test period_ids(dim, 1) == [1, 2]
        @test period_ids(dim, 3) == [3, 4]
    end

    @testset "a dimension that says nothing costs nothing" begin
        # the invariant the memory story rests on: describing 8760 hours that
        # carry no properties must not cost a dictionary per hour
        data = parse_tables(; radial_tables()...,
            dimension = (name = fill("time", 8760), coordinate = collect(1:8760)))

        dim = dimension(data)
        @test dim_length(dim, :time) == 8760
        @test _NMB._prop(dim, :time) isa Int

        # a property on any coordinate does buy the dictionaries, for that
        # dimension alone
        mixed = parse_tables(; radial_tables()...,
            dimension = (name       = ["time", "time", "scenario", "scenario"],
                         coordinate = [1, 2, 1, 2],
                         weight     = [missing, missing, 0.4, 0.6]))
        @test _NMB._prop(dimension(mixed), :time) isa Int
        @test _NMB._prop(dimension(mixed), :scenario) isa Vector
        @test dim_prop(dimension(mixed), :scenario, 2, :weight) == 0.6
    end

    @testset "the dimension table says what it cannot describe" begin
        base = radial_tables()

        # a hole in the coordinates
        err = try
            parse_tables(; base...,
                dimension = (name = fill("time", 2), coordinate = [1, 3]))
        catch e; e end
        @test err isa ArgumentError
        @test occursin("2 of the 3", err.msg)

        @test_throws ArgumentError parse_tables(; base...,
            dimension = (name = fill("time", 2), coordinate = [1, 1]))
        @test_throws ArgumentError parse_tables(; base...,
            dimension = (name = ["time"], coordinate = [0]))
        @test_throws ArgumentError parse_tables(; base..., dimension = (name = ["time"],))
    end

    @testset "an explicit dimension wins over the table" begin
        data = parse_tables(; radial_tables()...,
            dim       = Dimension(:time => 2),
            dimension = (name = fill("time", 5), coordinate = collect(1:5)))

        @test dim_length(dimension(data), :time) == 2
    end

    @testset "name and baseMVA are the caller's to give" begin
        data = parse_tables(; radial_tables()..., name = "radial", baseMVA = 250.0)

        @test data.name == "radial"
        @test data.baseMVA == 250.0
    end
end

################################################################################
# The Arrow extension                                                          #
################################################################################

@testset "arrow files" begin

    "write the tables of `nt` into `dir` as one Arrow file each"
    function write_tables(dir; kwargs...)
        for (name, tbl) in kwargs
            Arrow.write(joinpath(dir, "$name.arrow"), tbl)
        end
        return dir
    end

    @testset "a directory of tables is a network" begin
        mktempdir() do dir
            write_tables(dir; radial_tables()...)

            data = parse_arrow(dir)
            @test data isa NetworkData
            @test sort(collect(keys(units(network(data))))) == [1, 2, 3]
            @test edges(network(data))[1].terminals == [1, 2]
            @test units(network(data))[1].cost == [0.0, 10.0]

            # and it solves to the same hand-computed answer as the tables did
            result = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER))
            @test result["objective"] ≈ 55.0 atol = 1e-5
        end
    end

    @testset "parse_file takes the directory" begin
        mktempdir() do dir
            write_tables(dir; radial_tables()...)

            from_file = parse_file(dir)
            @test from_file isa NetworkData
            # the directory names the network, so a round trip is identifiable
            @test from_file.name == basename(dir)
        end
    end

    @testset "the optional tables are read where they are there" begin
        mktempdir() do dir
            write_tables(dir; radial_tables()...,
                dimension = (name = fill("time", 3), coordinate = [1, 2, 3]),
                profile   = (family = fill("unit", 3), id = fill(3, 3),
                             field = fill("pd", 3), nw = [1, 2, 3],
                             value = [1.0, 2.0, 3.0]))

            data = parse_arrow(dir)
            dim  = dimension(data)
            @test dim_length(dim) == 3
            @test [nw_value(dim, units(network(data))[3].pd, n) for n in 1:3] == [1.0, 2.0, 3.0]
        end
    end

    @testset "it says what is missing" begin
        mktempdir() do dir
            Arrow.write(joinpath(dir, "node.arrow"), TBL_NODE)

            err = try parse_arrow(dir) catch e; e end
            @test err isa ArgumentError
            @test occursin("edge.arrow", err.msg)
        end

        @test_throws ArgumentError parse_arrow(joinpath(@__DIR__, "no-such-directory"))
    end

    @testset "keywords reach parse_tables" begin
        mktempdir() do dir
            write_tables(dir; radial_tables()...)

            data = parse_arrow(dir; baseMVA = 250.0, dim = Dimension(:time => 4))
            @test data.baseMVA == 250.0
            @test dim_length(dimension(data), :time) == 4
        end
    end
end
