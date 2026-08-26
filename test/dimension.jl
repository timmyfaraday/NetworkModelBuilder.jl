################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.1.0 - initial implementation                                              #
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

    @testset "add_dimension" begin
        dim = add_dimension(Dimension(:time => 4), :harmonic, 3;
                            metadata = Dict{Symbol,Any}(:orders => [1, 5, 7]))

        @test dim_names(dim) == (:time, :harmonic)
        @test dim_length(dim) == 12
        @test dim_meta(dim, :harmonic, :orders) == [1, 5, 7]
        @test_throws ArgumentError add_dimension(dim, :time, 2)
    end
end
