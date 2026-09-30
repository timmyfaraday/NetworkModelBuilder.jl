# Environment

Facts about the machines NMB is developed on. When something fails because of the machine, add or
fix a line here: `- <fact> · works instead: <x> · found by <user>, YYYY-MM-DD`. Mark unverified
facts `(unverified)` and remove the marker once checked.

## Work machine

- Windows, PowerShell 5.1, execution policy `AllSigned` at machine scope — no `.ps1` file runs,
  even with a process-scoped bypass. Works instead: `python -c "..."` or single-line,
  semicolon-joined PowerShell typed directly; for Julia, write a temp `.jl` script file and run
  `julia script.jl` rather than passing code via `julia -e "..."` (a Windows path or embedded
  quote inside the string breaks `-e`'s escaping).
- Julia 1.12.5 via `juliaup`, on PATH. `julia --project=. -e "using Pkg; Pkg.test()"` from the
  repo root runs fully offline once `Manifest.toml` is resolved (~2-3 minutes, ~2400 tests).
- `Pkg.activate(temp=true)` is ephemeral — gone by the next separate `julia` process invocation
  even after a clean exit. Use `Pkg.activate("C:/explicit/persistent/path")` (forward slashes) for
  any scratch environment reused across multiple terminal calls.
- `Threads.@threads` only creates real concurrency if the Julia *process* starts with
  `JULIA_NUM_THREADS` > 1 (fixed at startup, can't change at runtime). CI sets it to `4` on the
  `julia-actions/julia-runtest@v1` step specifically so `test/thread_safety.jl` can't silently
  become a no-op; set `$env:JULIA_NUM_THREADS = '4'` locally before `Pkg.test()` to match.
- `┌ Error: mktempdir cleanup ... directory not empty (ENOTEMPTY)` from `test/tables.jl`'s Arrow
  round-trip tests on Windows is pre-existing noise, not a failure — check the final
  `Test Summary: ... Pass X Total X` line, not the presence of `@error` logs.
- Agent hooks (`.github/hooks/`) are Python, stdlib-only, and need a Python 3.9+ interpreter on
  PATH (no `.venv` — this is a Julia project, not a Python one). If missing, hooks fail silently:
  no `STATE.md` injection at session start, no `.git/agent-hooks.log` entry anywhere to say so.
  Verify with `/probe-environment` after setup, don't assume they're running.

## CI

- GitHub Actions. `CI.yml`: Julia `1.10` and `1`, `ubuntu-latest`, `JULIA_NUM_THREADS: '4'`,
  coverage via Codecov. `Documentation.yml`: builds `docs/` with Documenter, deploys on push to
  `main` and on tags.
- `/runs/` and `/scratch/` are gitignored (NMB's own simulation output, and agent/scratch working
  output, respectively) — don't expect either to survive a fresh clone.
