################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.1.0 - initial implementation                                              #
# v0.6.0 - a directory of tables is a network too                              #
################################################################################

################################################################################
# File input                                                                   #
################################################################################

"""
    parse_file(path)

Parse a network into a [`NetworkData`](@ref), choosing the reader from what
`path` is.

| path                | reader                       |
|:--------------------|:-----------------------------|
| a `.m` file         | [`parse_matpower`](@ref)     |
| a directory         | [`parse_arrow`](@ref)        |

A directory is a network held as [tables](@ref "Tabular input"), one Arrow file
per table, and reading one needs the Arrow package loaded — see
[`parse_arrow`](@ref).
"""
function parse_file(path::AbstractString)
    isdir(path) && return parse_arrow(path)

    ext = lowercase(splitext(path)[2])
    ext == ".m" && return parse_matpower(path)

    throw(ArgumentError("no reader is available for a `$ext` file"))
end

"""
    parse_arrow(dir; kwargs...)

Read a network held as Arrow files in `dir` and build a [`NetworkData`](@ref).

The directory holds one file per table of [`parse_tables`](@ref), which is also
where the columns are described:

| file              | required |
|:------------------|:---------|
| `node.arrow`      | yes      |
| `edge.arrow`      | yes      |
| `unit.arrow`      | yes      |
| `profile.arrow`   | no       |
| `dimension.arrow` | no       |

Keywords are passed to [`parse_tables`](@ref).

!!! note "Arrow is a weak dependency"
    This package does not depend on Arrow: reading one file format should not
    put a compression codec and a time-zone database into every install that
    never reads one. The method arrives with an extension, so `using Arrow`
    somewhere in the session is what switches it on.

    Nothing else is gated. [`parse_tables`](@ref) reads an `Arrow.Table`, a
    `DataFrame` or a `NamedTuple` of vectors without any of this, since a table
    is anything whose columns can be reached by name.
"""
function parse_arrow(args...; kwargs...)
    throw(ArgumentError("reading Arrow needs the Arrow package: run `using Arrow` " *
                        "and try again. `parse_tables` takes an `Arrow.Table`, a " *
                        "`DataFrame` or a `NamedTuple` of vectors without it."))
end
