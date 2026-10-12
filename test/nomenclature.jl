################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.14.0 - initial implementation                                             #
# v0.15.0 - constraints, functions and duals follow a grammar                  #
# v0.15.0 - the duals follow the grammar of constraints                        #
# v0.15.1 - c_thru is retired for c_dch                                        #
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
    "max_cycles_per_period" => "k_cycl_max", "cost_throughput" => "c_dch", "c_thru" => "c_dch", "cost_cycle" => "c_cycl",
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

"a key of `ext` the package reads, old and new"
const NOM_EXT = ["vr_start" => "v_real_init", "vi_start" => "v_imag_init", "va_start" => "v_angl_init"]

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

"the keys of the `ext` of a component the package reads as literals: `get(x.ext, :key, default)`"
function nom_ext_keys()
    found = Set{String}()
    for path in nom_files("src", ".jl")
        nom_walk(Meta.parseall(read(path, String))) do ex
            ex isa Expr && ex.head === :call && ex.args[1] === :get && length(ex.args) >= 3 || return nothing
            from = ex.args[2]
            from isa Expr && from.head === :. && from.args[end] == QuoteNode(:ext) || return nothing
            ex.args[3] isa QuoteNode && push!(found, String(ex.args[3].value))
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

"a name a file spells on purpose, as a word or as the name of something that is not a quantity: `(file, name)`"
const NOM_EXEMPT = Set([("test/rd.jl", "overload"),                         # a word in the `show` of `Redispatch`
                        ("scripts/run_year_redispatch.jl", "overload"),     # the name of an output table
                        ("src/core/redispatch.jl", "overload"),             # the field of `Redispatch`, a word
                        ("docs/src/problems/redispatch/index.md", "overload"), # the same field, in its table
                        ("docs/src/manual/nomenclature.md", "loss"),         # a descriptor of the grammar
                        ("test/zorba.jl", "overload"),                      # the same field, read back
                        ("src/io/matpower.jl", "baseMVA"),                  # Matpower's own key and local
                        ("src/io/zorba.jl", "cost"),                       # the `cost` column of Zorba's hvdc table
                        ("scripts/SteeringPlanData.jl", "energy_capacity")])  # a column of the steering plan's CSV

"where the old names of the map are still written: `(file, line, name)`"
function nom_stragglers()
    longer(names) = sort!(filter(n -> length(n) > 1 && !(n in NOM_SHARED), unique(names)); by = length, rev = true)
    alt = join(longer(first.(vcat(NOM_FIELDS, NOM_KEYS, NOM_SOLUTION, NOM_EXT))), "|")
    sym = join(longer(first.(vcat(NOM_FIELDS, NOM_KEYS, NOM_EXT))), "|")   # a solution key is a string

    code = [Regex("(?<=[\\w\\)\\]])\\.($alt)(?![\\w!])"),
            Regex("(?<![\\w:\\]\\)]):($sym)(?![\\w!])"),
            Regex("\"($alt)\"")]
    docs = [code..., Regex("`($alt)`")]

    skip = (joinpath(BASE_DIR, "test", "nomenclature.jl"), joinpath(BASE_DIR, "CHANGELOG.md"),
            joinpath(BASE_DIR, "test", "powermodels.jl"))

    found = Tuple{String,Int,String}[]
    for (dir, exts) in (("src", (".jl",)), ("ext", (".jl",)), ("test", (".jl",)), ("scripts", (".jl",)),
                        ("benchmark", (".jl",)), ("docs/src", (".md",)))
        for path in nom_files(dir, exts...)
            path in skip && continue
            rel     = relpath(path, BASE_DIR)
            isjulia = endswith(path, ".jl")
            for (n, line) in enumerate(readlines(path))
                isjulia && (line = replace(line, r"(^|\s)#.*$" => ""))
                for rx in (isjulia ? code : docs), m in eachmatch(rx, line)
                    (replace(rel, '\\' => '/'), m.captures[1]) in NOM_EXEMPT && continue
                    push!(found, (rel, n, m.captures[1]))
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

# The names of constraints, of the functions that write them and of the duals
# they give follow a second grammar (`nomenclature.md`, "Constraints, functions
# and duals"): one stem, `<owner>_<role>`, and one prefix each, `cstr_`, `fnct_`
# and `dual_`. What follows is that grammar as data, the map from the old names,
# and the checks that read the package for them.

"who writes a row: a family or a type of component, or the problem"
const CST_OWNERS = Set(["node", "edge", "unit", "br", "tf", "dcl", "sw", "gen", "stor", "flex", "shnt", "rd"])

"what a row states: a role is one or two of these"
const CST_WORDS = Set(["balance", "reference", "setpoint", "anchor", "limit", "range", "rating", "overload",
                       "peak", "angle", "difference", "voltage", "current", "flow", "power", "injection",
                       "energy", "final", "cycle", "redispatch", "control", "equation", "open", "loop",
                       "winding", "ratio", "tap", "step", "setting", "star", "pi", "section", "point"])

"a part of the id of a row, after the id of its component"
const CST_IDS = Set(["real", "imag", "magn", "angl", "min", "max", "fr", "to", "ser", "set", "loss",
                     "forward", "reverse", "pos", "neg", "side", "p", "q"])

"a key `con` publishes that bundles the rows of several keys, so no row is registered under it"
const CST_BUNDLES = Set(["cstr_br_equation", "cstr_edge_limit", "cstr_sw_equation"])

"a function that walks the registry of a family and writes the rows of every type of it"
const CST_ENTRIES = Set(["edge", "unit", "edge_limit", "edge_coupling", "unit_coupling"])

"a key a row is registered under, old and new; two old keys may be one row in two formulations"
const CST_KEYS = [
    "node_balance" => "cstr_node_balance", "node_reference" => "cstr_node_voltage_reference",
    "node_setpoint" => "cstr_node_voltage_setpoint", "node_limits" => "cstr_node_voltage_limit",
    "node_anchor" => "cstr_node_voltage_anchor",
    "edge_rating" => "cstr_edge_rating", "linear_rating" => "cstr_edge_rating",
    "edge_overload" => "cstr_edge_overload", "linear_overload" => "cstr_edge_overload",
    "edge_angle" => "cstr_edge_angle_difference", "linear_angle" => "cstr_edge_angle_difference",
    "linear_flow" => "cstr_edge_flow", "overload_peak" => "cstr_edge_overload_peak",
    "pi_section" => "cstr_br_pi_section", "branch_section" => "cstr_br_section", "branch_point" => "cstr_br_point",
    "winding" => "cstr_tf_winding", "star_balance" => "cstr_tf_star_balance", "transformer_ratio" => "cstr_tf_ratio",
    "tap_step" => "cstr_tf_tap_step", "tap_setting" => "cstr_tf_tap_setting",
    "dc_link" => "cstr_dcl_power", "dc_link_limits" => "cstr_dcl_limit", "dc_link_redispatch" => "cstr_dcl_redispatch",
    "switch_flow" => "cstr_sw_flow", "switch_open" => "cstr_sw_open", "switch_angle" => "cstr_sw_angle",
    "switch_loop" => "cstr_sw_loop", "switch_angle_range" => "cstr_sw_angle_range",
    "switch_flow_range" => "cstr_sw_flow_range", "switch_cycle" => "cstr_sw_cycle", "switch_rating" => "cstr_sw_rating",
    "switch_voltage" => "cstr_sw_voltage", "switch_voltage_range" => "cstr_sw_voltage_range",
    "switch_current_range" => "cstr_sw_current_range",
    "unit_power" => "cstr_unit_power", "unit_injection" => "cstr_unit_injection",
    "generator_energy" => "cstr_gen_energy", "generator_redispatch" => "cstr_gen_redispatch",
    "flexible_energy" => "cstr_flex_energy", "shunt_current" => "cstr_shnt_current",
    "storage_balance" => "cstr_stor_balance", "storage_final" => "cstr_stor_final_energy",
    "storage_cycles" => "cstr_stor_cycle", "storage_redispatch" => "cstr_stor_redispatch",
    "redispatch_control" => "cstr_rd_control"]

"a key of `con`, old and new; the four unit keys hold `cstr_unit_injection` in the linearized formulation"
const CST_CON = [
    "branch" => "cstr_br_equation", "dc_link" => "cstr_dcl_power", "dc_link_limits" => "cstr_dcl_limit",
    "dc_link_redispatch" => "cstr_dcl_redispatch", "edge_angle_difference" => "cstr_edge_angle_difference",
    "edge_limits" => "cstr_edge_limit", "edge_rating" => "cstr_edge_rating",
    "generator_power" => "cstr_unit_power", "load_power" => "cstr_unit_power",
    "slack_power" => "cstr_unit_power", "storage_power" => "cstr_unit_power",
    "generator_redispatch" => "cstr_gen_redispatch",
    "node_balance" => "cstr_node_balance", "node_balance_real" => "cstr_node_balance",
    "node_balance_imag" => "cstr_node_balance",
    "node_voltage_anchor" => "cstr_node_voltage_anchor", "node_voltage_limits" => "cstr_node_voltage_limit",
    "node_voltage_reference" => "cstr_node_voltage_reference", "node_voltage_setpoint" => "cstr_node_voltage_setpoint",
    "shunt_current" => "cstr_shnt_current", "star_balance" => "cstr_tf_star_balance",
    "storage_redispatch" => "cstr_stor_redispatch",
    "switch" => "cstr_sw_equation", "switch_limits" => "cstr_sw_rating", "switch_loop_free" => "cstr_sw_cycle",
    "tap_setting" => "cstr_tf_tap_setting", "tap_step" => "cstr_tf_tap_step", "winding" => "cstr_tf_winding"]

"a function that writes rows, old and new"
const CST_FUNCTIONS = [
    "constraint_edge" => "fnct_edge", "constraint_edge_limits" => "fnct_edge_limit",
    "constraint_edge_coupling" => "fnct_edge_coupling", "constraint_edge_rating" => "fnct_edge_rating",
    "constraint_edge_angle_difference" => "fnct_edge_angle_difference",
    "constraint_linear_flow" => "fnct_edge_flow_linear", "constraint_linear_ratings" => "fnct_edge_rating_linear",
    "constraint_linear_angle_difference" => "fnct_edge_angle_difference_linear",
    "constraint_node_balance" => "fnct_node_balance", "constraint_node_voltage_reference" => "fnct_node_voltage_reference",
    "constraint_node_voltage_setpoint" => "fnct_node_voltage_setpoint", "constraint_node_voltage_limits" => "fnct_node_voltage_limit",
    "constraint_node_voltage_anchor" => "fnct_node_voltage_anchor",
    "constraint_pi_section" => "fnct_br_pi_section", "constraint_overload_peak" => "fnct_edge_overload_peak",
    "constraint_redispatch_control" => "fnct_rd_control",
    "constraint_storage_final_energy" => "fnct_stor_final_energy", "constraint_storage_cycles" => "fnct_stor_cycle",
    "constraint_unit" => "fnct_unit", "constraint_unit_coupling" => "fnct_unit_coupling",
    "constraint_unit_power" => "fnct_unit_power", "constraint_unit_injection" => "fnct_unit_injection"]

"a dual of a node, old and new"
const CST_DUALS = ["lambda" => "dual_node_balance_p", "lambda_q" => "dual_node_balance_q",
                   "lambda_real" => "dual_node_balance_real", "lambda_imag" => "dual_node_balance_imag"]

"a variable that is still a parameter or a local of a function that writes rows under an old letter, old and new"
const CST_LETTERS = ["ctr" => "i_wind_real", "cti" => "i_wind_imag", "vtr" => "v_wind_real", "vti" => "v_wind_imag",
                     "csr" => "i_ser_real", "csi" => "i_ser_imag", "cru" => "i_real", "ciu" => "i_imag"]

"whether a constraint key is `cstr_<owner>_<role>`, the role one or two words of the list"
function cst_key_follows(key::AbstractString)
    startswith(key, "cstr_") || return false

    parts = String.(split(key[6:end], '_'))
    length(parts) >= 2 && parts[1] in CST_OWNERS || return false
    role = parts[2:end]

    return length(role) <= 2 && all(in(CST_WORDS), role)
end

"the calls of `constrain!` with a literal key: `(key, the words of its id)`"
function cst_rows()
    found = Tuple{String,Vector{String}}[]
    for path in nom_files("src", ".jl")
        nom_walk(Meta.parseall(read(path, String))) do ex
            ex isa Expr && ex.head === :call && ex.args[1] === :constrain! || return nothing

            args = [a for a in ex.args[2:end] if !(a isa Expr && a.head === :parameters)]
            length(args) >= 3 && args[2] isa QuoteNode || return nothing

            id    = args[3]
            words = id isa Expr && id.head === :tuple ? [String(a.value) for a in id.args if a isa QuoteNode] : String[]
            push!(found, (String(args[2].value), words))
        end
    end

    return found
end

"the keys of `con` the package writes and reads as literals: `get!(f, con(nm; nw), :key)`, `get(con(nm; nw), :key, d)`"
function cst_con_keys()
    found = Set{String}()
    for path in nom_files("src", ".jl")
        nom_walk(Meta.parseall(read(path, String))) do ex
            ex isa Expr && ex.head === :call && ex.args[1] in (:get, :get!) || return nothing

            for k in 2:length(ex.args) - 1
                c = ex.args[k]
                c isa Expr && c.head === :call && c.args[1] === :con && ex.args[k + 1] isa QuoteNode &&
                    push!(found, String(ex.args[k + 1].value))
            end
        end
    end

    return found
end

"the names of the functions `src/` and `ext/` define, with a method or without (`function f end`)"
function cst_defined()
    found = Set{String}()
    for dir in ("src", "ext"), path in nom_files(dir, ".jl")
        nom_walk(Meta.parseall(read(path, String))) do ex
            ex isa Expr && ex.head in (:function, :(=)) && length(ex.args) >= 1 || return nothing

            name = ex.args[1] isa Symbol && ex.head === :function ? ex.args[1] : nom_function_name(ex.args[1])
            name === nothing || push!(found, rstrip(String(name), '!'))
        end
    end

    return found
end

"where an old key, function, dual or letter of the maps is still written: `(file, line, name)`"
function cst_stragglers()
    longer(names) = sort!(unique(names); by = length, rev = true)
    ambiguous = ("branch", "switch", "winding")     # plain words elsewhere; the checks of the keys find them
    keys  = join(longer(filter(!in(ambiguous), first.(vcat(CST_KEYS, CST_CON)))), "|")
    funcs = join(longer(first.(CST_FUNCTIONS)), "|")
    duals = join(longer(first.(CST_DUALS)), "|")
    named = join(longer(filter(n -> length(n) > 1, first.(NOM_KEYS))), "|")

    symbol = Regex("(?<![\\w:\\]\\)]):($keys)(?![\\w!])")          # `:node_limits`, not in a comment
    others = [Regex("\\b($funcs)\\b"),                              # `constraint_unit`
              Regex("[\"`]($duals)[\"`]"),                          # `"lambda_real"`
              Regex("\\b($(join(first.(CST_LETTERS), "|")))\\b"),   # `ctr`, `csr`
              Regex("\\b\\d_($named)\\["),                          # `1_pg[3]`
              r"\b(cr|cru|ciu)\["]                               # a container under its old key

    skip = (joinpath(BASE_DIR, "test", "nomenclature.jl"), joinpath(BASE_DIR, "CHANGELOG.md"),
            joinpath(BASE_DIR, "test", "powermodels.jl"))

    found = Tuple{String,Int,String}[]
    for (dir, exts) in (("src", (".jl",)), ("ext", (".jl",)), ("test", (".jl",)), ("scripts", (".jl",)),
                        ("benchmark", (".jl",)), ("docs/src", (".md",)))
        for path in nom_files(dir, exts...)
            path in skip && continue
            rel     = replace(relpath(path, BASE_DIR), '\\' => '/')
            isjulia = endswith(path, ".jl")
            for (n, line) in enumerate(readlines(path))
                code = isjulia ? replace(line, r"(^|\s)#.*$" => "") : line
                for m in eachmatch(symbol, code)
                    push!(found, (rel, n, m.captures[1]))
                end
                for rx in others, m in eachmatch(rx, line)
                    push!(found, (rel, n, m.captures[1]))
                end
            end
        end
    end
    for (n, line) in enumerate(readlines(joinpath(BASE_DIR, "README.md")))
        for rx in (symbol, others...), m in eachmatch(rx, line)
            push!(found, ("README.md", n, m.captures[1]))
        end
    end

    return found
end

@testset "nomenclature" begin

    @testset "the vocabulary is closed, short and has no word in two lists" begin
        lists = (NOM_WHAT, NOM_PART, NOM_QUALIFIER, NOM_UNIT, NOM_WORDS)
        for (k, a) in enumerate(lists), b in lists[k + 1:end]
            @test isempty(intersect(a, b))
        end

        @test all(d -> 2 <= length(d) <= 4, union(NOM_WHAT, NOM_PART, NOM_QUALIFIER, NOM_UNIT))
        @test all(s -> length(s) == 1, NOM_SYMBOLS)
        @test all(isascii, union(NOM_WHAT, NOM_PART, NOM_QUALIFIER, NOM_UNIT, NOM_WORDS))
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
        for map in (NOM_FIELDS, NOM_KEYS, NOM_SOLUTION, NOM_EXT)
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
        @test all(k -> known(NOM_SOLUTION)(k) || k in last.(CST_DUALS), nom_solution_keys())
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
        @test nom_none("solution keys", filter(k -> !nom_key_follows(k, NOM_ECHOED) && !(k in last.(CST_DUALS)), keys))
    end

    @testset "an ext key the package reads follows the grammar" begin
        keys = nom_ext_keys()

        @test length(keys) >= 3
        @test nom_none("ext keys", filter(!nom_key_follows, keys))
    end

    @testset "a node starts its voltage where its ext says, under the new keys only" begin
        start(nm, key, i) = JuMP.start_value(_NMB.var(nm, key; nw = 1)[i])

        data  = quiet(() -> parse_file(case("case5")))
        nd    = nodes(network(data))
        i     = first(sort!(collect(keys(nd))))
        extra = nd[i].ext

        nm = instantiate_model(data, LoadFlowProblem, IVRFormulation)
        @test start(nm, :v_real, i) == 1.0 && start(nm, :v_imag, i) == 0.0

        extra[:v_real_init], extra[:v_imag_init], extra[:v_angl_init] = 0.9, -0.1, 0.2
        nm = instantiate_model(data, LoadFlowProblem, IVRFormulation)
        @test start(nm, :v_real, i) == 0.9 && start(nm, :v_imag, i) == -0.1
        @test start(instantiate_model(data, LoadFlowProblem, LPFFormulation), :v_angl, i) == 0.2

        for (old, _) in NOM_EXT
            extra[Symbol(old)] = 5.0
        end
        nm = instantiate_model(data, LoadFlowProblem, IVRFormulation)
        @test start(nm, :v_real, i) == 0.9 && start(nm, :v_imag, i) == -0.1
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

@testset "constraint nomenclature" begin

    @testset "the vocabulary of constraints is closed and has no word in two lists" begin
        lists = (CST_OWNERS, CST_WORDS, CST_IDS)
        for (k, a) in enumerate(lists), b in lists[k + 1:end]
            @test isempty(intersect(a, b))
        end

        @test all(isascii, union(CST_OWNERS, CST_WORDS, CST_IDS))
        @test all(o -> 2 <= length(o) <= 4, CST_OWNERS)
    end

    @testset "what the grammar of a key allows and refuses" begin
        for key in ("cstr_node_balance", "cstr_node_voltage_limit", "cstr_stor_final_energy", "cstr_sw_flow_range")
            @test cst_key_follows(key)
        end

        for key in ("node_balance", "cstr_balance", "cstr_node", "cstr_foo_balance", "cstr_node_foo",
                    "cstr_node_voltage_limit_range", "cstr_node__balance", "fnct_node_balance", "")
            @test !cst_key_follows(key)
        end
    end

    @testset "the maps are made of new names that follow the grammar and old ones that do not" begin
        for map in (CST_KEYS, CST_CON, CST_FUNCTIONS, CST_DUALS, CST_LETTERS)
            @test allunique(first.(map))
            @test isempty(intersect(first.(map), last.(map)))
        end

        registered = Set(last.(CST_KEYS))
        @test all(cst_key_follows, last.(CST_KEYS))
        @test all(cst_key_follows, last.(CST_CON))
        @test all(k -> k in registered || k in CST_BUNDLES, last.(CST_CON))
        @test all(k -> cst_key_follows(k) && !(k in registered), CST_BUNDLES)
        @test all(nom_follows, last.(CST_LETTERS))
    end

    @testset "a function and a dual are named after the row they write and price" begin
        stems = Set(k[6:end] for k in union(Set(last.(CST_KEYS)), CST_BUNDLES))

        for new in last.(CST_FUNCTIONS)
            @test startswith(new, "fnct_")
            stem = replace(new[6:end], r"_linear$" => "")
            @test stem in stems || stem in CST_ENTRIES
        end

        for new in last.(CST_DUALS)
            @test startswith(new, "dual_")
            @test replace(new[6:end], r"_(p|q|real|imag)$" => "") in stems
        end
    end

    @testset "a key a row is registered under follows the grammar" begin
        rows = cst_rows()

        @test length(rows) >= 90
        @test length(unique(first.(rows))) >= 40
        @test nom_none("register keys", Set(key for (key, _) in rows if !cst_key_follows(key)))
    end

    @testset "a key of con follows it, and is a key of the register or a bundle" begin
        con        = cst_con_keys()
        registered = Set(first.(cst_rows()))

        @test length(con) >= 20
        @test nom_none("con keys", Set(k for k in con if !cst_key_follows(k)))
        @test nom_none("con keys that no row is registered under", Set(k for k in con if !(k in registered) && !(k in CST_BUNDLES)))
    end

    @testset "the id of a row is its component and words of the lists" begin
        words = Set(w for (_, ws) in cst_rows() for w in ws)

        @test !isempty(words)
        @test nom_none("id words", filter(w -> !(w in CST_IDS), words))
    end

    @testset "a function that writes rows is fnct_, and none is constraint_" begin
        defined = cst_defined()

        @test nom_none("functions still named constraint_*", Set(filter(startswith("constraint_"), defined)))
        @test Set(filter(startswith("fnct_"), defined)) == Set(last.(CST_FUNCTIONS))
        @test isempty(filter(n -> startswith(String(n), "constraint_"), names(NetworkModelBuilder)))
    end

    @testset "a dual is dual_ and the stem of the row it prices" begin
        solution = nom_solution_keys()

        @test nom_none("duals still named lambda*", Set(filter(startswith("lambda"), solution)))
        @test Set(filter(startswith("dual_"), solution)) == Set(last.(CST_DUALS))
    end

    @testset "no old key, function, dual or letter is left where a reader would look" begin
        found = cst_stragglers()

        if !isempty(found)
            by_name   = Dict(n => count(f -> f[3] == n, found) for n in unique(last.(found)))
            by_folder = Dict(d => count(f -> startswith(f[1], d), found)
                             for d in ("src", "test", "docs", "scripts", "benchmark", "README", "ext"))
            @info "$(length(found)) old constraint names are still written" by_folder by_name = sort!(collect(by_name); by = last, rev = true)
        end

        @test isempty(found)
    end
end
