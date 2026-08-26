################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.1.0 - initial implementation                                              #
# v0.2.0 - network dependent data stored per component                         #
################################################################################

@testset "dimension" begin

    @testset "single network" begin
        dim = Dimension()

        @test dim_length(dim) == 1
        @test dim_names(dim) == ()
        @test nw_ids(dim) == [1]
        @test coordinates(dim, 1) == NamedTuple()
    end

    @testset "construction" begin
        dim = Dimension(:time => 4, :contingency => 3)

        @test dim_names(dim) == (:time, :contingency)
        @test dim_length(dim) == 12
        @test dim_length(dim, :time) == 4
        @test dim_length(dim, :contingency) == 3
        @test dim_position(dim, :contingency) == 2
        @test has_dim(dim, :time)
        @test !has_dim(dim, :harmonic)

        @test_throws ArgumentError Dimension(:time => 4, :time => 3)
        @test_throws ArgumentError Dimension(:time => 0)
        @test_throws ArgumentError dim_length(dim, :harmonic)
    end

    @testset "the first dimension varies fastest" begin
        dim = Dimension(:time => 4, :contingency => 3)

        @test nw_ids(dim) == collect(1:12)
        @test nw_ids(dim; contingency = 1) == [1, 2, 3, 4]
        @test nw_ids(dim; time = 2) == [2, 6, 10]
        @test nw_ids(dim; time = 2, contingency = 3) == [10]
        @test nw_ids(dim; time = 1:2, contingency = [1, 3]) == [1, 2, 9, 10]
        @test coordinates(dim, 7) == (time = 3, contingency = 2)
        @test coordinates(dim, 1) == (time = 1, contingency = 1)
        @test coordinates(dim, 12) == (time = 4, contingency = 3)
    end

    @testset "index arithmetic" begin
        dim = Dimension(:time => 4, :contingency => 3)

        @test similar_id(dim, 7; time = 1) == 5
        @test similar_ids(dim, 7; time = 1:4) == [5, 6, 7, 8]
        @test first_id(dim, 7, :time) == 5
        @test last_id(dim, 7, :time) == 8
        @test first_id(dim, 7, :contingency) == 3
        @test last_id(dim, 7, :contingency) == 11
        @test first_id(dim, 7, :time, :contingency) == 1
        @test prev_id(dim, 7, :time) == 6
        @test next_id(dim, 7, :time) == 8
        @test prev_ids(dim, 7, :time) == [5, 6]
        @test next_ids(dim, 7, :time) == [8]
        @test is_first_id(dim, 5, :time)
        @test is_last_id(dim, 8, :time)
        @test !is_first_id(dim, 7, :time)

        @test_throws ArgumentError prev_id(dim, 5, :time)
        @test_throws ArgumentError next_id(dim, 8, :time)
        @test_throws ArgumentError nw_ids(dim; harmonic = 1)
    end

    @testset "properties and metadata" begin
        dim = Dimension(:scenario => [Dict{Symbol,Any}(:probability => p) for p in [0.1, 0.4, 0.5]],
                        :time     => 2)

        @test dim_length(dim, :scenario) == 3
        @test dim_prop(dim, :scenario, 2, :probability) == 0.4
        @test dim_prop(dim, 5, :scenario, :probability) == 0.4   # nw 5 == (scenario 2, time 2)
        @test coordinates(dim, 5) == (scenario = 2, time = 2)

        dim.meta[:time][:unit] = "hour"
        @test dim_meta(dim, :time, :unit) == "hour"
        @test_throws ArgumentError dim_meta(dim, :harmonic)
    end

    @testset "nothing is stored per network index" begin
        # the index is arithmetic, and a dimension without properties stores its
        # size rather than a dictionary per coordinate, so a Dimension is the
        # same handful of bytes however many network indices it spans
        small = Dimension(:time => 2)
        big   = Dimension(:time => 100_000)

        @test Base.summarysize(big) == Base.summarysize(small)
        @test Base.summarysize(big) < 5_000
        @test dim_length(big) == 100_000
        @test nw_ids(big; time = 99_999) == [99_999]
        @test coordinates(big, 12_345) == (time = 12_345,)

        # properties are stored only where they were actually given
        withprop = Dimension(:scenario => [Dict{Symbol,Any}(:probability => 0.5) for _ in 1:2])
        @test Base.summarysize(withprop) > Base.summarysize(small)
        @test dim_prop(withprop, :scenario, 2, :probability) == 0.5
    end

    @testset "dim_prop falls back to a default" begin
        plain  = Dimension(:time => 3)
        scored = Dimension(:time => [Dict{Symbol,Any}(:weight => w) for w in 1:3])

        @test dim_prop(plain, :time, 2, :weight, 1.0) == 1.0
        @test dim_prop(plain, 2, :time, :weight, 1.0) == 1.0
        @test dim_prop(plain, :time, 2) == Dict{Symbol,Any}()
        @test_throws KeyError dim_prop(plain, :time, 2, :weight)

        @test dim_prop(scored, :time, 2, :weight, 99) == 2
        @test dim_prop(scored, 3, :time, :weight, 99) == 3

        # the dictionary handed back for a bare dimension is nobody else's
        d = dim_prop(plain, :time, 1)
        d[:weight] = 7.0
        @test dim_prop(plain, :time, 1, :weight, 1.0) == 1.0
    end

    @testset "NetworkVector and the generalized getters" begin
        dim = Dimension(:time => 3)

        v = nw_vector(dim, [10.0, 20.0, 30.0])
        @test v isa NetworkVector{Float64}
        @test length(v) == 3
        @test eltype(v) == Float64
        @test v[2] == 20.0
        @test collect(v) == [10.0, 20.0, 30.0]

        # a constant passes through whatever its type, a NetworkVector is indexed
        @test nw_value(dim, v, 2) == 20.0
        @test nw_value(dim, 0.4, 2) == 0.4
        @test nw_value(dim, [1, 2], 2) == [1, 2]        # a genuine vector, not a profile
        @test nw_value(dim, "bus 4", 2) == "bus 4"
        @test nw_values(dim, v) == [10.0, 20.0, 30.0]
        @test nw_values(dim, 0.4) == [0.4, 0.4, 0.4]
        @test_throws ArgumentError nw_value(dim, v, 4)

        @test is_nw_varying(v)
        @test !is_nw_varying(0.4)
        @test !is_nw_varying([1, 2])
    end

    @testset "nw_component resolves a whole component" begin
        dim = Dimension(:time => 3)
        ld  = Load(; id = 2, name = "load", node = 7,
                   pd = nw_vector(dim, [0.1, 0.2, 0.3]), qd = 0.05)

        @test has_nw_data(ld)
        for n in 1:3
            resolved = nw_component(dim, ld, n)
            @test resolved isa Load
            @test resolved.pd ≈ 0.1 * n
            @test resolved.qd == 0.05          # the constant survived
            @test resolved.node == 7
            @test !has_nw_data(resolved)
        end

        # a component with nothing network dependent is returned untouched
        plain = Load(; id = 3, node = 7, pd = 0.1, qd = 0.05)
        @test !has_nw_data(plain)
        @test nw_component(dim, plain, 2) === plain
    end

    @testset "all_nw broadcasts constants against vectors" begin
        dim = Dimension(:time => 3)

        @test all_nw(>(0), 1.05)
        @test !all_nw(>(0), 0.0)
        @test all_nw(>(0), nw_vector(dim, [1.0, 1.05, 0.95]))
        @test !all_nw(>(0), nw_vector(dim, [1.0, -0.1, 0.95]))

        @test all_nw(<=, -0.5, 0.5)
        @test all_nw(<=, nw_vector(dim, [-0.5, -0.4, -0.3]), 0.5)
        @test !all_nw(<=, nw_vector(dim, [-0.5, 0.9, -0.3]), 0.5)
        @test_throws ArgumentError all_nw(<=, nw_vector(dim, [1.0, 2.0, 3.0]),
                                          NetworkVector([1.0, 2.0]))
    end

    @testset "add_dimension" begin
        dim = add_dimension(Dimension(:time => 4), :harmonic, 3;
                            metadata = Dict{Symbol,Any}(:orders => [1, 5, 7]))

        @test dim_names(dim) == (:time, :harmonic)
        @test dim_length(dim) == 12
        @test dim_meta(dim, :harmonic, :orders) == [1, 5, 7]
        @test_throws ArgumentError add_dimension(dim, :time, 2)
    end
end
