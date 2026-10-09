# Topology lookups: answer a repeat from the last answer (B21)

Status: draft, decided (D45), not started · Author: Tom Van Acker (requested) · Date: 2026-10-09
Decisions: D45 recorded 2026-10-09 (next free after: D46); one entry, two if the stop rule fires
Priority: P2 · Effort: Small. Branch `b21-topology-lookup`, cut from `main` at `6d6f6f1` (v0.12.4);
becomes v0.12.5. First move of B20; the review it comes from is `julia-guide-review.md`, item 1.

## Handoff instructions

- Implement on `b21-topology-lookup`, the commits in "Commit order", no AI attribution.
- Per-file changelog header (80-column box) of every file touched, `version = "0.12.5"` in `Project.toml`,
  a `## [0.12.5]` section in `CHANGELOG.md`.
- Targeted tests per commit; the full suite once at the end with `$env:JULIA_NUM_THREADS = '4'`, and
  `julia --project=docs docs/make.jl`.
- Everything needed is quoted here; the study script is `scratch/b21_topology_study.jl` (local, gitignored).

## Evidence

- `topology(net; nw)` (`src/core/network.jl:547-551`) derives the answer on every call: a `BitVector`
  of the switchable statuses (`_signature`, `:305`), then `get!` with a closure on `net.topology`:
  ```julia
  net.fixed === nothing || return net.fixed
  return get!(() -> _topology_at(net.dim, net.node, net.edge, net.unit, nw),
              net.topology, _signature(net, nw))
  ```
  On case14 with an outage per branch (18 indices, 17 switchable statuses) one call is **432 B and
  ~0.7 µs**; it grows with the number of outages. `Base.return_types` is `Union{Nothing,Topology}`: the
  second read of `net.fixed` is not narrowed by the first.
- It is asked for by `arcs`, `node_arcs`, `node_units`, `edge_arcs` (`:561-570`), `ids` (`:586`),
  `islands` (`:623`), `check_islands` (`island.jl:98`), `monitored_edges` (`redispatch.jl:203`), `is_held`
  (`:274`), `same_topology` (`window.jl:235`). `edge_arcs(nm, e; nw)` has 30 call sites in 6 files under
  `src/comp/edge/`, each reached once per edge; the documented extension pattern does the same per
  node (`docs/src/manual/extended_graph.md:50`). `ids(nm, T; nw)` alone has over 100.
- Calls per `update_model!` (the path a roll runs), the same sequence replayed against a cache of the
  last `k` indices (`b21_topology_study.jl`, part 1):

  | problem, case14, 18 indices | calls | per index | hit rate k=1 | k=2 | k=4 |
  |:---|---:|---:|---:|---:|---:|
  | load flow LPF | 1,442 | 80.1 | 0.988 | 0.988 | 0.988 |
  | OPF LPF | 2,219 | 123.3 | 0.984 | 0.984 | 0.984 |
  | redispatch LPF | 2,561 | 142.3 | 0.913 | 0.967 | 0.980 |
  | redispatch IVR | 2,541 | 141.2 | 0.912 | 0.967 | 0.980 |

  Redispatch alternates between the index being built and the base case (`is_held` asks for the
  topology of `first_id(nm, nw, :contingency)`), which is why one entry misses 9 %.
- On the Zorba pipeline (`scratch/b6_roll_profile_flat.txt`, 8 windows, 29.6 s wall): `topology` 13 %
  of the wall, `_signature` 11 %, 9 % arriving through `edge_arcs`; `update_model!` is 26 %.
- Prototype, `update_model!` of redispatch LPF, best of 5 x 100, three variants in one process (each
  redefinition its own top-level statement, else the old method stays in force):
  shipped 6.6-7.1 ms; `fixed` bound once 6.7 ms (the type, not the time); one-entry memo **4.8-5.3 ms
  (-25 to -27 %)**; two entries 4.8 ms. A hit is 3.5 ns against ~700 ns, 0 B against 432 B.

## Root cause

A lookup is a pure function of `(net, nw)`: the statuses are captured when the `Network` is built, and
nothing mutates them. Yet it is recomputed for every node, edge and unit of every network index, because
the callers are loops over components at one index and each call is independent.

## Fix

Two changes in `src/core/network.jl`, nothing at a call site.

1. **A concrete return type.** `fixed = net.fixed; fixed === nothing || return fixed`.
2. **A memo of the last answer, on the `Network`.** One slot, written as one pair, atomic so that a
   reader never sees a half-written answer:
   ```julia
   mutable struct LastTopology
       @atomic seen::Union{Nothing,Pair{Int,Topology}}
   end
   # Network gets `last::LastTopology`, built as `LastTopology(nothing)` at `:282-284`

   function topology(net::Network; nw::Int = nw_id_default(net))
       fixed = net.fixed
       fixed === nothing || return fixed

       memo = net.last
       seen = @atomic memo.seen
       seen !== nothing && seen.first == nw && return seen.second

       top = get!(() -> _topology_at(net.dim, net.node, net.edge, net.unit, nw),
                  net.topology, _signature(net, nw))
       @atomic memo.seen = nw => top

       return top
   end
   ```
   Checked in a throwaway script: infers `Topo`, a hit 0.6 ns, a miss 19 ns, 4 threads x 1M lookups of two
   alternating indices, 0 wrong answers. `Network` is built positionally only at `:282`; every other
   constructor call in `src/`, `test/`, `scripts/`, `docs/` goes through `Network(I, E, U; dim)`.
3. **Docs.** The `Network` docstring (`:219`, "Nothing here is stored per network index") gains the
   `last` field and says it is one entry however many indices; `extended_graph.md:68-70` gains one
   sentence: the last answer is remembered, so a loop at one index derives it once.

Why not hoist the lookup at the call sites: over 130 sites in 16 files, each file needing a changelog
line, and the next component written from the docs repeats the pattern. Why not a slot per index: it
tabulates by index and changes the invariant; one entry does not (`domain-invariants`: "derived from the
statuses that vary, never tabulated" holds, and so does "nothing is stored per network index").

## Decisions

- **D45, recorded 2026-10-09 (Tom Van Acker):** a repeated topology lookup is answered from the last
  answer, held in one atomic slot on the `Network`; it is a cache of a derivation, one entry however many
  network indices, not a table.
- **Entries: one, part of D45.** The toy shows no gain from two (4.86 against 4.76 ms) and one is the
  smaller change. **Revise to two if the stop rule below fires**: after B21, `topology` is still above
  3 % of the pipeline profile (redispatch hit rate 0.913 to 0.967 on case14). The revision adds a second
  slot to `LastTopology` and edits D45 in place.

## Verification

- `@test @inferred(topology(net; nw = 1)) isa Topology` on a network with varying statuses and one
  without (`test/multinetwork.jl`, beside `"a network dependent status is a contingency"`). Red on
  `main`: `Union{Nothing,Topology}`.
- Allocation, deterministic: in a function, after one call, `@allocated topology(net; nw = n)` is `0`;
  `main` gives 432 B. Red/green.
- Sequence: for `n in (1, 1, 2, 3, 2, 2, 1, 3)`, `topology(net; nw = n) === tops[n]`, `tops` taken before.
  Red when the memo ignores `nw` (replace `seen.first == nw` by `true`).
- Threads (`test/thread_safety.jl`): fill `tops` serially, then `Threads.@threads` lookups in mixed order,
  each `=== tops[n]`. **Keep it only if the three-field `Slot` of the study script fails it** in a few runs;
  a test that cannot fail does not earn its place.
- Full suite and the docs build green. Results are unchanged by construction: the same `Topology` objects.
- Time on the toy: `update_model!` on `main` against the branch (git worktree for `main`), expect
  6.6-7.1 ms to at most 5.3 ms.
- Pipeline, week 1, 7 processes, beside a same-day control of `main` (`environment.md`): objectives
  bit-identical; chunk time **-8 to -13 %** (13 % is `topology`'s share, the ceiling); flat profile with
  `scratch/b6_roll_profile.jl`: `topology` under 3 % of the samples.

## Commit order

1. `topology` returns a concrete type, with the `@inferred` test (the one-line change, red then green).
2. The memo, `Network.last`, the allocation, sequence and (if it earns it) thread tests, docstring and docs.
3. `Project.toml` 0.12.5, `CHANGELOG.md`, changelog headers; then, after the pipeline run, STATE and B21.

## Stop rule, and what follows

If `topology` is still above 3 % of the profile: in order, two entries (the redispatch rate goes 0.913 to
0.967; this revises D45, see "Decisions"); B20's packed status matrix; a slot per
index, which needs its own decision. At or below 3 %, B21 is done and B22 (`build_solution`, 19 %) is next.

## What this deliberately does not decide

- `same_topology` (`window.jl:235`) asks for two indices in turn, so it misses a one-entry memo every
  time (689 ns against 691, no loss); 1.2 % of the samples, left alone.
- `net.topology` is a `Dict` filled by `get!`; two threads asking for a not yet derived topology on one
  shared `Network` can still race there. Unchanged by this, and a roll builds a `Network` per window.
- B22, B20's rest, Q7-Q9: see `julia-guide-review.md`.
