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
# Matpower input                                                               #
################################################################################

"""
    parse_matpower(path)

Parse a Matpower case file into a [`NetworkData`](@ref).

The `bus`, `gen`, `branch` and `gencost` tables are read; every other table is
kept, unconverted, in the `ext` dictionary of the data set under
`:matpower`, and cell arrays are skipped.

The mapping onto the extended graph is:

| Matpower                       | extended graph                              |
|:-------------------------------|:--------------------------------------------|
| a row of `bus`                 | a [`Node`](@ref)                            |
| a row of `branch` without a ratio | a [`Branch`](@ref)                        |
| a row of `branch` with a ratio | a [`Transformer`](@ref)                     |
| a row of `gen`                 | a [`Generator`](@ref)                       |
| `Pd`, `Qd` of a row of `bus`   | a [`FixedLoad`](@ref), when either is non-zero |
| `Gs`, `Bs` of a row of `bus`   | a [`Shunt`](@ref), when either is non-zero  |

Node identifiers are the Matpower bus numbers and need not be contiguous. Edge
identifiers are the row numbers of `branch`. Unit identifiers are assigned in one
sequence over the generators, then the loads, then the shunts, since a unit
identifier is unique across the whole set `U` and not within a kind. Every
component records where it came from in `ext[:source_id]`.

All quantities are converted to per unit on `baseMVA` and all angles to radians.
Bus types are corrected against the generators actually in service, with a
warning where the file and the generators disagree.
"""
function parse_matpower(path::AbstractString)
    mp = _read_matpower(path)

    return _matpower_network(mp)
end

################################################################################
# Reading the file                                                             #
################################################################################

function _read_matpower(path::AbstractString)
    isfile(path) || throw(ArgumentError("`$path` is not a file"))
    txt = read(path, String)

    # a comment runs from an unquoted `%` to the end of its line
    txt = join((first(split(line, '%')) for line in split(txt, '\n')), '\n')

    data = Dict{String,Any}()

    m = match(r"function\s+\w+\s*=\s*(\w+)", txt)
    data["name"] = m === nothing ? splitext(basename(path))[1] : String(m.captures[1])

    m = match(r"mpc\.baseMVA\s*=\s*([0-9.eE+-]+)", txt)
    data["baseMVA"] = m === nothing ? 100.0 : parse(Float64, m.captures[1])
    data["baseMVA"] > 0 || throw(ArgumentError("`$path` has a non-positive baseMVA"))

    # cell arrays carry names and labels only, drop them before reading matrices
    txt = replace(txt, r"mpc\.[A-Za-z_]\w*\s*=\s*\{.*?\}"s => "")

    for m in eachmatch(r"mpc\.([A-Za-z_]\w*)\s*=\s*\[(.*?)\]"s, txt)
        key = String(m.captures[1])
        key == "baseMVA" && continue
        data[key] = _parse_matpower_matrix(key, m.captures[2])
    end

    for key in ("bus", "gen")
        haskey(data, key) || throw(ArgumentError("`$path` has no `mpc.$key` table"))
    end

    return data
end

function _parse_matpower_matrix(key::AbstractString, body::AbstractString)
    rows = [strip(r) for r in split(body, ';')]
    filter!(!isempty, rows)
    isempty(rows) && return zeros(Float64, 0, 0)

    cells = [split(r, r"[\s,]+"; keepempty = false) for r in rows]
    ncol  = length(first(cells))
    all(length(c) == ncol for c in cells) ||
        throw(ArgumentError("`mpc.$key` has rows of unequal length, between $(minimum(length, cells)) and $(maximum(length, cells)) columns"))

    M = Matrix{Float64}(undef, length(cells), ncol)
    for (k, row) in enumerate(cells), (l, cell) in enumerate(row)
        v = tryparse(Float64, cell)
        v === nothing &&
            throw(ArgumentError("`mpc.$key` has a non-numeric entry `$cell` on row $k"))
        M[k, l] = v
    end

    return M
end

################################################################################
# Building the extended graph                                                  #
################################################################################

function _matpower_network(mp::Dict{String,Any})
    baseMVA = mp["baseMVA"]
    bus     = mp["bus"]
    gen     = mp["gen"]
    branch  = get(mp, "branch", zeros(Float64, 0, 13))

    I = _matpower_nodes(bus, gen)
    E = _matpower_edges(branch, baseMVA)
    U = Dict{Int,AbstractUnit}()

    u = 0
    u = _matpower_generators!(U, u, gen, get(mp, "gencost", nothing), baseMVA)
    u = _matpower_loads!(U, u, bus, baseMVA)
    u = _matpower_shunts!(U, u, bus, baseMVA)

    _correct_reference_node!(I, mp["name"])

    net = Network(I, E, U)
    ext = Dict{Symbol,Any}(:matpower => mp)

    return NetworkData(net; name = mp["name"], baseMVA, ext)
end

function _matpower_nodes(bus::Matrix{Float64}, gen::Matrix{Float64})
    gen_nodes = Set(Int(gen[k, 1]) for k in axes(gen, 1) if gen[k, 8] > 0)

    I = Dict{Int,AbstractNode}()
    for k in axes(bus, 1)
        i    = Int(bus[k, 1])
        code = Int(bus[k, 2])
        driven = i in gen_nodes

        if code == 4
            type, status = ISOLATED, false
        elseif code == 3
            type, status = REF, true
        else
            type, status = driven ? PV : PQ, true
            if code == 2 && !driven
                @warn "bus $i is declared PV but has no in-service generator, treating it as PQ"
            elseif code == 1 && driven
                @warn "bus $i is declared PQ but has an in-service generator, treating it as PV"
            elseif code != 1 && code != 2
                @warn "bus $i has the unknown bus type $code, treating it as $type"
            end
        end

        I[i] = Node(; id = i, name = "bus $i", type, status,
                    vm = bus[k, 8], va = deg2rad(bus[k, 9]),
                    base_kv = bus[k, 10],
                    vmax = size(bus, 2) >= 12 ? bus[k, 12] : 1.1,
                    vmin = size(bus, 2) >= 13 ? bus[k, 13] : 0.9,
                    area = Int(bus[k, 7]), zone = size(bus, 2) >= 11 ? Int(bus[k, 11]) : 1,
                    ext = Dict{Symbol,Any}(:source_id => i))
    end

    return I
end

"""
Designate a reference node when the file declares none, mirroring what Matpower
and PowerModels do: the node with the lowest identifier that carries an
in-service generator becomes the reference.
"""
function _correct_reference_node!(I::Dict{Int,AbstractNode}, name::AbstractString)
    any(nd -> nd.type == REF, values(I)) && return nothing

    candidates = sort!([i for (i, nd) in I if nd.type == PV])
    isempty(candidates) &&
        throw(ArgumentError("`$name` has no reference bus and no bus with an in-service generator to promote to one"))

    i  = first(candidates)
    nd = I[i]::Node
    @warn "`$name` declares no reference bus, promoting bus $i to reference"
    I[i] = Node(; id = nd.id, name = nd.name, type = REF, vm = nd.vm, va = nd.va,
                vmin = nd.vmin, vmax = nd.vmax, base_kv = nd.base_kv,
                area = nd.area, zone = nd.zone, status = nd.status, ext = nd.ext)

    return nothing
end

function _matpower_edges(branch::Matrix{Float64}, baseMVA::Float64)
    E = Dict{Int,AbstractEdge}()
    for e in axes(branch, 1)
        f, t   = Int(branch[e, 1]), Int(branch[e, 2])
        b      = branch[e, 5]
        rate   = branch[e, 6]
        ratio  = branch[e, 9]
        angle  = branch[e, 10]
        common = (id = e, terminals = [f, t],
                  r = branch[e, 3], x = branch[e, 4], b_fr = b / 2, b_to = b / 2,
                  rate_a = rate <= 0 ? Inf : rate / baseMVA,
                  angmin = size(branch, 2) >= 12 ? deg2rad(branch[e, 12]) : -pi / 2,
                  angmax = size(branch, 2) >= 13 ? deg2rad(branch[e, 13]) :  pi / 2,
                  status = branch[e, 11] > 0,
                  ext = Dict{Symbol,Any}(:source_id => (f, t, e)))

        # Matpower writes a branch and a transformer into the same table; a turns
        # ratio, or the lack of one, is what tells them apart. A ratio of zero
        # means the row is not a transformer at all.
        E[e] = if (ratio != 0 && ratio != 1) || angle != 0
            Transformer(; common..., name = "transformer $e",
                        tm = ratio == 0 ? 1.0 : ratio, ta = deg2rad(angle))
        else
            Branch(; common..., name = "branch $e")
        end
    end

    return E
end

function _matpower_generators!(U::Dict{Int,AbstractUnit}, u::Int, gen::Matrix{Float64},
                               gencost, baseMVA::Float64)
    for k in axes(gen, 1)
        u += 1
        U[u] = Generator(; id = u, name = "generator $k", node = Int(gen[k, 1]),
                         pg = gen[k, 2] / baseMVA, qg = gen[k, 3] / baseMVA,
                         qmax = gen[k, 4] / baseMVA, qmin = gen[k, 5] / baseMVA,
                         vg = gen[k, 6], status = gen[k, 8] > 0,
                         pmax = gen[k, 9] / baseMVA, pmin = gen[k, 10] / baseMVA,
                         cost = _matpower_cost(gencost, k, baseMVA),
                         ext = Dict{Symbol,Any}(:source_id => k))
    end

    return u
end

"the generation cost polynomial of generator `k`, in ascending order and in per unit"
function _matpower_cost(gencost, k::Int, baseMVA::Float64)
    gencost === nothing && return [0.0]
    k <= size(gencost, 1) || return [0.0]

    model, ncost = Int(gencost[k, 1]), Int(gencost[k, 4])
    if model != 2
        @warn "generator $k uses cost model $model, which is not supported; its cost is taken as zero"
        return [0.0]
    end
    4 + ncost <= size(gencost, 2) ||
        throw(ArgumentError("row $k of `mpc.gencost` announces $ncost coefficients but has room for $(size(gencost, 2) - 4)"))

    # Matpower writes the coefficients in descending order for a cost expressed
    # in MW; store them in ascending order for a cost expressed in per unit
    descending = gencost[k, 5:(4 + ncost)]

    return [c * baseMVA^(j - 1) for (j, c) in enumerate(reverse(descending))]
end

function _matpower_loads!(U::Dict{Int,AbstractUnit}, u::Int, bus::Matrix{Float64}, baseMVA::Float64)
    for k in axes(bus, 1)
        pd, qd = bus[k, 3] / baseMVA, bus[k, 4] / baseMVA
        (pd == 0.0 && qd == 0.0) && continue
        u += 1
        i = Int(bus[k, 1])
        U[u] = FixedLoad(; id = u, name = "load at bus $i", node = i, pd, qd,
                    ext = Dict{Symbol,Any}(:source_id => i))
    end

    return u
end

function _matpower_shunts!(U::Dict{Int,AbstractUnit}, u::Int, bus::Matrix{Float64}, baseMVA::Float64)
    for k in axes(bus, 1)
        gs, bs = bus[k, 5] / baseMVA, bus[k, 6] / baseMVA
        (gs == 0.0 && bs == 0.0) && continue
        u += 1
        i = Int(bus[k, 1])
        U[u] = Shunt(; id = u, name = "shunt at bus $i", node = i, gs, bs,
                     ext = Dict{Symbol,Any}(:source_id => i))
    end

    return u
end
