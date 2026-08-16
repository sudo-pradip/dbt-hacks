# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.1.0] — 2026-08-16

### Added

- **`source()` respects `--defer`** ([dbt-core#10912](https://github.com/dbt-labs/dbt-core/issues/10912))
  Defer-aware `source()` that resolves to the production catalog under
  `--defer`, mirroring `ref()` semantics. Activated via a one-time 3-line
  shim in the consuming project. Zero-config by default; optional kill switch
  and explicit-catalog override vars.

- **`strategy: append`** ([dbt-core#3878](https://github.com/dbt-labs/dbt-core/issues/3878))
  Custom snapshot strategy for append-only sources where the same
  `unique_key` arrives multiple times per run. Fixes
  `ERROR_ON_NONDETERMINISTIC_MERGE` on Snowflake and silent history loss
  on other adapters. Uses `lead()` to chain validity windows per version;
  merge stays deterministic via per-version `dbt_scd_id`.

- **`database_role_grants`** ([dbt-core#13756](https://github.com/dbt-labs/dbt-core/issues/13756))
  Parallel config key (`database_role_grants`) that grants privileges to
  Snowflake `DATABASE ROLE` recipients via a `snowflake__apply_grants`
  dispatch override. Supports revoke/diff semantics matching native dbt
  `grants`. Pure no-op on non-Snowflake adapters and when the config key
  is absent.

- Integration test suite (pytest + DuckDB) covering all three features,
  ~30 s, no warehouse credentials required.

- `docs/` directory with full per-feature documentation.

[0.1.0]: https://github.com/sudo-pradip/dbt-hacks/releases/tag/v0.1.0
