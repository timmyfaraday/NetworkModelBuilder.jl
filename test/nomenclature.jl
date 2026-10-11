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

# The names of fields, variable keys and solution keys follow one grammar
# (`.github/context/knowledge/nomenclature.md`): a symbol, then at most two of a
# what, a part and a qualifier in that order, then a unit where the quantity is
# not in pu. This file is that grammar as data, the map from the old names to the
# new ones, and four checks: the vocabulary is closed, every name the package
# builds follows it, and no old name is left anywhere a reader would look.

"a quantity: one letter, `η` the only one that is not ASCII"
const NOM_SYMBOLS = Set(["v", "i", "p", "q", "s", "r", "x", "g", "b", "e", "t", "c", "l", "z", "k", "η"])

"what a quantity belongs to: a location, an owner or a role"
const NOM_WHAT = Set(["term", "ser", "shnt", "mgnt", "star", "pnt", "wind",
                      "gen", "stor", "flex", "slk", "dcl", "sw", "unit",
                      "chg", "dch", "loss", "base", "ovl", "cycl", "per"])

"which part of a complex or polar quantity"
const NOM_PART = Set(["real", "imag", "magn", "angl"])

"a bound, a reference, a direction or a kind"
const NOM_QUALIFIER = Set(["min", "max", "set", "init", "fin", "nom", "mkt", "up", "dn",
                           "fix", "prop", "thru", "peak", "step", "ener"])

"a unit, only where the quantity is not in pu or rad"
const NOM_UNIT = Set(["kv", "mva", "km"])

"what is not a quantity stays a plain word"
const NOM_WORDS = Set(["id", "name", "node", "terminals", "status", "ext", "type", "area", "zone",
                       "lock", "position", "reverse", "oltc", "pst", "net",
                       "terminal", "tap"])

"an old name that is also a word elsewhere, so only the grammar check looks for it"
const NOM_SHARED = Set(["step"])

"the duals keep the names they have until the step that names constraints"
const NOM_KEPT = Set(["lambda", "lambda_q", "lambda_real", "lambda_imag"])

"a field, old and new"
const NOM_FIELDS = [
    "vm" => "v_magn_set", "va" => "v_angl_set", "vmin" => "v_magn_min", "vmax" => "v_magn_max",
    "base_kv" => "v_base_kv",
    "pg" => "p_set", "qg" => "q_set", "pmin" => "p_min", "pmax" => "p_max", "qmin" => "q_min",
    "qmax" => "q_max", "vg" => "v_magn_set", "max_energy_per_period" => "e_per_max",
    "cost" => "c", "cost_up" => "c_up", "cost_dn" => "c_dn",
    "pd" => "p_set", "qd" => "q_set",
    "pd_nominal" => "p_nom", "qd_nominal" => "q_nom", "pd_min" => "p_min", "pd_max" => "p_max",
    "energy" => "e_set",
    "gs" => "g", "bs" => "b",
    "ps" => "p_set", "qs" => "q_set", "energy_capacity" => "e_max", "energy_initial" => "e_init",
    "energy_final" => "e_fin", "charge_rating" => "p_chg_max", "discharge_rating" => "p_dch_max",
    "charge_efficiency" => "η_chg", "discharge_efficiency" => "η_dch",
    "max_cycles_per_period" => "k_cycl_max", "cost_throughput" => "c_thru", "cost_cycle" => "c_cycl",
    "rate_a" => "s_max", "loss_fixed" => "p_loss_fix", "loss_prop" => "p_loss_prop", "pdc" => "p_set",
    "angmin" => "v_angl_min", "angmax" => "v_angl_max",
    "g_sh" => "g_shnt", "b_sh" => "b_shnt", "length_km" => "l_km",
    "g_m" => "g_mgnt", "b_m" => "b_mgnt", "tm" => "t_magn", "ta" => "t_angl",
    "tm_min" => "t_magn_min", "tm_max" => "t_magn_max", "ta_min" => "t_angl_min", "ta_max" => "t_angl_max",
    "tm_step" => "t_magn_step", "ta_step" => "t_angl_step",
    "baseMVA" => "s_base_mva", "per_energy" => "c_ener", "per_peak" => "c_peak"]

"a variable key, old and new"
const NOM_KEYS = [
    "vr" => "v_real", "vi" => "v_imag", "va" => "v_angl",
    "cr" => "i_term_real", "ci" => "i_term_imag", "p" => "p_term",
    "csr" => "i_ser_real", "csi" => "i_ser_imag",
    "vpr" => "v_pnt_real", "vpi" => "v_pnt_imag", "vap" => "v_pnt_angl",
    "vsr" => "v_star_real", "vsi" => "v_star_imag", "vas" => "v_star_angl",
    "vtr" => "v_wind_real", "vti" => "v_wind_imag",
    "tr" => "t_real", "ti" => "t_imag", "tm" => "t_magn", "ta" => "t_angl", "zt" => "z_step",
    "ol" => "s_ovl", "olp" => "s_ovl_peak", "zsw" => "z_sw",
    "pdct" => "p_dcl_thru", "pdcup" => "p_dcl_up", "pdcdn" => "p_dcl_dn",
    "cru" => "i_unit_real", "ciu" => "i_unit_imag", "pu" => "p_unit",
    "pg" => "p_gen", "qg" => "q_gen", "pgup" => "p_gen_up", "pgdn" => "p_gen_dn",
    "psc" => "p_chg", "psd" => "p_dch", "es" => "e_stor", "qs" => "q_stor",
    "psup" => "p_stor_up", "psdn" => "p_stor_dn",
    "pdf" => "p_flex", "psl" => "p_slk"]

"a solution key, old and new"
const NOM_SOLUTION = [
    "vr" => "v_real", "vi" => "v_imag", "va" => "v_angl", "vm" => "v_magn",
    "cr" => "i_term_real", "ci" => "i_term_imag", "p" => "p_term", "q" => "q_term",
    "cru" => "i_unit_real", "ciu" => "i_unit_imag",
    "pg" => "p_gen", "qg" => "q_gen", "pgup" => "p_gen_up", "pgdn" => "p_gen_dn", "pg_market" => "p_gen_mkt",
    "psc" => "p_chg", "psd" => "p_dch", "es" => "e_stor", "psup" => "p_stor_up", "psdn" => "p_stor_dn",
    "ps_market" => "p_stor_mkt", "psl" => "p_slk",
    "pdc" => "p_dcl", "pdcup" => "p_dcl_up", "pdcdn" => "p_dcl_dn", "pdc_market" => "p_dcl_mkt",
    "pd" => "p_set", "qd" => "q_set", "gs" => "g", "bs" => "b",
    "overload" => "s_ovl", "loss" => "p_loss",
    "tr" => "t_real", "ti" => "t_imag", "tm" => "t_magn", "ta" => "t_angl",
    "tm_market" => "t_magn_mkt", "ta_market" => "t_angl_mkt", "step" => "z_step"]

"the class of a descriptor, in the order they may come in, or 0 where it is not in the vocabulary"
nom_class(d) = d in NOM_WHAT ? 1 : d in NOM_PART ? 2 : d in NOM_QUALIFIER ? 3 : 0

"whether `name` is a plain word or follows the grammar"
function nom_follows(name::AbstractString)
    name in NOM_WORDS && return true

    parts = String.(split(name, '_'))
    parts[1] in NOM_SYMBOLS || return false

    descriptors = parts[2:end]
    !isempty(descriptors) && last(descriptors) in NOM_UNIT && pop!(descriptors)
    length(descriptors) <= 2 || return false

    classes = nom_class.(descriptors)

    return all(>(0), classes) && all(classes[k] < classes[k + 1] for k in 1:length(classes) - 1)
end

"a key is shared by every owner, so it has a descriptor, unless it echoes a parameter (`bare`)"
nom_key_follows(name, bare = ()) =
    nom_follows(name) && (occursin('_', name) || name in NOM_WORDS || name in bare)

"the solution keys that are a parameter given back"
const NOM_ECHOED = ("g", "b")

"the paths of the files under `dir` of the package that end in one of `ext`"
function nom_files(dir::String, ext::String...)
    root  = joinpath(BASE_DIR, dir)
    isdir(root) || return String[]
    paths = String[]
    for (path, _, files) in walkdir(root)
        for f in files
            any(e -> endswith(f, e), ext) && push!(paths, joinpath(path, f))
        end
    end

    return sort!(paths)
end

"call `f` on `ex` and on every expression inside it"
function nom_walk(f, ex)
    f(ex)
    ex isa Expr && foreach(a -> nom_walk(f, a), ex.args)

    return nothing
end

"the keys the package creates and reads as literals: `variable!(nm, :key, ...)`, `variable_container!(nm, :a, :b)`, `var(nm, :key)`"
function nom_variable_keys()
    found = Set{String}()
    for path in nom_files("src", ".jl")
        nom_walk(Meta.parseall(read(path, String))) do ex
            ex isa Expr && ex.head === :call || return nothing
            ex.args[1] in (:variable!, :variables!, :variable_container!, :var) || return nothing

            args = [a for a in ex.args[2:end] if !(a isa Expr && a.head === :parameters)]
            for a in args[2:end]
                a isa QuoteNode || break
                push!(found, String(a.value))
                ex.args[1] === :variable_container! || break
            end
        end
    end

    return found
end

"the name a method definition is for, or `nothing` where it is not a plain function"
function nom_function_name(sig)
    sig isa Expr || return nothing
    sig.head === :where && return nom_function_name(sig.args[1])
    sig.head === :call && sig.args[1] isa Symbol && return sig.args[1]

    return nothing
end

"the keys the solution builders write: `entry[\"key\"] = ...` and `\"key\" => ...` inside a `solution_*` function"
function nom_solution_keys()
    found = Set{String}()
    for path in nom_files("src", ".jl")
        nom_walk(Meta.parseall(read(path, String))) do ex
            ex isa Expr && ex.head in (:function, :(=)) && length(ex.args) >= 2 || return nothing
            name = nom_function_name(ex.args[1])
            name === nothing && return nothing
            startswith(String(name), "solution_") || startswith(String(name), "_solution_") ||
                return nothing

            nom_walk(ex.args[2]) do inner
                inner isa Expr || return nothing
                if inner.head === :(=) && inner.args[1] isa Expr && inner.args[1].head === :ref &&
                   length(inner.args[1].args) == 2 && inner.args[1].args[2] isa String
                    push!(found, inner.args[1].args[2])
                elseif inner.head === :call && inner.args[1] === :(=>) && inner.args[2] isa String
                    push!(found, inner.args[2])
                end
            end
        end
    end

    return found
end

"where the old names of the map are still written: `(file, line, name)`"
function nom_stragglers()
    old = unique(first.(vcat(NOM_FIELDS, NOM_KEYS, NOM_SOLUTION)))
    old = sort!(filter(n -> length(n) > 1 && !(n in NOM_SHARED), old); by = length, rev = true)
    alt = join(old, "|")

    code = [Regex("(?<=[\\w\\)\\]])\\.($alt)(?![\\w!])"),
            Regex("(?<![\\w:]):($alt)(?![\\w!])"),
            Regex("\"($alt)\"")]
    docs = [code..., Regex("`($alt)`")]

    skip = (joinpath(BASE_DIR, "test", "nomenclature.jl"), joinpath(BASE_DIR, "CHANGELOG.md"),
            joinpath(BASE_DIR, "test", "powermodels.jl"))

    found = Tuple{String,Int,String}[]
    for (dir, exts) in (("src", (".jl",)), ("ext", (".jl",)), ("test", (".jl",)), ("scripts", (".jl",)),
                        ("benchmark", (".jl",)), ("docs/src", (".md",)))
        for path in nom_files(dir, exts...)
            path in skip && continue
            isjulia = endswith(path, ".jl")
            for (n, line) in enumerate(readlines(path))
                isjulia && (line = replace(line, r"(^|\s)#.*$" => ""))
                for rx in (isjulia ? code : docs), m in eachmatch(rx, line)
                    push!(found, (relpath(path, BASE_DIR), n, m.captures[1]))
                end
            end
        end
    end
    for path in (joinpath(BASE_DIR, "README.md"),)
        for (n, line) in enumerate(readlines(path)), rx in docs, m in eachmatch(rx, line)
            push!(found, (relpath(path, BASE_DIR), n, m.captures[1]))
        end
    end

    return found
end

"`true` where there is nothing to report, and the names that break the rule are logged where there is"
function nom_none(what, offenders)
    isempty(offenders) ||
        @info "$what: $(length(offenders)) that break the grammar" offenders = sort!(collect(offenders); by = string)

    return isempty(offenders)
end

@testset "nomenclature" begin

    @testset "the vocabulary is closed, short and has no word in two lists" begin
        lists = (NOM_WHAT, NOM_PART, NOM_QUALIFIER, NOM_UNIT, NOM_WORDS, NOM_KEPT)
        for (k, a) in enumerate(lists), b in lists[k + 1:end]
            @test isempty(intersect(a, b))
        end

        @test all(d -> 2 <= length(d) <= 4, union(NOM_WHAT, NOM_PART, NOM_QUALIFIER, NOM_UNIT))
        @test all(s -> length(s) == 1, NOM_SYMBOLS)
        @test all(isascii, union(NOM_WHAT, NOM_PART, NOM_QUALIFIER, NOM_UNIT, NOM_WORDS, NOM_KEPT))
        @test count(!isascii, join(NOM_SYMBOLS)) == 1
    end

    @testset "what the grammar allows and refuses" begin
        for name in ("v_magn_max", "v_real", "i_term_real", "p_gen_up", "p_chg_max", "η_chg", "l_km",
                     "v_base_kv", "s_base_mva", "t_magn_step", "z_step", "r", "x", "c", "status")
            @test nom_follows(name)
        end

        for name in ("vmax", "v_max_magn", "pg", "p_gen_up_max", "v_magn_max_kv_kv", "rate_a", "eta_chg",
                     "p_foo", "w_real", "v__real", "")
            @test !nom_follows(name)
        end

        # a field may be a bare symbol, a key may not
        @test nom_follows("p") && !nom_key_follows("p")
        @test nom_key_follows("p_term") && nom_key_follows("id") && nom_key_follows("g", NOM_ECHOED)
    end

    @testset "the map is made of new names that follow it, and of old ones that do not" begin
        for map in (NOM_FIELDS, NOM_KEYS, NOM_SOLUTION)
            @test allunique(first.(map))
            @test all(nom_follows, last.(map))
            @test isempty(intersect(first.(map), last.(map)))
        end
        @test all(nom_key_follows, last.(NOM_KEYS))
        @test all(k -> nom_key_follows(k, NOM_ECHOED), last.(NOM_SOLUTION))
    end

    @testset "every name there is is a word, follows the grammar, or is in the map" begin
        types = [T for T in values(component_types()) if parentmodule(T) === NetworkModelBuilder]
        push!(types, NetworkData, OverloadPrice)

        known(map) = name -> nom_follows(name) || name in first.(map)

        @test all(known(NOM_FIELDS), String(f) for T in types for f in fieldnames(T))
        @test all(known(NOM_KEYS), nom_variable_keys())
        @test all(k -> known(NOM_SOLUTION)(k) || k in NOM_KEPT, nom_solution_keys())
    end

    @testset "a field is a word or follows the grammar" begin
        types = [T for T in values(component_types()) if parentmodule(T) === NetworkModelBuilder]
        push!(types, NetworkData, OverloadPrice)

        @test length(types) >= 14
        @test nom_none("fields", Set((nameof(T), f) for T in types for f in fieldnames(T)
                                     if !nom_follows(String(f))))
    end

    @testset "a variable key follows the grammar" begin
        keys = nom_variable_keys()

        @test length(keys) >= 40
        @test nom_none("variable keys", filter(!nom_key_follows, keys))
    end

    @testset "a solution key follows the grammar" begin
        keys = nom_solution_keys()

        @test length(keys) >= 40
        @test nom_none("solution keys", filter(k -> !nom_key_follows(k, NOM_ECHOED) && !(k in NOM_KEPT), keys))
    end

    @testset "no old name is left where a reader would look" begin
        found = nom_stragglers()

        if !isempty(found)
            by_name   = Dict(n => count(f -> f[3] == n, found) for n in unique(last.(found)))
            by_folder = Dict(d => count(f -> startswith(f[1], d), found)
                             for d in ("src", "test", "docs", "scripts", "benchmark", "README", "ext"))
            @info "$(length(found)) old names are still written" by_folder by_name = sort!(collect(by_name); by = last, rev = true)
        end

        @test isempty(found)
    end
end
