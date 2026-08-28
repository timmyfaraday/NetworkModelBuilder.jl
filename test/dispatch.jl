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

@testset "problem and formulation dispatch" begin

    @testset "the type hierarchies" begin
        @test LoadFlowProblem          <: AbstractPowerFlowProblem <: AbstractProblemType
        @test OptimalPowerFlowProblem  <: AbstractDispatchProblem  <: AbstractProblemType
        @test RedispatchProblem        <: AbstractDispatchProblem
        @test IVRFormulation           <: AbstractCurrentFormulation <: AbstractACFormulation
        @test ACPFormulation           <: AbstractPowerFormulation   <: AbstractACFormulation
        @test LPFFormulation           <: AbstractLinearizedFormulation      <: AbstractFormulationType

        # every tag is abstract, so an extension package can specialise it
        @test isabstracttype(LoadFlowProblem)
        @test isabstracttype(IVRFormulation)
    end

    @testset "the model carries both types" begin
        data = quiet(() -> parse_file(case("case5")))
        nm   = instantiate_model(data, LoadFlowProblem, IVRFormulation)

        @test nm isa NetworkModel{LoadFlowProblem,IVRFormulation}
        @test problem_type(nm) === LoadFlowProblem
        @test formulation_type(nm) === IVRFormulation
        @test nw_ids(nm) == [1]
        @test nw_id_default(nm) == 1
    end

    @testset "the implemented combinations" begin
        @test (LoadFlowProblem, IVRFormulation) in implemented_models()
        @test (OptimalPowerFlowProblem, IVRFormulation) in implemented_models()
        @test (RedispatchProblem, IVRFormulation) in implemented_models()
    end

    @testset "an unsupported combination reports what is available" begin
        data = quiet(() -> parse_file(case("case5")))

        err = try
            instantiate_model(data, LoadFlowProblem, ACPFormulation)
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("no model builder", err.msg)
        @test occursin("ACPFormulation", err.msg)
        @test occursin("LoadFlowProblem with IVRFormulation", err.msg)

        err = try
            instantiate_model(data, RedispatchProblem, ACRFormulation)
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("ACRFormulation", err.msg)
        @test occursin("RedispatchProblem with IVRFormulation", err.msg)
    end

    @testset "the problem type changes the model" begin
        data = quiet(() -> parse_file(case("case5")))
        lf   = instantiate_model(data, LoadFlowProblem, IVRFormulation)
        opf  = instantiate_model(data, OptimalPowerFlowProblem, IVRFormulation)

        # a load flow leaves the voltage unbounded and fixes the generator setpoints
        @test !JuMP.has_upper_bound(_NMB.var(lf, :vr, 1))
        @test JuMP.is_fixed(_NMB.var(lf, :pg, 1))

        # a dispatch problem bounds the voltage and the generator power instead
        @test JuMP.has_upper_bound(_NMB.var(opf, :vr, 1))
        @test JuMP.upper_bound(_NMB.var(opf, :vr, 1)) == node(opf, 1).vmax
        @test !JuMP.is_fixed(_NMB.var(opf, :pg, 1))
        @test JuMP.upper_bound(_NMB.var(opf, :pg, 1)) ≈ unit(opf, 1).pmax

        # the PV magnitude setpoint exists only in a load flow, the limits only in a dispatch
        @test haskey(_NMB.con(lf), :node_voltage_setpoint)
        @test !haskey(_NMB.con(lf), :node_voltage_limits)
        @test haskey(_NMB.con(opf), :node_voltage_limits)
        @test !haskey(_NMB.con(opf), :node_voltage_setpoint)

        @test JuMP.objective_function(lf.model) == JuMP.AffExpr(0.0)
        @test JuMP.objective_function(opf.model) != JuMP.AffExpr(0.0)
    end
end
