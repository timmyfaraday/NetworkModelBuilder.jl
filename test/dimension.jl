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
        ld  = FixedLoad(; id = 2, name = "load", node = 7,
                   pd = nw_vector(dim, [0.1, 0.2, 0.3]), qd = 0.05)

        @test has_nw_data(ld)
        for n in 1:3
            resolved = nw_component(dim, ld, n)
            @test resolved isa FixedLoad
            @test resolved.pd ≈ 0.1 * n
            @test resolved.qd == 0.05          # the constant survived
            @test resolved.node == 7
            @test !has_nw_data(resolved)
        end

        # a component with nothing network dependent is returned untouched
        plain = FixedLoad(; id = 3, node = 7, pd = 0.1, qd = 0.05)
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

    @testset "no grouping is one period spanning the horizon" begin
        dim = Dimension(:time => 4, :contingency => 3)

        @test period_count(dim) == 1
        @test all(period_id(dim, n) == 1 for n in nw_ids(dim))
        # the whole horizon, and only this contingency
        @test period_ids(dim, 6) == [5, 6, 7, 8]
        @test is_first_period_id(dim, 5) && is_last_period_id(dim, 8)
        @test !is_first_period_id(dim, 6) && !is_last_period_id(dim, 7)
    end

    @testset "a regular grouping is arithmetic" begin
        dim = Dimension(:time => 96, :contingency => 3)
        dim_meta(dim, :time)[:period_length] = 24

        @test period_count(dim) == 4
        @test period_id(dim, 24) == 1
        @test period_id(dim, 25) == 2
        @test period_ids(dim, 30) == collect(25:48)
        @test is_first_period_id(dim, 25)
        @test is_last_period_id(dim, 48)
        @test !is_first_period_id(dim, 26)

        # nothing is stored per coordinate to say so
        @test _NMB._prop(dim, :time) isa Int
    end

    @testset "a period composes with the other dimensions" begin
        dim = Dimension(:time => 96, :contingency => 3)
        dim_meta(dim, :time)[:period_length] = 24

        # index 100 is hour 4 of contingency 2: its day is that contingency's
        @test coordinates(dim, 100) == (time = 4, contingency = 2)
        @test period_ids(dim, 100) == collect(97:120)
        @test all(coordinates(dim, m).contingency == 2 for m in period_ids(dim, 100))

        # every index belongs to exactly one period of its own contingency
        for n in nw_ids(dim)
            @test n in period_ids(dim, n)
            @test length(period_ids(dim, n)) == 24
        end
    end

    @testset "an irregular grouping is a coordinate property" begin
        dim = Dimension(:time => [Dict{Symbol,Any}(:period => p) for p in [1, 1, 1, 2, 2]])

        @test period_count(dim) == 2
        @test period_ids(dim, 2) == [1, 2, 3]
        @test period_ids(dim, 5) == [4, 5]
        @test is_first_period_id(dim, 4) && is_last_period_id(dim, 3)

        # a period that does not divide the dimension evenly is why this exists
        @test length(period_ids(dim, 1)) != length(period_ids(dim, 5))
    end

    @testset "the property wins over the rule, being the more specific" begin
        dim = Dimension(:time => [Dict{Symbol,Any}(:period => 1) for _ in 1:4])
        dim_meta(dim, :time)[:period_length] = 2

        @test period_count(dim) == 1
        @test period_ids(dim, 3) == [1, 2, 3, 4]
    end

    @testset "a period length has to be a positive integer" begin
        dim = Dimension(:time => 4)

        dim_meta(dim, :time)[:period_length] = 0
        @test_throws ArgumentError period_ids(dim, 1)

        dim_meta(dim, :time)[:period_length] = 2.5
        @test_throws ArgumentError period_ids(dim, 1)
    end

    @testset "a window carries the periods it cut, not the rule" begin
        dim = Dimension(:time => 96)
        dim_meta(dim, :time)[:period_length] = 24

        # hours 20 to 31 straddle the boundary between day 1 and day 2
        sub = _NMB._window_dimension(dim, :time, collect(20:31))

        @test [period_id(sub, m) for m in nw_ids(sub)] == [fill(1, 5); fill(2, 7)]
        @test period_ids(sub, 1) == [1, 2, 3, 4, 5]
        @test period_ids(sub, 6) == collect(6:12)

        # the rule is left behind rather than reapplied to renumbered coordinates
        @test !haskey(dim_meta(sub, :time), :period_length)

        # and the source keeps both its rule and its metadata dictionary
        @test dim_meta(dim, :time)[:period_length] == 24
        @test period_ids(dim, 30) == collect(25:48)

        # a window aligned on a boundary is one whole period
        aligned = _NMB._window_dimension(dim, :time, collect(25:48))
        @test all(period_id(aligned, m) == 2 for m in nw_ids(aligned))

        # a problem with no grouping keeps the cheap representation
        plain = _NMB._window_dimension(Dimension(:time => 96), :time, collect(20:31))
        @test _NMB._prop(plain, :time) isa Int
    end
end
