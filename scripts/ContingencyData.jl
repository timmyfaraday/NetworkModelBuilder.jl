################################################################################
# ContingencyData.jl                                                          #
# Loads Elia's own N-1 study (LTSteering_Structuur_SMA_v3_EME.xlsx, sheet     #
# "N-1") into a list of contingency events, and resolves each event's raw     #
# asset-name strings against an already-`load_network`-ed `NetworkData`.      #
#                                                                              #
# The sheet stacks three mini-tables in one worksheet, each with its own      #
# header row: a "simple N-1" table (one asset per event), a "multiple         #
# sections" table (2-3 line sections that trip together), and a "BB outages"  #
# table (a busbar and the elements taken out when it trips). Header rows are  #
# *found*, not assumed at a fixed row number, since this is a manually        #
# maintained spreadsheet whose rows can shift between revisions.              #
################################################################################

module ContingencyData

using XLSX
using DataFrames
using NetworkModelBuilder

export RawContingencyEvent, ContingencyEvent, load_contingency_events,
       resolve_contingency_events

################################################################################
# Raw events, as the spreadsheet states them                                 #
################################################################################

"""
    RawContingencyEvent

One row (simple N-1) or group of rows (multi-section, busbar) of the N-1
sheet, before any of its asset names have been checked against a network.

# Fields
- `label`: a human-readable identifier — the asset name for a simple N-1, the
  busbar name for a BB outage, and the joined asset names for a multi-section
  line.
- `category`: `:simple`, `:multi_section` or `:busbar`.
- `names`: the raw asset-name strings the event lists, in sheet order.
- `xb_flag`: the sheet's own `XB?` column, `:simple` events only; `missing`
  for the other two categories, which carry no such flag.
"""
struct RawContingencyEvent
    label   ::String
    category::Symbol
    names   ::Vector{String}
    xb_flag ::Union{Missing,Bool}
end

################################################################################
# Resolved events                                                             #
################################################################################

"""
    ContingencyEvent

A [`RawContingencyEvent`](@ref) whose asset names resolved to network
identifiers: the edges and units that go out together when this event occurs.

`units` holds generator identifiers only — the one unit type this package
lets an outage act on the same way it does an edge, see
[`resolve_contingency_events`](@ref). An event kept here resolved *at least
one* of its names; see the `status` column of the report
[`resolve_contingency_events`](@ref) also returns for what, if anything,
did not.
"""
struct ContingencyEvent
    label   ::String
    category::Symbol
    edges   ::Vector{Int}
    units   ::Vector{Int}
    xb_flag ::Union{Missing,Bool}
end

################################################################################
# Reading the sheet                                                          #
################################################################################

"`nothing` for a blank cell (missing, empty, or the literal \"None\"), the cell's trimmed string otherwise"
function _clean(x)
    x isa Missing && return nothing
    s = strip(x isa AbstractString ? x : string(x))
    (isempty(s) || lowercase(s) == "none") && return nothing
    return String(s)
end

"the first row in `1:max_row` for which `pred(sh, row)` holds, or `nothing`"
function _find_row(sh, max_row::Int, pred)
    for r in 1:max_row
        pred(sh, r) && return r
    end
    return nothing
end

"""
    _load_simple(sh, header_row, max_row)

The `:simple` events below `header_row`: column B is the asset name, C the
`XB?` flag, E whether Elia's study considers it — only rows with `Consider ==
"Yes"` are kept, everything else in this mini-table is out of scope by the
sheet's own design.
"""
function _load_simple(sh, header_row::Int, max_row::Int)
    events = RawContingencyEvent[]
    r = header_row + 1
    while r <= max_row
        name = _clean(sh[r, 2])
        name === nothing && break

        consider = _clean(sh[r, 5])
        if consider !== nothing && lowercase(consider) == "yes"
            xb = _clean(sh[r, 3])
            xb_flag = xb === nothing ? missing :
                      lowercase(xb) == "yes" ? true :
                      lowercase(xb) == "no"  ? false : missing
            push!(events, RawContingencyEvent(name, :simple, [name], xb_flag))
        end
        r += 1
    end

    return events
end

"""
    _load_multi_section(sh, header_row, max_row)

The `:multi_section` events below `header_row`: columns B-D list the 2-3
asset names that trip together. This mini-table carries no `Consider` flag of
its own — every row is in scope — but column E is checked anyway and any row
whose value is not blank and not `"Yes"` is warned about, in case a future
revision of the sheet adds an exclusion here after all.
"""
function _load_multi_section(sh, header_row::Int, max_row::Int)
    events = RawContingencyEvent[]
    r = header_row + 1
    while r <= max_row
        a = _clean(sh[r, 2])
        a === nothing && break

        names = [a]
        for c in 3:4
            nm = _clean(sh[r, c])
            nm === nothing || push!(names, nm)
        end

        flag = _clean(sh[r, 5])
        (flag === nothing || lowercase(flag) == "yes") ||
            @warn "multi-section N-1 row $r has an unexpected column E value \"$flag\" — kept anyway, this mini-table has no documented exclusion flag" names

        push!(events, RawContingencyEvent(join(names, " + "), :multi_section, names, missing))
        r += 1
    end

    return events
end

"""
    _load_busbar(sh, header_row, max_row)

The `:busbar` events below `header_row`: column A is the busbar name, columns
B-F up to 5 connected elements taken out when it trips. All in scope, like
[`_load_multi_section`](@ref).
"""
function _load_busbar(sh, header_row::Int, max_row::Int)
    events = RawContingencyEvent[]
    r = header_row + 1
    while r <= max_row
        bus = _clean(sh[r, 1])
        bus === nothing && break

        names = String[]
        for c in 2:6
            nm = _clean(sh[r, c])
            nm === nothing || push!(names, nm)
        end

        push!(events, RawContingencyEvent(bus, :busbar, names, missing))
        r += 1
    end

    return events
end

"""
    load_contingency_events(path; sheet = "N-1") -> Vector{RawContingencyEvent}

Parse every in-scope event out of Elia's N-1 study workbook at `path`: the
`Consider == "Yes"` rows of its simple N-1 mini-table, and every row of its
multi-section and busbar-outage mini-tables.

Each mini-table's header row is located by content (`"XB?"` in column C for
the simple table, `"multiple section"` in column B for the next, `"bb
outages"` in column A for the last) rather than assumed at a fixed row
number: this is a manually maintained spreadsheet, and re-deriving the layout
on every load is what lets it shift between revisions without silently
mis-reading it.
"""
function load_contingency_events(path::AbstractString; sheet::AbstractString = "N-1")
    return XLSX.openxlsx(path; mode = "r") do xf
        sh      = xf[sheet]
        max_row = Int(XLSX.get_dimension(sh).stop.row_number)

        simple_header = _find_row(sh, max_row,
            (s, r) -> (v = _clean(s[r, 3])) !== nothing && lowercase(v) == "xb?")
        simple_header === nothing &&
            error("could not find the simple N-1 header row (looked for \"XB?\" in column C of sheet \"$sheet\")")

        multi_header = _find_row(sh, max_row,
            (s, r) -> (v = _clean(s[r, 2])) !== nothing && occursin("multiple section", lowercase(v)))
        multi_header === nothing &&
            error("could not find the multi-section N-1 header row (looked for \"multiple section\" in column B of sheet \"$sheet\")")

        bb_header = _find_row(sh, max_row,
            (s, r) -> (v = _clean(s[r, 1])) !== nothing && occursin("bb outages", lowercase(v)))
        bb_header === nothing &&
            error("could not find the busbar outage header row (looked for \"BB outages\" in column A of sheet \"$sheet\")")

        events = RawContingencyEvent[]
        append!(events, _load_simple(sh, simple_header, max_row))
        append!(events, _load_multi_section(sh, multi_header, max_row))
        append!(events, _load_busbar(sh, bb_header, max_row))

        return events
    end
end

################################################################################
# Resolving against a network                                                 #
################################################################################

"""
    resolve_contingency_events(data, raw) -> (events, report)

Resolve every [`RawContingencyEvent`](@ref) in `raw` against `network(data)`,
returning the [`ContingencyEvent`](@ref)s that resolved at least one asset
name, and a `DataFrame` reporting every event in `raw`, resolved or not.

Names are matched against edges (`Branch`, `PhaseShifter`, ...) by exact
`.name`, and against generators by case-insensitive `.name` — a
[`Generator`](@ref) is the one unit type this package lets an outage act on
the same way it does an edge (it carries the same `status` field, see
`with_contingencies` in `Contingencies.jl`), which is what a busbar
group's generator element needs. A name that matches neither is left
unresolved, which is expected for an asset this data slice has no table for
(e.g. the HVDC link `ALEGRO`) or a generator whose sheet name does not follow
this data's own naming convention.

An event is dropped — absent from `events`, `status = :dropped` in `report` —
only when *none* of its names resolved; an event with some names unresolved is
kept with `status = :partial` and its own edges/units, and a fully-resolved
event is `status = :ok`. Nothing here decides whether an event is a bridge/cut
set on its own — that is `contingency_events` in `Contingencies.jl`,
run after this on the events this function keeps.

A `:busbar` event's own label is checked against the node names too, but only
as a sanity note (`@warn`): the outage set a busbar event contributes is
always its listed *elements*, resolved exactly like any other event's, never
the busbar itself as a node deletion, since removing a node — rather than the
edges/units connected to it — is not what a busbar fault does to the rest of
the network.
"""
function resolve_contingency_events(data::NetworkData, raw::Vector{RawContingencyEvent})
    net = network(data)

    edge_by_name = Dict{String,Int}()
    for (e, c) in edges(net)
        if haskey(edge_by_name, c.name)
            @warn "edge name \"$(c.name)\" is used by more than one edge (ids $(edge_by_name[c.name]) and $e); keeping the first one seen for name resolution"
        else
            edge_by_name[c.name] = e
        end
    end

    node_by_name = Dict{String,Int}()
    for (i, c) in nodes(net)
        get!(node_by_name, lowercase(c.name), i)
    end

    generator_by_name = Dict{String,Int}()
    for (u, c) in units(net)
        c isa Generator || continue
        get!(generator_by_name, lowercase(c.name), u)
    end

    events = ContingencyEvent[]
    rows = NamedTuple{(:label, :category, :n_names, :n_edges, :n_units, :unresolved, :status),
                      Tuple{String,Symbol,Int,Int,Int,String,Symbol}}[]

    for ev in raw
        edge_ids   = Int[]
        unit_ids   = Int[]
        unresolved = String[]
        for nm in ev.names
            if haskey(edge_by_name, nm)
                push!(edge_ids, edge_by_name[nm])
            elseif haskey(generator_by_name, lowercase(nm))
                push!(unit_ids, generator_by_name[lowercase(nm)])
            else
                push!(unresolved, nm)
            end
        end

        status = isempty(edge_ids) && isempty(unit_ids) ? :dropped :
                 isempty(unresolved) ? :ok : :partial
        push!(rows, (label = ev.label, category = ev.category, n_names = length(ev.names),
                     n_edges = length(edge_ids), n_units = length(unit_ids),
                     unresolved = join(unresolved, "; "), status = status))

        status == :dropped && continue
        push!(events, ContingencyEvent(ev.label, ev.category, sort!(unique(edge_ids)),
                                       sort!(unique(unit_ids)), ev.xb_flag))
    end

    for ev in raw
        ev.category == :busbar || continue
        haskey(node_by_name, lowercase(ev.label)) ||
            @warn "busbar \"$(ev.label)\" does not match any node name in this network; its listed elements were resolved and used regardless, only the busbar's own name as a sanity check failed"
    end

    return events, DataFrame(rows)
end

end # module
