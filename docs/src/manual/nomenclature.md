# Nomenclature

Every quantity the package names follows one grammar: the fields of a component,
the keys of its variables, the keys of a solution and the keywords that carry a
quantity. A name is a **symbol**, the letter of the quantity, followed by at most
two **descriptors** and, where the quantity is not in per unit, a **unit**:

```
symbol _ primary _ secondary _ unit
```

`v_magn_max` is the upper limit of a voltage magnitude, `i_term_real` the real
part of a terminal current, `p_chg_max` the charge power limit of a storage unit
and `v_base_kv` the voltage base in kV. Each name reads as a short sentence, and
a name that reads the same in the code and in the docs needs no translation.

## The rules

- Lowercase ASCII, snake_case and singular. The one exception is the symbol `η`
  of an efficiency.
- A descriptor has two to four letters and is taken from the lists below.
- The descriptors come in a fixed order: a *what*, then a *part*, then a
  *qualifier*, at most two of them. The first is the primary, the second the
  secondary descriptor. An empty slot is dropped: `v_magn_max` has a part and a
  qualifier, `i_ser_real` has a what and a part.
- A unit comes last, and only where the quantity is not in per unit or in radians.
- What is not a quantity stays a plain word.

## The symbols

| symbol | quantity |
|:-------|:---------|
| `v` | voltage |
| `i` | current |
| `p` | active power |
| `q` | reactive power |
| `s` | apparent power |
| `r` | resistance |
| `x` | reactance |
| `g` | conductance |
| `b` | susceptance |
| `e` | energy |
| `t` | ratio of a winding |
| `c` | cost or price |
| `l` | length |
| `z` | a binary decision |
| `k` | a count |
| `η` | efficiency |

An index letter is never a quantity, so a symbol may share its letter with one:
`i_term_real` is a current, while the `i` of ``i \in I`` is a node.

## The descriptors

A **what** says where a quantity is, or whose it is:

| descriptor | meaning |
|:-----------|:--------|
| `term` | a terminal of an edge |
| `ser` | the series element of a branch |
| `shnt` | the shunt element of an edge |
| `mgnt` | the magnetising branch of a transformer |
| `star` | the star point of a transformer |
| `pnt` | the point of a branch with more than two terminals |
| `wind` | behind the ratio of a winding |
| `gen`, `stor`, `flex`, `slk`, `unit` | a generator, a storage unit, a flexible load, a slack unit, any unit |
| `dcl`, `sw` | a DC link, a switch |
| `chg`, `dch` | charging, discharging |
| `loss`, `base`, `ovl`, `cycl`, `per` | a loss, a base, an overload, a cycle, a period |

A **part** says which part of a complex or polar quantity: `real`, `imag`,
`magn` for the magnitude and `angl` for the angle. Where nothing says what, the
part is the primary descriptor: `v_real`, `v_angl`.

A **qualifier** says what kind of number it is:

| descriptor | meaning |
|:-----------|:--------|
| `min`, `max` | a lower and an upper bound |
| `set`, `init`, `fin`, `nom`, `mkt` | a setpoint, an initial value, a final value, a nominal value, the market schedule |
| `up`, `dn` | upward and downward |
| `fix`, `prop`, `thru`, `peak`, `step`, `ener` | fixed, proportional, throughput, peak, step size, per unit of energy |

A **unit** is `kv`, `mva` or `km`.

**Words** are not quantities and are not built from the grammar: `id`, `name`,
`node`, `terminals`, `status`, `ext`, `type`, `area`, `zone`, `lock`,
`position`, `reverse`, `oltc`, `pst` and `exact`.

## Fields and keys

A field and a key follow the same grammar and differ in one respect. A **key**
names its owner, because the keys of every component of a network index share one
dictionary: `:p_gen`, `:p_stor_up`, `:p_term`. A role that only one owner has
says it instead: `:p_chg` and `:p_dch` are a storage unit's. A **field** does not
name its owner, the type already says whose it is:

```@example nomenclature
using NetworkModelBuilder

(generator = fieldnames(Generator), storage = fieldnames(Storage))
```

`Generator.p_max` and `Storage.p_chg_max` are both an active power limit. A
solution key is the key of the variable it reports, `"p_gen"` for `:p_gen`, and a
parameter that is given back takes its field name, `"g"` and `"b"` of a shunt.

Two fields deserve a note, because their names say less than they mean:

- `v_angl_min` and `v_angl_max` of an edge limit the voltage angle **difference**
  across it, not an angle.
- `s_max` bounds apparent power, which is active power wherever there is no
  reactive power: for a [`DCLink`](@ref) and in the
  [linearized formulation](@ref "The linearized formulation").

The names of Matpower, PowerModels and Zorba are kept in their readers and nowhere
else: the package reads the base power of a Matpower case and calls it `s_base_mva`.

The keys of `ext` that the package reads for a quantity follow the grammar too: a
[`Node`](@ref) starts its voltage at `ext[:v_real_init]` and `ext[:v_imag_init]`,
or its angle at `ext[:v_angl_init]`. The other keys of `ext` are free-form.

## In the mathematics

The code name column of the tables on the component pages joins a name in the code
to the symbol in the formulas. The formulas use the same letters: ``v`` for
voltage, ``i`` for current, ``p`` for power, ``c`` for cost, ``\eta`` for
efficiency, with a **subscript for an index** and a **superscript for a
descriptor**, see [Notation](@ref). A letter that is an index keeps its meaning:
``i`` is also a node, as in ``v^{\text{r}}_{i}``, and ``i^{\text{r}}_{u}`` is the
current a unit injects.

## Constraints, functions and duals

A constraint, the function that writes it and the dual it gives share one **stem**,
`owner_role`, and take one prefix each, which says which of the three a name is:

| kind | name | for the node balance |
|:--|:-----|:---------------------|
| the constraint | `cstr_` and the stem | `cstr_node_balance` |
| the function that writes it | `fnct_` and the stem | [`fnct_node_balance`](@ref) |
| its dual | `dual_` and the stem, then the part it prices | `dual_node_balance_real` |

The **owner** is whoever writes the row: a family, `node`, `edge` or `unit`, where
several types write it; a type, `br` for a branch, `tf` for a transformer, `dcl`,
`sw`, `gen`, `stor`, `flex` or `shnt`; or the problem, `rd` for a redispatch. The
**role** is what the row states, one or two words from a closed list: `balance`,
`voltage_reference`, `angle_difference`, `final_energy`, `tap_setting`. A key never
names the formulation, as `:p_term` does not: `cstr_edge_rating` is the rating of an
edge in the current based and in the linearized formulation. A function written for
the linearized formulation alone keeps that word, as
[`fnct_edge_rating_linear!`](@ref) does, and those that walk a registry and write the
rows of every type of a family take the family as the stem: [`fnct_edge`](@ref) and
[`fnct_unit`](@ref).

A row is registered under its key and an **id**: the identifier of its component, or
a tuple of it and its parts, `(i, :real)`, `(e, :fr, :imag)`, `(a, :magn, :max)`. A
part is `real`, `imag`, `magn` or `angl`; a bound, `min` or `max`; a side, `fr` or
`to`; `ser` for the series element and `set` for a setpoint; or one of `loss`,
`forward`, `reverse`, `pos`, `neg`, `side`, `p`, `q`, `chg` and `dch`. The current based
formulation writes a row for each part where the linearized one writes one, so an id
has one shape per key within a formulation, not across the two.

In [debug mode](@ref "Debug mode") a row is named from its network index, its key
and its id, a tuple flattened, which is what a solver log or an LP file shows:

```@example nomenclature
using JuMP

nm = instantiate_model("case14.m", OptimalPowerFlowProblem, IVRFormulation; debug_mode = true)

rows = registered_constraints(nm)
(keys   = sort!(unique(String(key) for (_, key, _) in keys(rows))),
 names  = sort!([JuMP.name(first(row)) for ((_, key, _), row) in rows if key === :cstr_node_balance])[1:4])
```

The duals a node reports are named for the balance they price. `dual_node_balance_p`
and `dual_node_balance_q` are the price of active and of reactive power, and in the
current based formulation `dual_node_balance_real` and `dual_node_balance_imag` are
the prices of a unit of current they are recovered from, see [`nodal_prices`](@ref).

## What is not covered

The functions of the families `variable_*`, `solution_*` and `objective_*`, and the plain words, are
not part of the grammar. `"dual_status"` is JuMP's own word, the status of the solve, not a dual.

`test/nomenclature.jl` holds the grammar as code and checks every field, every
variable key, every solution key, every constraint key and id, every function that writes
rows and every dual of the package against it; `test/docs_tables.jl`
checks that the tables of the component pages list exactly the fields and the
variable keys that exist.
