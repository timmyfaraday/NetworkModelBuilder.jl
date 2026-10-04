---
name: NMB Julia code
description: Coding rules for the NetworkModelBuilder package. Use when writing or changing Julia under src/ or test/.
applyTo: "src/**/*.jl,test/**/*.jl"
---
# NMB Julia code

- Every `src/` and `test/` file starts with the 80-column box header (name, one-line description,
  URL, Authors, Changelog). Add a new `# vX.Y.Z - <what changed>` line to files you modify; don't
  rewrite existing lines. Every content line is exactly 80 characters — compute the padding,
  don't hand-count it.
- Version bumps are the patch digit (`version = "0.10.x"` in `Project.toml`), one per
  gap/item closed, or the minor digit for an item that adds a component type. Don't tag a git
  release per bump, and don't push, unless asked.
- `BASE_DIR = dirname(@__DIR__)` (exported from `NetworkModelBuilder.jl`) resolves the package
  root at runtime — use it instead of `pkgdir(NetworkModelBuilder)` for anything needing bundled
  fixtures (e.g. `test/data/matpower/*.m`) from a doc example.
- A registry (`_EDGE_TYPES`, `_UNIT_TYPES`, `_MODELS`) is a plain `Vector`; any new check-then-push
  against one goes under its own `ReentrantLock` — see `edge.jl`/`unit.jl`/`model.jl`.
- `using X` in a shared file (`test/runtests.jl`) pollutes every other test file's namespace. A
  test-only dependency whose exports might collide with NMB's own (a general-purpose package, not
  a solver) is `import`ed and called qualified (`PowerModels.parse_file`), never `using`d.
- Docstrings: what the function does, its inputs/outputs, why when non-obvious. No decision ids or
  phase names in comments.
- Before editing a module, check `.github/context/decisions.md` for the section that governs it.
