# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Versions before 0.9.1 were never tagged in git; the version numbers and dates
below are reconstructed from `Project.toml`'s own history, cross-referenced
against the per-file changelog comments the source already carries.

## [0.15.3] - 2026-10-12

### Changed

- **Breaking.** The `s_max` of a `Storage` is positive: the constructor refuses zero, at any network index, and
  names `status` as the way to take a unit out of service.

## [0.15.2] - 2026-10-12

### Added

- `s_max` on `Storage`, the rating of the converter the unit sits behind, `Inf` by default. Where it is
  finite, `IVRFormulation` keeps the net injection and the reactive power inside the circle
  `(p^sd - p^sc)^2 + q^2 <= s_max^2`, and `LPFFormulation`, which has no reactive power, limits the net
  active power to `[-s_max, s_max]`. The rows are `:cstr_stor_rating`. A redispatch with a preventive
  setup writes the linearized rows at the base case only.
- The `Storage` constructor refuses a negative or undefined `s_max`.

### Changed

- A subtype of `AbstractStorage` carries an `s_max`, and `structure_gates` of a storage unit is `(:s_max,)`:
  a rating that is finite at one network index and `Inf` at another is a change of shape.

## [0.15.1] - 2026-10-12

### Added

- `e_min` on `Storage`, the energy a unit keeps in reserve: the lower bound of its state of charge, `0` by
  default.
- `c_chg` and `c_dch`, a price on what a storage unit charges and on what it discharges, each at its own
  price and both paid in a dispatch and in a redispatch.
- `check_storage(data)`, run by every model before it builds. It refuses, with an `ArgumentError` that
  names the unit and the network index, an `e_init` or an `e_fin` outside `[e_min, e_max]` at the index it is
  read at, and, in a redispatch, a market schedule whose own energy leaves the bounds or whose cycles
  exceed `k_cycl_max` over any 24 hours. A cycle counts half of what goes into the store and what comes out
  of it. `scheduled_energy(data, u)` returns the energy a schedule leaves, a `NetworkVector` over `:time`.
- The `Storage` constructor refuses a negative or undefined rating, a negative energy before the first step,
  a price that is negative or not finite, an `e_min` above `e_max`, and a pair `c_up`, `c_dn` that sums
  below zero, which would pay the solver to raise both volumes by the same amount.
- A note in the storage page on what a battery is not here, with the reference it leaves out.

### Changed

- **Breaking.** `c_thru` is replaced by `c_chg` and `c_dch`, with no alias and no hint: a `c_thru` of `x` is
  a `c_dch` of `x`. In a redispatch the throughput is charged on both sides, where it was charged on the
  discharge only. A subtype of `AbstractStorage` carries `e_min`, `c_chg` and `c_dch` in place of `c_thru`.
- The state of charge of a unit is bounded below by `e_min`, not by zero.
- `interior_state` and `initial_state` copy a storage unit by field name, so that a field added to `Storage`
  travels through a rolling horizon without a list being changed.

## [0.15.0] - 2026-10-11

### Added

- One grammar for the names of constraints, of the functions that write them and of the duals they give: a
  stem, `owner_role`, and one prefix each, `cstr_`, `fnct_` and `dual_`, as `cstr_node_balance`,
  `fnct_node_balance` and `dual_node_balance_real`. The manual's page `Nomenclature` has the rules.
- `test/nomenclature.jl` holds the maps and fails for a key, an id, a function or a dual that breaks the
  grammar, and for an old name written anywhere in `src`, `test`, `docs` or the README, the old letters
  of a parameter or a local included. `test/registers.jl` checks that a built model,
  current based or linearized, holds one id shape per key.
- Every solve takes `debug_mode = false`. With `true` every variable and every constraint is named from its
  network index, its key and its id, `1_p_gen[3]` and `1_cstr_node_balance[3,real]`, and
  `JuMP.set_string_names_on_creation` is switched on; by default nothing is named and it is switched off,
  whichever way the `jump_model` handed in was set. On the real step-3 window of the Zorba pipeline,
  249,118 variables and 274,523 constraints, `instantiate_model` takes 1,707 ms and 764 MB by default and
  2,401 ms and 1,372 MB in debug mode; the 274,523 names are distinct.

### Changed

- **Breaking.** The keys a constraint is registered under and the keys of `con` are `cstr_<owner>_<role>`,
  the functions that write constraints are `fnct_*` and the duals of a node are `dual_*`, with no alias and
  no hint. The tables below list every one. A key does not name the formulation, so the rating, the
  overload and the angle rows of the linearized formulation are written under the keys of the current
  based ones, with the id shape of their formulation.
- **Breaking.** Some words of a constraint id are spelled as the nomenclature spells a part: see the table
  of ids below.
- **Breaking.** The node balance of the current based formulation is one entry of `con`,
  `con(nm)[:cstr_node_balance][i]`, the pair of rows `(real, imag)`, where it was two entries,
  `:node_balance_real` and `:node_balance_imag`. The units of every type share `con[:cstr_unit_power]`, or
  `con[:cstr_unit_injection]` in the linearized formulation, where each type had a key of its own.
- **Breaking.** Variable names are off by default: `set_string_name = true` of 0.14.0 is `debug_mode = true`,
  with the default reversed. A `NetworkModel` has `debug_mode` where it had `string_names`.
- The parameters and locals that still carried an old letter are named as their key: `ctr`, `cti`, `vtr`,
  `vti` of the π-section are `i_wind_real`, `i_wind_imag`, `v_wind_real`, `v_wind_imag`, `csr` and `csi` are
  `i_ser_real` and `i_ser_imag`, and a scalar read out of `i_unit_real` is `i_real`.

### Removed

- **Breaking.** `set_string_name`, for `debug_mode`, and the `constraint_*` functions and the `"lambda*"`
  solution keys of the tables below.

### Migrating

#### Constraint keys

| owner | renamed |
|:------|:--------|
| node | `:node_balance` → `:cstr_node_balance`, `:node_reference` → `:cstr_node_voltage_reference`, `:node_setpoint` → `:cstr_node_voltage_setpoint`, `:node_limits` → `:cstr_node_voltage_limit`, `:node_anchor` → `:cstr_node_voltage_anchor` |
| edge | `:edge_rating` → `:cstr_edge_rating`, `:linear_rating` → `:cstr_edge_rating`, `:edge_overload` → `:cstr_edge_overload`, `:linear_overload` → `:cstr_edge_overload`, `:edge_angle` → `:cstr_edge_angle_difference`, `:linear_angle` → `:cstr_edge_angle_difference`, `:linear_flow` → `:cstr_edge_flow`, `:overload_peak` → `:cstr_edge_overload_peak` |
| unit | `:unit_power` → `:cstr_unit_power`, `:unit_injection` → `:cstr_unit_injection` |
| `br` | `:pi_section` → `:cstr_br_pi_section`, `:branch_section` → `:cstr_br_section`, `:branch_point` → `:cstr_br_point` |
| `tf` | `:winding` → `:cstr_tf_winding`, `:star_balance` → `:cstr_tf_star_balance`, `:transformer_ratio` → `:cstr_tf_ratio`, `:tap_step` → `:cstr_tf_tap_step`, `:tap_setting` → `:cstr_tf_tap_setting` |
| `dcl` | `:dc_link` → `:cstr_dcl_power`, `:dc_link_limits` → `:cstr_dcl_limit`, `:dc_link_redispatch` → `:cstr_dcl_redispatch` |
| `sw` | `:switch_flow` → `:cstr_sw_flow`, `:switch_open` → `:cstr_sw_open`, `:switch_angle` → `:cstr_sw_angle`, `:switch_loop` → `:cstr_sw_loop`, `:switch_angle_range` → `:cstr_sw_angle_range`, `:switch_flow_range` → `:cstr_sw_flow_range`, `:switch_cycle` → `:cstr_sw_cycle`, `:switch_rating` → `:cstr_sw_rating`, `:switch_voltage` → `:cstr_sw_voltage`, `:switch_voltage_range` → `:cstr_sw_voltage_range`, `:switch_current_range` → `:cstr_sw_current_range` |
| `gen` | `:generator_energy` → `:cstr_gen_energy`, `:generator_redispatch` → `:cstr_gen_redispatch` |
| `stor` | `:storage_balance` → `:cstr_stor_balance`, `:storage_final` → `:cstr_stor_final_energy`, `:storage_cycles` → `:cstr_stor_cycle`, `:storage_redispatch` → `:cstr_stor_redispatch` |
| `flex` | `:flexible_energy` → `:cstr_flex_energy` |
| `shnt` | `:shunt_current` → `:cstr_shnt_current` |
| `rd` | `:redispatch_control` → `:cstr_rd_control` |

#### Keys of `con`

| owner | renamed |
|:------|:--------|
| node | `:node_balance` → `:cstr_node_balance`, `:node_balance_real` → `:cstr_node_balance`, `:node_balance_imag` → `:cstr_node_balance`, `:node_voltage_anchor` → `:cstr_node_voltage_anchor`, `:node_voltage_limits` → `:cstr_node_voltage_limit`, `:node_voltage_reference` → `:cstr_node_voltage_reference`, `:node_voltage_setpoint` → `:cstr_node_voltage_setpoint` |
| edge | `:edge_angle_difference` → `:cstr_edge_angle_difference`, `:edge_limits` → `:cstr_edge_limit`, `:edge_rating` → `:cstr_edge_rating` |
| unit | `:generator_power` → `:cstr_unit_power`, `:load_power` → `:cstr_unit_power`, `:slack_power` → `:cstr_unit_power`, `:storage_power` → `:cstr_unit_power` |
| `br` | `:branch` → `:cstr_br_equation` |
| `tf` | `:star_balance` → `:cstr_tf_star_balance`, `:tap_setting` → `:cstr_tf_tap_setting`, `:tap_step` → `:cstr_tf_tap_step`, `:winding` → `:cstr_tf_winding` |
| `dcl` | `:dc_link` → `:cstr_dcl_power`, `:dc_link_limits` → `:cstr_dcl_limit`, `:dc_link_redispatch` → `:cstr_dcl_redispatch` |
| `sw` | `:switch` → `:cstr_sw_equation`, `:switch_limits` → `:cstr_sw_rating`, `:switch_loop_free` → `:cstr_sw_cycle` |
| `gen` | `:generator_redispatch` → `:cstr_gen_redispatch` |
| `stor` | `:storage_redispatch` → `:cstr_stor_redispatch` |
| `shnt` | `:shunt_current` → `:cstr_shnt_current` |

Several old keys give one new one: `:cstr_node_balance` for the two node balances of the current based
formulation, `:cstr_unit_power` for the four unit types, and the bundles `:cstr_edge_limit`,
`:cstr_br_equation` and `:cstr_sw_equation`, each of which holds the rows of several register keys.

#### Ids

| key | renamed |
|:----|:--------|
| `cstr_br_pi_section` | `(e, :cr_fr)` → `(e, :fr, :real)`, `(e, :ci_fr)` → `(e, :fr, :imag)`, `(e, :cr_to)` → `(e, :to, :real)`, `(e, :ci_to)` → `(e, :to, :imag)`, `(e, :v_real)` → `(e, :ser, :real)`, `(e, :v_imag)` → `(e, :ser, :imag)` |
| `cstr_tf_tap_setting` | `(a, :magnitude_max)` → `(a, :magn, :max)`, `(a, :magnitude_min)` → `(a, :magn, :min)`, `(a, :magnitude)` → `(a, :magn, :set)`, `(a, :max)` → `(a, :angl, :max)`, `(a, :min)` → `(a, :angl, :min)` |
| `cstr_node_voltage_reference`, `cstr_node_voltage_anchor` | `(i, :angle)` → `(i, :angl)` |
| `cstr_edge_flow` | `(e, :from)` → `(e, :fr)` |
| `cstr_dcl_power` | `(e, :setpoint)` → `(e, :set)` |
| `cstr_unit_power` | `(u, :active)` → `(u, :p)`, `(u, :reactive)` → `(u, :q)` |

#### Functions

A name that ended in `!` still does: `constraint_pi_section!` is `fnct_br_pi_section!`.

| family | renamed |
|:-------|:--------|
| node | `constraint_node_balance` → `fnct_node_balance`, `constraint_node_voltage_reference` → `fnct_node_voltage_reference`, `constraint_node_voltage_setpoint` → `fnct_node_voltage_setpoint`, `constraint_node_voltage_limits` → `fnct_node_voltage_limit`, `constraint_node_voltage_anchor` → `fnct_node_voltage_anchor` |
| edge | `constraint_edge` → `fnct_edge`, `constraint_edge_limits` → `fnct_edge_limit`, `constraint_edge_coupling` → `fnct_edge_coupling`, `constraint_edge_rating` → `fnct_edge_rating`, `constraint_edge_angle_difference` → `fnct_edge_angle_difference`, `constraint_linear_flow` → `fnct_edge_flow_linear`, `constraint_linear_ratings` → `fnct_edge_rating_linear`, `constraint_linear_angle_difference` → `fnct_edge_angle_difference_linear`, `constraint_overload_peak` → `fnct_edge_overload_peak` |
| unit | `constraint_unit` → `fnct_unit`, `constraint_unit_coupling` → `fnct_unit_coupling`, `constraint_unit_power` → `fnct_unit_power`, `constraint_unit_injection` → `fnct_unit_injection` |
| `br` | `constraint_pi_section` → `fnct_br_pi_section` |
| `stor` | `constraint_storage_final_energy` → `fnct_stor_final_energy`, `constraint_storage_cycles` → `fnct_stor_cycle` |
| `rd` | `constraint_redispatch_control` → `fnct_rd_control` |

#### Duals

`"lambda"` → `"dual_node_balance_p"`, `"lambda_q"` → `"dual_node_balance_q"`, `"lambda_real"` → `"dual_node_balance_real"`, `"lambda_imag"` → `"dual_node_balance_imag"`.

#### Other

| before | now |
|:-------|:----|
| `instantiate_model(data, P, F; set_string_name = false)` | the default; `debug_mode = true` for the names |
| `function NetworkModelBuilder.constraint_edge(nm, ::Type{MyEdge}; nw)` | `function NetworkModelBuilder.fnct_edge(nm, ::Type{MyEdge}; nw)` |
| `result["solution"]["nw"]["1"]["node"]["2"]["lambda"]` | `result["solution"]["nw"]["1"]["node"]["2"]["dual_node_balance_p"]` |
| `con(nm)[:node_balance_real][i]` | `real, imag = con(nm)[:cstr_node_balance][i]` |
| `nm.string_names` | `nm.debug_mode` |

### Verified

- The full suite passes with four threads, 3,686 checks. A 24 h chunk of the Zorba pipeline is byte-identical to
  the same chunk of 0.12.7, objectives 317686796.800330 and 308105792.250268 equal.
- The docs build is clean, with every `@docs` entry under its new name.

## [0.14.0] - 2026-10-11

### Added

- One nomenclature for the names of quantities: a symbol, then at most two descriptors from closed lists,
  then a unit where the quantity is not in per unit, as `v_magn_max`, `i_term_real` and `v_base_kv`. It
  holds for the fields of every component, the keys of the variables and the solution, and the keywords
  that carry a quantity. The manual has a page for it, `Nomenclature`.
- `test/nomenclature.jl` holds the grammar and the map from the old names to the new ones, and fails for a
  name that breaks the grammar and for an old name that is written anywhere in `src`, `test`, `docs` or the
  README. `test/docs_tables.jl` fails where the Parameters table of a component page does not list the
  fields of its type, or where a variable key is in no Variables table.
- Every concrete component type has a Parameters table and a Variables table in the docs, with the symbol
  of the formulas next to the code name. `load.md` and `slack.md` have one per type.
- Every solve takes `set_string_name = true`. With `false` no variable gets a name, and
  `JuMP.set_string_names_on_creation` is switched off once for the model: the model is the same, it builds
  a little faster, and `print(model)` shows `_[1]` for a variable.

### Changed

- **Breaking.** The fields, the variable keys, the solution keys and some keywords are renamed, with no
  alias and no hint. The keys of `ext` that the package reads are renamed too, and the others are free-form
  and stay. A solution key is the key of
  its variable.
- In the mathematics of the docs the current is `i`, as the code name is, the cost is `c` and the ratio
  of a winding is `t`: ``i^{\text{r}}_{a}``, ``c_{u,k}``, ``t^{\text{m}}_{a}``. A node is still `i` in an
  index.
- A table has one `p_set` column for the setpoint of a generator, a fixed load and a storage unit.

#### Fields

| type | renamed |
|:-----|:--------|
| `Node` | `vm` → `v_magn_set`, `va` → `v_angl_set`, `vmin` → `v_magn_min`, `vmax` → `v_magn_max`, `base_kv` → `v_base_kv` |
| `Generator` | `pg` → `p_set`, `qg` → `q_set`, `pmin` → `p_min`, `pmax` → `p_max`, `qmin` → `q_min`, `qmax` → `q_max`, `vg` → `v_magn_set`, `max_energy_per_period` → `e_per_max`, `cost` → `c`, `cost_up` → `c_up`, `cost_dn` → `c_dn` |
| `FixedLoad` | `pd` → `p_set`, `qd` → `q_set` |
| `FlexibleLoad` | `pd_nominal` → `p_nom`, `qd_nominal` → `q_nom`, `pd_min` → `p_min`, `pd_max` → `p_max`, `energy` → `e_set` |
| `Shunt` | `gs` → `g`, `bs` → `b` |
| `Storage` | `ps` → `p_set`, `qs` → `q_set`, `qmin` → `q_min`, `qmax` → `q_max`, `energy_capacity` → `e_max`, `energy_initial` → `e_init`, `energy_final` → `e_fin`, `charge_rating` → `p_chg_max`, `discharge_rating` → `p_dch_max`, `charge_efficiency` → `η_chg`, `discharge_efficiency` → `η_dch`, `max_cycles_per_period` → `k_cycl_max`, `cost_throughput` → `c_thru`, `cost_cycle` → `c_cycl`, `cost_up` → `c_up`, `cost_dn` → `c_dn` |
| `EnergyNotServed`, `Spill` | `pmax` → `p_max`, `cost` → `c` |
| `DCLink` | `rate_a` → `s_max`, `loss_fixed` → `p_loss_fix`, `loss_prop` → `p_loss_prop`, `pdc` → `p_set`, `cost` → `c` |
| `Switch` | `rate_a` → `s_max`, `angmin` → `v_angl_min`, `angmax` → `v_angl_max` |
| `Branch` | `g_sh` → `g_shnt`, `b_sh` → `b_shnt`, `rate_a` → `s_max`, `angmin` → `v_angl_min`, `angmax` → `v_angl_max`, `length_km` → `l_km` |
| `Transformer` | `g_sh` → `g_shnt`, `b_sh` → `b_shnt`, `g_m` → `g_mgnt`, `b_m` → `b_mgnt`, `tm` → `t_magn`, `ta` → `t_angl`, `tm_min` → `t_magn_min`, `tm_max` → `t_magn_max`, `ta_min` → `t_angl_min`, `ta_max` → `t_angl_max`, `tm_step` → `t_magn_step`, `ta_step` → `t_angl_step`, `rate_a` → `s_max`, `angmin` → `v_angl_min`, `angmax` → `v_angl_max` |
| `OverloadPrice` | `per_energy` → `c_ener`, `per_peak` → `c_peak` |
| `NetworkData` | `baseMVA` → `s_base_mva`, also the accessor `s_base_mva(data)` and the keyword of `parse_tables` and `parse_zorba` |

`v_angl_min` and `v_angl_max` of an edge limit the voltage angle
difference across it. `r`, `x`, the words (`id`, `name`, `node`, `terminals`, `status`, `ext`, `type`, `area`,
`zone`, `lock`, `position`, `reverse`, `oltc`, `pst`) and the Zorba adapter keywords are not renamed.

#### Variable keys

| owner | renamed |
|:------|:--------|
| node | `:vr` → `:v_real`, `:vi` → `:v_imag`, `:va` → `:v_angl` |
| arc | `:cr` → `:i_term_real`, `:ci` → `:i_term_imag`, `:p` → `:p_term` |
| branch | `:csr` → `:i_ser_real`, `:csi` → `:i_ser_imag`, `:vpr` → `:v_pnt_real`, `:vpi` → `:v_pnt_imag`, `:vap` → `:v_pnt_angl` |
| transformer | `:vsr` → `:v_star_real`, `:vsi` → `:v_star_imag`, `:vas` → `:v_star_angl`, `:vtr` → `:v_wind_real`, `:vti` → `:v_wind_imag`, `:tr` → `:t_real`, `:ti` → `:t_imag`, `:tm` → `:t_magn`, `:ta` → `:t_angl`, `:zt` → `:z_step` |
| edge | `:ol` → `:s_ovl`, `:olp` → `:s_ovl_peak`, `:zsw` → `:z_sw` |
| `DCLink` | `:pdct` → `:p_dcl_thru`, `:pdcup` → `:p_dcl_up`, `:pdcdn` → `:p_dcl_dn` |
| unit | `:cru` → `:i_unit_real`, `:ciu` → `:i_unit_imag`, `:pu` → `:p_unit` |
| `Generator` | `:pg` → `:p_gen`, `:qg` → `:q_gen`, `:pgup` → `:p_gen_up`, `:pgdn` → `:p_gen_dn` |
| `Storage` | `:psc` → `:p_chg`, `:psd` → `:p_dch`, `:es` → `:e_stor`, `:qs` → `:q_stor`, `:psup` → `:p_stor_up`, `:psdn` → `:p_stor_dn` |
| other units | `:pdf` → `:p_flex`, `:psl` → `:p_slk` |

#### Keys of `ext`

| owner | renamed |
|:------|:--------|
| node | `:vr_start` → `:v_real_init`, `:vi_start` → `:v_imag_init`, `:va_start` → `:v_angl_init`, where the solver starts the voltage |

#### Solution keys

A solution key is the key of the variable it reports: `"vr"` → `"v_real"`, `"vi"` → `"v_imag"`,
`"pg"` → `"p_gen"`, `"qg"` → `"q_gen"`, `"pgup"` → `"p_gen_up"`, `"pgdn"` → `"p_gen_dn"`,
`"psc"` → `"p_chg"`, `"psd"` → `"p_dch"`, `"es"` → `"e_stor"`, `"psup"` → `"p_stor_up"`,
`"psdn"` → `"p_stor_dn"`, `"psl"` → `"p_slk"`. The others:

| where | renamed |
|:------|:--------|
| node | `"vm"` → `"v_magn"`, `"va"` → `"v_angl"` |
| terminal | `"p"` → `"p_term"`, `"q"` → `"q_term"`, `"cr"` → `"i_term_real"`, `"ci"` → `"i_term_imag"` |
| unit | `"p"` → `"p_unit"`, `"q"` → `"q_unit"`, `"cru"` → `"i_unit_real"`, `"ciu"` → `"i_unit_imag"` |
| a parameter given back | `"pd"` → `"p_set"`, `"qd"` → `"q_set"`, `"gs"` → `"g"`, `"bs"` → `"b"` |
| edge | `"overload"` → `"s_ovl"`, `"loss"` → `"p_loss"` |
| `DCLink` | `"pdc"` → `"p_dcl"`, `"pdcup"` → `"p_dcl_up"`, `"pdcdn"` → `"p_dcl_dn"` |
| tap of a winding | `"tr"` → `"t_real"`, `"ti"` → `"t_imag"`, `"tm"` → `"t_magn"`, `"ta"` → `"t_angl"`, `"step"` → `"z_step"` |
| a market schedule | every `*_market` → `*_mkt`: `"pg_market"` → `"p_gen_mkt"`, `"ps_market"` → `"p_stor_mkt"`, `"pdc_market"` → `"p_dcl_mkt"`, `"tm_market"` → `"t_magn_mkt"`, `"ta_market"` → `"t_angl_mkt"` |

The duals `"lambda"`, `"lambda_q"`, `"lambda_real"` and `"lambda_imag"` keep their names.

## [0.13.0] - 2026-10-11

### Added

- A `Branch` has two or more terminals, as `n` π-sections from its terminals to one common point where the
  shunts are aggregated; two terminals are the single π as before. `r`, `x`, `g_sh`, `b_sh` and `rate_a`
  are vectors with an entry per terminal, as those of a `Transformer` are. In the `IVRFormulation` the
  point is a pair of variables of the edge, `vpr` and `vpi`, and the current of a section is an expression
  of the terminal current; in the `LPFFormulation` it is an angle, `vap`, with `p = -b (va - vap)` for each
  section and the flows summing to zero. A branch with more than two terminals has no angle limit, as a
  transformer with more windings has none. `test/multiterminal.jl` checks a three-terminal `Branch` against
  a `Transformer` of ratio one, written independently, and against the point written out as a node with a
  two-terminal `Branch` to each terminal: a load flow, an optimal power flow with the rating of one terminal
  binding, in both formulations, and a redispatch with that rating priced.
- `length_km` of a `Branch` is `NaN` when not known, which is its default. A negative or infinite length is
  refused.
- `constraint_linear_angle_difference!`, the angle limit of the linearized formulation, as
  `constraint_edge_angle_difference!` is that of the current based one.
- A table may give a number for a field with an entry per terminal of a `Branch` or a `Transformer`, as the
  constructors take one; the `cost` of a generator is still a list.

### Changed

- **Breaking.** The shunt of a `Branch` is `g_sh` and `b_sh`, the whole shunt of a section, half at each end.
  `g_fr`, `b_fr`, `g_to` and `b_to` are gone, so a shunt that differs between the two ends is no longer
  expressible; nothing in the repository gave one. `parse_matpower` gives `b_sh = b`, which puts `b/2` at
  each end as before. On a `Transformer` the same names are still the shunt at the terminal of a winding.
- **Breaking.** `r`, `x`, `g_sh`, `b_sh` and `rate_a` of a `Branch` read as vectors, so `br.r` is
  `[r, 0.0]` for two terminals, and `impedance(br)` and `shunt_admittance(br)` return one entry per
  terminal. A scalar given to the constructor stands for the first entry of two terminals, the second being
  0, and a scalar `rate_a` is the rating of every terminal. A branch with two terminals whose second entry
  is not 0 is refused.
- A rating and an angle limit are two constraints in the linearized formulation. `constraint_linear_ratings!`
  is the one linear rating, for a number or one per terminal, and a branch and a two-winding transformer write
  the angle limit with `constraint_linear_angle_difference!`. A two-winding transformer rated 0.5 and 0.8 gets
  the rows `(-0.5, 0.5)` and `(-0.8, 0.8)` where it had the tighter of the two on both; the feasible set is the
  same without losses.
- `variable_edge_series_current` takes the ids of the edges it is for, or a type as before.
- A branch is rebuilt by a window in 47 ns and 32 B, against 62 ns and 144 B, and a transformer in 222 ns
  against 521: a `Float64` vector given for a field with an entry per terminal is kept, not copied.

### Removed

- **Breaking.** `Cable`, `OverheadLine` and their files. A cable and an overhead line are a `Branch` with
  another `length_km`; they were the same equations, so no model changes. No shim.
- `constraint_linear_limits!`, for `constraint_linear_ratings!` and `constraint_linear_angle_difference!`.
- `pi_model.jl`: what a branch and a transformer share is in `edge.jl`, what only a branch uses in `branch.jl`.

### Migrating

| before | now |
|:-------|:----|
| `Cable(; length_km = l, ...)`, `OverheadLine(; length_km = l, ...)` | `Branch(; length_km = l, ...)` |
| `Branch(; b_fr = b/2, b_to = b/2)` | `Branch(; b_sh = b)` |
| `Branch(; g_fr, b_fr, g_to, b_to)` with `fr` and `to` equal | `Branch(; g_sh = 2 * g_fr, b_sh = 2 * b_fr)` |
| `br.r`, `br.x`, `br.rate_a` as numbers | `br.r[1]`, `br.x[1]`, `br.rate_a[1]` |
| `constraint_linear_limits!(nm, e, A, rate_a, angmin, angmax; nw)` | `constraint_linear_ratings!(nm, e, A, rate_a; nw)` and `constraint_linear_angle_difference!(nm, a_fr, a_to, angmin, angmax; nw)` |

### Verified

- The full suite passes with four threads, 3,340 checks. A 24 h chunk of the Zorba pipeline is byte-identical
  to the same chunk of 0.12.7, objectives 317686796.800330 and 308105792.250268 equal.
- Cost beside a same-day control of 0.12.9: cutting a step-3 window takes 7.7 and 7.8 ms against 7.7 and
  8.0, `update_model!` of the real step-3 window 1,145 ms against 1,155, and `benchmark/window.jl`'s update
  25.95 ms against 26.08.

## [0.12.9] - 2026-10-10

### Changed

- A variable key names one set of variables. `variable!`, `variable_container!` and `variables!` raise an
  `ArgumentError` that names the key and the network index where a key is asked for again with an index
  set or a type of id other than the one it holds. Before, four of the five ways to do that were accepted
  and handed back the container already there: `variables!(nm, :x, 1:3)` then `(:x, 1:5)` returned the
  3-element array, `variables!` then `variable!` under one key returned a variable of the array, and
  `variable_container!` with another `idtype` returned the old container; the fifth, `variable!` with
  an `Arc` after an `Int`, was a `MethodError` far from the cause. Asked again as before, a key returns
  what it holds, so an update is unchanged. An extension prefixes its keys with its own name, see
  `docs/src/manual/extending.md`.
- `constrain!` raises where a constraint id is written twice in the first build of a model, the one
  `instantiate_model` makes, instead of overwriting the first row with the second. `NetworkModel` has a
  `building` field for it. An update, and a `constrain!` by hand after the build, replace in place as
  before. A collision that first appears in a later pass is not seen.
- The constraints a model registered are the `registered` field of `NetworkModel`, typed, and no longer
  the `:registered` key of `nm.ext`. `registered_constraints(nm)` returns it as before. `ext` holds only
  what is the caller's: the `Redispatch` a redispatch problem is posed with, and what an extension adds.

### Removed

- Seven keys the package wrote into `nm.ext` and nothing read: `:redispatch_control`, `:overload_peak`,
  `:storage_balance`, `:storage_final`, `:storage_cycles`, `:generator_energy` and `:flexible_load_energy`.
  Each held references `registered_constraints(nm)` holds under `(nw, key, id)`; for the redispatch
  controls that is `(nw, :redispatch_control, (family, id, key))`. A held step-3 model of the Zorba
  pipeline (80 network indices, 274,523 registered rows) is 7.3 MB smaller, 243.6 to 236.3 MB, and
  `update_model!` of it 1,171 and 1,185 ms against 1,309 and 1,266 ms for 0.12.8 the same day. A 24 h chunk
  of the pipeline is byte-identical to the same chunk of 0.12.7, objectives equal.

## [0.12.8] - 2026-10-10

### Changed

- A constructor refuses input a model cannot use. Before, 19 of 19 such inputs built, and the solver
  answered `INFEASIBLE` with nothing pointing at the component, or a row held a `NaN`. Each now raises an
  `ArgumentError` that names the component, and checks a `NetworkVector` at every network index, whether
  or not the component is in service:
  - `Node`: `vmin` below 0 or above `vmax`, a `base_kv` below 0, a `vm` or `va` that is not finite.
    A `base_kv` of 0 stands for unknown, as Matpower's case14 has it.
  - `Generator`: `pmin` above `pmax`, `qmin` above `qmax`, a NaN limit, a setpoint or a cost coefficient
    that is not finite. An infinite limit is how a bound is left out, and `cost_up` and `cost_dn` may be NaN.
  - `FixedLoad` and `Shunt`: a demand or an admittance that is not finite.
  - `Branch`, `Cable` and `OverheadLine`: `r` or `x` not finite, `r` and `x` both 0 (a bus coupler is a
    `Switch`), a shunt admittance not finite, a negative or NaN `rate_a` (`Inf` is unlimited); `Cable`
    and `OverheadLine` also a `length_km` negative or not finite.
  - Not refused: the sign of `r` and `x` (a series capacitor has a negative `x`), a negative demand, a
    negative `bs`, and `pg` outside its limits.
  Code that built such a component now fails where it builds it. The rules were run over the four bundled
  Matpower cases and the Zorba year of 8,760 hours (234 nodes, 93 generators, 234 loads, 399 branches):
  only `base_kv > 0` failed, on case14, hence the 0. Cutting a real step-3 window, which rebuilds 1,437
  components, takes 7.5 ms against 7.7 ms before, and a 24 h chunk of the Zorba pipeline comes out
  byte-identical to the same chunk of 0.12.7.

## [0.12.7] - 2026-10-09

Tests and tooling only; nothing under `src/` changed.

### Added

- `test/hot_path.jl`: `has_nw_data` and `nw_component` of a node, a branch and a generator without
  network data allocate nothing. Run against the sources before 0.12.2 the same file fails all six
  checks, with the 1,248, 1,664 and 2,176 bytes a call that the boxed field loop cost; `@inferred` passes
  on those sources, so it is not used.
- `benchmark/`, an environment of its own (BenchmarkTools, HiGHS, JuMP and the package by path), and
  `benchmark/window.jl`: one window of a rolling redispatch on case14 with an outage per branch, timed stage
  by stage (cutting the window, `instantiate_model`, `update_model!`, the solve, `build_solution` whole and with
  a `report`, the whole roll). Run by hand beside a worktree of the other version. Two runs apart every
  minimum agrees within 3 %; against 0.12.4 it shows `update_model!` 30.4 to 26.9 ms, `build_solution`
  9.3 to 4.7 ms and the roll 868 to 706 ms, and leaves the solve at 35.7 ms.
- `scripts/run_year_redispatch.jl`: `chunk.csv` gains `gc_s` and `alloc_gb` for the chunk and for steps 2 and 3
  (six columns), the seconds of garbage-collection pause and the gigabytes allocated, read from the process's
  own counters, so exact for a process that runs one chunk. A run begun before them must not be resumed
  after. Zorba week 1, 7 one-thread processes against one process on 7 threads, side by side: a chunk takes
  125 s against 224 s and spends 14.2 % against 14.4 % of it in pauses (step 3: 16.7 % against 14.9 %), so
  the collector does not explain why threads stop paying.

### Changed

- The `[run]` lines of that script report the pause since the start of the solve, which is what the
  elapsed time beside them measures, rather than the process total with its set-up.

## [0.12.6] - 2026-10-09

### Added

- A solution holds what it is asked for. `build_solution(nm; nws, report)` and
  `optimize_model!(nm, optimizer; solution_indices, report)` take the network indices to build
  and a `report`, a `NamedTuple` whose `node`, `edge` and `unit` are each `true`, `false` or a
  vector of identifiers; a family left out is `true`, so the default is the whole solution, as
  before. A family that is not asked for stays in the result, empty. An unknown family, an
  identifier the model does not have, or any other value is an `ArgumentError`. `solve_model`,
  `solve_rd` and `solve_rolling_horizon` take `report` too. `solution_tables` and `print_summary`
  show what the result holds; `zorba_tables` and `security_tables` read every edge, so leave
  `report` alone for a result they are to read.

### Changed

- A rolling horizon builds, for each window, the solution of the network indices that window
  commits and no others, where it built the lookahead too and threw it away. The `solution_processors`
  of a roll therefore see the committed indices in `nm.sol["solution"]`. The result of the roll
  is unchanged.
- The six solution builders (node, edge and unit, in current and linearized form) look a container
  up once per component type, make a component's key once and assign each entry, where they looked
  up per component, made the key up to five times and built each entry through the vararg `Dict`
  constructor. The result is `isequal` to the old one on case14, on case5 with time and contingency
  dimensions, and on real windows. One real window, `build_solution` over every index, minimum of
  five: 80 indices 0.43 s to 0.29 s and 0.20 to 0.18 GB, 42 indices 0.134 s to 0.080 s.
- With the `report` the Zorba pipeline reads (`pipeline_report` in `scripts/PipelineReports.jl`: no
  node, the monitored edges and the phase shifting transformers, every generator and storage
  unit), the same window builds 9,762 of 34,962 edges and 32,880 of 51,600 units: 0.31 s to 0.14 s
  and 89 MB to 31 MB. A Zorba week of 24 h chunks against 0.12.5, side by side, took 12.3 % less
  wall time (871 s against 993 s over the 7 chunks, faster in 7 of 7), and a chunk peaked at 2.9 GB
  where it peaked at 5.0 GB. Objectives are bit-identical and so are the overload, shedding,
  spillage and congestion files; the redispatch volume files hold the same rows in another order,
  since `redispatch_volumes` reads them in `Dict` order.

## [0.12.5] - 2026-10-09

### Changed

- `topology` remembers the answer it gave last. `Network` has a new field, `last`: one
  slot, written atomically, holding the network index asked last and its topology. A model
  build asks for the topology of one index many times in a row (80 to 142 times per index
  on case14), and each ask derived the statuses of every switchable component again; a
  repeat is now a comparison and allocates nothing. It is one entry however many network
  indices there are, not a table of them. `topology` also returns one concrete type,
  `Topology`, where it inferred `Union{Nothing,Topology}`. Results are unchanged;
  `update_model!` of a redispatch on case14 with an outage per branch, against 0.12.4 on
  the same machine, took 4.8 ms against 6.7 ms (-28 %) and allocated 3.1 MB against 4.0 MB.
  A Zorba week of 24 h chunks against 0.12.4, side by side, took 10.7 % less wall time
  (135 s against 151 s a chunk, faster in 7 of 7), with objectives, overload rows and
  redispatch volumes bit-identical.

## [0.12.4] - 2026-10-07

### Fixed

- `test/lf.jl` asserted `solve_time > 0.0`, which failed whenever a small case solved
  faster than the resolution of `time()` on Windows. It now asserts `>= 0.0`, which still
  fails for the `NaN` a solve that never recorded its time would leave. Tests only.

## [0.12.3] - 2026-10-07

### Changed

- `Network` has a new field, `status`: the status of each switchable component, in the
  order of `switchable`. `topology` is asked for every node, edge and unit of every
  network index, and picked the topology of an index by reading the status of each
  switchable component through the component, an abstract `Dict` value, on every call.
  It now reads the typed vectors. Results are unchanged; a Zorba week of 24 h chunks
  against 0.12.2, side by side, took 15.6 % less wall time (152 s against 180 s a chunk).
  Together with 0.12.1 and 0.12.2 the Zorba year, as 73 one-thread processes, took 24
  minutes against 52 with 0.12.0, for the same objectives to 3e-8.

## [0.12.2] - 2026-10-07

### Changed

- `has_nw_data` and `nw_component`, which resolve a component at a network index, are
  generated per component type and read every field by a constant index. The loop over
  `getfield(c, k)` with a runtime `k` boxed every field of every component at every
  network index, in the model build, `update_model!` and `build_solution` alike. Results
  are unchanged; a Zorba week of 24 h chunks against 0.12.1 with the same feasibility
  check, side by side, took 13.6 % less wall time (180 s against 208 s a chunk).

## [0.12.1] - 2026-10-07

### Fixed

- A rolling horizon with `reuse = true` built almost every window from scratch when a
  generator's limit varied over the network index: `same_structure` read a power limit
  or a rating that crossed ±π/2 = 1.571 pu as a change of the shape of the model. That
  test is now asked only of an angle limit, `angmin` or `angmax`; every other limit is
  asked whether it is finite. On the Zorba year 8,353 of 8,760 windows of the internal
  redispatch were built from scratch; a Zorba week of 24 h chunks, side by side with
  0.12.0, now takes 26 % less wall time (254 s against 344 s a chunk) for the same
  objective to 4e-10.
- `same_structure` did not tell a `DCLink` whose `loss_prop` is zero from one whose
  `loss_prop` is positive, although the transfer variable of the link exists only for
  the second. A model updated across the change kept a transfer variable and a loss row
  the window does not have; the objective was equal in the cases checked, and it is now
  rebuilt.

## [0.12.0] - 2026-10-06

This release replaces four transformer types with one, and breaks the code that
named them: there are no shims for the old names. See the migration table at the end
of the section.

### Added

- `Transformer` is every transformer: two or more windings, each with a ratio, a
  series impedance and a shunt, meeting at a star point that carries the
  magnetising branch, `g_m` and `b_m`. The model is a T for two windings as for
  more, and the π-equivalent a Matpower branch with a ratio is, is the special case
  of no magnetising branch and the whole impedance on the first winding. The star
  point is an edge variable, not a node. A transformer with two windings accepts a
  scalar for the first winding where a field takes an entry per winding.
- `TapMode`, with `FIXED`, `CONTINUOUS` and `STEPPED`: the `oltc` field of a winding
  says whether its ratio magnitude can move, as a tap changer's does, and `pst`
  whether its angle can, as a phase shifter's does. A `Bool` is accepted, `true`
  for `CONTINUOUS`. A winding can be both, which in the `IVRFormulation` keeps the
  ratio in a ring between `tm_min` and `tm_max`, cut to the angles between `ta_min`
  and `ta_max`, and a transformer can have a control on any of its windings.
- `STEPPED` windings, with `tm_step` and `ta_step`: the winding takes one of the
  positions `lo, lo + step, …, hi`, a binary `zt` for each. A dispatch problem is
  then mixed-integer, a MILP in the `LPFFormulation` and a nonconvex MINLP in the
  `IVRFormulation`, with no duals, so the nodal prices are `nothing`. A winding can
  step its magnitude, its angle, or both over every pair; in the `LPFFormulation`
  only the angle exists, so only `pst` steps there. The solution reports the index
  of the position as `step`.
- `is_held(nm, family, id; nw)`: whether a preventive measure takes the setting of
  the base case at a network index. A held measure writes no row that only restricts
  it, and a held winding that steps reuses the binaries of the base case instead of
  tying copies of them, which leaves a mixed-integer solver `P` binaries rather
  than `P × N`.
- `constraint_linear_ratings!`, the rating of every terminal of an edge, and a
  rating per terminal where `constraint_edge_rating!` took one for the edge.
- `docs/src/components/transformer.md` rewritten for the one type, with the
  literature it follows.

### Changed

- **Breaking.** The fields of a `Transformer` are per winding: `r`, `x`, `g_sh`,
  `b_sh`, `tm`, `ta`, `tm_min`, `tm_max`, `ta_min`, `ta_max` and `rate_a` are vectors
  with an entry per terminal, and the shunt that was `b_fr` and `b_to` is
  `b_sh = [b_fr, b_to]`. `parse_matpower` builds the transformer with the ratio on
  the first winding and half the charging on each.
- **Breaking.** The tap of a transformer is reported under each terminal,
  `solution["edge"][e]["terminal"][k]["tap"]`, and not under the edge. In a
  redispatch it carries `tm_market` and `ta_market`, the setpoint the market left it
  at; `taup` and `tadn` are gone with the price.
- A phase shifter is a non-costly measure, and so is a tap changer: a transformer has
  no `cost` and no `redispatch_cost` method. Without the price that picked the
  least movement, a free angle is one of however many settings relieve the
  congestion equally; the overload of a redispatch is unchanged, but how the flow
  splits between parallel paths is not determined.
- A ratio that is held is substituted into the rows in the `IVRFormulation`, so a
  transformer that holds its ratio has no variable for the voltage behind it:
  case14 is 192 variables instead of 198.
- A transformer held at the base case writes the rows that restrict its ratio once.
  Written at every contingency as well, they were dependent next to the tie, and
  Ipopt stopped at its first iteration on a preventive phase shifter set at exactly
  zero.

### Deprecated

- `pst_cost` of `parse_zorba` warns and has no effect.

### Removed

- `PhaseShifter`, `TapChanger`, `MultiWindingTransformer` and
  `AbstractTwoWindingTransformer`, with `solution_tap`, `variable_two_winding!`,
  `constraint_two_winding_limits!` and `constraint_two_winding_flow!`.

### Fixed

- A transformer with three or more windings and a winding without impedance, which
  the `LPFFormulation` would write with an infinite susceptance and fail on with
  `NaN`, is an `ArgumentError` that names the winding.

### Migrating

| before | now |
|:-------|:----|
| `PhaseShifter(; ta_min, ta_max, cost)` | `Transformer(; pst = true, ta_min, ta_max)`; there is no price |
| `TapChanger(; tm_min, tm_max)` | `Transformer(; oltc = true, tm_min, tm_max)` |
| `MultiWindingTransformer(; terminals, r, x, g_m, b_m)` | `Transformer(; terminals, r, x, g_m, b_m)` |
| `Transformer(; b_fr, b_to)` | `Transformer(; b_sh = [b_fr, b_to])` |
| `solution["edge"][e]["tap"]` | `solution["edge"][e]["terminal"][k]["tap"]` |
| `parse_zorba(; pst_cost = c)` | `parse_zorba()`; the keyword warns and does nothing |
| a type test, `edge isa PhaseShifter` | `any(tf.pst .!== FIXED)` on the `Transformer` |

## [0.11.0] - 2026-10-04

### Added

- `Switch`, under `AbstractSwitch`, with `SwitchLock` (`FREE` and `LOCKED`): an
  edge with exactly two terminals that is closed or open and has no impedance,
  so a busbar coupler need not be a branch with a reactance of `1e-7`. Closed
  it equates the voltages at its two nodes, open it stops the flow, in both the
  `LPFFormulation` and the `IVRFormulation`. A locked switch is data; a free
  one is a binary variable `zsw` in a dispatch problem, which makes that model
  mixed-integer — with no duals, so the nodal prices are `nothing`, and a
  finite `rate_a` that the big-M rows are written with. A power flow holds every
  switch where its `position` puts it.
- Loops of closed switches share the flow equally, in every solver: the
  equality of voltages is written for a spanning tree of each group and every
  other switch gets the equation of its loop instead. A loop that free
  switches can close gets a row that holds when they are closed, one per
  simple cycle, and the model is not built above 1000 of them.
- A free switch is a preventive or a corrective measure of a redispatch, and
  non-costly. The solution carries the `"position"` and the `"lock"` of every
  switch, and so do the tables of `solution_tables`.
- `islands`, `connects` and `can_open`, and `check_islands`, which
  `instantiate_model` runs before it builds. An island that has units but no
  reference node and no source is now an `ArgumentError` that names its nodes;
  opening every free switch may not split an island unless
  `instantiate_model(...; islanding = :allow)`. An island that has a source but
  no reference node has its lowest node anchored, by
  `constraint_node_voltage_anchor`.
- `variable!` takes `binary = true`, and an integer is a structure gate, so a
  model of a different position is rebuilt rather than updated in a rolling
  horizon.
- `docs/src/components/switch.md`, with the literature it follows, the islands in
  the manual, and a
  cross-check of the switch against PowerModels.jl's `_solve_opf_sw` and
  `_solve_oswpf` on `test/data/matpower/switch_loop.m`. They agree except on a
  loop of closed switches, which PowerModels.jl leaves with a free flow.
- DocumenterCitations in the documentation: the references are in
  `docs/src/refs.bib`, cited author-year from the pages, and listed on a
  References page.
- Juniper, a test-only dependency like HiGHS, for the free switch in the
  `IVRFormulation`.

### Changed

- A network with an island that has load and no source no longer reaches the
  solver: where it came back as `INFEASIBLE`, or in the current-based load flow
  as a false `LOCALLY_SOLVED` with the voltage pushed towards infinity, it is
  refused when the model is instantiated.

### Fixed

- A file added under `src/comp/` was not seen by a package loaded from its
  compiled cache, so the new component was left undefined. `_include_dir` now
  declares every directory it walks with `include_dependency`.

## [0.10.2] - 2026-09-30

### Added

- `solution_tables(data, result)`: a tidy view of a `result` alongside
  `nw_solution` — one `NamedTuple` of plain columns per family of the
  extended graph (`node`, `edge`, `unit`), every dimension `data` is posed
  over becoming its own column, an edge's row per terminal rather than per
  edge, and a column no component or network index ever reports at all
  dropped rather than kept `missing` throughout. For a caller who wants every
  node or edge at once rather than one value at a time, e.g.
  `DataFrame(tables.node)` with DataFrames.jl, no new dependency of this
  package's own (gap #9 of `plans/GAP_CLOSURE_PLAN.md`).
- `docs/src/manual/concepts.md`: a "concepts for newcomers" page working one
  small network through `LoadFlowProblem`, `OptimalPowerFlowProblem` and
  `RedispatchProblem`, and through both formulations, then showing
  `nw_solution` and `solution_tables` side by side — plus a short, honest
  comparison to SmaLoadFlow's `PowerSystem`/`SolveOptions`/`RunResultXr`.

## [0.10.1] - 2026-09-30

### Changed

- `src/NetworkModelBuilder.jl` no longer lists every file under `src/comp/` or
  every name a component exports: a new `_include_dir` helper walks
  `comp/node/`, `comp/edge/` and `comp/unit/` (the file named like its own
  directory loading first in each one), and each component file now exports
  its own public names next to their definition. Adding a new edge or unit
  type needs no edit to the central file at all now — only its own file, in
  the right folder (gap #8 of `plans/GAP_CLOSURE_PLAN.md`). Purely internal:
  the public API is unchanged, verified by comparing `names(NetworkModelBuilder)`
  before and after.

## [0.10.0] - 2026-09-30

### Added

- `security_tables`: the flow of every edge, at every time step and every
  contingency but the base case, plus the two tables that reduce those to the
  worst case in either direction across contingency, together with which one
  attained it. Works on any `NetworkData` posed over a `:contingency`
  dimension, not only one `parse_zorba` built — towards feeding a dashboard's
  N-1 security screening directly from a solved model.
- `write_security_tables`: writes what `security_tables` returned as Parquet,
  one file per table. Parquet2 is a new weak dependency, gated the same way
  Arrow already is.
- `docs/src/manual/dashboard.md` and `plans/dashboard-output-mapping.md`: the
  manual page for the new output, and a reference mapping it against a real
  GRIP/Zorba-dashboard run's own file and column names.

## [0.9.7] - 2026-09-29

### Added

- `test/powermodels.jl`: a live cross-check against PowerModels.jl v0.21 on
  `case14` (load flow, optimal power flow in both formulations), alongside
  the existing frozen-value regression tests rather than instead of them.
  PowerModels.jl is a test-only dependency, like Ipopt and HiGHS.

## [0.9.6] - 2026-09-29

### Added

- Every complete example in the documentation now runs in CI, as a
  `test/docs.jl` check and as Documenter `@example` blocks, so a broken one
  (like 0.9.1's) fails the build instead of going unnoticed.

### Fixed

- The redispatch LPF example referenced an undefined `data`; it now builds
  the two-node network its own surrounding prose describes.

## [0.9.5] - 2026-09-29

### Added

- `CHANGELOG.md`.

## [0.9.4] - 2026-09-29

### Fixed

- `register_edge_type!`, `register_unit_type!` and `register_model!` could
  crash with `ConcurrencyViolationError` when called from more than one
  thread at once; each registry is now guarded by its own lock.

## [0.9.3] - 2026-09-29

### Changed

- `parse_tables` now warns when the `node`, `edge` and `unit` tables all come
  back empty, rather than silently building an empty network.

## [0.9.2] - 2026-09-29

### Fixed

- `parse_tables` raised a raw `BoundsError` when a table's columns disagreed
  on how many rows they had; it now raises a clear `ArgumentError` naming
  every column and its length.

## [0.9.1] - 2026-09-29

### Fixed

- A bare Matpower case file name (e.g. `"case14.m"`) now resolves against
  the package's own bundled case files when it isn't found relative to the
  working directory, so the documentation's quick-start examples work from
  anywhere, not only from `test/data/matpower/`.

## [0.9.0] - 2026-09-03

### Added

- The asset model: an energy limit per generator period; `EnergyNotServed`
  and `Spill` as slack units; storage cycle limits, a throughput cost, an
  inflow hook and an end-of-horizon target.
- Nodal prices, read from the duals of the node balance.
- The Zorba adapter (`parse_zorba`, `solve_zorba`, `zorba_tables`,
  `write_zorba`), translating a Zorba study into a network and back.
- A phase shifter's movement can be priced.
- A slack unit can take a side in the preventive-corrective split.

### Changed

- Price accessor nomenclature, to say which price each one returns.

## [0.6.0] - 2026-09-03

### Added

- `DCLink`.
- Tabular input (`parse_tables`, `parse_arrow`): a network as four tables,
  one Arrow file per table, without a hard dependency on Arrow.
- Periods group the coordinates of a `Dimension`, and a rolling-horizon
  window carries the periods it cut.
- A monitored edge's rating can be priced instead of enforced, and its
  overload is reported in the solution.

### Changed

- A flexible load's energy balance runs per period.

### Fixed

- A markdown table whose alignment row used a narrow cell (e.g. `|:-|`)
  silently fell back to a paragraph instead of rendering as a table; every
  table in the documentation is now checked for this in CI.

### Removed

- Ipopt as a hard dependency of the package; it remains a test dependency.

## [0.5.0] - 2026-08-28

### Added

- `RedispatchProblem`, and `solve_rolling_horizon`: a long horizon solved as
  a sequence of windows, reusing one `JuMP.Model` and warm-starting each
  window from the one before it.

## [0.4.0] - 2026-08-27

### Added

- `LPFFormulation`, the linearized power flow.
- A full problem statement per formulation in the documentation.

## [0.3.0] - 2026-08-27

### Added

- The component type hierarchy: `Branch`, `Cable`, `OverheadLine`,
  `Transformer`, `PhaseShifter`, `TapChanger`, `MultiWindingTransformer`,
  `Generator`, `FixedLoad`, `FlexibleLoad`, `Storage`, `Shunt`.
- A documentation site.

## [0.2.0] - 2026-08-26

### Changed

- Data that varies over the network index is now stored on the component
  itself as a `NetworkVector`, rather than the extended graph being
  replicated per index; the topology of a network index is derived from the
  statuses that vary, rather than tabulated.

### Deprecated

- `replicate`.

## [0.1.0] - 2026-08-26

### Added

- Initial implementation: the extended graph `(I, E, U)`, `NetworkModel{P,F}`,
  the load flow and optimal power flow problems in the IVR formulation, and a
  Matpower reader.
