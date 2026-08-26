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

################################################################################
# Redispatch                                                                   #
################################################################################

# A redispatch problem minimizes the cost of moving away from a market dispatch
# rather than the cost of the dispatch itself. Adding it needs three things and
# no change to any component file:
#
#   1. a place to put the market dispatch. Either a `pg_market` field on
#      `Generator`, or an entry in its `ext`, written by the parser;
#   2. the upward and downward redispatch variables, a `variable_unit` method
#      for `Generator` dispatching on `P <: RedispatchProblem`, together with a
#      `constraint_unit` method that splits `pg` into the market dispatch plus
#      the upward minus the downward volume;
#   3. an `objective` method dispatching on `P <: RedispatchProblem` that prices
#      those two volumes.
#
# The builder itself is then the one below.

# function build_model!(nm::NetworkModel{P,F}) where {P<:RedispatchProblem,F<:IVRFormulation}
#     for n in nw_ids(nm)
#         variable_node_voltage(nm; nw = n)
#         variable_edge(nm; nw = n)
#         variable_unit(nm; nw = n)
#
#         constraint_node_voltage_reference(nm; nw = n)
#         constraint_node_voltage_limits(nm; nw = n)
#         constraint_node_balance(nm; nw = n)
#         constraint_edge(nm; nw = n)
#         constraint_edge_limits(nm; nw = n)
#         constraint_unit(nm; nw = n)
#     end
#
#     objective(nm)
#
#     return nm
# end
#
# register_model!(RedispatchProblem, IVRFormulation)
