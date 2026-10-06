---
name: NMB domain invariants
description: Invariants of NetworkModelBuilder's dispatch model (problem × formulation, extended graph, dimensions). Use when changing src/core/, src/comp/ or src/prob/, or when reasoning about a NetworkModel's structure.
applyTo: "src/core/**,src/comp/**,src/prob/**"
---
# Domain invariants

These hold today and are relied on across the package. Changing one needs a decision
(`record-decision`).

- **Problem type and formulation type are orthogonal axes** that meet on `NetworkModel{P,F}`;
  every variable, constraint and objective is a method dispatched on that pair. Both hierarchies
  (`AbstractProblemType`, `AbstractFormulationType`) are abstract-only dispatch tags, never
  instantiated; an extension specialises by subtyping a leaf.
- **The extended graph is `(I, E, U)`**: nodes, edges, units. An edge connects an *ordered list*
  of nodes — not always two, so a three-winding transformer or a multi-terminal HVDC link is an
  ordinary edge; a unit connects to exactly one node. Edge variables are indexed by
  `Arc(edge, terminal, node)` because terminals are not interchangeable.
- **There is one extended graph, not one per network index.** A field the index varies over is a
  `NetworkVector` (`nw_vector(dim, :time, profile)`); a field that doesn't is a plain value. Both
  read through one getter — don't store per-index data any other way.
- **`Dimension` gives the bijection between a coordinate tuple and the scalar index `n`.** Coupling
  constraints use its arithmetic (`similar_id`, `prev_ids`, `next_ids`), not hand-rolled index math.
- **`Topology` is derived from the statuses that vary, never tabulated** — a contingency is nothing
  more than a `status` that varies per index.
- **A type earns its place by changing the model, not by carrying a label.** `Cable` and
  `OverheadLine` are electrically identical to `Branch`; don't add a type that changes no variable
  or constraint relative to its parent.
- **One file per component** holds its struct, its variables and its constraints together — no
  `src/form/` directory; a formulation is methods spread over component files, not a place.
- **Within `src/comp/`, the file named like its own directory loads first** — `branch/branch.jl`
  before `cable.jl`/`overhead_line.jl` — because
  `NetworkModelBuilder.jl` includes `src/comp/` by walking the directory tree, not by naming each
  file. A sibling needing a different order needs its own explicit `include`.
- **Registration is the only way a type participates**: `register_edge_type!` /
  `register_unit_type!` / `register_model!`, each guarded by its own `ReentrantLock`. Read
  functions (`edge_types()`, `unit_types()`) return a `copy()` and stay lock-free.
