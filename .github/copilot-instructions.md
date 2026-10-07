# NetworkModelBuilder.jl: agent instructions

NetworkModelBuilder.jl (NMB) builds optimization models for power system problems: load flow,
optimal power flow, redispatch, rolling horizon. Two orthogonal dispatch axes — problem type
(`AbstractProblemType`) and formulation type (`AbstractFormulationType`) — meet on
`NetworkModel{P,F}`; every variable, constraint and objective is a method on that pair. Julia
≥1.10, JuMP + MathOptInterface, GitHub (public package, solo maintainer).

## Project memory lives in `.github/context/`

The repo carries its own memory. Use it instead of re-deriving things from the code or asking.

- `context/STATE.md`: where the work stands. Injected at session start by a hook; if you don't see
  it in context, read it first.
- `context/INDEX.md`: one line per context file saying when to open it. Open only what the task
  needs.
- Detailed specs live in `context/knowledge/plan/` (e.g. `GAP_CLOSURE_PLAN.md`);
  `context/decisions.md` holds the lasting rules those specs produced.

## Hard rules

1. **One file per component** holds its struct, variables and constraints together — no
   `src/form/` directory; a formulation is methods spread over component files, not a place.
2. **Every `src/` and `test/` file carries an 80-column box header ending in a Changelog
   section.** Add a new `# vX.Y.Z - <what changed>` line to files you modify; don't rewrite
   existing lines. Version bumps are the patch digit, one per gap/item, in `Project.toml`; the
   minor digit for an item that adds a component type.
3. **A documentation code example that claims to run must actually run**: wrap it as a Documenter
   `@example` block and it will be swept by `test/docs.jl`. `README.md` claims are load-bearing.
4. **Registries (`_EDGE_TYPES`, `_UNIT_TYPES`, `_MODELS`) are mutated under their own
   `ReentrantLock`.** CI runs with `JULIA_NUM_THREADS=4` specifically to exercise this.
5. **A generic-purpose test dependency is `import`ed, never `using`d,** in `test/runtests.jl` — it
   is a shared namespace across every test file; `using` risks silently shadowing NMB's own
   exports (happened with PowerModels' `parse_file`/`ids`/`solve_opf`).
6. **Numeric behavior changes are checked against PowerModels.jl** (`test/powermodels.jl`, a live
   cross-check) or the existing frozen-value tests (`lf.jl`/`opf.jl`/`lpf.jl`) — frozen tests catch
   NMB's own regressions, the live one catches divergence from a reference implementation.
7. Docstrings say what and why. No decision ids, no phase names, in comments.
8. **A question, observation or open idea is not a go-ahead to edit.** "What do you think?" or a
   described problem with no explicit "do it" means state the plan first; edit only once confirmed.

## Decisions

A change that alters behavior, a public API, a file format or a layering convention needs a
decision: check `context/decisions.md` first; record new ones with the `record-decision` skill.
Owner: **Tom Van Acker**.

## Finishing a task

Before you stop after changing anything, run the `wrap-up` skill: update `STATE.md`, the backlog,
decisions, environment/lessons if you learned something.

## Changing this setup

Files under `.github/` other than `context/`, and `.vscode/`, are the setup (instructions, skills,
hooks). **Never edit them without Tom's explicit OK in this conversation.** Propose instead: the
diff, the evidence, what it removes. Skills and the hook engine come from the
`sma-coding-second-brain` plugin; five NMB skills override it in `.github/skills/`.
