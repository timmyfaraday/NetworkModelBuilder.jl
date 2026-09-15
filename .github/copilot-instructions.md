# NetworkModelBuilder.jl Copilot Instructions

## Project overview
NetworkModelBuilder.jl is a Julia package for building and solving JuMP optimization models for power-system load-flow, optimal-power-flow, and redispatch problems. Its core model combines an extended component graph with a single named network index, using multiple dispatch over problem and formulation types.

## Stack and tooling
- Julia `1.10` or newer; CI tests Julia `1.10` and the latest compatible `1.x` release.
- Dependencies are managed with Julia's built-in `Pkg` and declared in `Project.toml`.
- Core dependencies: `JuMP`, `MathOptInterface`, and `Printf`. `Arrow` is an optional extension; tests also use `Ipopt`.
- From the repository root, install dependencies with `julia --project -e 'using Pkg; Pkg.instantiate()'`.
- Run all tests with `julia --project -e 'using Pkg; Pkg.test()'`.
- Build documentation with `julia --project=docs -e 'using Pkg; Pkg.develop(PackageSpec(path = pwd())); Pkg.instantiate()'`, then `julia --project=docs docs/make.jl`.
- No dedicated formatter, linter, or static type-checker is configured. Preserve local formatting and do not claim an automated check that does not exist.

## Project layout
- `src/NetworkModelBuilder.jl` defines the module, include order, and public exports.
- `src/core/` owns dimensions, networks, models, solutions, objectives, rebuilding, redispatch, and rolling windows.
- `src/comp/` contains node, edge, and unit component definitions; each component file keeps its data type, variables, constraints, and registration together.
- `src/prob/` defines load-flow, optimal-power-flow, and redispatch builders; `src/io/` handles Matpower, Arrow tables, and Zorba input/output.
- `test/runtests.jl` includes focused `Test` suites; `docs/` is a separate Documenter environment.

## Code style
- Extend behavior through Julia multiple dispatch on concrete component, problem, and formulation types. Keep problem and formulation logic orthogonal rather than branching on type tags.
- Register new edge or unit types with the existing registries so generic model builders discover them; do not hardcode component lists in problem builders.
- Use `Base.@kwdef` structs with typed fields and constructor validation for component data. Use Julia `!` suffixes for mutating builders, registration, and constraint-writing functions.
- Retain explicit method signatures, type parameters, and keyword arguments such as `nw` where neighboring APIs use them. Throw contextual `ArgumentError`, `KeyError`, or other standard Julia exceptions at invalid boundaries.
- Write Julia docstrings for public types and functions: triple-quoted docstrings for substantial API documentation and concise string docstrings for simple queries. Keep explanatory comments focused on design intent.

## Testing
- Add or update focused assertions in the relevant `test/*.jl` file for behavior changes. Include a new test file from `test/runtests.jl`.
- Use nested `@testset`s, explicit `@test_throws` checks for invalid inputs, and `≈` for numerical assertions when appropriate.
- Run `julia --project -e 'using Pkg; Pkg.test()'` before handing off changes. For documentation changes, also run the documented Documenter build.
- CI records coverage with Codecov, but this repository does not declare a coverage threshold.

## Team conventions
- Explain non-obvious code, because coding levels on this team vary.
- Challenge questionable requests and propose simpler alternatives rather than complying by default.
- Match existing patterns before introducing new ones.