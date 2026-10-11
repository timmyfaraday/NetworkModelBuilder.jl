# Nomenclature for variables and parameters

Status: decided (D55-D60), spellings marked `?` wait for Tom's review of the map · Owner: Tom Van Acker · Date: 2026-10-11
Scope: quantities, i.e. component fields (the parameters, and the columns of a table), variable keys, solution keys, and the
keywords and parameters that name one. Not yet: constraints (their own step), function names, plain words.
Plan: `plan/naming.md`. The docs page `docs/src/manual/nomenclature.md` is written from this file.

## Grammar (D55)

`<symbol>[_<primary>][_<secondary>][_<unit>]`: lowercase, snake_case, singular, a descriptor of at most 4 letters taken from the
lists below. An empty slot is dropped. The classes are disjoint, so the position of a descriptor is recoverable: `max` is only
ever secondary, `real` only primary, `kv` only a unit. ASCII, except the Greek symbol `η` (checked: a valid identifier, stable
under NFC, a field, a keyword and an Arrow or Parquet column, read back by Julia and by `pyarrow`).

- **Symbol:** the quantity, one letter. `v` voltage, `i` current, `p` active power, `q` reactive power, `s` apparent power,
  `r` resistance, `x` reactance, `g` conductance, `b` susceptance, `e` energy, `t` ratio of a winding, `c` cost or price,
  `l` length, `z` a binary decision, `k` a count, `η` efficiency (D56). An index letter (`i e u a n k t`) is never a quantity,
  so a symbol may share its letter: `i_term_real` is a current, `i` in `for i in I` is a node.
- **Primary:** what part or whose. A part `real imag magn angl`; a location `term ser shnt mgnt star pnt wind`; an owner
  `gen stor flex slk dcl sw unit`; a role `chg dch dem loss base ovl cycl per step`.
- **Secondary:** a qualifier. A bound `min max`; a reference `set init fin nom mkt`; a direction `up dn`; `fix prop thru peak step`.
- **Unit:** last slot, only where the quantity is not in pu or rad: `kv mva km`.
- **Words:** what is not a quantity stays a plain word: `id name node terminals status ext type area zone lock position reverse oltc pst`.

## Fields and keys (D57, D58)

- A **key** names the owner, because keys share one dictionary per network index: `:p_gen`, `:p_stor_up`, `:p_term`. A role that
  only one owner has says it instead: `:p_chg`, `:p_dch` (storage).
- A **field** does not, the type says whose it is: `Generator.p_max`, `Storage.p_chg_max`, `Switch.s_max`.
- A **local** in an equation is named as its key: `v_real, v_imag = var(nm, :v_real; nw), var(nm, :v_imag; nw)`. The component
  locals stay `br tf dl sw ld st`, the indices `i e u a t k n`.
- Matpower, PowerModels and Zorba names live at the reader boundary only; inside the package the names below.
- `v_angl_min` and `v_angl_max` on an edge limit the voltage angle **difference** across it; the docs index says so.
- `s_max` bounds apparent power, which is active power wherever no reactive power exists: a `DCLink`, and the linearized model.
- In the docs mathematics current is `i` and cost is `c` (D56); the node index `i` keeps its letter.

## Fields, old to new (D58)

| type | rename |
|:--|:--|
| `Node` | `vm` `v_magn_set`?, `va` `v_angl_set`?, `vmin` `v_magn_min`, `vmax` `v_magn_max`, `base_kv` `v_base_kv` |
| `Generator` | `pg` `p_set`, `qg` `q_set`, `pmin` `p_min`, `pmax` `p_max`, `qmin` `q_min`, `qmax` `q_max`, `vg` `v_magn_set`?, `max_energy_per_period` `e_per_max`?, `cost` `c`, `cost_up` `c_up`, `cost_dn` `c_dn` |
| `FixedLoad` | `pd` `p_set`?, `qd` `q_set`? |
| `FlexibleLoad` | `pd_nominal` `p_nom`, `qd_nominal` `q_nom`, `pd_min` `p_min`, `pd_max` `p_max`, `energy` `e_set`? |
| `Shunt` | `gs` `g`, `bs` `b` |
| `Storage` | `ps` `p_set`, `qs` `q_set`, `qmin` `q_min`, `qmax` `q_max`, `energy_capacity` `e_max`, `energy_initial` `e_init`, `energy_final` `e_fin`, `charge_rating` `p_chg_max`, `discharge_rating` `p_dch_max`, `charge_efficiency` `η_chg`, `discharge_efficiency` `η_dch`, `max_cycles_per_period` `k_cycl_max`?, `cost_throughput` `c_thru`, `cost_cycle` `c_cycl`, `cost_up` `c_up`, `cost_dn` `c_dn` |
| `EnergyNotServed`, `Spill` | `pmax` `p_max`, `cost` `c` |
| `DCLink` | `rate_a` `s_max`, `loss_fixed` `p_loss_fix`, `loss_prop` `p_loss_prop`?, `pdc` `p_set`, `cost` `c` |
| `Switch` | `rate_a` `s_max`, `angmin` `v_angl_min`, `angmax` `v_angl_max` |
| `Branch` | `g_sh` `g_shnt`, `b_sh` `b_shnt`, `rate_a` `s_max`, `angmin` `v_angl_min`, `angmax` `v_angl_max`, `length_km` `l_km` |
| `Transformer` | `g_sh` `g_shnt`, `b_sh` `b_shnt`, `g_m` `g_mgnt`, `b_m` `b_mgnt`, `tm` `t_magn`, `ta` `t_angl`, `tm_min` `t_magn_min`, `tm_max` `t_magn_max`, `ta_min` `t_angl_min`, `ta_max` `t_angl_max`, `tm_step` `t_magn_step`, `ta_step` `t_angl_step`, `rate_a` `s_max`, `angmin` `v_angl_min`, `angmax` `v_angl_max` |
| `NetworkData` | `baseMVA` `s_base_mva`, also the accessor `baseMVA(data)` and the keyword of `parse_tables`, `parse_zorba` |
| `OverloadPrice` | `per_energy` `c_ener`?, `per_peak` `c_peak`? |

`r`, `x` and the words above do not change. `Zorba` adapter keywords (`overload_penalty`, `wiggle_room`, `contingency_weight`,
`hvdc`, `grid`) follow Zorba's vocabulary and stay.

## Variable keys, old to new

| owner | rename |
|:--|:--|
| node | `:vr` `:v_real`, `:vi` `:v_imag`, `:va` `:v_angl` |
| arc | `:cr` `:i_term_real`, `:ci` `:i_term_imag`, `:p` `:p_term` |
| branch | `:csr` `:i_ser_real`, `:csi` `:i_ser_imag`, `:vpr` `:v_pnt_real`, `:vpi` `:v_pnt_imag`, `:vap` `:v_pnt_angl` |
| transformer | `:vsr` `:v_star_real`, `:vsi` `:v_star_imag`, `:vas` `:v_star_angl`, `:vtr` `:v_wind_real`, `:vti` `:v_wind_imag`, `:tr` `:t_real`, `:ti` `:t_imag`, `:tm` `:t_magn`, `:ta` `:t_angl`, `:zt` `:z_step`? |
| edge | `:ol` `:s_ovl`?, `:olp` `:s_ovl_peak`?, `:zsw` `:z_sw`? |
| `DCLink` | `:pdct` `:p_dcl_thru`, `:pdcup` `:p_dcl_up`, `:pdcdn` `:p_dcl_dn` |
| unit | `:cru` `:i_unit_real`, `:ciu` `:i_unit_imag`, `:pu` `:p_unit` |
| `Generator` | `:pg` `:p_gen`, `:qg` `:q_gen`, `:pgup` `:p_gen_up`, `:pgdn` `:p_gen_dn` |
| `Storage` | `:psc` `:p_chg`, `:psd` `:p_dch`, `:es` `:e_stor`, `:qs` `:q_stor`, `:psup` `:p_stor_up`, `:psdn` `:p_stor_dn` |
| other units | `:pdf` `:p_flex`, `:psl` `:p_slk` |

## Solution keys

A solution key is the variable key where there is one: `"vr"` `"v_real"`, `"pg"` `"p_gen"`, `"psc"` `"p_chg"`. Besides: node `"vm"`
`"v_magn"`, `"va"` `"v_angl"`; terminal `"p"`, `"q"`, `"cr"`, `"ci"` `"p_term"`, `"q_term"`, `"i_term_real"`, `"i_term_imag"`; unit
`"p"`, `"q"` `"p_unit"`, `"q_unit"`; an echoed parameter takes its field name (`"pd"` `"p_set"`, `"gs"` `"g"`); `"overload"`
`"s_ovl"`, `"loss"` `"p_loss"`; the tap `"tr" "ti" "tm" "ta"` `"t_real" "t_imag" "t_magn" "t_angl"`; every `*_market` `*_mkt`
(`"pg_market"` `"p_gen_mkt"`, `"tm_market"` `"t_magn_mkt"`). The duals `"lambda*"`, the words and the dashboard names (D9) stay.

## To confirm (`?` above)

`v_magn_set`, `v_angl_set` for the setpoints a node and a generator carry; `p_set` for the power a fixed load withdraws, as
generator, storage and DC link have one; `e_per_max` and `k_cycl_max` for a limit per period; `p_loss_prop` for a loss that is a
fraction; `e_set` for the energy a flexible load must receive; `c_ener`, `c_peak` for an overload price; `:s_ovl`, `:s_ovl_peak`,
`:z_sw`, `:z_step` for an overload, a switch position and a tap position.
