# Zorba adapter handoff

## Purpose

This handoff specifies the implementation boundary for the Zorba to NetworkModelBuilder.jl (NMB) bridge. It is the detailed companion to [zorba-integration.md](zorba-integration.md). Build the bridge as a generic, versioned NMB bundle plus a Zorba compatibility adapter. Do not enlarge the existing Zorba-specific transport into an unvalidated catch-all payload.

| Label | Meaning |
| --- | --- |
| **[Verified]** | Checked on 2026-09-03 against the named repository state, or supplied as a binding project fact. |
| **[Planned]** | Required implementation work. |
| **[Assumption]** | Requires evidence before it can be used as a compatibility or release claim. |

## 1. Revisions and current status

| Item | State |
| --- | --- |
| Zorba plan reference | **[Verified]** `99f60a5a448c6788fd6188504e5c7980e83c9943` |
| Current Zorba revision | **[Verified]** `069e8aad18d662316cfd028602c3fcd20be219c1`, 16 commits after the plan reference |
| Current NMB revision | **[Verified]** `9682804defd99de42a62ee7b89e05dd8584344e4` |
| NMB package version | **[Verified]** `Project.toml` says `0.9.0` |
| NMB release tag | **[Verified]** No immutable `v0.9.0` tag exists; pin the full commit until a published immutable tag is verified |
| Phase 0 behavioral contract | **[Verified]** Zorba owns `docs/network_model_parity_conventions.md` and `tests/fixtures/baseline_parity` |
| Phase 0 goldens | **[Verified]** Generation is blocked by unavailable private SMA dependencies; this is a promotion dependency, not a reason to duplicate the contract |
| Generic NMB parser | **[Verified]** `parse_tables` and `parse_arrow` provide the generic component, dimension, and profile direction |
| Existing Zorba adapter | **[Verified]** `parse_zorba` accepts `grid`, `net_position`, optional `hvdc`, and optional `outage`; `zorba_tables` returns `grid_flows` and `pst_dispatch` |

The NMB commit and resolved Julia `environment_digest` are included in `request_logical_digest` and are part of every bridge identity. Package version alone is informational until it is backed by an immutable release tag.

## 2. Architecture and seam ownership

### 2.1 The two-tier bridge

```text
Zorba schemas and business orchestration
                |
                v
Zorba compatibility adapter
                |
                v
Versioned generic NMB envelope + canonical model bundle
                |
                v
Registry validation for (ProblemType, FormulationType, semantic profile)
                |
                v
NMB parse_tables / parse_arrow, model construction, solve
                |
                v
Generic result and diagnostic tables + completed manifest
                |
                v
Zorba compatibility adapter and existing Zorba response schemas
```

The generic bundle is the inter-language contract. The Zorba adapter is a source-specific translation layer. It translates schema names, business orchestration, units, ID conventions, and result surfaces; it must not create an implicit new NMB problem type.

### 2.2 Ownership rules

| Concern | Owner | Rule |
| --- | --- | --- |
| Behavioral parity and tolerances | Zorba Phase 0 | Zorba's semantic contract and fixtures are authoritative. Do not fork goldens into NMB. |
| Zorba input and output mapping | Zorba adapter | Map existing schemas to a selected generic profile and map only declared generic outputs back. |
| Canonical bundle and profile registry | NMB protocol surface | Define generic tables, canonical serialization, pair/profile validation, and generic result response surfaces. |
| Process and filesystem transport | Bridge CLI | Read/write the manifest and Arrow tables atomically; no Zorba workflow decisions live here. |
| Problem/formulation behavior | NMB | Construct and solve only the pair and profile accepted by the registry. |
| Cache identity | Zorba caller | Include all bridge semantic inputs, including `request_logical_digest`, from the first rollout; cleanup is separate operations work. |

### 2.3 Validation boundary

The order is mandatory:

1. Python structural preflight reads the pinned NMB registry artifact and verifies the manifest shape, protocol/version selector, `profile_registry.logical_digest`, file list, declared table schemas, table `logical_digest` and `file_digest` values, `request_logical_digest`, selected pair, and named profile.
2. The Julia bridge independently reads the same registry artifact, recomputes and verifies its `logical_digest`, and authoritatively validates required, optional, and prohibited tables, components, fields, units, indexes, policies, response surfaces, and solver options.
3. Julia consumes every declared table and normalizes accepted canonical tables to the NMB `parse_tables`/`parse_arrow` representation.
4. Julia constructs a model only after step 2 and step 3 pass.

Python preflight is deliberately structural; it must not recreate NMB's semantic or model validation. Malformed tables, a bad required hash, or an impossible canonical value are protocol `error`. A well-formed request for an unregistered pair/profile or prohibited semantics is `unsupported`. Neither reaches model construction.

### 2.4 Generic transport versus Zorba compatibility input

Only the generic tables declared by the selected NMB profile may appear in a bridge manifest. Zorba source tables and fields such as `grid`, `net_position`, `hvdc`, `outage`, `pst_deg`, `pst_tap`, `pst_tap_min`, and `pst_tap_max` are compatibility-adapter input only. The Zorba adapter translates them into the generic core bundle before serialization; the generic transport neither accepts nor interprets them. Conversely, the NMB compatibility adapter translates the validated generic core into NMB parser/model inputs without acquiring Zorba business rules.

## 3. Current gap analysis

| Area | Current fact | Required change |
| --- | --- | --- |
| General data boundary | **[Verified]** NMB has `parse_tables`/`parse_arrow` for generic component data. | **[Planned]** Define a stable generic bundle and canonical manifest around those APIs. |
| Current Zorba transport | **[Verified]** `parse_zorba` is limited to `grid`, `net_position`, `hvdc`, and `outage`; output is `grid_flows` and `pst_dispatch`. | Keep it as a compatibility reference/transport where useful, but do not represent it as the M1/M2 protocol. |
| Pair selection | **[Verified]** The old transport is shaped around redispatch. | **[Planned]** Make the selected `ProblemType` and `FormulationType` drive registry validation and table transfer. Start only with `RedispatchProblem x LPFFormulation`. |
| Manifest and provenance | **[Verified]** The current adapter has no versioned generic bridge envelope. | **[Planned]** Add protocol, immutable revision, required logical/file hash classes, solver/configuration, status, diagnostics, and batch metadata. |
| M1 PST controls | **[Verified]** Legacy M1 uses `pst_deg`, `pst_tap`, `pst_tap_min`, and `pst_tap_max`; Belgian controls are time-indexed. | **[Planned]** Emit explicit generic time-indexed `pst_control` degree setpoints and bounds. The compatibility adapter uses the documented scalar fallback only when no complete tap triplet exists; scalar behavior is never implicit. |
| Angle conversion | **[Verified]** Phase 0 records a legacy `3.14 / 180` conversion for one API and exact-pi conversions elsewhere. | Replace the old global code-fix task with a profile-level angle policy gate and tests. |
| M2 public workflow | **[Verified]** The public Belgian workflow is overload-screened and PST-only. | **[Planned]** Deliver it separately as M2a. |
| M2 direct helpers | **[Verified]** Phase 0 direct curative/preventive fixtures exercise a distinct asset-rich surface. | **[Planned]** Deliver it separately as J2/M2b with flex, storage, slack, control, and pricing semantics. |
| Results | **[Verified]** Current Zorba transport returns only flows and PST dispatch. | **[Planned]** Define final net position, dispatch, ENS/spill, SOC, objective, status, diagnostics, and partial-batch response rules where the profile requires them. |
| Cache | **[Verified]** Existing result caches can outlive a backend change. | **[Planned]** Add protocol/backend/revision/configuration/request-logical identity at bridge introduction. |

## 4. Generic NMB bridge envelope

### 4.1 Normative principles

**[Planned]** Protocol `1.0` uses JSON manifests and Arrow tables. Every materialized Arrow table descriptor has a stable logical name, the exact selected-profile schema and canonical key/order, and these two required hash classes:

- `logical_digest` is a required SHA-256 of the table's canonical logical representation. It is the table's semantic identity and is the only table hash admitted to semantic or cache identity.
- `file_digest` is a required SHA-256 of the final raw Arrow regular-file bytes. It protects transport integrity only. Equivalent recompression or serialization may change it without changing `logical_digest`; it is never part of semantic or cache identity.

The canonicalization algorithm is fixed by the pair of `protocol_version` and `profile_registry.version`/`profile_registry.logical_digest`. A registry revision or protocol revision that changes this algorithm changes the corresponding logical identity; neither side may infer an algorithm from Arrow bytes.

The exact input to a table's `logical_digest` is this UTF-8 canonical JSON logical-table object:

```json
{
  "canonicalization": {
    "profile_registry_logical_digest": "sha256:<64 lowercase hex>",
    "protocol_version": "1.0"
  },
  "key": ["declared_key_column"],
  "name": "declared_table_name",
  "order": ["declared_canonical_order_column"],
  "rows": [["values follow the declared schema column order"]],
  "schema": [
    {
      "logical_type": "utf8",
      "name": "declared_key_column",
      "nullable": false,
      "unit": null
    }
  ]
}
```

`schema` is the complete selected-profile logical schema, including ordered columns, logical types, nullability, and units. `rows` is an array of row arrays in that schema order and in the declared canonical row order. Object keys are lexically sorted and the JSON is serialized according to RFC 8785 with no insignificant whitespace. Strings use its UTF-8 JSON escaping with no Unicode normalization or implementation-specific escaping. Integer values are exact base-10 JSON integers with no leading plus sign or leading zero; finite `float64` values use RFC 8785's shortest round-trip base-10 form, with negative zero normalized to `0`. `NaN`, infinities, implicit string-to-number coercion, and lossy integer conversion are rejected. The declared schema distinguishes an integer `1` from a `float64` `1`; raw Arrow bytes do not participate in this representation.

The canonical request digest recipe is normative:

1. Construct the request semantic projection from protocol version, NMB identity, registry identity, selection, `coordinate_mode`, `period_coordinate_mode`, profile policy, solver configuration, and every input table's logical name, row count, declared schema/key/order, and `logical_digest`.
2. Exclude physical paths, temporary names, timestamps, compression choices, arbitrary Arrow metadata, every `file_digest`, all response fields, and `request_logical_digest` itself.
3. Serialize that projection with the same canonical JSON rules and calculate `request_logical_digest` as its SHA-256. This is the request semantic identity used by the cache. A response records its originating `request_logical_digest` and gives every output table both hash classes.

Moving, staging, or recompressing a table can therefore change `file_digest` while preserving both its `logical_digest` and the request cache identity. A changed logical row, schema, name, key, or canonical ordering changes `logical_digest` and then `request_logical_digest`.

Manifest paths are transport locators, not semantic identifiers. A path must be either a profile-defined logical name resolved under the bundle root or a normalized relative descendant. The secure resolver must reject absolute paths, empty paths, `..`, duplicate logical names or paths, unknown files, non-regular files, and symlinks or Windows reparse points. It must resolve every ancestor and prove the final path remains below the bridge-owned root. On a platform where that proof is not available, the bridge must copy each verified input into a newly created regular-file staging root and verify its `file_digest`, then its `logical_digest`, before reading it.

**[Planned]** The manifest records both NMB source revision and resolved environment digest. A source commit without its resolved Julia package graph is not sufficient provenance for a numerical result.

### 4.2 Closed manifest schema

The NMB-owned versioned registry artifact defines a JSON Schema `oneOf` with `additionalProperties: false` at every object. Request and response manifests are disjoint:

| Manifest variant | Required and permitted top-level members | Prohibited members |
| --- | --- | --- |
| Request | `manifest_kind: "request"`, `protocol_version`, `request_logical_digest`, `nmb`, `profile_registry`, `selection`, `coordinate_mode`, `period_coordinate_mode`, `profile_policy`, `solver`, and `input_tables` | `response_kind`, `outcome`, `output_tables`, and `partial_output_tables` |
| Optimal response | `manifest_kind: "response"`, `protocol_version`, `request_logical_digest`, echoed `nmb`, `profile_registry`, `selection`, `coordinate_mode`, `period_coordinate_mode`, `response_kind: "optimal"`, `outcome`, and `output_tables` | `input_tables`, `profile_policy`, `solver`, and `partial_output_tables` |
| Terminal non-optimal response | The same response identity fields, one `response_kind` of `infeasible`, `unbounded`, `unsupported`, or `error`, and `outcome` | `input_tables`, `profile_policy`, `solver`, `output_tables`, and `partial_output_tables` |
| Partial response | The same response identity fields, `response_kind: "partial"`, `outcome`, and `partial_output_tables` | `input_tables`, `profile_policy`, `solver`, and `output_tables` |

`outcome` is a closed variant object, never a nullable request placeholder. An optimal outcome requires `normalized_status: "optimal"`, every profile-required normal output table, and an objective when that profile defines one. A terminal non-optimal outcome requires `normalized_status`, `raw_status`, `raw_status_source`, `objective: null`, `complete`, and structured diagnostics; it has no normal solution table. A partial outcome requires those status/diagnostic fields, `complete: false`, and only quarantined table descriptors. Its `partial_output_tables` paths must be below the bundle-root `quarantine/` namespace and cannot satisfy a normal response-surface requirement. The artifact separately closes the members of `nmb`, `profile_registry`, `selection`, `profile_policy`, `solver`, table descriptors, and each `outcome` variant.

A well-formed but unlisted manifest member, table, component family/type, column, output surface, policy field, or policy enumeration value is `unsupported` before model construction. Invalid JSON, invalid types, broken referential keys, invalid hashes, or unsafe paths are `error`. Optional means accepted only when its entire declared schema is valid; it never means ignored.

### 4.3 Optimal response manifest example

The example is illustrative; names and digest values are examples, not fixed values.

```json
{
  "manifest_kind": "response",
  "protocol_version": "1.0",
  "request_logical_digest": "sha256:8d4db8d9c2d4e7b9f0a7b5c4a6d1e3f2c8b7a9d5e4f6c2a1b3d7e9f0a2c4b6d8",
  "nmb": {
    "revision": "9682804defd99de42a62ee7b89e05dd8584344e4",
    "package_version": "0.9.0",
    "environment_digest": "sha256:6c1e4a8d2b7f9c3e5d0a1b4c8f2e6d9a3c7b0e5f1a4d8c2b6e9f3a7d0c4b8e1"
  },
  "profile_registry": {
    "version": "1",
    "logical_digest": "sha256:7a1d4c8e2b6f9a3c5d0e1b4f8a2c6d9e3b7f0a5c1d4e8b2f6a9c3d7e0b4f8a1"
  },
  "selection": {
    "problem_type": "RedispatchProblem",
    "formulation_type": "LPFFormulation",
    "semantic_profile": "zorba.m1.redispatch-lpf.v1"
  },
  "coordinate_mode": "full_cartesian",
  "period_coordinate_mode": "absent",
  "response_kind": "optimal",
  "output_tables": [
    {
      "name": "result_flow",
      "path": "output/result_flow.arrow",
      "rows": 20,
      "logical_digest": "sha256:4444444444444444444444444444444444444444444444444444444444444444",
      "file_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    },
    {
      "name": "result_dispatch",
      "path": "output/result_dispatch.arrow",
      "rows": 8,
      "logical_digest": "sha256:5555555555555555555555555555555555555555555555555555555555555555",
      "file_digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
  ],
  "outcome": {
    "normalized_status": "optimal",
    "raw_status": "OPTIMAL",
    "raw_status_source": "MathOptInterface",
    "objective": 1234.5,
    "diagnostics": [],
    "batches": [
      {
        "batch_id": "2026-01-01",
        "normalized_status": "optimal",
        "raw_status": "OPTIMAL",
        "output_partition": "batch_id=2026-01-01"
      }
    ],
    "complete": true
  }
}
```

The corresponding request has the request-only members in section 4.2 and no response block or output-table list. Every request input-table descriptor and every response output-table descriptor carries both `logical_digest` and `file_digest`; the example omits request tables because they are not response members. Section 8 defines the partial response form and status precedence.

### 4.4 Canonical table-family matrix

The following names are generic NMB bridge tables, not Zorba compatibility inputs. The registry, not this matrix alone, declares the exact columns, nullability, units, and allowed values for each selected profile.

| Family | Canonical tables | Purpose | NMB alignment | Availability |
| --- | --- | --- | --- | --- |
| Topology/components | `node`, `edge`, `unit` | Stable component IDs, concrete component kind, terminals/node association, and constant component fields. | Directly maps to the generic `parse_tables` component families. | Core |
| Dimensions/time/periods | `dimension`, `network_index`, optional `period` | Time coordinates, durations, weights, period membership, and stable multidimensional addresses. | `dimension` maps directly; the normalizer maps stable coordinates to NMB network indexes. | Core, profile-specific fields |
| Profiles | `profile` | Values varying by component field and network index, including availability, ratings, injections, and schedules. | Directly follows the generic `profile` direction; profile registry controls supported fields. | Core when varying data exists |
| PST control | `pst_control` | Time-expanded generic PST setpoints, angle bounds, and movement prices. | The NMB compatibility adapter converts accepted generic degrees to NMB control fields. | Required by M1 and M2a |
| Scenario/contingency state | `state`, `state_member`, optional `state_link` | Named scenario/contingency state, base relationship, concrete membership, and explicit links. | Normalizes to a dimension and status/profile vectors rather than a Zorba-only outage special case. | Required by M1/M2 profiles |
| Monitoring/reporting | `monitoring` | Declares edges constrained for overload versus edges emitted for reporting. | Normalizer maps constraint and output selections independently. | Required by the appropriate M2 profile |
| Screening/work items | `screening`, `work_item` | Records M2a screening decisions and the sparse state-time solves actually requested. | Normalizer creates `nw` only for selected work items. | M2a sparse mode |
| Policy/control | `control_policy`, `control_policy_exception`, `state_group_member`, `price_policy` | Declares control mode, equality scopes, slack, storage, and price semantics. | Passed only after registry validation. | M2b |
| Generic results | `result_flow`, `result_dispatch`, `result_net_position`, `result_slack`, `result_storage_soc`, `result_objective` | Declared response surfaces, not implicit reconstruction from a solver object. | Produced by the selected profile's formatter. | Profile-specific |
| Diagnostics | `diagnostic`, `batch_status` | Structured warnings, errors, timings, status provenance, and partial-batch state. | Manifest always carries summary fields; tables carry row-level detail when needed. | Optional tables, mandatory manifest fields |

`network_index` is important even when NMB eventually stores a compact `nw` index. It preserves the profile-declared logical coordinate address used by Zorba results and lets the adapter canonicalize ordering without guessing from a row's position.

### 4.5 Initial M1 core schema

`zorba.m1.redispatch-lpf.v1` has the following closed generic input schema. All IDs are non-empty UTF-8 strings, all numeric values are finite, and no unlisted columns are permitted. A field marked conditional is required for the listed component kind and prohibited otherwise. The profile artifact carries the executable Arrow types and nullability; these names and units are binding.

| Table | Required columns and types | Key and canonical order |
| --- | --- | --- |
| `node` | `node_id: utf8` | `node_id`; lexical byte order by `node_id` |
| `edge` | `edge_id: utf8`, `kind: utf8` enum `ac_branch`, `pst`, `hvdc`, `from_node_id: utf8`, `to_node_id: utf8`, `x_pu: float64` for `ac_branch`/`pst`, `rate_a_mw: float64` for `ac_branch`/`pst`, `monitored: bool`, `reported: bool` | `edge_id`; lexical byte order by `edge_id` |
| `unit` | `unit_id: utf8`, `kind: utf8` enum `net_position`, `node_id: utf8` | `unit_id`; lexical byte order by `unit_id` |
| `dimension` | `dimension: utf8` enum `time`, `state`; `id: utf8`; `ordinal: int32` starting at zero without gaps; time rows also carry `duration_hours: float64 > 0` | `(dimension, id)`; `time` then `state`, then `(ordinal, id)` |
| `network_index` | `nw: int64 >= 1`, `time_id: utf8`, `state_id: utf8` | both `nw` and `(time_id, state_id)` are unique; canonical coordinate order in section 4.6 |
| `profile` | `family: utf8` enum `unit`, `edge`; `component_id: utf8`; `field: utf8`; `nw: int64`; `value: float64` | `(family, component_id, field, nw)`; canonical sort `(nw, family, component_id, field)` |
| `state` | `state_id: utf8`, `base_state_id: utf8` nullable only for the one base state, `objective_weight: float64 >= 0`, `objective_gross_up: float64 > 0` | `state_id`; dimension ordinal order |
| `state_member` | `state_id: utf8`, `component_family: utf8` enum `edge`, `unit`; `component_id: utf8`; `membership: utf8` enum `in_service`, `out_of_service` | `(state_id, component_family, component_id)`; state order then family/id |
| `pst_control` | `edge_id: utf8`, `time_id: utf8`, `setpoint_deg: float64`, `lower_deg: float64`, `upper_deg: float64`, `movement_cost_eur_per_deg: float64 >= 0` | `(edge_id, time_id)`; time ordinal then `edge_id` |

`zorba.m1.redispatch-lpf.v1` declares `period_coordinate_mode: absent`; the schema above is therefore the no-independent-period form. A profile declaring `period_coordinate_mode: independent` must use the full-coordinate rules in section 4.6 instead of reusing a partial M1 key.

For M1, `profile.field` is closed to `injection_mw` for `unit/net_position` and `schedule_mw`, `lower_mw`, `upper_mw`, and `adjustment_cost_eur_per_mwh` for `edge/hvdc`. `lower_mw <= schedule_mw <= upper_mw` is required. Other component kinds, profile families, fields, columns, and tables are `unsupported`, including Zorba compatibility names. Each controllable PST edge has exactly one `pst_control` row for every declared time, and `lower_deg <= setpoint_deg <= upper_deg` is required after conversion.

### 4.6 Logical coordinates, `nw`, and parser ownership

Every registered profile declares exactly one `period_coordinate_mode`, and every manifest records that selected value. The only values are `absent`, `time_partition`, and `independent`:

- `absent` has no period coordinate.
- `time_partition` permits a `period` table mapping every `time_id` to exactly one `period_id`; period is metadata and does not add an `nw` dimension.
- `independent` adds `period` to `dimension` and makes the full profile coordinate key `(time_id, state_id, period_id)`.

For `absent` and `time_partition`, `network_index` has the unique logical key `(time_id, state_id)` and prohibits `period_id`. For `independent`, `network_index.period_id` is required and both `nw` and `(time_id, state_id, period_id)` are unique. In an independent profile, `profile`, `screening`, `work_item`, and every registry-declared coordinate-bearing input table or result surface must carry `time_id`, `state_id`, and `period_id`, with the full triple in its logical key; `nw` may remain as an audit lookup but never as the only coordinate. A table with an explicitly declared narrower scope, such as M1's time-only `pst_control`, is not a network-coordinate surface and must not be joined through a partial network key. A profile that does not declare `period_coordinate_mode: independent` rejects independent-period coordinates; a request claiming `independent` but omitting any required `period_id` is an error.

`dimension.ordinal`, never raw IDs or Arrow row positions, determines coordinate ordering. The normalizer assigns dense one-based NMB network indices in this order:

```text
(time_ordinal, state_ordinal[, period_ordinal]) -> nw = 1, 2, ...
```

`full_cartesian` requests are required for M1 and M2b. They contain every declared full profile coordinate exactly once: every time x state coordinate without an independent period, or every time x state x period coordinate with one. A missing, duplicate, or extra coordinate is rejected. M2a alone may additionally use `screened_work_items`. In that mode, `screening` has `time_id: utf8`, `state_id: utf8`, `decision: utf8` enum `selected` or `not_selected`, and `period_id: utf8` exactly when `period_coordinate_mode` is `independent`; it is keyed and sorted by the full profile coordinate. `work_item` has `work_item_id: utf8` plus that same full coordinate, is keyed by both ID and full coordinate, and is sorted by full coordinate then ID. `screening` contains one row for every candidate coordinate; `work_item` contains exactly the selected coordinates. Each selected coordinate has one `network_index` row. A `not_selected` coordinate has no `network_index`, no model variables, and no result rows; it is not represented by a zero, null, or implicit fallback. A missing screening row, a selected/work-item mismatch, or any unlisted sparse coordinate is rejected as `unsupported`.

`parse_arrow` is not currently the full bundle parser. J1 must create or extend a manifest-aware bundle reader/normalizer that opens every manifest-declared table, validates it against the selected profile, and either consumes it into the normalized NMB inputs or rejects it. It must not call current `parse_arrow` in a way that silently ignores newly declared files. `parse_arrow` remains a downstream generic table parser after this reader has established the complete bundle.

Before writing results, the normalizer performs the inverse join from every `nw` to the full profile coordinate key. Generic coordinate-bearing result rows must carry `time_id`, `state_id`, and, for `independent`, `period_id`; `nw` is retained only as an audit key. A partial-key join, unknown `nw`, or unmappable full key is an `error`. Results use coordinate order above, then batch ID where applicable, then the profile-declared component key order.

## 5. Closed profile registry and validation ownership

### 5.1 Closed-world registry rule

**[Planned]** NMB owns one versioned, machine-readable profile/schema artifact. It contains the manifest JSON schema, table Arrow schemas, canonical keys/order, `period_coordinate_mode`, component-family/type enumerations, per-field units and value domains, profile-policy schemas, response schemas, status rules, and the registry keyed by `(ProblemType, FormulationType, semantic_profile)`. The artifact is closed-world: every accepted table, component family/type, column, output surface, manifest member, and policy field/value is listed explicitly. Everything else is rejected.

The initial entries are deliberately narrow:

| Profile | Pair | Request coordinate modes | `period_coordinate_mode` | Allowed component types | Required generic input tables | Declared output surfaces |
| --- | --- | --- | --- | --- | --- | --- |
| `zorba.m1.redispatch-lpf.v1` | `RedispatchProblem x LPFFormulation` | `full_cartesian` only | `absent` | `node`, `edge/ac_branch`, `edge/pst`, optional `edge/hvdc`, `unit/net_position` | `node`, `edge`, `unit`, `dimension`, `network_index`, `profile`, `state`, `state_member`, `pst_control` | `result_flow`, `result_dispatch`, `result_objective`, `diagnostic`, `batch_status` |
| `zorba.be-screened-pst-lpf.v1` | `RedispatchProblem x LPFFormulation` | `full_cartesian`, `screened_work_items` | `absent` | `node`, `edge/ac_branch`, `edge/pst`, `unit/net_position`; no other type | M1 core plus `screening` and `work_item` in sparse mode | `result_flow`, `result_dispatch`, `result_objective`, `diagnostic`, `batch_status` |
| `zorba.be-direct-asset-rich-lpf.v1` | `RedispatchProblem x LPFFormulation` | `full_cartesian` only | Pending registration: the committed entry must declare one value; until then the profile, including independent periods, is unsupported | `node`, `edge/ac_branch`, `edge/pst`, `edge/hvdc`, `unit/net_position`, `unit/flex_generator`, `unit/storage`, `unit/ens`, `unit/spill`; no other type | M1 core as extended by `period`, `state_link`, `monitoring`, `control_policy`, `control_policy_exception`, `state_group_member`, and `price_policy` | `result_flow`, `result_dispatch`, `result_net_position`, `result_slack`, `result_storage_soc`, `result_objective`, `diagnostic`, `batch_status` |

M1's exact initial schema is section 4.5. M2 profiles must be equally explicit before registration; generic parser capability does not imply support. A validly encoded item that is not listed in the selected profile is `unsupported` before model construction. A syntactically or structurally invalid item is `error`.

### 5.2 Shared artifact and compatibility checks

The artifact must be committed with NMB protocol code and receive a canonical SHA-256 `logical_digest`. The manifest carries `profile_registry.version` and `profile_registry.logical_digest`. Python obtains the exact pinned artifact from the bridge environment and performs only structural preflight: manifest shape, profile selector, allowed file/table names, Arrow schemas, canonical keys/order, and all declared hash classes. It does not duplicate NMB interpretations of units, control semantics, or model feasibility.

Julia loads the same artifact, recomputes its canonical `logical_digest`, verifies the manifest selector/version/logical digest, and performs authoritative semantic validation before model construction. Both sides therefore reject a version/logical-digest mismatch rather than relying on package version text. A well-formed request that names a profile or registry logical digest not supported by the running bridge returns `unsupported` with `registry_not_supported` or `registry_logical_digest_mismatch`. A malformed, tampered, or unverifiable artifact/logical digest returns `error` with `registry_logical_digest_invalid`.

### 5.3 Registry validation rules

The selected entry must explicitly classify every table as required, optional, or prohibited; every component family/type and column as allowed or prohibited; every policy property as required, optional-with-default, or prohibited; and every result table/column as required or prohibited. Optional data may use a default only when the artifact names that default and its semantic effect. Raw model options, dynamic columns, free-form policy maps, and undeclared result surfaces are prohibited.

The validator must reject all of the following before model construction:

- A pair, profile, registry version, or registry `logical_digest` not accepted by the running bridge.
- An unknown, duplicate, missing, unsafe, or undeclared input/output file.
- A table, component family/type, column, field, unit, response surface, manifest member, or policy value not allowed by the selected entry.
- Missing required data, invalid canonical keys, invalid coordinate completeness, or a profile-default request that does not exactly match the artifact.
- An undeclared result table, result field, solver option, or raw model option.

The normalizer consumes every declared table. It may not preserve opaque extension data for a future parser.

## 6. M1 compatibility profile

### 6.1 Scope

`zorba.m1.redispatch-lpf.v1` is the first profile. It is for the current security-constrained redispatch surface only, under:

```text
RedispatchProblem x LPFFormulation
```

It includes topology, fixed net position semantics, optional compatible HVDC behavior, time, named outage states, overload semantics, and PST controls. It returns generic flow and dispatch results that the Zorba adapter maps to existing flow and PST-dispatch schemas.

The current four-table `parse_zorba` input can inform the Zorba compatibility adapter, but it does not define this profile. The profile uses the generic closed tables in section 4.5, so NMB's generic parser remains the controlling boundary.

### 6.2 Legacy PST conversion into `pst_control`

The legacy names `pst_deg`, `pst_tap`, `pst_tap_min`, and `pst_tap_max` are Zorba compatibility input, never generic transport fields. For each controllable PST edge, the adapter emits one generic `pst_control` row for every M1 `time_id`; scalar legacy values are repeated over that time axis. `pst_deg` must be finite. The conversion is exact:

- With a complete non-null tap triplet `pst_tap`, `pst_tap_min`, and `pst_tap_max`, set `setpoint_deg = pst_deg * pst_tap`. Set `(lower_deg, upper_deg)` to the sorted pair `(pst_deg * pst_tap_min, pst_deg * pst_tap_max)`.
- Without a complete tap triplet, including a scalar `pst_deg` with all tap fields absent or any partial triplet, set `setpoint_deg = 0`. Set `(lower_deg, upper_deg)` to the sorted pair `(-pst_deg, +pst_deg)`. Partial tap values are not guessed or combined.

The Phase 0 fixture with scalar `pst_deg` follows the second rule and must not be rejected merely because it lacks taps. The generic table holds degree values only. The NMB compatibility adapter, after generic validation, applies the selected angle policy and NMB `ta` sign convention; the Zorba adapter and generic transport do not perform that `ta` sign conversion.

The legacy quick solver source `RdsSettings.pst_cost` is EUR/radian, not EUR/degree. The compatibility adapter derives the generic value as `movement_cost_eur_per_deg = pst_cost_eur_per_rad * angle_conversion_factor`. For the legacy quick-solver profile, `angle_conversion_factor = 3.14 / 180`; an exact-pi factor for that legacy path requires a separately approved profile revision under section 6.3. The generic field is EUR/degree, and the NMB adapter converts it with the selected angle convention for NMB's internal radian representation. No contract may relabel the unconverted legacy source as EUR/degree.

### 6.3 Angle-conversion gate

Phase 0 identifies at least two angle-conversion paths. The M1 adapter must declare one of these policies for each exposed API surface:

- `legacy_3_14_over_180`: preserve the legacy `3.14 / 180` behavior.
- `exact_pi_over_180`: use exact-pi conversion where the existing source contract does.
- `approved_difference`: use a changed conversion only with a documented Phase 0 expected difference and a focused test.

The profile must select one policy explicitly. The current legacy `3.14 / 180` API remains on `legacy_3_14_over_180` unless a separately approved `approved_difference` profile revision says otherwise; exact pi is never a silent correction. Do not change a shared Zorba constant as bridge preparation. The acceptance test is the API's declared behavior, not an assumption that exact pi is always preferable.

### 6.4 M1 profile policy and objective semantics

`profile_policy` for M1 is closed to the following fields and semantics:

| Policy | Required semantics |
| --- | --- |
| `base_mva` | Finite `float64 > 0`, required with no hidden default. All bridge power fields are MW; the NMB compatibility adapter converts them to per-unit using this value. |
| `overload` | `mode` is exactly `hard` or `soft`. `hard` permits no overload slack and requires a null price. `soft` requires finite `price_eur_per_mwh >= 0` and adds a non-negative MW overload slack cost of `price_eur_per_mwh * duration_hours * objective_multiplier`. |
| Monitored/reporting edges | `edge.monitored` alone selects overload constraints; `edge.reported` alone selects result-flow rows. Every monitored edge must be reported. Neither flag is inferred from the presence of a rating. |
| `balance_wiggle` | Object with `enabled`, `bound_mw`, and `scope`. `scope` is exactly `node_time_all_states`. Disabled requires zero bound and creates no relaxation. Enabled creates one signed, zero-cost bounded balance relaxation in `[-bound_mw, +bound_mw]` per node/time, shared across all outage/contingency states; it is not a per-`nw` or state-varying slack. The generic profile must represent this scope explicitly, and the NMB adapter must encode it exactly or reject the profile as unsupported. It must not silently substitute independent state slacks. |
| PST movement | `pst_control.movement_cost_eur_per_deg` is EUR/degree, derived from the legacy EUR/radian source as required by section 6.2. M1 charges it once for each edge/time as `price * abs(selected_deg - setpoint_deg)`; the time-only preventive control is shared across its state rows and is not multiplied by state weight or duration. |
| HVDC | An `edge/hvdc` has signed MW positive from `from_node_id` to `to_node_id`. Its `profile` schedule/bounds are per `nw`. Fixed HVDC requires `lower_mw = schedule_mw = upper_mw` and zero adjustment cost. Controllable HVDC requires `lower_mw <= schedule_mw <= upper_mw`; its adjustment cost is `adjustment_cost_eur_per_mwh * abs(dispatch_mw - schedule_mw) * duration_hours * objective_multiplier`. |
| State weighting and gross-up | `objective_multiplier = objective_weight * objective_gross_up`. Every state is constrained regardless of weight. Cost and soft-overload terms that occur per network index use `duration_hours * objective_multiplier`; values are neither normalized nor implicitly grossed up. |
| `angle_conversion_policy` | Exactly one of the policy identifiers in section 6.3; no default. |

### 6.5 M1 response surface and acceptance

M1 permits exactly these generic output tables: `result_flow`, `result_dispatch`, `result_objective`, `diagnostic`, and `batch_status`. `result_flow` keys are `(time_id, state_id, edge_id)` and contains `flow_mw`; `result_dispatch` keys are `(time_id, state_id, component_family, component_id, field)` and contains a typed numeric value; `result_objective` contains one `objective_eur` value for an optimal complete response. `diagnostic` has at least `severity`, `code`, `message`, `source`, and optional table/key context. `batch_status` has `batch_id`, normalized/raw status, raw-status source, objective when meaningful, and output partition identity. Every M1 execution returns a response manifest; an optimal response includes these normal tables.

- A valid synthetic M1 bundle passes registry validation, parses through the generic NMB path, and returns declared generic result tables.
- Missing generated PST rows, duplicate time/control keys, invalid converted bounds, or prohibited asset/control data fail before model construction. A scalar `pst_deg` without a complete tap triplet is valid only through the explicit fallback in section 6.2.
- The compatibility adapter produces Zorba-schema-valid flow and PST dispatch results in Phase 0 canonical order.
- A synthetic M1 parity scenario has nonzero wiggle and at least two states; it asserts node/time state sharing and the legacy PST movement-cost basis.
- The response manifest reports normalized/raw status, objective, diagnostics, both table hash classes, and batch completion.
- Cache identities differ when backend, protocol, NMB revision/environment digest, profile, solver configuration, or request logical inputs change.

## 7. M2 profiles

### 7.1 Common state and overlay contract

M2 `state` rows add three required Boolean role fields: `is_base`, `is_constrained`, and `is_reported`. Exactly one state is base. `is_constrained` selects a state whose limits must be enforced; `is_reported` selects a state whose result rows must be emitted. A state may be constrained and reported. Every non-base state has one `base_state_id`; `state_link` has `(child_state_id, parent_state_id, relation)` with relation restricted by the profile to `inherits` or `contingency_of`. `state_member` remains the concrete membership/status table for a state. Both tables use stable IDs and declared canonical keys.

Zorba owns state-overlay construction, grouping, and screening orchestration. Before serializing a generic bundle it applies its overlays and writes the resulting generic `state`, `state_link`, `state_member`, profiles, and work items. NMB consumes those explicit facts; it must not recreate, merge, or infer Zorba overlay behavior.

### 7.2 M2a: public screened PST-only workflow

**[Verified]** The public Belgian workflow is overload-screened and PST-only. It is not evidence that the direct curative/preventive helper APIs are supported.

**[Planned]** `zorba.be-screened-pst-lpf.v1` is a narrow profile. It reuses canonical topology, state, profile, and explicit PST controls, then returns only the public response surfaces needed by that workflow. Asset-rich components are prohibited. The old public backend remains selectable until the profile passes its parity and release gates.

M2a keeps overload screening as explicit upstream Zorba orchestration. A sparse request uses the `screening` and `work_item` contract in section 4.6: it records all candidate decisions, sends only selected state-time combinations to NMB, and has no implicit absent combinations. It must not silently widen the workload to unscreened direct scenarios while claiming public-workflow parity.

### 7.3 J2/M2b: direct asset-rich curative and preventive helpers

**[Verified]** Direct curative and preventive Phase 0 fixtures are distinct from the public M2a surface.

M2b control policy is a closed schema, not a free-form map:

| Table | Required fields and rules |
| --- | --- |
| `control_policy` | `component_family`, `default_mode`, `state_group_id`, `state_equality_scope`, `time_scope`. There is exactly one row per controlled family. `default_mode` is `fixed`, `curative`, or `preventive`. |
| `control_policy_exception` | `component_family`, `component_id`, `mode`, `state_group_id`, `state_equality_scope`, `time_scope`. One row per component ID; it replaces the full family default rather than inheriting nullable fragments. |
| `state_group_member` | `state_group_id`, `state_id`; its key is the pair and it is the only source of group membership. |

`state_equality_scope` is exactly `none`, `group`, `all_constrained`, or `all_reported`; `time_scope` is exactly `per_time`, `per_period`, or `all_times`. `fixed` takes its profile schedule without an optimization degree of freedom. `curative` may vary at the selected state/time scope. `preventive` requires an equality scope other than `none`: the selected control value is constrained equal over the resolved state group and the resolved time scope. This makes preventive state-equality requirements expressible and testable rather than implicit.

M2b `profile_policy` is closed to the following additional fields:

| Policy | Required semantics |
| --- | --- |
| `allow_ens_and_spill` | Boolean. `false` prohibits both component families and slack rows. `true` only permits the explicit per-family slack policies below; it does not enable them by default. |
| `overload` | The same `hard`/`soft` object and price semantics as M1; no solver default. |
| `slack` | One explicit object per allowed family `ens`, `spill`, or `balance`: `enabled`, `lower_bound_mw`, `upper_bound_mw`, `price_eur_per_mwh`, and `objective_sign`. Bounds are finite and ordered; `objective_sign` is exactly `penalty` or `credit`, applying `+price` or `-price` respectively. Signed prices are not a substitute for this field. |
| `negative_price_transform` | Exactly `reject`, `preserve`, or `clip_to_zero`. It is applied to each raw negative energy-price input before model construction: reject it, preserve its signed value, or replace it with zero. Every allowed policy value has distinct semantics. |
| `storage_initial_policy` | Exactly `fixed_input`, `previous_batch_terminal`, or `zero`. The chosen policy names the source of the initial SOC; no solver default is allowed. |
| `storage_terminal_target_policy` | Exactly `none`, `hard_target`, or `soft_target`, with a declared target and soft-target price where applicable. Input `energy_final` maps to this target only; it is never a reported terminal SOC. |
| `batch_carry_state` | Exactly `independent` or `rolling`. `rolling` requires an explicit canonical batch order and carries the prior completed terminal SOC only after the prior response and `result_storage_soc` table `logical_digest` and `file_digest` values are verified; `independent` carries no state. |
| Output diagnostics | Requires `result_flow`, `result_dispatch`, `result_net_position`, `result_slack`, `result_storage_soc`, `result_objective`, `diagnostic`, and `batch_status`. `result_storage_soc` reports actual initial/final SOC, including `terminal_soc_mwh`; it must not echo `energy_final` as an observed value. |

M2b additionally requires separate monitored and reported edge flags, flex generation bounds/base dispatch/upward and downward prices, storage power/energy/efficiency/cost data, and the closed policies above before direct-helper claims are allowed.

### 7.4 Daily-throughput equivalence gate

The **Daily-throughput equivalence gate** is a hard stop for M2b. Do not map Zorba's daily throughput cap to NMB `max_cycles_per_period` by name. J2/M2b must write down and test the exact numerator, denominator, unit, period membership, timestep duration, charge/discharge treatment, efficiencies, initial/final SOC, and rolling-window behavior.

Proceed only if one of these outcomes is demonstrated:

1. An exact mapping exists and tests cover boundary, partial-period, charge-only, discharge-only, efficiency, and multi-day cases.
2. A new NMB/protocol semantic is added, documented, and validated against those same cases.

If neither outcome holds, stop M2b before production cutover. Retain the current direct-helper backend rather than approximating the constraint.

## 8. Response, error, and partial-batch protocol

### 8.1 Normalized statuses

The only `outcome.normalized_status` values are ordered by exact top-level aggregation precedence:

| Precedence | Normalized status | Meaning | `complete` | Top-level objective and output rules |
| --- | --- | --- | --- | --- |
| 1 | `error` | Protocol validation, environment, parser, model-build, solver, serialization, or unexpected execution failure. | Always `false`. | `outcome.objective` is `null`; only diagnostics and, for a partial response, quarantined records may exist. |
| 2 | `unsupported` | The request is well-formed but outside the registered pair/profile/data semantics. | `true` only for a terminal non-optimal response in which every requested record is terminal; `false` for a partial response. | `outcome.objective` is `null`; no normal result surface is present. |
| 3 | `unbounded` | At least one valid model is unbounded and no higher-precedence status occurs. | `true` only for a terminal non-optimal response in which every requested batch is terminal; `false` for a partial response. | `outcome.objective` is `null`; no normal result surface is present. |
| 4 | `infeasible` | At least one valid model is infeasible and no higher-precedence status occurs. | `true` only for a terminal non-optimal response in which every requested batch is terminal; `false` for a partial response. | `outcome.objective` is `null`; no normal result surface is present. |
| 5 | `optimal` | Every requested batch is optimal and all profile-required result surfaces are present. | Always `true`. | Objective is finite when the profile defines one, and every required normal output table is present with both hash classes verified. |

Aggregate `outcome.normalized_status` in the table's order: any `error`, then any `unsupported`, then any `unbounded`, then any `infeasible`, otherwise `optimal` only when all batches are optimal. A missing or nonterminal batch is `error`. `response_kind` is `optimal` only in the all-optimal case. If any optimal batch coexists with a non-optimal batch, `response_kind` is `partial`, regardless of the aggregate normalized status. Otherwise a terminal non-optimal response uses the matching `response_kind`. A partial response always has `complete: false`; `complete` otherwise means processing reached terminal, recorded outcomes, not that it succeeded. A complete infeasible response is therefore not a successful result bundle.

`raw_status` preserves the backend-specific string and `raw_status_source` identifies where it came from, such as protocol validation, Julia, MathOptInterface, or the optimizer. Raw values are diagnostic provenance; they are not cross-backend equality fields.

### 8.2 Outcome, objective, and diagnostics

`outcome` is required in every response manifest. It contains normalized/raw status, raw-status source, nullable objective, diagnostics, per-batch status, and `complete`. Its objective is numerical only for an optimal response when the profile defines one; it is `null` for every terminal non-optimal or partial response. Terminal non-optimal responses have no `output_tables` or `partial_output_tables` and require structured diagnostics with at least severity, code, message, source, and optional table/key context. Human-readable exception text alone is insufficient.

The M1 response surface includes objective and diagnostics. M2b additionally exposes final net position, dispatch, ENS/spill, and SOC diagnostics as declared result tables. Do not infer those values from a flow table.

### 8.3 Partial and quarantined batches

When a request contains independently executable batches:

- Every `outcome.batches` entry has `batch_id`, normalized status, raw status, raw-status source, nullable objective, and output partition identity.
- An optimal response advertises all and only the profile-required normal tables in `output_tables`. A partial response never advertises `output_tables`.
- A partial response places every retained successful result partition and every emitted output/status table descriptor in `partial_output_tables` below `quarantine/`. Each is marked `quarantined`, cannot satisfy a profile normal response-surface requirement, and cannot be promoted by aggregation.
- Legacy Frank behavior is represented as `response_kind: "partial"`: successful Frank batch partitions are retained under `quarantine/`, the infeasible batch has an `outcome.batches` status/diagnostic record, `outcome.objective` is `null`, and `complete` is `false`. These are not a normal Zorba solution or aggregate study result.
- Profile-specific callers decide whether and how to inspect quarantined artifacts. No caller may treat a partial response as full success.

## 9. Bridge and cache implementation tasks

### 9.1 J0: immutable release and protocol foundation

**NMB work:**

- Freeze the initial pin at `9682804defd99de42a62ee7b89e05dd8584344e4` and record the resolved Julia environment digest.
- Choose and commit a bridge-specific Julia project. The expected location is a sibling `julia/` project in Zorba; any different location must be named in the bridge manifest and handoff. Its committed `Project.toml` and `Manifest.toml` must pin NMB at the immutable commit and declare Arrow, a JSON dependency, and HiGHS.
- Activate NMB's Arrow weak dependency from that bridge environment and prove it with an Arrow bundle test. NMB's source availability alone does not activate the Arrow path.
- Define protocol `1.0`, canonical JSON/table serialization, `logical_digest` and `file_digest` behavior, and manifest location/layout.
- Define compatibility behavior for future protocol/profile changes: additive compatible fields, profile version bump, or protocol major bump.

**Gate:** A clean checkout of the committed bridge project resolves the recorded NMB commit, Arrow, JSON dependency, HiGHS, and produces the recorded environment identity. No dependency declaration uses a nonexistent `v0.9.0` tag. Xpress is not claimed as wired here; its environment and license proof remain the P2 production gate.

### 9.2 J1: generic bundle and registry validator

**NMB work:**

- Implement the manifest-aware reader/normalizer that consumes or rejects every declared table before invoking downstream `parse_tables`/`parse_arrow`.
- Implement the versioned closed registry artifact, Python structural preflight contract, Julia authoritative validation, and exact logical/file hash checks.
- Register only `RedispatchProblem x LPFFormulation` and M1 compatibility profile `zorba.m1.redispatch-lpf.v1`.
- Implement canonical generic result serialization for its declared response surface.

**Gate:** Tests reject unregistered pairs/profiles, unknown/prohibited manifest fields, tables, components, columns, policies, units/indexes, duplicate canonical keys, sparse-coordinate violations, and mismatched registry `logical_digest`, table `logical_digest`/`file_digest`, or `request_logical_digest` values before model construction. `parse_arrow` cannot silently ignore a declared file.

### 9.3 M1-Z: Zorba adapter, CLI, and cache identity

**Zorba work:**

- Add a thin adapter that converts existing M1 inputs to the selected generic profile and maps generic output tables back to current Zorba result schemas.
- Materialize temporary Arrow/manifest bundles, invoke the pinned Julia CLI with its parent environment, and read the completed manifest before reading outputs.
- Include `backend`, `protocol_version`, `nmb_revision`, `nmb_environment_digest`, `semantic_profile`, `solver_configuration`, and `request_logical_digest` in cache identity. `file_digest` values are checked for transport integrity but never form cache identity.
- Preserve the existing backend behind explicit selection until validation and observation gates pass.

**Gate:** A small Python-to-Julia-to-Python test proves data, status, output-table logical/file digest verification, and cache separation. Manual deletion may clean old artifacts, but changing a backend must never reuse an old cache key.

### 9.4 P1: synthetic parity

**Shared work:**

- Build hand-workable synthetic cases independent of unavailable private SMA packages.
- Test soft/hard overload behavior, base and outage states, fixed/controllable PSTs, explicit PST bounds, legacy PST movement-cost conversion, nonzero state-shared wiggle with at least two states, compatible HVDC direction, result ordering, and status/error paths.
- Test every supported angle policy against the corresponding Phase 0 expectation.
- Compare objective only after the profile declares its cost/state weighting semantics.

**Gate:** Every delta is either within the Phase 0 comparison policy or a reviewed profile-level expected difference. No error/status/ordering difference is excused by a numerical tolerance.

### 9.5 M2a: public screened PST-only profile

**Shared work:**

- Register and implement the separate public profile.
- Keep screening upstream in the Zorba workflow.
- Map only public workflow inputs and response outputs; reject asset-rich direct-helper data as unsupported.

**Gate:** Public Belgian scenarios validate through the profile without claiming curative/preventive asset-rich parity.

### 9.6 J2/M2b: direct asset-rich profile

**Shared work:**

- Add validated monitoring/reporting, flex, storage, slack, control mode, and negative-price semantics.
- Add direct curative/preventive response tables and direct-helper adapter mappings.
- Resolve the storage stop condition before an end-to-end production claim.

**Gate:** Curative and preventive Phase 0 fixtures validate independently. Direct results include final net position, dispatch, ENS/spill, SOC diagnostics, and normalized status.

### 9.7 P2: solver, performance, cutover, and cleanup

**Shared work:**

- Use HiGHS for portable protocol/CI coverage. Validate against the production solver only when both implementations use the same solver.
- Verify Xpress Julia wiring and license inheritance as an environment gate; do not assume it works merely because Python has a solver configuration.
- Measure complete-study wall time, memory, startup/precompile cost, batching, concurrency, and license limits before choosing an execution shape.
- Cut over one profile at a time, retain rollback selection for the defined observation period, then schedule cleanup.

**Gate:** Release evidence includes solver parity conditions, performance decision, cache identity keyed by `request_logical_digest`, rollback path, and observed production behavior. Dependency removal is a later explicit decision.

## 10. Tests, CI, and release controls

### 10.1 Required test layers

| Layer | Required checks |
| --- | --- |
| Protocol unit tests | Canonical JSON logical digests, raw Arrow file digests, number restrictions, manifest-variant closure, bad paths, changed revision/configuration logical identity, registry logical-digest mismatch, and atomic completion behavior. |
| Registry tests | Required/optional/prohibited tables, fields, components, policy values, units, response surfaces, declared period-coordinate modes, full versus sparse coordinates, and rejection before model construction. |
| NMB parser tests | The manifest-aware reader consumes/rejects every declared table before `parse_tables`/`parse_arrow`; profile-specific result formatting preserves stable inverse coordinate keys. |
| Synthetic bridge tests | Python CLI round trip with the committed Arrow/JSON/HiGHS bridge environment; status precedence, response variants, completion, diagnostics, output logical/file digests, timeout/error behavior, and quarantined partial batches. |
| Zorba adapter tests | Legacy scalar/tap PST conversion, legacy PST movement-cost basis, state-shared wiggle, canonical input/output ordering, cache logical identity, selected angle policy, and Phase 0 scalar-PST fallback. |
| Phase 0 promotion tests | Existing Zorba fixtures and goldens once private SMA dependencies are available. |
| Production validation | Same-solver comparison, performance, Xpress environment gate when applicable, and profile-by-profile cutover evidence. |

### 10.2 CI policy

CI must run portable, deterministic protocol and synthetic bridge tests without requiring private SMA dependencies or an Xpress license. The Phase 0 golden job is a provisioned integration gate until dependencies are available; its blocked state must be visible rather than silently skipped as a passing parity claim.

Use the committed bridge Julia project, pinned NMB commit, and resolved Julia environment in CI. Cache the Julia depot only as an optimization; correctness comes from the manifest pin and logical digest. CI must exercise Arrow through the bridge environment, rather than assuming NMB's weak dependency is active. The CI result must include the selected protocol/profile, registry logical digest, and NMB identity in failure diagnostics.

### 10.3 Release policy

- Pin `9682804defd99de42a62ee7b89e05dd8584344e4` until an immutable NMB release tag is published and verified.
- A change to NMB revision or resolved environment requires a cache key with a new `request_logical_digest` and targeted compatibility tests.
- A new problem/formulation pair requires a registry entry, synthetic tests, and an explicit profile acceptance gate. It is not activated by generic parser availability alone.
- Additive fields are accepted only when the profile marks them optional and the canonical logical-digest/schema rules allow them. Semantic changes require a profile version bump; incompatible envelope changes require a protocol major version bump.
- Keep the old backend available through the agreed release observation period. Delay dependency cleanup until both M2a and M2b are stable and an explicit owner approves removal.

## 11. Non-goals

- Hydro, reservoir/pumping/inflow semantics, and unit commitment.
- PTDF/flow-based migration.
- Changes to `FbCalculator` or `Nm1Calculator`.
- A claim that `parse_zorba` already satisfies generic M1/M2 requirements.
- Implicit support for all NMB `ProblemType` and `FormulationType` combinations.
- Conflating monitored edges with reporting edges.
- Treating daily throughput caps and `max_cycles_per_period` as equivalent without proof.
- Solving cache invalidation by manual deletion rather than including backend/protocol/revision identity and `request_logical_digest`.

## 12. Unresolved decisions and explicit gates

| Decision | Current state | Required resolution |
| --- | --- | --- |
| Published immutable NMB release | No immutable `v0.9.0` tag exists. | Keep the full commit pin; replace it only after a tag and resolved bundle are verified. |
| Final protocol schema locations and generated validators | Planned. | J0/J1 choose the committed versioned schema/registry artifact location and test its `logical_digest` from both Julia and Python. |
| M1 PST schema and fallback | Defined in sections 4.5 and 6.2. | Implement unchanged, including the scalar Phase 0 fallback, then test it. |
| Legacy angle behavior | Phase 0 shows multiple current conversion paths. | Select/preserve a policy per exposed API or record an approved expected difference. |
| Xpress from Julia | Assumption. | Prove environment/library/license wiring in a toy solve before using it as a validation dependency. |
| Objective/state weighting | M1 semantics are defined in section 6.4. | Test objective parity before accepting values; add an M2 profile-specific rule before M2 objective comparisons. |
| Storage throughput semantics | Assumption. | Prove exact mapping or add an extension; otherwise stop M2b. |
| Direct preventive control sharing | M2b schema is defined in section 7.3. | Demonstrate its state/time equality behavior against the Phase 0 preventive fixture rather than inferring it from public M2a behavior. |
| Batching/parallelism | Planned. | Measure with the same solver, including license constraints, before production selection. |

The implementation rule is simple: add a new generic table or profile field only when it is required by an accepted NMB pair/profile contract and has a testable semantic definition. That keeps the bridge extensible without turning it into an opaque payload.