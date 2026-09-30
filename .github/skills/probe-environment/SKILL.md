---
name: probe-environment
description: Check the machine the agent runs on (shell, Julia/juliaup, git, gates, hooks, docs build) and record facts in .github/context/environment.md. Use on first use of a new machine, after a machine or tooling change, or when environment.md has lines marked (unverified).
---
# Probe the environment

Run each check, keep output short, and record results. Don't install or change anything without
asking.

## Checks

1. Shell and OS: `$PSVersionTable.PSVersion`, `[Environment]::OSVersion.VersionString`.
2. Script policy: `Get-ExecutionPolicy -List`. Then try a one-line `.ps1` written to `scratch/`
   (`Write-Output ok`) and run it. Record whether unsigned scripts run.
3. Julia: `julia --version`, `juliaup status`. Confirm `Project.toml`'s `julia` compat floor still
   matches (currently `1.10`).
4. Python (for the agent hooks only, not the package itself): `python --version`, and whether
   `python3` also resolves (the hooks' non-Windows `command` field assumes it does).
5. Git: `git --version`, `git config user.name`, `git config core.autocrlf`.
6. Gates, timed: `julia --project=. -e "using Pkg; Pkg.test()"` (full suite, ~2-3 minutes, ~2400
   tests); `julia --project=docs docs/make.jl` (doc build).
7. Hooks: is there context from a SessionStart hook in this session (STATE.md content)? Check
   `.git/agent-session/` for a file from this session and `.git/agent-hooks.log` for errors.
8. Thread count: confirm `JULIA_NUM_THREADS` before running `test/thread_safety.jl` manually — it
   silently exercises nothing if the process itself started with only one thread.

## Record

For each check: update or add the line in `.github/context/environment.md` (fact · works instead ·
found by `git config user.name` · date), removing `(unverified)` where confirmed. Anything that
blocks the setup (hooks not firing, scripts blocked) also goes to `setup-feedback.md` as an `F<n>`
entry.
