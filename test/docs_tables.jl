################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.14.0 - initial implementation                                             #
################################################################################

# Every concrete component type has a Parameters table and a Variables table in
# the docs (`docs/src/components/`). The first is the type's fields, so a field
# that is added, renamed or removed without the table following is a failure; the
# second is the variable keys a solve registers, so a key nobody documented, or
# one the docs name and no solve registers, is one too. This file reads the pages
# the way a reader does, a table row at a time, and compares them with the code.

"the component types of the docs, each with the page it is on"
const DT_PAGES = [Node            => "node",
                  Branch          => "branch",
                  Transformer     => "transformer",
                  DCLink          => "dc_link",
                  Switch          => "switch",
                  Generator       => "generator",
                  FixedLoad       => "load",
                  FlexibleLoad    => "load",
                  Storage         => "storage",
                  Shunt           => "shunt",
                  EnergyNotServed => "slack",
                  Spill           => "slack"]

"the heading level of a markdown line, 0 where it is not a heading"
function dt_level(line::AbstractString)
    m = match(r"^(#+) ", line)

    return m === nothing ? 0 : length(m.captures[1])
end

"the lines under `heading`, up to the next heading of the same or a higher level, or `nothing` where there is no such heading"
function dt_section(lines::Vector{String}, heading::String)
    first = findfirst(==(heading), lines)
    first === nothing && return nothing

    level = dt_level(heading)
    stop  = length(lines)
    for i in first+1:length(lines)
        0 < dt_level(lines[i]) <= level && (stop = i - 1; break)
    end

    return lines[first+1:stop]
end

"the rows of every table in `lines`, each as its cells; the header comes first and the separator is dropped"
function dt_tables(lines::Vector{String})
    tables = Vector{Vector{String}}[]
    current = nothing
    for line in lines
        if startswith(line, "|")
            cells = String.(strip.(split(line, "|")[2:end-1]))
            all(c -> occursin(r"^:?-+:?$", c), cells) && continue
            current === nothing && (current = Vector{String}[]; push!(tables, current))
            push!(current, cells)
        else
            current = nothing
        end
    end

    return tables
end

"the words in backticks in a cell"
dt_words(cell::AbstractString) = [m.captures[1] for m in eachmatch(r"`([^`]+)`", cell)]

"the section of a page for one type: its own `### \\`T\\`` where the page holds several types, the whole of it where it holds one"
function dt_for_type(lines::Vector{String}, heading::String, T::Type)
    section = dt_section(lines, heading)
    section === nothing && return nothing
    own = dt_section(section, "### `$(nameof(T))`")

    return own === nothing ? section : own
end

"the page `name` of the components docs, as lines"
dt_page(name::String) = readlines(joinpath(BASE_DIR, "docs", "src", "components", "$name.md"))

"the code names in the second column of `tables`"
dt_table_names(tables) = [w for t in tables for row in t[2:end] for w in dt_words(row[2])]

"the code names in the second column of the tables of `lines`"
dt_code_names(lines::Vector{String}) = dt_table_names(dt_tables(lines))

@testset "docs tables" begin

    @testset "a Parameters table lists the fields of its type, no more and no less" begin
        for (T, page) in DT_PAGES
            section = dt_for_type(dt_page(page), "## Parameters", T)
            @test section !== nothing
            section === nothing && continue

            documented = Set(Symbol.(dt_code_names(section)))
            fields     = Set(fieldnames(T))
            @test (T, setdiff(fields, documented)) == (T, Set{Symbol}())
            @test (T, setdiff(documented, fields)) == (T, Set{Symbol}())
        end
    end

    @testset "the tables read symbol, code name and, for variables, index" begin
        for (T, page) in DT_PAGES, (heading, head) in ("## Parameters" => ["symbol", "code name"],
                                                       "## Variables"  => ["symbol", "code name", "index"])
            section = dt_for_type(dt_page(page), heading, T)
            section === nothing && continue

            for table in dt_tables(section)
                @test (T, heading, table[1][1:length(head)]) == (T, heading, head)
            end
        end
    end

    @testset "a Variables table lists keys a solve registers, and every key is in a table" begin
        registered = nom_variable_keys()
        for (T, page) in DT_PAGES
            section = dt_for_type(dt_page(page), "## Variables", T)
            @test section !== nothing
            section === nothing && continue

            keys = Set(lstrip(w, ':') for w in dt_code_names(section))
            @test (T, setdiff(keys, registered)) == (T, Set{String}())
        end

        # a key that belongs to a problem rather than to a type is in the page of the problem
        documented = Set{String}()
        for path in nom_files("docs/src", ".md"), table in dt_tables(readlines(path))
            table[1][2] == "code name" || continue
            for w in dt_table_names([table])
                startswith(w, ":") && push!(documented, w[2:end])
            end
        end
        @test setdiff(registered, documented) == Set{String}()
    end

end
