################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.10.2 - initial implementation                                             #
################################################################################

# `solution_tables` is a view over the same kind of `result` every other test
# file already solves for, so this file solves nothing new: it reuses
# `radial_network` and `meshed_network` from `rd.jl` and `star_network` from
# `multiterminal.jl`, and checks the tidy tables they turn into rather than the
# numbers themselves — those are already covered where the fixtures live.
# `meshed_network` carries a phase shifter, which only a dispatch problem can
# solve, so it is posed as an `solve_opf` here rather than a `solve_lf`.

@testset "solution tables" begin

    @testset "a plain load flow: shapes and always-present columns" begin
        data   = radial_network()
        result = quiet(() -> solve_lf(data, LPFFormulation, OPTIMIZER))
        tables = solution_tables(data, result)

        @test result["termination_status"] == JuMP.LOCALLY_SOLVED

        # 2 nodes, 1 edge with 2 terminals, 3 units (2 generators, 1 load)
        @test length(tables.node.id) == 2
        @test length(tables.edge.id) == 2
        @test length(tables.unit.id) == 3

        @test issubset([:id, :name, :type, :vm, :va], propertynames(tables.node))
        @test issubset([:id, :name, :type, :terminal, :node, :p], propertynames(tables.edge))
        @test issubset([:id, :name, :type, :node, :p], propertynames(tables.unit))

        @test tables.node.type == ["REF", "PQ"]

        # a linearized solve never carries reactive power or current: the columns
        # they would need are not merely `missing` here, they are not there at all
        @test :q  ∉ propertynames(tables.edge)
        @test :cr ∉ propertynames(tables.edge)
        @test :q  ∉ propertynames(tables.unit)
    end

    @testset "a generator and a load leave different columns behind" begin
        data   = radial_network()
        result = quiet(() -> solve_lf(data, LPFFormulation, OPTIMIZER))
        tables = solution_tables(data, result)

        @test only(tables.unit.pg[tables.unit.id .== 1]) isa Real
        @test only(tables.unit.pd[tables.unit.id .== 3]) isa Real

        # `pg` is a real column here — some unit does carry it — so the load's
        # entry is `missing`, not simply absent; likewise `pd` for a generator
        @test ismissing(only(tables.unit.pg[tables.unit.id .== 3]))
        @test ismissing(only(tables.unit.pd[tables.unit.id .== 1]))
    end

    @testset "an IVR solve carries what a linearized one cannot" begin
        data   = radial_network()
        result = quiet(() -> solve_lf(data, IVRFormulation, OPTIMIZER))
        tables = solution_tables(data, result)

        @test issubset([:q, :cr, :ci], propertynames(tables.edge))
        @test issubset([:q, :cru, :ciu], propertynames(tables.unit))
    end

    @testset "an edge with more than two terminals gets one row per terminal" begin
        data   = star_network()
        result = quiet(() -> solve_lf(data, IVRFormulation, OPTIMIZER))
        tables = solution_tables(data, result)

        @test length(tables.node.id) == 3
        @test length(tables.unit.id) == 3

        # one edge, three terminals: three rows, not one
        @test length(tables.edge.id) == 3
        @test all(==(1), tables.edge.id)
        @test tables.edge.terminal == [1, 2, 3]
        @test tables.edge.node     == [1, 2, 3]
    end

    @testset "every dimension becomes its own column" begin
        data   = meshed_network(; dim = Dimension(:contingency => 2))
        result = quiet(() -> solve_opf(data, LPFFormulation, OPTIMIZER))
        tables = solution_tables(data, result)

        @test result["termination_status"] == JuMP.LOCALLY_SOLVED

        # 3 nodes and 3 units over 2 network indices, 3 edges of 2 terminals each
        @test length(tables.node.id) == 6
        @test length(tables.unit.id) == 6
        @test length(tables.edge.id) == 12

        @test :contingency in propertynames(tables.node)
        @test sort(unique(tables.node.contingency)) == [1, 2]
        @test count(==(1), tables.node.contingency) == 3
        @test count(==(2), tables.node.contingency) == 3
    end

    @testset "a transformer's tap is flattened, a plain branch has none" begin
        data   = meshed_network()
        result = quiet(() -> solve_opf(data, LPFFormulation, OPTIMIZER))
        tables = solution_tables(data, result)

        # the linearized formulation carries the tap as a magnitude and an angle,
        # not as the real/imaginary pair the current based one needs to stay
        # polynomial — see `solution_edge!` in `transformer.jl`
        @test issubset([:tap_tm, :tap_ta], propertynames(tables.edge))

        shifter = tables.edge.type .== "PhaseShifter"
        branch  = tables.edge.type .== "Branch"
        @test count(shifter) == 2      # one phase shifter, two terminals
        @test count(branch)  == 4      # two branches, two terminals each

        @test all(!ismissing, tables.edge.tap_tm[shifter])
        @test all(ismissing,  tables.edge.tap_tm[branch])
    end
end
