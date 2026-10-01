################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.5.0 - initial implementation                                              #
# v0.9.6 - every complete example in the docs runs in CI                       #
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

# A complete example is a fenced ```julia block, or a Documenter ```@example
# block, that imports the package itself rather than continuing one shown
# earlier on the same page — the latter reads naturally in prose but was never
# executed, which is exactly how a bad bare filename (`"case14.m"`) went
# unnoticed until someone happened to run it from the wrong directory.

"the language or directive on a fence-opening line, or an empty string"
_fence_lang(l) = (m = match(r"^\s*```(\S*)", l); m === nothing ? "" : m.captures[1])

"the fenced code blocks of `file` that read like a complete, runnable example"
function complete_examples(file)
    examples, lang, block, fenced = String[], "", String[], false
    for l in readlines(file)
        if occursin(r"^\s*(```|~~~)", l)
            if fenced && lang in ("julia", "@example")
                code = join(block, "\n")
                occursin("using NetworkModelBuilder", code) && push!(examples, code)
            end
            empty!(block)
            fenced = !fenced
            fenced && (lang = _fence_lang(l))
        else
            fenced && push!(block, l)
        end
    end
    return examples
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

    @testset "every complete example runs" begin
        found = false
        for (root, _, files) in walkdir(DOCS_SRC), f in sort(files)
            endswith(f, ".md") || continue
            file = joinpath(root, f)
            for (i, code) in enumerate(complete_examples(file))
                found = true
                @testset "$(relpath(file, DOCS_SRC))#$i" begin
                    quiet(() -> redirect_stdout(devnull) do
                        include_string(Module(), code)
                    end)
                    @test true
                end
            end
        end
        @test found
    end

end
