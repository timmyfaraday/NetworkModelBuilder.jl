################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.9.4 - initial implementation                                              #
################################################################################

# `register_edge_type!`, `register_unit_type!` and `register_model!` are called
# from many threads at once here, exactly what a parallel test harness or a
# plugin-style loader would do. `edge_types()`, `unit_types()` and
# `implemented_models()` are the read side, already safe by inspection since
# each `copy()`s a snapshot rather than exposing the registry itself, and are
# reconfirmed here under concurrent readers.

const _THREAD_SAFETY_EDGES = DataType[]
const _THREAD_SAFETY_UNITS = DataType[]

for k in 1:64
    edge_name, unit_name = Symbol(:_ThreadSafetyEdge, k), Symbol(:_ThreadSafetyUnit, k)
    @eval struct $edge_name <: AbstractEdge end
    @eval struct $unit_name <: AbstractUnit end
    push!(_THREAD_SAFETY_EDGES, getfield(@__MODULE__, edge_name))
    push!(_THREAD_SAFETY_UNITS, getfield(@__MODULE__, unit_name))
end

@testset "thread safety" begin

    @testset "concurrent registration does not crash" begin
        Threads.@threads for k in 1:64
            register_edge_type!(_THREAD_SAFETY_EDGES[k])
        end
        @test all(T -> T in edge_types(), _THREAD_SAFETY_EDGES)

        Threads.@threads for k in 1:64
            register_unit_type!(_THREAD_SAFETY_UNITS[k])
        end
        @test all(T -> T in unit_types(), _THREAD_SAFETY_UNITS)

        Threads.@threads for k in 1:64
            register_model!(:_thread_safety_problem, k)
        end
        @test all(k -> (:_thread_safety_problem, k) in implemented_models(), 1:64)
    end

    @testset "concurrent reads of a registry stay safe" begin
        Threads.@threads for _ in 1:64
            for _ in 1:1000
                edge_types(); unit_types(); implemented_models()
            end
        end
        @test true
    end

    @testset "concurrent topology lookups answer for the index asked" begin
        data = quiet(() -> parse_file(case("case5")))
        net  = network(set_dimension(data, Dimension(:contingency => 3); apply! = function (net, d)
                   br = net.edge[1]::Branch
                   net.edge[1] = Branch(; id = br.id, terminals = br.terminals, r = br.r, x = br.x,
                                        status = nw_vector(d, (n, c) -> n != 2))
               end))
        # derived before the threads start: what they share and write is the remembered answer
        tops = [topology(net; nw = n) for n in 1:3]

        wrong = Threads.Atomic{Int}(0)
        Threads.@threads for t in 1:64
            for i in 1:2000
                n = 1 + (i + t) % 3
                topology(net; nw = n) === tops[n] || Threads.atomic_add!(wrong, 1)
            end
        end
        @test wrong[] == 0
    end

end
