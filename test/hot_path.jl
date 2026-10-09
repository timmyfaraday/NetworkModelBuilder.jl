################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.12.7 - the component lookups of a build allocate nothing                  #
################################################################################

# A model build resolves a component at a network index for every node, edge and
# unit it touches, tens of thousands of times a window. Before v0.12.2 each of
# those walked the fields of the component with a runtime index and boxed every
# one of them: 1,248 to 2,176 bytes a call, 12 % of a rolling horizon, and no test
# that asks whether an answer is right could see it. Counting bytes does.

"bytes allocated by `f(args...)`: the least of five calls, made after one that compiles it"
function allocated(f, args...)
    f(args...)

    return minimum(@allocated(f(args...)) for _ in 1:5)
end

@testset "hot path" begin

    @testset "resolving a component allocates nothing where it holds no network data" begin
        data = quiet(() -> parse_file(case("case14")))
        mn   = set_dimension(data, Dimension(:time => 3, :contingency => 2))
        net  = network(mn)
        dim  = dimension(mn)

        for c in (net.node[first(ids(net, Node))],
                  net.edge[first(ids(net, Branch))],
                  net.unit[first(ids(net, Generator))])
            @test allocated(has_nw_data, c) == 0
            @test allocated(nw_component, dim, c, 1) == 0
        end
    end

end
