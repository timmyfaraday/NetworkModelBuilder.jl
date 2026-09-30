# Environment

Facts about the machines NMB is developed on. When something fails because of the machine, add or
fix a line here: `- <fact> · works instead: <x> · found by <user>, YYYY-MM-DD`. Mark unverified
facts `(unverified)` and remove the marker once checked.

## Work machine

- Windows, PowerShell 5.1, execution policy `AllSigned` at machine scope — no `.ps1` file runs,
  even with a process-scoped bypass. Works instead: `python -c "..."` or single-line,
  semicolon-joined PowerShell typed directly; for Julia, write a temp `.jl` script file and run
  `julia script.jl` rather than passing code via `julia -e "..."` (a Windows path or embedded
  quote inside the string breaks `-e`'s escaping). Exact versions: PowerShell 5.1.20348.5499,
  Windows NT 10.0.20348.0, `MachinePolicy=AllSigned` overriding `LocalMachine=RemoteSigned` —
  re-confirmed by running an unsigned `scratch/probe.ps1` directly (found by Tom Van Acker,
  2026-09-30).
- Julia 1.12.5 via `juliaup` (default `release` channel), on PATH — matches the `julia = "1.10"`
  compat floor in `Project.toml` with headroom; `juliaup status` shows `1.13.1` available but not
  installed (no action taken). `julia --project=. -e "using Pkg; Pkg.test()"` from the repo root
  runs fully offline once `Manifest.toml` is resolved: 2436 tests, `Test Summary` time 3m03.6s
  (~3m21s wall including precompilation) with `JULIA_NUM_THREADS=4` set first (found by Tom Van
  Acker, 2026-09-30).
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
- `julia --project=docs docs/make.jl` builds cleanly in ~57s cold: one non-fatal warning
  (`problems/redispatch/index.md` HTML over the 100 KiB soft `size_threshold_warn`) and an
  expected "could not auto-detect the building environment, skipping deployment" outside CI —
  neither is a failure (found by Tom Van Acker, 2026-09-30).
- Python 3.14.7 is on PATH as `python`; `python3` does **not** resolve. Harmless today because
  `agent-hooks.json` has a `windows` override (`python ...`) for every hook, but would break if a
  hook config ever dropped that override. Git 2.43.0.windows.1; `git config user.name` → `Tom Van
  Acker`; `core.autocrlf` → `true` (found by Tom Van Acker, 2026-09-30).
- Agent hooks (`.github/hooks/`) are Python, stdlib-only, need a 3.9+ interpreter on PATH — present
  here (Python 3.14.7) and not the blocker. **Probed 2026-09-30 (Tom Van Acker) and confirmed NOT
  firing**: no `.git/agent-session/` dir ever created, no `.git/agent-hooks.log`, and this session
  got no SessionStart-injected `STATE.md` context. `agent-hooks.json`'s schema matches Claude
  Code's hook config, not a known VS Code Copilot Chat feature — likely why. See
  `setup-feedback.md` F1; the "read `STATE.md` yourself if you don't see it injected" fallback in
  `copilot-instructions.md` is carrying this alone for now.

## CI

- GitHub Actions. `CI.yml`: Julia `1.10` and `1`, `ubuntu-latest`, `JULIA_NUM_THREADS: '4'`,
  coverage via Codecov. `Documentation.yml`: builds `docs/` with Documenter, deploys on push to
  `main` and on tags.
- `/runs/` and `/scratch/` are gitignored (NMB's own simulation output, and agent/scratch working
  output, respectively) — don't expect either to survive a fresh clone.
