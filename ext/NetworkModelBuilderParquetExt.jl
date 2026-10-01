################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.10.0 - initial implementation                                             #
################################################################################

# What an Arrow file is to `NetworkModelBuilderArrowExt`, a Parquet file is
# here, and for the same reason: a dashboard reads Parquet, and nothing outside
# this file needs to know that.

module NetworkModelBuilderParquetExt

using Parquet2
using NetworkModelBuilder

function NetworkModelBuilder.write_security_tables(dir::AbstractString, tables)
    mkpath(dir)

    paths = String[]
    for (name, tbl) in pairs(tables)
        path = joinpath(dir, "$name.parquet")
        Parquet2.writefile(path, tbl)
        push!(paths, path)
    end

    return paths
end

end # module
