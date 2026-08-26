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
# File input                                                                   #
################################################################################

"""
    parse_file(path)

Parse a network file into a [`NetworkData`](@ref), choosing the reader from the
file extension.

| extension | reader                       |
|:----------|:-----------------------------|
| `.m`      | [`parse_matpower`](@ref)     |
"""
function parse_file(path::AbstractString)
    ext = lowercase(splitext(path)[2])
    ext == ".m" && return parse_matpower(path)

    throw(ArgumentError("no reader is available for a `$ext` file"))
end
