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
- Machine: 112 cores, 1 TB RAM. Many one-thread Julia processes run fine side by side: 73
  `julia --project=scripts -t 1` started with `Start-Process ... -RedirectStandardOutput <abs path>
  -PassThru` then `Wait-Process`, each ~1 GB in the load phase (solve-phase peak not measured);
  Xpress's development licence did not limit them. Env vars set before each `Start-Process` are
  inherited by that child. `julia -e '...'` loses its inner quotes in PowerShell: use a temp `.jl`
  (found by Tom Van Acker, 2026-10-02). A child's `-RedirectStandardOutput` file stays empty until the
  process exits (Julia buffers stdout to a file), so watch `runs/<id>/chunks/*/` for written files
  instead of the `.log`; a sync `Wait-Process -Timeout` call is moved to the background when idle, and
  a second `Wait-Process` call in a new command blocks until the processes are gone (found by Tom Van
  Acker, 2026-10-05).
- A same-day control run of an older commit: `git worktree add --detach $env:TEMP\nmb-control-wt <commit>`,
  one `julia --project=<wt>\scripts -e "using NetworkModelBuilder, Xpress ..."` to warm its compile
  cache, then `Start-Process julia ... -WorkingDirectory <root>` per process, `--project=scripts` being
  relative to it. Week 1 as 7 + 7 processes took 7 min. Copy `<wt>\runs\<id>` out before `git worktree
  remove --force` (found by Tom Van Acker, 2026-10-07).
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
- Piping `julia`'s output through `2>&1 | Select-Object`/`Tee-Object` in PowerShell 5.1 can report a
  spurious `NativeCommandError` / non-zero exit for Julia's very first `@info` line (stderr), even
  though the run completes fully and `$LASTEXITCODE` is `0` — seen on `docs/make.jl`. Check
  `$LASTEXITCODE` after a plain, unpiped run instead of trusting a piped call's reported exit code
  (found by Tom Van Acker, 2026-10-01).
- Python 3.14.7 is on PATH as `python`; `python3` does **not** resolve. Harmless today because
  `agent-hooks.json` has a `windows` override (`py -3 ...` since SC6) for every hook, but would break if a
  hook config ever dropped that override. Git 2.43.0.windows.1; `git config user.name` → `Tom Van
  Acker`; `core.autocrlf` → `true` (found by Tom Van Acker, 2026-09-30).
- Agent hooks (`.github/hooks/`) are Python, stdlib-only, need a 3.9+ interpreter on PATH — present
  here (Python 3.14.7) and not the blocker. **Probed 2026-09-30 (Tom Van Acker) and confirmed NOT
  firing**: no `.git/agent-session/` dir ever created, no `.git/agent-hooks.log`, and this session
  got no SessionStart-injected `STATE.md` context. `agent-hooks.json`'s schema matches Claude
  Code's hook config, not a known VS Code Copilot Chat feature — likely why. See
  `setup-feedback.md` F1; the "read `STATE.md` yourself if you don't see it injected" fallback in
  `copilot-instructions.md` is carrying this alone for now.
- Since SC6 the hooks run through `.github/hooks/launch.py`, which finds the plugin's engine under
  `~/.vscode/agent-plugins/` (plugin 0.2.0, installed, its source allowed in the user's
  `chat.plugins.strictMarketplaces`). From the repo root, `session_start`, `guard` and `stop_check`
  each work through `py -3 .github\hooks\launch.py <name>` with `{}` on stdin. Whether VS Code runs
  them is not yet re-tested: delete `.git/agent-session/` and `.git/agent-hooks.log` first, since a
  manual run creates both (found by Tom Van Acker, 2026-10-07).
- The repo's `.venv` is empty on purpose (D39): it only stops `launch.py` from adding a "no .venv"
  note, and is gitignored, so a fresh clone needs `py -3 -m venv .venv` (2026-10-07).

## CI

- GitHub Actions. `CI.yml`: Julia `1.10` and `1`, `ubuntu-latest`, `JULIA_NUM_THREADS: '4'`,
  coverage via Codecov. `Documentation.yml`: builds `docs/` with Documenter, deploys on push to
  `main` and on tags.
- `/runs/` and `/scratch/` are gitignored (NMB's own simulation output, and agent/scratch working
  output, respectively) — don't expect either to survive a fresh clone.
- A `[weakdeps]` + `[extras]`/`[targets]` package (e.g. Arrow, PowerModels, and now Parquet2) is
  **not** written into the main `Manifest.toml` by a plain `Pkg.resolve()`/`Pkg.instantiate()` —
  neither Arrow nor PowerModels appear there today despite being used every test run. `Pkg.test()`
  resolves `[extras]`/`[targets]` into its own temporary test environment each time instead. Don't
  expect (or try to force) a new test-only weak dependency to show up in the committed
  `Manifest.toml`; adding it to `Project.toml` alone is enough, and `Pkg.test()` fetches it in
  running the suite (found by Tom Van Acker, 2026-09-30, adding Parquet2).
- `run_in_terminal` output redirected to a file with PowerShell's `*>` (or `>`) is UTF-16LE with a
  BOM by default on this PowerShell 5.1 — `grep_search`/plain `Select-String` on that file can
  silently return zero matches even though the text is there. Read it with `Get-Content -Path ...
  -Encoding Unicode | Select-String ...` instead (found by Tom Van Acker, 2026-09-30, capturing a
  `Pkg.test()` run to a log file).
- `Get-Content -Raw` without `-Encoding UTF8` reads this repo's BOM-less UTF-8 files as ANSI, so a
  rewritten copy of a test file (`–`, `≈`) is mojibake and Julia fails to parse it. Read with `-Encoding
  UTF8` and write with `[IO.File]::WriteAllText(path, text, (New-Object Text.UTF8Encoding($false)))`
  (found by Tom Van Acker, 2026-10-05, perturbing a helper to prove a test can fail).
