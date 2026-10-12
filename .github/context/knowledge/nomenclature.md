# Nomenclature for variables and parameters

Status: decided (D55-D62), the map confirmed by Tom 2026-10-11 · Owner: Tom Van Acker · Date: 2026-10-11
Scope: quantities, i.e. component fields (the parameters, and the columns of a table), variable keys, solution keys, and the
keywords and parameters that name one. Constraints, functions and duals are the last section (D63-D70, confirmed by Tom 2026-10-11); not covered: plain words.
Plan: `plan/naming.md`. The docs page `docs/src/manual/nomenclature.md` is written from this file.

## Grammar (D55)

`<symbol>[_<primary>][_<secondary>][_<unit>]`: lowercase, snake_case, singular, a descriptor of at most 4 letters taken from the
lists below. An empty slot is dropped. The lists are disjoint and used in a fixed order, a what, then a part, then a qualifier,
at most two of them: the first is the primary, the second the secondary (`v_magn_max`: part, qualifier; `i_ser_real`: what, part).
A unit comes last. ASCII, except the Greek symbol `η` (checked: a valid identifier, stable
under NFC, a field, a keyword and an Arrow or Parquet column, read back by Julia and by `pyarrow`). `test/nomenclature.jl` is this
grammar as code.

- **Symbol:** the quantity, one letter. `v` voltage, `i` current, `p` active power, `q` reactive power, `s` apparent power,
  `r` resistance, `x` reactance, `g` conductance, `b` susceptance, `e` energy, `t` ratio of a winding, `c` cost or price,
  `l` length, `z` a binary decision, `k` a count, `η` efficiency (D56). An index letter (`i e u a n k t`) is never a quantity,
  so a symbol may share its letter: `i_term_real` is a current, `i` in `for i in I` is a node.
- **Primary:** what, or which part. A location `term ser shnt mgnt star pnt wind`; an owner `gen stor flex slk dcl sw unit`; a role
  `chg dch loss base ovl cycl per`; or, where nothing says what, a part `real imag magn angl`.
- **Secondary:** after a what, a part; otherwise a qualifier. A bound `min max`; a reference `set init fin nom mkt`; a direction
  `up dn`; a kind `fix prop thru peak step ener`.
- **Unit:** last slot, only where the quantity is not in pu or rad: `kv mva km`.
- **Words:** what is not a quantity stays a plain word: `id name node terminals status ext type area zone lock position reverse oltc pst exact`.

## Fields and keys (D57, D58)

- A **key** names the owner, because keys share one dictionary per network index: `:p_gen`, `:p_stor_up`, `:p_term`. A role that
  only one owner has says it instead: `:p_chg`, `:p_dch` (storage). A key carries at least one descriptor; only a field, or a
  solution key that echoes one (`"g"`, `"b"`), is a bare symbol.
- A **field** does not, the type says whose it is: `Generator.p_max`, `Storage.p_chg_max`, `Switch.s_max`.
- A **local** in an equation is named as its key: `v_real, v_imag = var(nm, :v_real; nw), var(nm, :v_imag; nw)`. The component
  locals stay `br tf dl sw ld st`, the indices `i e u a t k n`. A scalar read out of such a container in a solution builder
  (`vr = JuMP.value(v_real[i])`) keeps its short name, the container has the key's.
- Matpower, PowerModels and Zorba names live at the reader boundary only; inside the package the names below.
- A key of `ext` the package reads for a quantity follows the grammar (D62): `:v_real_init`, `:v_imag_init`, `:v_angl_init` of a
  node (old `:vr_start`, `:vi_start`, `:va_start`). Keys that are not quantities (`:source_id`, `:country`, `:zorba`) stay words.
- `v_angl_min` and `v_angl_max` on an edge limit the voltage angle **difference** across it; the docs index says so.
- `s_max` bounds apparent power, which is active power wherever no reactive power exists: a `DCLink`, and the linearized model.
- In the docs mathematics current is `i` and cost is `c` (D56); the node index `i` keeps its letter.

## Fields, old to new (D58)

| type | rename |
|:--|:--|
| `Node` | `vm` `v_magn_set`, `va` `v_angl_set`, `vmin` `v_magn_min`, `vmax` `v_magn_max`, `base_kv` `v_base_kv` |
| `Generator` | `pg` `p_set`, `qg` `q_set`, `pmin` `p_min`, `pmax` `p_max`, `qmin` `q_min`, `qmax` `q_max`, `vg` `v_magn_set`, `max_energy_per_period` `e_per_max`, `cost` `c`, `cost_up` `c_up`, `cost_dn` `c_dn` |
| `FixedLoad` | `pd` `p_set`, `qd` `q_set` |
| `FlexibleLoad` | `pd_nominal` `p_nom`, `qd_nominal` `q_nom`, `pd_min` `p_min`, `pd_max` `p_max`, `energy` `e_set` |
| `Shunt` | `gs` `g`, `bs` `b` |
| `Storage` | `ps` `p_set`, `qs` `q_set`, `qmin` `q_min`, `qmax` `q_max`, `energy_capacity` `e_max`, `energy_initial` `e_init`, `energy_final` `e_fin`, `charge_rating` `p_chg_max`, `discharge_rating` `p_dch_max`, `charge_efficiency` `η_chg`, `discharge_efficiency` `η_dch`, `max_cycles_per_period` `k_cycl_max`, `cost_throughput` `c_dch`, `c_thru` `c_dch`, `cost_cycle` `c_cycl`, `cost_up` `c_up`, `cost_dn` `c_dn` |
| `EnergyNotServed`, `Spill` | `pmax` `p_max`, `cost` `c` |
| `DCLink` | `rate_a` `s_max`, `loss_fixed` `p_loss_fix`, `loss_prop` `p_loss_prop`, `pdc` `p_set`, `cost` `c` |
| `Switch` | `rate_a` `s_max`, `angmin` `v_angl_min`, `angmax` `v_angl_max` |
| `Branch` | `g_sh` `g_shnt`, `b_sh` `b_shnt`, `rate_a` `s_max`, `angmin` `v_angl_min`, `angmax` `v_angl_max`, `length_km` `l_km` |
| `Transformer` | `g_sh` `g_shnt`, `b_sh` `b_shnt`, `g_m` `g_mgnt`, `b_m` `b_mgnt`, `tm` `t_magn`, `ta` `t_angl`, `tm_min` `t_magn_min`, `tm_max` `t_magn_max`, `ta_min` `t_angl_min`, `ta_max` `t_angl_max`, `tm_step` `t_magn_step`, `ta_step` `t_angl_step`, `rate_a` `s_max`, `angmin` `v_angl_min`, `angmax` `v_angl_max` |
| `NetworkData` | `baseMVA` `s_base_mva`, also the accessor `baseMVA(data)` and the keyword of `parse_tables`, `parse_zorba` |
| `OverloadPrice` | `per_energy` `c_ener`, `per_peak` `c_peak` |

`r`, `x` and the words above do not change. `Zorba` adapter keywords (`overload_penalty`, `wiggle_room`, `contingency_weight`,
`hvdc`, `grid`) follow Zorba's vocabulary and stay.

Two types may share a new name: a generator's `pg`, a fixed load's `pd` and a storage unit's `ps` are all `p_set`, so a unit table
has one `p_set` column for all of them. The readers keep the names of what they read: the `baseMVA` key and local of Matpower, its
`pd`, `qd`, `gs`, `bs`, the `cost` column of Zorba's `hvdc` table and the `energy_capacity` column of the steering plan's CSV; the
exemptions of `test/nomenclature.jl` list them.

## Variable keys, old to new

| owner | rename |
|:--|:--|
| node | `:vr` `:v_real`, `:vi` `:v_imag`, `:va` `:v_angl` |
| arc | `:cr` `:i_term_real`, `:ci` `:i_term_imag`, `:p` `:p_term` |
| branch | `:csr` `:i_ser_real`, `:csi` `:i_ser_imag`, `:vpr` `:v_pnt_real`, `:vpi` `:v_pnt_imag`, `:vap` `:v_pnt_angl` |
| transformer | `:vsr` `:v_star_real`, `:vsi` `:v_star_imag`, `:vas` `:v_star_angl`, `:vtr` `:v_wind_real`, `:vti` `:v_wind_imag`, `:tr` `:t_real`, `:ti` `:t_imag`, `:tm` `:t_magn`, `:ta` `:t_angl`, `:zt` `:z_step` |
| edge | `:ol` `:s_ovl`, `:olp` `:s_ovl_peak`, `:zsw` `:z_sw` |
| `DCLink` | `:pdct` `:p_dcl_thru`, `:pdcup` `:p_dcl_up`, `:pdcdn` `:p_dcl_dn` |
| unit | `:cru` `:i_unit_real`, `:ciu` `:i_unit_imag`, `:pu` `:p_unit` |
| `Generator` | `:pg` `:p_gen`, `:qg` `:q_gen`, `:pgup` `:p_gen_up`, `:pgdn` `:p_gen_dn` |
| `Storage` | `:psc` `:p_chg`, `:psd` `:p_dch`, `:es` `:e_stor`, `:qs` `:q_stor`, `:psup` `:p_stor_up`, `:psdn` `:p_stor_dn` |
| other units | `:pdf` `:p_flex`, `:psl` `:p_slk` |

## Solution keys

A solution key is the variable key where there is one: `"vr"` `"v_real"`, `"pg"` `"p_gen"`, `"psc"` `"p_chg"`. Besides: node `"vm"`
`"v_magn"`, `"va"` `"v_angl"`; terminal `"p"`, `"q"`, `"cr"`, `"ci"` `"p_term"`, `"q_term"`, `"i_term_real"`, `"i_term_imag"`; unit
`"p"`, `"q"` `"p_unit"`, `"q_unit"`; an echoed parameter takes its field name (`"pd"` `"p_set"`, `"gs"` `"g"`); `"overload"`
`"s_ovl"`, `"loss"` `"p_loss"`; a DC link's `"pdc"` `"p_dcl"`; the tap `"tr" "ti" "tm" "ta"` `"t_real" "t_imag" "t_magn" "t_angl"`
and its `"step"` `"z_step"`; every `*_market` `*_mkt`
(`"pg_market"` `"p_gen_mkt"`, `"tm_market"` `"t_magn_mkt"`). The duals are `dual_node_balance_*` (D68); the words and the dashboard names (D9) stay.
`test/nomenclature.jl` holds this map as data.

## Constraints, functions and duals (D63-D70, confirmed by Tom 2026-10-11)

A constraint, the function that writes it and the dual it gives share one stem, `<owner>_<role>`, and take one prefix each: the key `cstr_<stem>`, the
function `fnct_<stem>`, the dual `dual_<stem>`, as in `cstr_node_balance`, `fnct_node_balance`, `dual_node_balance_real`. `test/nomenclature.jl` is it as code.

- **Owner:** who writes the row: a family `node edge unit`, a type `br tf dcl sw gen stor flex shnt` (the descriptors of the quantities where there is
  one, the component locals `br tf` where not), or the problem `rd`. The family where several types write the row (D51), the type where one does.
- **Role:** what the row states, one or two of `balance reference setpoint anchor limit range rating overload peak angle difference voltage current
  flow power injection energy final cycle redispatch control equation open loop winding ratio tap step setting star pi section point exclusion`.
- **No formulation in a key**, as `:p_term` has none: `cstr_edge_rating` is the rating in IVR and in LPF, with the id shape of its formulation. A function
  written for the linearized formulation only keeps `linear`: `fnct_edge_rating_linear`.
- **Id:** the component's id, or `(id, part...)`, a part one of `real imag magn angl min max fr to ser set loss forward reverse pos neg side p q chg dch`.
  A nested tuple of edges names a loop, `(family, sub, key)` a control. One shape per key within a formulation: an IVR row carries the phasor part where
  an LPF row has none, and a row that is two-sided in one is a single row in the other (D70).
- **`con`** takes the register's key where an entry holds the rows of one key; a bundle of several takes an owner and `equation` or `limit`
  (`cstr_br_equation`, `cstr_sw_equation`, `cstr_edge_limit`). Its ids stay component ids, its value a row, or a tuple of rows in the order of the register's id parts:
  `con[:cstr_node_balance][i]` is `(real, imag)` in IVR.

New keys are `cstr_` and the stem shown; old keys are as written in `src/` today.

| owner | register key, old `new stem` |
|:--|:--|
| `node` | `node_balance` `node_balance`, `node_reference` `node_voltage_reference`, `node_setpoint` `node_voltage_setpoint`, `node_limits` `node_voltage_limit`, `node_anchor` `node_voltage_anchor` |
| `edge` | `edge_rating`, `linear_rating` `edge_rating`; `edge_overload`, `linear_overload` `edge_overload`; `edge_angle`, `linear_angle` `edge_angle_difference`; `linear_flow` `edge_flow`; `overload_peak` `edge_overload_peak` |
| `br`, `tf`, `dcl` | `pi_section` `br_pi_section`, `branch_section` `br_section`, `branch_point` `br_point`; `winding` `tf_winding`, `star_balance` `tf_star_balance`, `transformer_ratio` `tf_ratio`, `tap_step` `tf_tap_step`, `tap_setting` `tf_tap_setting`; `dc_link` `dcl_power`, `dc_link_limits` `dcl_limit`, `dc_link_redispatch` `dcl_redispatch` |
| `sw` | `switch_flow`, `_open`, `_angle`, `_loop`, `_cycle`, `_rating`, `_voltage`, `_angle_range`, `_flow_range`, `_voltage_range`, `_current_range`: `switch_` becomes `sw_` |
| `unit`, `gen`, `flex`, `shnt`, `stor`, `rd` | `unit_power`, `unit_injection` stay; `generator_energy` `gen_energy`, `generator_redispatch` `gen_redispatch`, `flexible_energy` `flex_energy`, `shunt_current` `shnt_current`, `storage_balance` `stor_balance`, `storage_final` `stor_final_energy`, `storage_cycles` `stor_cycle`, `storage_redispatch` `stor_redispatch`, `redispatch_control` `rd_control` |

`con` keys that are not a register key: `branch` `br_equation`, `switch` `sw_equation`, `edge_limits` `edge_limit`, `switch_limits` `sw_rating`, `switch_loop_free` `sw_cycle`,
`generator_power`, `load_power`, `slack_power`, `storage_power` `unit_power` (`unit_injection` in LPF), `node_balance_real`, `node_balance_imag` `node_balance`,
`node_voltage_limits` `node_voltage_limit`; `edge_angle_difference`, `node_voltage_*` and the rest keep their stem.

Ids that change: `:pi_section` `(e, :cr_fr)`, `:ci_fr`, `:cr_to`, `:ci_to`, `:v_real`, `:v_imag` become `(e, :fr, :real)`, `(e, :fr, :imag)`, `(e, :to, :real)`, `(e, :to, :imag)`,
`(e, :ser, :real)`, `(e, :ser, :imag)`; `:tap_setting` `:magnitude_max`, `:magnitude_min`, `:magnitude`, `:max`, `:min` become `(a, :magn, :max)`, `(a, :magn, :min)`, `(a, :magn, :set)`, `(a, :angl, :max)`,
`(a, :angl, :min)`; `:angle` `:angl`; `:from` `:fr`; `:setpoint` `:set`; `:active`, `:reactive` `:p`, `:q`. The shape of an id is fixed per key and formulation.

Functions, old `constraint_` to `fnct_`: `edge` `edge`, `edge_limits` `edge_limit`, `edge_coupling`, `edge_rating`, `edge_angle_difference` keep their stem; `linear_flow` `edge_flow_linear`, `linear_ratings`
`edge_rating_linear`, `linear_angle_difference` `edge_angle_difference_linear`; `node_balance`, `node_voltage_reference`, `_setpoint`, `_anchor` keep theirs, `node_voltage_limits` `node_voltage_limit`;
`pi_section` `br_pi_section`; `overload_peak` `edge_overload_peak`; `redispatch_control` `rd_control`; `storage_final_energy` `stor_final_energy`, `storage_cycles` `stor_cycle`; `unit`, `unit_coupling`,
`unit_power`, `unit_injection` keep theirs. `edge`, `unit` and the `*_coupling` and `edge_limit` ones walk a registry and write the rows of every type.

Duals: `"lambda"` `dual_node_balance_p`, `"lambda_q"` `dual_node_balance_q`, `"lambda_real"` `dual_node_balance_real`, `"lambda_imag"` `dual_node_balance_imag`; the sign stays (a price is minus the dual).
`"dual_status"` is JuMP's own word and stays. Old letters of a parameter or a local: `ctr cti vtr vti` `i_wind_real i_wind_imag v_wind_real v_wind_imag`, `csr csi` `i_ser_real i_ser_imag`,
`cru ciu` `i_real i_imag` (scalars read out of the containers `i_unit_real`, `i_unit_imag`), each where it does not clash with a container local of the same function.

Owners are the descriptors of the quantities (`stor`, `sw`, `gen`), as Tom chose on 2026-10-11 over the type's own word (`storage`, `switch`, `generator`).
