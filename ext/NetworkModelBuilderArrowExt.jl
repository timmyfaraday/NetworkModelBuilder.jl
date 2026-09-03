################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.6.0 - initial implementation                                              #
# v0.8.0 - the zorba tables, in and out                                        #
################################################################################

# Everything that knows what an Arrow file is lives here, and it is four lines
# of it. `parse_tables` reads an `Arrow.Table` without any of this, because a
# table there is anything whose columns can be reached by name; what an
# extension is needed for is only turning a path into one.

module NetworkModelBuilderArrowExt

using Arrow
using NetworkModelBuilder

const _REQUIRED = (:node, :edge, :unit)
const _OPTIONAL = (:profile, :dimension)

function NetworkModelBuilder.parse_arrow(dir::AbstractString; kwargs...)
    isdir(dir) ||
        throw(ArgumentError("`$dir` is not a directory; a network held as tables is " *
                            "one Arrow file per table in a directory of its own"))

    tables = Dict{Symbol,Any}()
    for tbl in _REQUIRED
        path = _path(dir, tbl)
        path === nothing &&
            throw(ArgumentError("`$dir` has no `$tbl.arrow`, and a network needs a " *
                                "`node`, an `edge` and a `unit` table"))
        tables[tbl] = Arrow.Table(path)
    end
    for tbl in _OPTIONAL
        path = _path(dir, tbl)
        path === nothing || (tables[tbl] = Arrow.Table(path))
    end

    return NetworkModelBuilder.parse_tables(; name = basename(abspath(dir)),
                                              tables..., kwargs...)
end

"the path of the `tbl` table in `dir`, or `nothing` where there is none"
function _path(dir::AbstractString, tbl::Symbol)
    path = joinpath(dir, "$tbl.arrow")

    return isfile(path) ? path : nothing
end

const _ZORBA_REQUIRED = (:grid, :net_position)
const _ZORBA_OPTIONAL = (:hvdc, :outage)

function NetworkModelBuilder.parse_zorba(dir::AbstractString; kwargs...)
    isdir(dir) ||
        throw(ArgumentError("`$dir` is not a directory; a Zorba study held as tables is " *
                            "one Arrow file per table in a directory of its own"))

    tables = Dict{Symbol,Any}()
    for tbl in _ZORBA_REQUIRED
        path = _path(dir, tbl)
        path === nothing &&
            throw(ArgumentError("`$dir` has no `$tbl.arrow`, and a Zorba study needs a " *
                                "`grid` and a `net_position` table"))
        tables[tbl] = Arrow.Table(path)
    end
    for tbl in _ZORBA_OPTIONAL
        path = _path(dir, tbl)
        path === nothing || (tables[tbl] = Arrow.Table(path))
    end

    return NetworkModelBuilder.parse_zorba(; name = basename(abspath(dir)),
                                             tables..., kwargs...)
end

function NetworkModelBuilder.write_zorba(dir::AbstractString, tables)
    mkpath(dir)

    return [Arrow.write(joinpath(dir, "$name.arrow"), tbl)
            for (name, tbl) in pairs(tables)]
end

end # module
