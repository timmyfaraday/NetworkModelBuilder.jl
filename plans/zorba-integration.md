# Zorba → NetworkModelBuilder.jl integration — engineering handoff

<!--
################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Changelog:                                                                   #
# v0.9.0 - initial implementation, the Zorba integration plan                  #
################################################################################
-->

**Milestone:** v0.9.0 — the Zorba integration. The package work this plan depends on is complete; what remains is on the Zorba side.
**Audience:** an agentic coding assistant (GPT 5.6 Terra) working in VS Code, plus the human reviewing its PRs.
**Status of this document:** written 2026-09-03 against verified repository state. Every claim marked ✅ was checked against source or a test run on that date. Claims marked ⚠️ are assumptions you must verify before relying on them.

**Where paths point.** This file lives in the NetworkModelBuilder.jl repository, but most of the work it describes is in Zorba. Paths are marked `Zorba: …` where they refer to that repository; unmarked relative links resolve within this one.

---

## 0. TL;DR

Zorba currently contains **two** DC-load-flow optimization models and consumes a **third** from an internal package. The decision is to replace all three model-building paths with `NetworkModelBuilder.jl` (NMB), a Julia package.

**The Julia side is done.** NMB v0.6.0+ already implements every feature this integration needs, including a purpose-built Zorba adapter with a file-based Arrow round trip. Its test suite is green: **2385 passing, exit 0** ✅ (run 2026-09-03).

**The Python side has not been started.** There is no Julia dependency, no bridge, no NMB reference anywhere in Zorba ✅. That — plus numerical validation and cutover — is all the remaining work.

Three features are **deliberately deferred** and are not in scope: hydro, unit commitment, and the PTDF/flow-based formulation. A key finding below is that **none of them block either migration** ✅.

Remaining effort: roughly **9 person-weeks**, in two independent migrations.

---

## 1. Repositories and environment

**This work will not be done on the machine where this plan was written.** Nothing below assumes a local path, a pre-installed toolchain, or a warm cache. Set up from scratch as in §1.2, and verify the baseline in §1.3 before writing any code.

### 1.1 The three repositories

| Repo | Language | Role |
|---|---|---|
| **Zorba** | Python 3.12 | The consumer. All remaining work is here. |
| **NetworkModelBuilder.jl** | Julia ≥1.10 | The new model builder. Complete for this scope; touch only if a gap is found. |
| **SmaLoadFlow** | Python 3.12 | Internal shared package being displaced **inside Zorba only**. Read-only reference. |

Reference commits, so you can tell whether the ground has moved under this plan:

- Zorba `99f60a5` ✅
- NetworkModelBuilder.jl at tag **`v0.9.0`** ✅ — this plan is committed at that tag, in `plans/`
- SmaLoadFlow `98998b9` (v0.6.4) ✅

If any repo is materially ahead of its reference commit, re-verify §2 before trusting it. The ✅ marks mean "checked on 2026-09-03", not "true forever".

### 1.2 Getting set up

1. **Clone all three.** Put them side by side; several instructions below assume sibling directories, and nothing assumes a specific parent.
2. **Python.** Zorba needs 3.12+ and `uv`. It resolves `read-antares`, `sma-opt`, `sma-load-flow` and `python_commons` from a private Azure Artifacts feed — see `[[tool.uv.index]]` in Zorba's `pyproject.toml`. **You need credentials for that feed.** Without them Zorba will not install at all, and that is the first thing to confirm, not the last.
3. **Julia.** Install ≥1.10 (`juliaup` is the easy route). No Julia is needed to *read* this plan, but M1-2 onward cannot start without it.
4. **Solver.** `HiGHS.jl` on the Julia side — see §8. No licence needed.
5. **Depending on NMB from Zorba's Julia project.** Prefer pinning the published package by revision rather than a local path, so CI and a developer machine resolve identically:

   ```julia
   # in Zorba's julia/ project
   ] add https://github.com/timmyfaraday/NetworkModelBuilder.jl#v0.9.0
   ```

   Use `Pkg.develop(path=…)` against a sibling clone **only** while actively changing NMB — for example during task M2-1 — and switch back to the pinned revision before the branch is merged. A committed `Manifest.toml` is what makes this reproducible; commit it.

### 1.3 Verify the baseline before starting

Do all four. Each has caught something in the past.

1. `julia --project=. -e 'using Pkg; Pkg.test()'` in NMB → expect **2385 passing, exit 0** ✅ (measured 2026-09-03, ~50 s after precompile).
2. `python -m pytest` in Zorba → expect green.
3. `lint-imports` in Zorba → expect green. You will be changing the layers it checks.
4. **Confirm you can reach a real study.** M1-1 needs one, via `get_study_by_name` / `get_frank_study`. ⚠️ Study data is not in the repository, and whether it is reachable from your environment is unverified. **If it is not, stop and raise it** — without a golden dataset there is no way to validate this migration, and every task after M1-1 depends on it.

### 1.4 Ownership, and why it matters

SmaLoadFlow is actively maintained by Robbie Muir, who is also Zorba's second-largest contributor. Displacing it inside Zorba forks the organisation's dispatch modelling. This is a decision the human has taken; it is not yours to re-open, but do not delete SmaLoadFlow code or remove it from `pyproject.toml` without an explicit instruction — see §9, task M2-6.

---

## 2. What NMB already provides (verified)

All of the following exist on `main` and are covered by the passing test suite. **Do not re-implement any of it.**

### 2.1 Core modelling

| Capability | API | Verified |
|---|---|---|
| Linearized DC flow | `LPFFormulation` | ✅ |
| Security-constrained redispatch | `RedispatchProblem` + `Dimension(:contingency)` | ✅ |
| Preventive / corrective measures | `Redispatch(; control, exception)` | ✅ |
| Monitored-edge subset | `Redispatch(; monitored)` | ✅ |
| **Priced overloads** | `OverloadPrice(; per_energy, per_peak)` | ✅ |
| Period grouping on `:time` | `period_ids`, `period_weight`, `period_cost` | ✅ |
| Cost spanning indices | `horizon_cost(nm)` | ✅ |
| **DC link / HVDC** | `DCLink` with `loss_fixed`, `loss_prop`, `reverse` | ✅ |
| **ENS and spill** | `EnergyNotServed`, `Spill` (`AbstractSlackUnit`) | ✅ |
| Storage cycle limits | `Storage.max_cycles_per_period` | ✅ |
| Storage throughput cost | `Storage.cost_throughput` | ✅ |
| Storage end-of-horizon energy | `Storage.energy_final` | ✅ |
| Generator daily energy cap | `Generator.max_energy_per_period` | ✅ |
| **Nodal prices from duals** | `active_nodal_price`, `reactive_nodal_price` | ✅ |
| Phase shifter, priced or free | `PhaseShifter`, `redispatch_price` | ✅ |
| Rolling horizon | `solve_rolling_horizon`, `initial_state` | ✅ |
| Tabular / Arrow input | `parse_tables`, `parse_arrow` | ✅ |

### 2.2 The Zorba adapter — `src/io/zorba.jl` (719 LOC) ✅

This is the piece that matters most, and it is **already written**. It translates Zorba's `MinimalStudy` + `RdsSettings` into a `NetworkData` and the answer back into Zorba's own schemas.

```julia
# in, from a directory of Arrow files
data   = parse_zorba(dir; overload_penalty = 1e3, wiggle_room = 0.0,
                          pst_cost = 1.0, baseMVA = 100.0)
# or in, from any column-addressable tables
data   = parse_zorba(; grid, net_position, hvdc, outage, kwargs...)

result = solve_zorba(data, optimizer)                       # RedispatchProblem × LPFFormulation
result = solve_zorba(data, P, F, optimizer; horizon, step)  # any other pair, or rolling

tables = zorba_tables(data, result)   # (; grid_flows, pst_dispatch)
write_zorba(out_dir, tables)          # one Arrow file per table
```

**Input tables it expects** (column names exactly as Zorba's schemas emit them):

| Table | Columns | Required |
|---|---|---|
| `grid` | `id`, `from_node`, `to_node`, `capacity`, `reactance_pu`, `pst_deg` | yes |
| `net_position` | `node`, `time_id`, `value_mw` | yes |
| `hvdc` | `id`, `from_node`, `to_node`, `cost` | no |
| `outage` | `name`, `link` | no |

**Output tables it produces**, matching `GfOverloadSchema` and `PstDispatchSchema`:

| Table | Columns |
|---|---|
| `grid_flows` | `outage`, `Name`, `from_node`, `to_node`, `time_id`, `flow_mw`, `overload_mw` |
| `pst_dispatch` | `Name`, `from_node`, `to_node`, `time_id`, `pst_deg` |

Behaviours already handled, which you must **not** re-derive:

- Unit conversion is at this boundary and nowhere else. Zorba is MW/degrees; NMB is per-unit on `baseMVA` and radians.
- Node ordering follows first appearance in `net_position`, matching `MinimalStudy.node_list`.
- Extra `grid` columns (`could_trip`, `trip_with`, tap columns) are ignored; outages come from the `outage` table.
- A blank `capacity` means unlimited.
- A link removed by an outage is reported with flow `0.0`, not omitted — matching what Zorba's downstream join expects.
- `wiggle_room` becomes a zero-priced `EnergyNotServed`/`Spill` pair at every node.
- `overload_penalty = :force` produces a hard rating; a number produces `OverloadPrice`.

> **Objective equivalence — read this before you debug any cost mismatch.**
> Zorba prices measures **once** and congestion **once per outage, summed**. NMB weights every cost by its network index's weight, and a `:contingency` coordinate carries a *probability* (uniform `1/N` by default), which makes congestion an **expectation**. The adapter multiplies the congestion price by `N` to turn that average back into Zorba's sum, so the two objectives are the same function ✅. Passing real `contingency_weight` probabilities asks the expected-cost question instead, and the gross-up is then *not* applied. If you see objective values off by a factor of exactly the number of states, this is why — do not "fix" it in Python.

### 2.3 What this means for the bridge

Because `parse_zorba` / `write_zorba` work on **directories of Arrow files**, there are two viable bridge designs, and they carry very different risk:

- **A — file/subprocess.** Python writes Arrow, invokes `julia --project=... script.jl`, reads Arrow back. No in-process FFI, no `juliacall` in CI, no interaction with the existing `ProcessPoolExecutor`. Cost is process startup + Julia precompile per invocation, amortised over a whole study.
- **B — in-process `juliacall`.** Lower per-call latency, but adds a Julia runtime to every forked worker and a second dependency resolver to CI.

**Recommendation: build A first.** It is strictly simpler, it is the design the adapter was written for, and it removes the single largest risk in the original plan (35 forked workers each holding a Julia runtime). Treat B as an optimisation to reach for only if A's measured wall-clock is unacceptable — see task M1-3.

---

## 3. Deferred — explicitly out of scope

| Feature | Why deferred | Blocks anything? |
|---|---|---|
| **Hydro** (reservoir, pumping, inflow) | Efficiency-convention question with SmaLoadFlow/Antares unresolved | **No** ✅ — see §4.3 |
| **Unit commitment** (min stable power) | Heuristic-vs-MILP decision unresolved | **No** ✅ — see §4.3 |
| **PTDF / flow-based formulation** | No consumer found in Zorba's pipeline | **No** ✅ |

All three are to be tackled after the Zorba–NMB connection is stable. **Do not implement them. Do not add placeholder types or `NotImplementedError` stubs for them.** If you hit something that seems to need one, stop and report it — it means an assumption in §4.3 is wrong.

Also explicitly out of scope, permanently:

- **`FbCalculator` / `Nm1Calculator` stay in NumPy.** These are a PTDF matrix and an N-1 sweep over ~250 outages × 8760 hours — closed-form linear algebra with no solver in the loop. Re-expressing them as optimization problems is a two-to-three order of magnitude regression. Do not touch `src/stages/small_zone_reliability/fb_calculator.py` or `calculate_nm1.py` beyond the `DEG_TO_RAD` fix.

---

## 4. The two migrations

### 4.1 M1 — replace `src/stages/small_zone_reliability/redispatch_solver/`

Zorba's own linopy DC-OPF. ~630 LOC including its models. Net positions only, no assets, but with an in-model `outage` dimension. This exists **only** because SmaLoadFlow has no contingency support ✅ (`grep -ri "outage\|contingenc\|n-1" sma_load_flow/` returns nothing).

The NMB adapter was written for exactly this study shape. **M1 is mostly plumbing and validation.**

Call site to preserve: `RedispatchSolver.run(minimal_study, hvdcs, settings, execution_plan, outages) -> RdsSolution`, reached from `zorba_kari.run_redispatch_calculation`.

### 4.2 M2 — replace the `sma_load_flow` path behind `src/scripts/kari/be_redispatch.py`

The BE curative redispatch. The model is built by SmaLoadFlow; `be_redispatch.py` (985 LOC) is orchestration.

**The adapter does not cover this yet.** `_zorba_units` builds one `FixedLoad` per node plus the wiggle-room slack pair ✅ — it has no generators and no batteries. M2 requires extending `parse_zorba` (or adding a sibling entry point) to carry per-node assets.

### 4.3 Why the deferred features do not block M2 — verified

This is the load-bearing finding that makes full replacement achievable now. Read `_build_power_system` at `Zorba: src/scripts/kari/be_redispatch.py:559`. The `PowerSystem` it constructs contains:

```python
PowerSystem(
    n_timesteps=..., nodes=...,
    transmission=TransmissionSystem(ntc_lines=transmission_lines),
    fixed_powers=fixed_powers,      # net position per node
    flex_powers=flex_powers,        # redispatch up/down per node
    storages=storages,              # batteries
    ens_and_spill=EnsAndSpillSettings.make(...),
)
```

- **No `power_plants=`** → no `min_stable_power` → unit commitment is unreachable ✅
- **No `HydroPlant`** anywhere in the file ✅
- `SolveOptions` at line 394 sets `enable_negative_prices`, `dc_load_flow`, `base_power_mva`, `transmission_overloads` — and **never `enable_unit_commitment`**, which defaults to `False` ✅

Zorba's use of SmaLoadFlow is a **strict subset** of SmaLoadFlow. Every component it actually uses has an NMB equivalent today.

One structural difference worth noting as an *improvement*: `be_redispatch.py` handles outages by **rebuilding the whole `PowerSystem` per outage in a Python loop**, then solving each separately. In NMB this collapses into the `:contingency` dimension of a single model — which is both faster and lets preventive/corrective control modes be expressed, something the current code cannot do at all.

---

## 5. Task breakdown

Work the tasks in order within each migration. M1 and M2 are independent after M1-2; do not start M2 until M1 has passed its validation gate, because M1 is what proves the bridge.

### M1 — the security-constrained redispatch

---

#### **M1-0 — Fix `DEG_TO_RAD`, on its own commit** · ~0.5 day

**Why first:** `Zorba: src/config/dc_lf.py` defines `DEG_TO_RAD = 3.14 / 180`, a 0.05 % error against π/180 ✅. It is used by the linopy redispatch model, while `FbCalculator` uses `np.deg2rad` and SmaLoadFlow uses `np.pi/180`. **Zorba's two internal DC paths already disagree with each other and with SmaLoadFlow.** Fixing this first makes every later migration delta attributable.

**Do:**
1. Change to `DEG_TO_RAD = math.pi / 180`.
2. Run the existing test suite; record which tests move and by how much.
3. Regenerate any cached study output that changes (see M1-7 on `banana_cache`).
4. Commit alone, with the measured flow deltas in the message.

**Acceptance:** the constant is exact; the commit touches no other behaviour; the delta is recorded.

---

#### **M1-1 — Golden dataset and comparison harness** · ~3 days

**Why:** this is the only thing that will tell you the migration is correct. Build it before writing any integration code.

**Do:**
1. Pick a real study reachable via `get_study_by_name` / `get_frank_study`.
2. Capture, from the **current** linopy path, for one full week and one full year at daily granularity: the `MinimalStudy` inputs and the complete `RdsSolution` — `flow_mw`, `overload_mw`, `phase_shift_deg`, `hvdc_flow_mw`, and the objective value.
3. Persist inputs and outputs as Parquet under a stable path (suggest `tests/fixtures/golden/`), not in `banana_cache` — you need them immune to cache invalidation.
4. Write `compare_rds_solutions(a, b) -> report` diffing per `(Name, time_id, outage)` and reporting max, p99 and mean absolute error per quantity, plus the objective delta.
5. Extend `Zorba: tests/test_stages/test_sz_reliability/test_redispatch_solver.py` — 3 tests today — to pin: overload pricing vs `"force"`, PST saturation, HVDC direction, and `wiggle_room`.

**Acceptance:** the harness reports zero difference when run against the current implementation twice; the four new tests fail if any of those behaviours change.

---

#### **M1-2 — Julia environment and the bridge skeleton** · ~4 days

**Do:**
1. Add a pinned Julia project under `julia/` in the Zorba repo: `Project.toml` + **committed** `Manifest.toml`, depending on `NetworkModelBuilder` (pinned by revision — see §1.2), `Arrow`, and a solver (`HiGHS` — see the solver note in §8). Pin the Julia version too, in CI and in a `.julia-version` or equivalent, so a developer machine and the pipeline agree.
2. Write `julia/run_redispatch.jl`: reads an input directory, calls `parse_zorba` → `solve_zorba` → `zorba_tables` → `write_zorba`, writes an output directory. Take input/output paths and settings as CLI args or a small JSON side-car. Exit non-zero with a readable message on solver failure.
3. Write `src/tools/julia_bridge.py`: a thin Python wrapper that materialises polars frames to Arrow in a temp dir, invokes Julia via `subprocess`, reads the results back with polars, and raises a clear Python exception on failure. Put the Julia executable path behind an env var with a sensible default.
4. Add Julia setup to `azure-pipelines.yaml`, including a cache for the Julia depot so precompile is not paid on every run.

**Acceptance:** a five-node toy study round-trips Python → Julia → Python and returns sane flows; CI is green from a clean image; cold-cache precompile time is measured and recorded.

---

#### **M1-3 — Measure, then decide on parallelism** · ~2 days · **STOP GATE**

**Why a gate:** the current path uses a 35-worker `ProcessPoolExecutor`. This is the single largest performance risk, and finding out here is much cheaper than finding out after M1-4.

**Do:**
1. Time a full year at daily granularity through the bridge, against the linopy baseline on the same machine.
2. Try, in order: (a) one Julia process solving all batches, using NMB's own rolling horizon (`solve_zorba(...; horizon, step, reuse = true, warm_start = true)`) — model reuse across windows may beat naive batching outright; (b) Julia-side threading over batches; (c) several Julia subprocesses from Python.
3. Record wall-clock and peak memory for each.

**Acceptance:** a written comparison, and an explicit decision. **If no configuration lands within a factor the human accepts, stop and report rather than proceeding.** Note that option (a) has no equivalent in the current code and may make the comparison favourable in a way the original estimate did not assume.

---

#### **M1-4 — The NMB backend behind the existing interface** · ~1 week

**Do:**
1. Add an `RdsBackend` seam so `RedispatchSolver.run` can dispatch to either implementation. Keep the signature and the `RdsSolution` return type **exactly** as they are — everything downstream validates against `GfOverloadSchema` and `PstDispatchSchema`.
2. Implement the NMB backend: `MinimalStudy` + `hvdcs` + `outages` + `RdsSettings` → the four Arrow tables → bridge → `grid_flows` / `pst_dispatch` → `RdsSolution`.
3. Map the settings: `RdsSettings.overload_penalty` → `overload_penalty` (pass `:force` through as-is), `wiggle_room` → `wiggle_room`, `pst_cost` → `pst_cost`, `BASE_POWER_MVA` → `baseMVA`.
4. Select the backend by an explicit argument defaulting to the current implementation. **Do not** switch the default in this task.

**Acceptance:** both backends are callable from the same call site; the new one returns a schema-valid `RdsSolution`; no downstream file changes.

---

#### **M1-5 — Numerical validation** · ~1 week

**Do:**
1. Run the M1-1 harness across the golden dataset, both backends.
2. Compare **`flow_mw`, `overload_mw` and the objective**. Treat `phase_deg` as unconstrained by the comparison — the node phase variables are degenerate wherever the LP has ties, and a different solver will land on a different vertex. `phase_shift_deg` is meaningful only where it is uniquely determined; check it as a distribution, not row-by-row.
3. For every material difference, determine which implementation is right rather than tuning until they agree. NMB's exact radians (after M1-0, both are exact) and its angle limits make it the more defensible of the two.
4. Re-run the full pipeline — `run_make_frank_border_safe` → `get_nm1_flows_for_safe_borders` — and diff the reported horizontal-grid statistics, not just solver output. Downstream N-1 consumes these.

**Acceptance:** flows agree within an agreed tolerance on the golden year; every residual difference has a written explanation; no fudge factors.

---

#### **M1-6 — Cutover** · ~2 days

**Do:** flip the default backend. Keep the linopy path callable for one release cycle.

**Acceptance:** default path is NMB; the old path is still reachable by explicit argument; full pipeline green.

---

#### **M1-7 — Cache invalidation** · ~1 day

**Why:** `banana_cache` keys on argument hash. `run_redispatch_calculation`, `run_make_frank_border_safe`, `run_be_nm1_with_safe_borders` and everything downstream will **happily serve stale results** across this change.

**Do:** identify every cached function on the path and invalidate deliberately (`src/tools/cache.py::remove_cached` exists). Document which keys were dropped.

**Acceptance:** a clean-cache run reproduces the validated numbers.

---

#### **M1-8 — Delete the duplicate** · ~2 days · *after one release cycle*

**Do:** remove `redispatch_solver/common.py`, the executors, and the xarray pre-processing in `solver.py`. Update the `[tool.importlinter]` layer contracts.

**Do NOT** remove `linopy`, `highspy` or `pulp` from `pyproject.toml` — `sma_load_flow` still depends on all three and is still in use until M2 lands.

---

### M2 — the BE curative redispatch

---

#### **M2-1 — Extend the adapter for per-node assets** · ~1 week · *Julia-side*

**Why:** `parse_zorba` builds only fixed net-position loads ✅. M2 needs generators, batteries and priced slack.

**Do (in NMB, not Zorba):** add optional `generator`, `storage` and `slack` tables to `parse_zorba`, or add a sibling entry point if the signature gets unwieldy — the human's call. Follow the file's existing conventions exactly: unit conversion at this boundary only, validation in constructors, one `NetworkVector` per varying field.

Use these mappings (all target types verified present ✅):

| SmaLoadFlow | NMB | Notes |
|---|---|---|
| `FixedPower(net_production=…)` | `FixedLoad` with negated `pd` | already done by `_zorba_units` |
| `FlexPower(max_power=u, min_power=-d, flex_spec=FlexSpec(0, up, down))` | `Generator(pg=0, pmin=-d, pmax=u, cost_up=up, cost_dn=down)` | `Generator` has **no** `pmin ≥ 0` check ✅, so negative `pmin` is legal |
| `Storage(max_withdraw_power, max_inject_power, duration_hours, rte, throughput_cost, start_soe, max_throughput_per_day)` | `Storage(charge_rating, discharge_rating, energy_capacity = power × duration, charge_efficiency, discharge_efficiency, cost_throughput, energy_initial, max_cycles_per_period)` | `energy_model="Balanced"` means the round-trip efficiency is split evenly: set both one-way efficiencies to `√rte`. ⚠️ **Verify this against SmaLoadFlow's `EnergyStorageModel.Balanced` before trusting it** — read `sma_load_flow/models/energy_storage.py`. |
| `EnsAndSpillSettings(global_ens_price, global_spill_price)` | `EnergyNotServed(cost=…)` + `Spill(cost=…)` per node | ENS cost ≥ 0, Spill cost ≤ 0, enforced in constructors |
| `NtcTransmissionLine(x_pu, capacity, phase_shift_setpoint_degrees)` | `PhaseShifter` with `ta_min = ta_max = setpoint` | fixed PST; `be_redispatch` sets `phase_shift_flex_degrees=0.0` |
| outage loop rebuilding `PowerSystem` | `Dimension(:contingency)` + `status` | one model instead of N |

**Acceptance:** NMB's own tests cover the new tables with a hand-workable network; `julia --project=. -e 'using Pkg; Pkg.test()'` stays green.

---

#### **M2-2 — BE redispatch backend in Zorba** · ~1 week

**Do:** behind a flag in `run_redispatch_inside_belgium`, build the extended Arrow tables from `_read_node_settings` / `_build_power_system`'s inputs and route through the bridge. Preserve the `(GfOverloads, PstDispatch, MinimalStudy)` return contract.

Watch for: `_get_belgian_nodes` voltage filtering, islanded-node dropping per outage state (NMB derives topology from `status` — ⚠️ confirm it tolerates a node that ends up with no in-service edges, or filter as the current code does), and the fixed-HVDC-as-net-position preprocessing which happens *before* the model and should stay in Python.

**Acceptance:** both backends callable; schema-valid outputs.

---

#### **M2-3 — Validation** · ~1 week

Same protocol as M1-5, against a golden `be_redispatch` run. Additionally compare ENS/spill volumes and battery SOC trajectories.

**Expect a real difference here and do not suppress it:** the current code solves each outage as a **separate** `PowerSystem` with its own independent battery trajectory; NMB solves one model where preventive measures are shared across contingencies. Configure `Redispatch(control=…)` to match the current semantics first (all-corrective reproduces independent per-outage solves most closely), validate against that, and only then explore the preventive split as a deliberate modelling change.

---

#### **M2-4 — Cutover, M2-5 — cache invalidation, M2-6 — dependency cleanup** · ~1 week total

On M2-6: only once **both** migrations are live and stable may `sma_load_flow` be dropped from `pyproject.toml`, and `linopy`/`highspy`/`pulp` with it if nothing else imports them. **Check `python_commons` and any other internal package first.** Removing a dependency that another consumer reaches through Zorba is not a rollback you can do quickly. Get explicit human sign-off.

---

## 6. Verified traps

These were each confirmed against source. They will cost you a day each if you meet them cold.

1. **`constrain!` cannot change a constraint's set *type*.** [`src/core/rebuild.jl`](../src/core/rebuild.jl) updates rows in place via `MOI.set(backend, MOI.ConstraintSet(), index, c.set)`, which requires the same set type. Writing a `LessThan` pair over a stored `Interval` row throws. Relevant only if you add constraints in NMB — give new constraint forms their own `key` ✅.
2. **`Redispatch` is not `@kwdef`.** It has a hand-written outer constructor that calls the inner one positionally. Adding a field means changing both ✅.
3. **A `DCLink`'s `rate_a` is an equipment limit, not a congestion limit.** It is enforced regardless of `monitored` and an `OverloadPrice` cannot relax it ✅. Do not model a congestion limit on a DC link by inflating its rating.
4. **`GridModelSchema` enforces `from_node < to_node`.** Flow sign convention follows the table's own column order. The adapter respects this; if you build tables by hand, do not reorder endpoints.
5. **Degenerate phase variables.** Node phase angles are not uniquely determined when the LP has ties. Never assert on them row-by-row across implementations.
6. **`banana_cache` will serve stale results** across every one of these changes. It is keyed on argument hash and knows nothing about which backend ran.

---

## 7. Validation protocol (applies to M1-5 and M2-3)

Compare in this order, and stop at the first that disagrees:

1. **Feasibility** — both solve, same termination status.
2. **Objective** — within solver tolerance, after accounting for the documented `N`-state gross-up (§2.2).
3. **`flow_mw`** — per link, time step, outage. This is the primary quantity.
4. **`overload_mw`** — same index. Zorba's headline output.
5. **Downstream statistics** — `calculate_horizontal_grid_stats` over the full pipeline.
6. *(M2 only)* ENS/spill volumes, battery SOC trajectories.

Report max, p99 and mean absolute error, not just max — a single degenerate row should not fail a run, and a systematic 0.05 % bias should not pass one.

---

## 8. Solver

NMB takes any JuMP optimizer. Zorba currently reaches HiGHS and Xpress through `sma_opt`.

- **Use `HiGHS.jl` for the LP work.** It is open, matches `highspy` already in Zorba's dependency set, and needs no licence plumbing.
- The test suite uses Ipopt because it exercises the nonlinear IVR formulation too; you do not need Ipopt for the linearized path.
- ⚠️ **Xpress:** `Xpress.jl` exists, but the licence handling in `Zorba: src/stages/small_zone_reliability/redispatch_solver/process_executor.py` (`xpress_license`, env-var marshalling to workers) has no equivalent on the Julia side and would need re-doing. Do not attempt this unless HiGHS proves inadequate, and raise it with the human first.

---

## 9. Definition of done

**M1 done when:** the default `RedispatchSolver` path builds its model in NMB; flows and overloads match the golden year within tolerance with every difference explained; CI green from a clean image; caches invalidated; `redispatch_solver/`'s linopy model deleted; import-linter contracts updated.

**M2 done when:** `run_redispatch_inside_belgium` builds its model in NMB; validated as above including ENS/spill and SOC; `sma_load_flow` no longer imported by Zorba — and removed from `pyproject.toml` only with explicit sign-off.

**Not done, and not in scope:** hydro, unit commitment, PTDF formulation, and any change to `FbCalculator` / `Nm1Calculator` beyond M1-0.

---

## 10. Commands

Run each from the root of the repository named. No absolute paths — see §1.

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```
*NetworkModelBuilder.jl — expect 2385 passing, ~50 s after precompile.*

```bash
python -m pytest
```
*Zorba — the existing suite.*

```bash
lint-imports
```
*Zorba — import-layer contracts. These will need updating as you move code.*

```bash
uv sync
```
*Zorba — needs credentials for the private Azure Artifacts feed. If this fails, fix it before anything else.*

---

## 11. Working agreements

- **Small, reviewable commits.** One task per PR where possible. `M1-0` in particular must be alone.
- **Never change both sides in one commit.** NMB and Zorba are separate repos with separate CI.
- **Do not delete the old implementation until its replacement has passed validation** and one release cycle has elapsed.
- **When NMB and Zorba disagree numerically, investigate before adjusting.** The reflex to tune until the numbers match will hide a real modelling difference. Every difference gets a written explanation.
- **If a task's assumption turns out to be wrong** — particularly the §4.3 finding that hydro and unit commitment are unreachable — **stop and report** rather than implementing around it.
- ⚠️-marked claims in this document are unverified. Check them before you depend on them.
