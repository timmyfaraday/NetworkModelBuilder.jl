################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.5.0 - initial implementation                                              #
################################################################################

# Julia's stdlib Markdown parser, the one Documenter builds the site with, wants
# every cell of a table's alignment row to be at least three characters wide:
# `---`, `:--` or `--:`. A narrower cell, `|:-|`, makes it reject the whole block
# and fall back to a paragraph, which reaches the site as a run-on line of pipes
# and en-dashes. Nothing warns about it — a paragraph holding pipes is valid
# markdown — so the check lives here, where a broken table fails CI instead.

const DOCS_SRC = normpath(joinpath(@__DIR__, "..", "docs", "src"))

"the indices of the lines of `lines` that sit outside a fenced block"
function unfenced(lines)
    fenced, ids = false, Int[]
    for (i, l) in enumerate(lines)
        if occursin(r"^\s*(```|~~~)", l)
            fenced = !fenced
        elseif !fenced
            push!(ids, i)
        end
    end
    return ids
end

"true if `l` is a table alignment row, a line of nothing but `|`, `-`, `:` and space"
is_alignment_row(l) = occursin(r"^\s*\|?[\s:|-]+\|[\s:|-]*$", l) &&
                      occursin("-", l) && occursin("|", l)

"the alignment rows of `file` whose table the markdown parser does not accept"
function broken_tables(file)
    lines, broken = readlines(file), String[]
    for i in unfenced(lines)
        i > 1                       || continue
        is_alignment_row(lines[i])  || continue
        occursin("|", lines[i - 1]) || continue

        block = join(lines[i-1:min(i + 1, end)], "\n") * "\n"
        any(x -> x isa Markdown.Table, Markdown.parse(block).content) && continue

        push!(broken, "$(relpath(file, DOCS_SRC)):$i\n    $(lines[i - 1])\n    $(lines[i])")
    end
    return broken
end

@testset "docs" begin

    @testset "every table renders as a table" begin
        broken = String[]
        for (root, _, files) in walkdir(DOCS_SRC), f in sort(files)
            endswith(f, ".md") || continue
            append!(broken, broken_tables(joinpath(root, f)))
        end

        isempty(broken) ||
            @error "these tables fall back to a paragraph, widen every alignment " *
                   "cell to at least three characters:\n" * join(broken, "\n")

        @test isempty(broken)
    end

    @testset "the check catches a narrow alignment cell" begin
        good = "| h | a |\n|:--|:--|\n| x | 1 |\n"
        bad  = "| h | a |\n|:-|:--|\n| x | 1 |\n"

        @test  any(x -> x isa Markdown.Table, Markdown.parse(good).content)
        @test !any(x -> x isa Markdown.Table, Markdown.parse(bad).content)

        @test is_alignment_row("|:--|----------:|")
        @test !is_alignment_row("| x | 1 |")
    end

end
