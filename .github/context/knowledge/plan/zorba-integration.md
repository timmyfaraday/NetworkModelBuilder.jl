# Zorba and NetworkModelBuilder.jl integration plan

**Status:** revised 2026-09-03. This is the delivery plan for a versioned Zorba to NetworkModelBuilder.jl (NMB) bridge. The detailed implementation contract is in [zorba-adapter-handoff.md](zorba-adapter-handoff.md).

## Reading this plan

| Label | Meaning |
| --- | --- |
| **[Verified]** | Checked against the named repository state on 2026-09-03, or supplied as a binding project fact. |
| **[Planned]** | Required work that does not exist yet. |
| **[Assumption]** | A dependency or semantic choice that must be demonstrated before it becomes an acceptance claim. |

This plan deliberately does not assert a current passing-test count. Test counts and wall-clock measurements age quickly; each delivery gate below names the behavior that must be checked instead.

## 1. Reference state and release policy

**[Verified]** The prior Zorba plan reference is `99f60a5a448c6788fd6188504e5c7980e83c9943`. Zorba is currently at `069e8aad18d662316cfd028602c3fcd20be219c1`, 16 commits later.

**[Verified]** NMB is currently at `9682804defd99de42a62ee7b89e05dd8584344e4`. Its `Project.toml` declares package version `0.9.0`, but no immutable `v0.9.0` tag exists. The integration must pin this full commit, plus the resolved Julia `environment_digest`, until a published immutable release tag is available.

**[Verified]** Zorba has Phase 0 semantic-contract work in `docs/network_model_parity_conventions.md` and `tests/fixtures/baseline_parity`. Those fixtures and their eventual goldens are the behavioral source of truth. Golden generation is currently blocked by unavailable private SMA dependencies; NMB must not recreate or silently fork that contract.

**[Planned]** A bridge invocation will identify all of the following in a versioned manifest:

- Protocol version and `request_logical_digest`.
- Immutable NMB revision and resolved Julia `environment_digest`.
- Selected `ProblemType`, `FormulationType`, semantic profile, solver, and solver configuration.
- Input and output table names, paths, `logical_digest`, `file_digest`, and row counts.
- Normalized status, raw backend status, objective, diagnostics, and batch completion state.

## 2. Architecture decision

The bridge has two tiers. The first is a generic, versioned NMB bridge envelope containing a canonical generic model bundle. The second is a Zorba compatibility adapter that translates Zorba business orchestration and schemas to and from that bundle.

**[Verified]** NMB already has generic tabular entry points, `parse_tables` and `parse_arrow`, for component tables, dimensions, and varying profiles. Its current `parse_zorba` adapter accepts only `grid`, `net_position`, optional `hvdc`, and optional `outage`; it emits only `grid_flows` and `pst_dispatch`. It is useful compatibility transport, but it is not a general M1 or M2 protocol.

**[Planned]** The selected `(ProblemType, FormulationType)` controls the data contract. A strict compatibility and data-profile registry, keyed first by that pair and then by an explicit semantic profile, will declare:

- Required, optional, and prohibited tables, components, and fields.
- Units, indexing, state semantics, and canonical result ordering.
- Supported response tables and mandatory diagnostic fields.
- The status rules and any approved expected semantic differences.

The bridge validates this registry before invoking Julia. An unlisted pair, profile, table, component, or field is `unsupported`; a generic bundle is not an unchecked blob. The first supported entry is deliberately narrow:

```text
RedispatchProblem x LPFFormulation
```

No other pair is promised merely because NMB may implement it internally.

### Ownership

| Boundary | Owner | Responsibility |
| --- | --- | --- |
| Phase 0 semantic contract and goldens | Zorba | Defines behavioral parity, canonical IDs, statuses, ordering, and tolerated numeric differences. |
| Zorba compatibility adapter | Zorba | Maps Zorba schemas and orchestration to/from a selected generic profile. It does not choose NMB model semantics. |
| Generic bundle, manifest, and profile registry | NMB protocol surface | Defines canonical tables, profile validation, parser mapping, and generic result surfaces. |
| CLI process boundary | Shared protocol, implemented at the bridge | Materializes Arrow tables, validates the manifest, runs Julia, and writes a completed manifest. It contains no Zorba business logic. |
| Model construction and solve | NMB | Parses the validated bundle through `parse_tables`/`parse_arrow`, constructs the selected pair, solves it, and normalizes generic results. |

## 3. Scope

### In scope

- A file/subprocess bridge using a JSON manifest and Arrow tables. Python writes a validated bundle, Julia reads it, and Python reads a validated response. The parent environment is passed through to the subprocess so existing solver-license configuration can be inherited.
- A cache identity that includes backend name, protocol version, profile version, immutable NMB revision, and `request_logical_digest` from the first M1 bridge introduction. Manual cache deletion is operational cleanup only, not the migration's correctness mechanism.
- M1 compatibility for Zorba's security-constrained redispatch surface.
- M2a for the public Belgian overload-screened, PST-only workflow.
- M2b for the distinct direct curative and preventive helper surfaces exercised by Phase 0, after an asset-rich profile is validated.
- Synthetic parity, then Phase 0 promotion and production validation with the relevant solver configuration.

### Out of scope

- Hydro, unit commitment, and a PTDF or flow-based migration.
- Changes to `FbCalculator` or `Nm1Calculator`.
- Treating `parse_zorba` as a complete general-purpose transport.
- Deleting the existing Python or SMA paths before their replacement has passed validation and completed a defined release observation period.

## 4. Semantic rules that change the old plan

### M1 PST controls and angle policy

**[Verified]** The legacy M1 PST surface uses `pst_deg`, `pst_tap`, `pst_tap_min`, and `pst_tap_max`. The Belgian surface uses time-indexed setpoints and bounds. A scalar, zero-centered adapter interpretation is insufficient for either contract where those controls vary over time.

**[Planned]** The M1 profile will carry explicit time-indexed PST control data, including setpoint and lower and upper degree bounds. The Zorba compatibility adapter expands legacy scalar PST input into those rows using the handoff's deterministic fallback; it never leaves scalar behavior implicit.

**[Verified]** Phase 0 records a legacy `3.14 / 180` conversion in one redispatch API and exact-pi conversion in other Zorba paths. The former M1-0 proposal to globally "fix" that constant is replaced by an angle-conversion policy gate. The M1 profile must either preserve the legacy behavior for that API surface or record an approved expected difference with a targeted parity test. It must not change the behavior incidentally.

### M2 is two separate deliveries

**[Verified]** The public Belgian workflow is overload-screened and PST-only. The direct curative and preventive helpers covered by Phase 0 fixtures are a different, richer surface.

**[Planned]** M2a covers only the public screened PST-only workflow. M2b covers direct helper parity and must include monitored versus reporting edges, flex generation, storage, slack, control modes, and negative-price policy. M2b results must include final net position, dispatch, ENS and spill, and storage state-of-charge diagnostics.

### Storage stop condition

**[Assumption]** A Zorba daily throughput cap may be representable using NMB `max_cycles_per_period`, but that has not been proven. Do not call the two equivalent.

**[Planned]** M2b stops before cutover unless tests establish an exact mapping for period boundaries, timestep duration, charge/discharge accounting, efficiencies, initial/final SOC, and partial-day windows. If no exact mapping exists, the work must define and test an NMB or protocol extension. A silent approximation is not acceptable.

## 5. Revised high-level sequence

### P0 - Phase 0 promotion gate

Promote the existing Zorba semantic contract and fixture scenarios into the migration acceptance suite once private SMA dependencies are available. Keep the Zorba documents and canonical fixture implementation as the source of truth.

**Gate:** the fixture generator can run in a provisioned environment; canonical input/output artifacts, statuses, and tolerated fields are reviewed. Until then, the blocked state is recorded rather than replaced with duplicated goldens.

### J0 - Immutable release and protocol decision

Pin NMB at `9682804defd99de42a62ee7b89e05dd8584344e4`, record the resolved Julia environment digest, choose protocol `1.0`, and define canonical table serialization and hashing. Do not depend on `v0.9.0` as a tag until a real immutable tag has been published and verified.

**Gate:** a clean environment resolves the recorded NMB commit and produces the recorded bundle identity; changing the commit, protocol, or canonical serializer changes the identity predictably.

### J1 - Generic envelope, profile registry, and M1 compatibility profile

Implement the canonical bundle and the pre-Julia registry validator aligned with NMB `parse_tables`/`parse_arrow`. Register only `RedispatchProblem x LPFFormulation` and its M1 compatibility profile. Model time, period, profiles, contingency state, and explicit time-indexed PST controls rather than extending a Zorba-only four-table payload.

**Gate:** valid M1 synthetic bundles normalize to NMB tables; missing required data and prohibited data are rejected before a Julia process starts; every emitted table is declared by the selected response surface.

### M1-Z - Python CLI bridge and cache identity

Add the Zorba-side compatibility adapter and a thin CLI wrapper. The adapter writes Arrow input tables and a manifest, launches the pinned Julia environment, reads generic result tables, and maps them to existing Zorba result schemas. Cache keys include backend, protocol, NMB revision, profile version, solver configuration, and `request_logical_digest` from day one.

**Gate:** a small end-to-end case survives Python to Julia to Python with a completed manifest, schema-valid legacy-shaped results, and cache separation from the existing backend.

### P1 - Synthetic parity and semantic gate

Run hand-workable networks through both the legacy implementation and the M1 profile. Exercise soft versus hard overload handling, outage states, fixed and controllable PST behavior, HVDC direction where the M1 profile permits it, status normalization, objective reporting, and the selected angle policy.

**Gate:** differences are either within the Phase 0 rules or documented expected differences approved at the profile level. There are no unclassified objective, status, ordering, or unit-conversion deltas.

### M2a - Public screened PST-only workflow

Add a separate public Belgian profile and route only the existing overload-screened/PST-only public workflow behind an explicit backend flag. Preserve its public return contract and avoid claiming parity for direct asset-rich helpers.

**Gate:** selected Belgian screened cases return the public flow and PST response surfaces with the Phase 0 IDs, ordering, status, and angle policy. The old backend remains selectable.

### J2/M2b - Direct asset-rich profile

Extend the generic registry and bundle only after M2a has passed its gate. Support the direct curative and preventive helper inputs using generic component, profile, state, monitoring, control-mode, and pricing data. Add the required final net position, dispatch, ENS/spill, and SOC response surfaces.

**Gate:** the exact storage-cap semantic test passes or an explicit extension does; direct curative and preventive fixtures prove the declared control-mode behavior; unsupported islands or configurations return normalized `unsupported` or `error`, never a fabricated solution.

### P2 - Production solver, performance, cutover, and delayed cleanup

Verify the production solver path, including Xpress if it is required for like-for-like validation, then measure performance with the same solver on both sides. Decide batching and concurrency from measurements, including license limits. Cut over each approved workflow behind explicit release criteria, retain the old path for the agreed observation period, and clean dependencies only after both migrations are stable.

**Gate:** production validation, performance decision, cache identity, rollback path, and release observation are recorded. Cleanup is delayed; manual cache deletion is not used as evidence that the new backend is correct.

## 6. Validation and status protocol

Each response has a normalized status of exactly `optimal`, `infeasible`, `unbounded`, `error`, or `unsupported`. It also preserves a machine-readable raw backend status, objective when meaningful, structured diagnostics, and per-batch status. A raw solver string is provenance, not a parity field by itself.

Compare results in this order:

1. Manifest identity, selected profile, and successful validation.
2. Normalized status and declared output-table presence.
3. Objective and diagnostics where the profile defines them.
4. Canonical result keys and ordering.
5. Numerical fields declared by the Phase 0 scenario, using its tolerance policy.
6. M2b-only final net position, dispatch, ENS/spill, and SOC diagnostics.

For a partial batch response, each completed batch must identify its own status and output-table partitions. The top-level response cannot be `optimal` unless every requested batch is `optimal`. Consumers must not aggregate incomplete output as a successful study.

## 7. Solver and performance policy

**[Planned]** Use HiGHS for portable protocol and CI coverage. Use the same production solver on both old and new paths when validating numerical parity. The availability and Julia wiring of Xpress are environment gates, not facts assumed by this plan.

**[Planned]** Measure a whole-study bridge before choosing one Julia process, Julia-side parallelism, or multiple Python-launched Julia processes. Record wall time, peak memory, cold-start/precompile behavior, and license concurrency constraints. Do not compare different solvers and attribute the difference to the bridge.

## 8. Definition of done

M1 is complete when the registry-backed M1 profile is validated through the CLI bridge, synthetic and promoted Phase 0 gates pass, result/status contracts are stable, and the legacy implementation remains selectable through the observation period.

M2a is complete when the public Belgian screened PST-only workflow has passed its own profile-specific gate. M2b is complete only when direct curative/preventive semantics and storage behavior are validated separately.

Neither completion permits a broad dependency removal by default. Hydro, unit commitment, PTDF migration, and changes to `FbCalculator` or `Nm1Calculator` remain out of scope.
