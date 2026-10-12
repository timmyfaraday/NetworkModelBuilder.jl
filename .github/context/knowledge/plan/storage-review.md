# Storage: a review against the literature, and the changes it asks for

Status: B33 built on `b33-storage-fields` (v0.15.1, suite 3788, not merged), the rest ready to implement, decided by Tom 2026-10-12 · Author: Tom Van Acker (requested) · Date: 2026-10-12 · Decisions: D71-D88 (next free after: D89)
Priority: P1 · Effort: Large. Open: Q11 (what Zorba's throughput cap counts). Backlog B33-B38 and B40, B39 later.

Literature: knowledge-base nodes Storage Models in OPF (14 sources that model storage, raw PDFs re-read) and Redispatch and
Congestion Management (6 sources, 3 with storage rows; text layers and storage pages re-read 2026-10-12). Notes here cite authors and pages and never quote.
Measured with HiGHS; the scripts are `%LOCALAPPDATA%\Temp\nmb_storage_review\*.jl` and `nmb_redispatch_review\measure*.jl`; every number below is a test below.

## Handoff instructions

- One branch per item, in the order B33 to B38 then B40 (items 1 to 7), each a patch of `Project.toml` from 0.15.1, test first and red, no AI attribution.
- Per-file changelog header on every `src/` and `test/` file touched, `CHANGELOG.md`, the docs page `docs/src/components/storage.md` (item 1 adds the Fortenbacher note of D77).
- Item 1 first: it adds `e_min`, `c_chg`, `c_dch` and `scheduled_energy`, which items 3, 4 and 7 use; items 2, 5 and 6 stand alone. A branch that finds the plan wrong stops and says so.
- Every name goes through `test/nomenclature.jl` first (a name the grammar refuses is a decision, not a workaround); the evidence below is the whole brief.

## Evidence

- **The relaxation is not exact.** Three steps, a must-run surplus of 0.3 pu, the default `Spill` (-500), a full battery (e_max 0.5, 0.2 pu,
  η 0.9 each way): relaxed 393.00, with binaries 426.54, no battery 450.00. With `c_thru` 100 it is 441.60 against 446.54, with 130 both 450.00.
  The threshold is `|λ|(1-η_c η_d)/(η_c η_d)` = 117.3 (Liang et al. 2024 B-1a p.7; Wang et al. 2023 C2 p.4-5; Garifi et al. 2020 Eq. 14 p.5).
  `_warn_free_cycling` (`storage.jl:459`) scans generator costs only and was silent.
- **Cost of the ways to avoid it** (10-node chain, 4 storages, T=24, 36 of 96 unit-steps violate): relaxed LP 0.01 s and 2.9 % below the exact
  optimum; plus a hull row 1.3 % below, same violators; binaries on every unit-step 0.16 s; the hull row and binaries only on the violators,
  two solves, 36 binaries, 0.19 s, the same optimum; iterative fixing of the direction (Felder and Hiskens p.4, Marley and Hiskens p.2) 0.01 s,
  0.6 % above. Where the relaxation is exact the lazy loop is the LP (0.01 s against 0.08 s). A price above the threshold made the LP exact.
- **End of horizon.** A roll with no terminal value, prices 10 five times then 100 three times, perfect foresight 27.763: extra cost 26.2, 10.1,
  8.4, 0 at horizons 2, 3, 4, 5 (the lead time is the length of the peak plus the hours to charge, minus one).
- **Validation and outages.** `e_init` or `e_fin` above `e_max` is accepted. A `status` over `:time` is `KeyError: key :p_chg not found`. Zero
  ratings over steps 2-3 hold the energy (e_stor 0.0205 across the gap, objective 28.216 against 10.432 in service).
- **Cycles in a roll.** Eight steps, periods of four, `k_cycl_max` 0.2, e_max 0.5 (0.1 pu·h a period): one problem 0.1 + 0.1; a roll of
  horizon 2 step 2 gives 0.2 + 0.2, and horizon 4 step 2 with prices 100, 10, 90, 10, ... also 0.2 + 0.2. `Generator.e_per_max` 0.3 a period:
  1.2 in total instead of 0.6 at horizon 2 step 2. A window carries the fragment of a period it cut, with a fresh allowance (`window.jl`).
- **Redispatch.** Two parallel branches, a unit behind them, 4 steps, 3 contingencies, `k_cycl_max` 0.5: a preventive unit writes 3 cycle rows beside 32 control ties that make two of them copies, a corrective unit needs all 3.
  A `status` over `:contingency` is the same `KeyError: key :p_chg not found` as over `:time`. `c_up` 10 with `c_dn` -30, no congestion: objective -20.0 (up 0.737, dn 1.0), 0 at `c_dn` 10.
  A balanced schedule discharging 0.3 for three steps from a full 0.5 (η 1, no congestion) is repaired silently, unit -0.4 and generator 1 +0.4, cost 24.0; at 0.1 it costs 0.

## 1. Fields and validation (B33, D74, D75, D83, D84, D87, D88, v0.15.1)

- **Fix.** `_with(st; kwargs...)` replaces the two field lists of `interior_state` and `initial_state`. `_check_storage` in the constructor, as
  `_check_branch`, with `all_nw`: ratings at least 0, `0 <= e_min <= e_max`, `c_chg`, `c_dch` and `c_cycl` finite and at least 0, `c_up` and `c_dn` finite with `c_up + c_dn >= 0`,
  `η` as today; not `e_init` or `e_fin` against the bounds, since the constructor runs again at every index and a window starts from a solver value, a digit outside them.
  `check_storage(data)` before the build, as `check_islands`, reads those at the index they matter at, within 1e-5: `e_init` at the first, `e_fin` at the last, and a market schedule
  (its count under D81, `max(p_set, 0)` as discharge and `max(-p_set, 0)` as charge, at most `k_cycl_max·e_max` over any 24 h). A roll checks the schedule once and its windows skip it.
- **Decided (D83, D84).** The pair `c_up + c_dn >= 0` is the guard, each price alone only finite: a sum below zero pays the solver to raise both volumes by the same
  amount (Evidence); the thesis keeps binaries on its up and down bids for prices that need not be ordered (Scarponi p.90, rows 4.12-4.14). `check_storage(data)` also refuses
  a market schedule whose own energy, `e_n = e_{n-1} + Δt(η_chg max(-p_set, 0) - max(p_set, 0)/η_dch)` from `e_init`, leaves `[e_min, e_max]`: a redispatch repairs it at its
  prices and books the bill as redispatch (Evidence). The exported helper `scheduled_energy(data, u)` returns that trajectory, a `NetworkVector` over `:time`.
- **Fields.** `e_min` (default 0, the lower bound of `e_stor`); `c_chg` and `c_dch` replace `c_thru`, a hard removal (D59): both are charged in
  `dispatch_cost` and `redispatch_cost`, the exactness guard reads both. `NOM_FIELDS` gets `cost_throughput` to `c_dch`.
- **Verification.** `test/validation.jl`, one `@test_throws` per refusal and the bad value at one index of a `NetworkVector`. On the two-step
  arbitrage network (spread 90 per pu, 0.2 pu, free objective 4.0): `c_chg = 40` gives 12.0, `c_chg = c_dch = 40` gives 20.0, 50 and 50 give 22.0 (idle).
  A schedule discharging 0.3 for three steps from 0.5 (η 1) is refused at step 2 (energy 0.2, -0.1, -0.4), 0.1 for three steps is accepted (0.4, 0.3, 0.2); `c_up` 10 with `c_dn` -30 is refused.

## 2. Converter limit (B34, D73, v0.15.2)

- **Fix.** `s_max` (default `Inf`, no row). IVR, dispatch and redispatch: `cstr_stor_rating`, `(p_dch - p_chg)^2 + q_stor^2 <= s_max^2`, a nonconvex
  quadratic row in a formulation that already is one. LPF: `|p_dch - p_chg| <= s_max`, two linear rows. The box `q_min`, `q_max` stays. A linear
  formulation with reactive power, when it exists: the box only, the circle would make it a second-order cone program.
- **Literature.** Net circle: Zafar et al. 2020 Eq. 13g, Barrera-Singana et al. 2026 Eq. 24. Separate cones: Wang et al. 2023 Eq. 23-24, Liang et
  al. 2024 App. B. Fixed box: Jha et al. 2024 Eq. 11. Separate cones are the alternative if Tom prefers them in IVR.
- **Verification.** A unit with `s_max` below its ratings, q fixed at 0: `p_dch` stops at `s_max` in both formulations; no row at `Inf`; with q free
  the solution satisfies the circle to 1e-6.

## 3. `exact` (B35, D71, v0.15.3)

- **API.** `@enum Exclusion RELAXED EXACT FROZEN`, a field `exact` that takes an `Exclusion` or a `Bool` (`true` is `EXACT`) as `pst` takes a
  `TapMode`; `RELAXED` by default; `exact` goes into `NOM_WORDS`. `FROZEN` (D78) is the iterative fixing above: each violating unit-step has the
  direction of its net power fixed and the model is solved again, feasible and not optimal.
- **Fix.** RELAXED builds what it builds today. EXACT: after a solve a hook `refine!` (called by `optimize_model!` as `solution_processors` are)
  adds a hull row for the unit and a binary `z_stor` with two big-M rows for each unit-step whose `p_chg·p_dch/(p_chg_max·p_dch_max)` is above 1e-5,
  solves again, and repeats until none is left (at most 8 rounds, then an error). A refined model is mixed-integer: no duals, Juniper in IVR; a
  roll rebuilds a window that refined. The gap is a solution key and in `print_summary`. `_warn_free_cycling` becomes the price guard
  `η_c c_dch + c_chg/η_d >= (1/η_d - η_c)|λ_floor|` with `λ_floor` the most negative price a `Spill` or a generator sets, saying that a
  cycle limit bounds the artefact and does not remove it. The docstring and `storage.md` stop saying simultaneous operation is never worth it.
- **Literature.** Binaries on every counted change are the slow form in a redispatch too: the thesis's change-counting recovery model R1 took 375 s and 859 s on two cases and
  hit the 1800 s limit on two, gaps 16.67 % and 10.91 %, against 9.4, 2.3, 66.6 and 82.4 s for the continuous R2 (Table 4.13, p.104); lazy binaries add only the violating ones.
- **Verification.** The three-step network: 393.00 and 426.54 (RELAXED, EXACT), 441.60 and 446.54 at `c_dch` 100, 450.00 at 130; the chain
  instance: EXACT equals binaries on every unit-step to 1e-9 with 36 binaries, FROZEN is feasible and within 1 % of EXACT.

## 4. Terminal conditions (B36, D72, D85, v0.15.4)

- **API.** `terminal = [Floor(0.1), Value(90.0)]`: any combination of `Pin(e)`, `Cyclic()`, `Floor(e)`, `Value(c)`, `Soft(e; c_up, c_dn)`, `Quad(e;
  weight)`; `e_fin` stays as `Pin(e_fin)`. `Cyclic` is written as `Pin(e_init)` when built, since `initial_state` replaces `e_init` in each window.
  `fnct_stor_terminal!` has one method per type, so an extension subtypes `AbstractTerminal`. Refused: `Pin` with `Cyclic`, a cost type with `Pin`,
  two cost types, a floor above the pin.
- **Roll.** `Pin`, `Cyclic` and `Floor` are about the end of the problem: `interior_state` drops them. `Value`, `Soft` and `Quad` apply at the end of
  every window, which is what stops the drain (Marley and Hiskens p.3); `e` may be a profile over `:time`, read at the last index of the window.
- **Literature.** Pin: Wang 2013, Felder and Hiskens. Cyclic: Wang 2023, Barrera, Zafar, Jha. Floor: Li 2016, Liang 2024. Value: Chandy 2010.
  Quad: Marley and Hiskens Eq. 1a, 2. Soft is the `soft_target` of `zorba-integration.md`.
- **Decided (D85).** The natural target of a redispatch is the energy the market schedule leaves (Dratsas et al. 2024 restores the scheduled state of charge by rule,
  p.4-5; Lindner et al. 2023 and Qin et al. 2025 state no end energy, p.4 and p.2): `scheduled_energy(data, u)` of item 1, a profile over `:time`, is accepted as the
  target of `Pin`, `Soft` and `Quad`; no new terminal type.
- **Verification.** The roll above with `Value(95.0)`: extra cost about 0 at horizons 2 to 5; with `Value(500.0)` the unit holds its energy and the
  extra cost is above 0. The three-step network keeps its numbers ([0.4, 0.2, 0.0] free, 14.0 pinned at 0.2). The radial redispatch of `test/rd.jl` (2 steps, battery 0.25 pu·h
  from 0.25, free): 85.0 with no end condition (`e_stor` [0.25, 0.0]), 110.0 ending on the scheduled 0.25 ([0.25, 0.25]).

## 5. Outages (B37, D76, v0.15.5)

- **Fix.** A unit out of service has no variables; `energy_at(nm, u, n)` returns the state at `n`, or at the last in-service index before it, or
  `e_init`; the balance, `Pin`, `Floor`, `Cyclic`, `Soft` and `initial_state` read through it. `_warn_free_cycling`'s replacement scans every index.
  Held energy means no self-discharge: D77. The solution has no row for a step out of service.
- **Hazard.** `initial_state` reads `e_stor` at the committed index; out of service it would return the original `e_init` and refill the unit
  across a window boundary. Own test.
- **Contingency.** A `status` over `:contingency` fails the same way (Evidence) and is how an N-1 that loses the unit is posed: the unit has no variables there,
  `fnct_rd_control` already skips an out-of-service measure, and `energy_at` returns `e_init` for the whole contingency. The acceptance test adds that case.
- **Verification.** A `status` outage over steps 2-3 reproduces the zero-rating run above: objective 28.216, e_stor 0.0205 across the gap, also
  when a roll boundary falls inside the gap.

## 6. Cycles (B38, D79 to D82, v0.15.6)

- **Today.** A cycle is the energy a unit delivers (`p_dch·Δt`) over `e_max`; `k_cycl_max` is one row per calendar period of `period_ids`; `c_cycl` prices
  the same quantity (`storage.jl:394`, `:422`, `:524`). The row is not carried across the windows of a roll (Evidence), and `Generator.e_per_max` has the same defect.
- **Fix, storage.** The count covers both sides (D81): `d_n = Δt_n·(η_chg·p_chg,n + p_dch,n/η_dch)/2`, the energy into the store and the energy drawn from it, over `e_max`; a lossless full cycle counts 1. `k_cycl_max` holds over any sliding 24 h window: for every
  index `n` of a unit with a finite limit, the `d_m` of the steps in the 24 h up to the end of `n` sum to at most `k_cycl_max·e_max` (read at `n`), per contingency.
  Either 24 h/`Δt` terms a row or a running sum with two terms a row: pick by a timing on a year of 15-minute steps. A roll hands on the trailing 24 h of `d`
  through `initial_state`, a vector in step order (zeros at the start of a problem), which the rows of the first indices of a window read as constants.
- **Decided (D82).** `c_cycl` is linear in the same count and needs no period, so it is charged per index and `storage_cycles` and the storage `period_cost`
  go (the horizon-term test of `test/hierarchy.jl` changes). `Generator.e_per_max` keeps its calendar period and carries the energy used in the period of the
  first index of the next window through `initial_state`; the sliding window is for storage only.
- **Control mode.** A held (preventive) unit writes the sliding rows at the base case only, as `fnct_rd_control` says of every row that only restricts a held measure
  (3 rows for 1 needed today, Evidence); a corrective unit writes them at every contingency. The carried vector is the base case's: `_carry_state!` reads the base case at the
  last committed step, corrective units included, since a contingency has not happened.
- **Pipeline.** Independent chunks start with zero history, so the limit does not hold across a chunk boundary unless the pipeline passes the vector on.
- **Verification.** Eight steps of 6 h, prices alternating, `k_cycl_max` 0.2, `e_max` 0.5, η 1 (0.1 pu·h counted per 24 h): the largest count over any four
  consecutive steps is at most 0.1 in one problem and in rolls of horizon 2 step 2, horizon 4 step 2 and horizon 2 step 1 (0.2 against 0.1 a period before); at η 0.9 the count, not the delivered energy, stays within it; a
  generator with `e_per_max` 0.3: 0.6 in total at horizon 2 step 2 (1.2 before); a market schedule over the budget is refused before the build, naming the unit.

## 7. Corrective range (B40, D86, v0.15.7)

- **Fix.** A field `h_cur` [h], default 0 (no row), at least 0; its name needs the symbol `h` and the word `cur` in `test/nomenclature.jl` and `docs/src/manual/nomenclature.md` first.
  For a corrective unit with `h_cur > 0` in a problem with more than one `:contingency` coordinate, `fnct_stor_range!` writes per time step two free variables `p_stor_max`,
  `p_stor_min` and, for every contingency coordinate with the base case, `p_stor_min <= p_dch - p_chg <= p_stor_max`, then `p_stor_max - p_stor_min <= e_max/h_cur` (`e_max` read
  at the step), key `cstr_stor_range`. A preventive unit gets no row: its net power is the same in every state.
- **Meaning.** Lindner et al. 2023 (Eq. 40-42, p.8) hold a booster's curative set points in one band of width `W_max/t_GB`, so that one pre-positioned state of charge serves whichever
  contingency occurs. The base case is in the band, so the unit may centre it by moving its base-case output; the per-contingency trajectories stay untied. `e_min` is another thing, a floor in every state.
- **Verification.** One step, three contingencies (three parallel branches of 0.4 into a load of 1.0, branch 3 out in the second, branches 2 and 3 in the third), a free unit of 0.5 pu·h
  behind them, every measure corrective: no row 6.0 with net power [0.0, 0.2, 0.5]; `h_cur` 2 (range 0.25) 7.0 with [0.25, 0.25, 0.5]; `h_cur` 1 6.0 as without; `e_max` 0.8 and `h_cur` 2
  (range 0.4) 6.3333 with [0.1, 0.2, 0.5]; the default `:preventive` control writes no row.

## 8. Notes (B39, D77, no version)

- Later (B39, D77): detailed battery physics, self-discharge and a ramp limit (Qin et al. 2025 Eq. 4, 12). Not planned: Qin's binary per redispatch action (`c_up` and `c_dn` are the continuous form of
  the thesis's R2) and a group cap on summed energy (Balzer and Watts 2024 Eq. 16-17, p.8; `e_per_max` caps one unit). None of the six redispatch sources bounds or prices cycles or throughput; Barrera et al. 2026 price both sides (D74).

## What this deliberately does not decide

Q11, the Zorba throughput cap; a lifetime or degradation cost beyond `c_dch`, `c_chg` and `c_cycl`; a ramp limit; storage groups that net to
zero (Lindner's virtual power line).
