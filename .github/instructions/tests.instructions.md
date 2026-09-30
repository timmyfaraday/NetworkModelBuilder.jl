---
name: NMB tests
description: What earns a test in NMB and how to run tests. Use when writing, changing or running tests.
applyTo: "test/**"
---
# Tests

- A test earns its place if it exercises a path the real data/API surface does not, or reproduces
  a defect that actually happened. Otherwise it belongs in a doc example, or not at all.
- `test/runtests.jl` defines `case(name)` (path to a bundled Matpower fixture) and `quiet(f)` (runs
  with `NullLogger`, for expected bus-type-correction warnings) — both available unprefixed in
  every included test file.
- A defect fix lands test first: the test fails before the fix and passes after. For a concurrency
  fix, prove it against a real crash first (a standalone throwaway script with the fix reverted),
  not just by reading the code.
- Never monkeypatch a package function to reach a branch; extend through `register_edge_type!` /
  `register_unit_type!` / `register_model!` or a documented constructor keyword.
- Full suite: `julia --project=. -e "using Pkg; Pkg.test()"`, offline once `Manifest.toml` is
  resolved (~2-3 minutes, ~2400 tests). `Threads.@threads` tests (`test/thread_safety.jl`) only
  exercise real concurrency if the process itself starts with `JULIA_NUM_THREADS` > 1 (CI sets
  `4`; set it locally too before `Pkg.test()` when touching a registry lock).
- A complete documentation example (anything with `using NetworkModelBuilder`) must be wrapped in
  a Documenter `@example <name>` block so `test/docs.jl`'s sweep actually executes it too.
