# `strategy: append` — SCD2 snapshots over append-only sources

**Fixes:** [dbt-core#3878](https://github.com/dbt-labs/dbt-core/issues/3878) · **Remove when:** #3878 ships a native append strategy

## The problem

dbt's built-in snapshot strategies (`timestamp`, `check`) assume the source delivers **at most one row per `unique_key` per run**. Append-only sources break this:

1. On Snowflake — the snapshot merge fails with `ERROR_ON_NONDETERMINISTIC_MERGE`.
2. On other adapters — intermediate versions are silently dropped; `dbt_valid_from/to` chains are wrong.

## The fix

Two macros in `macros/snapshot_append/` implement a custom `strategy: append`:

- **`snapshot_append_strategy.sql`** — the strategy definition via dbt's official extension API (`snapshot_<name>_strategy`). dbt finds it across installed packages automatically; no dispatch config needed.
- **`snapshot_append_overrides.sql`** — two gated `default__` overrides that only fire when `strategy == 'append'`. All other snapshots fall through to stock dbt.

How it works: `lead()` over `(partition by unique_key order by updated_at)` chains validity windows for N source versions in one run. One `update` row per key closes the open snapshot row at the earliest new version's timestamp. Per-version `dbt_scd_id` keeps the merge deterministic.

## Installation

**1.** Add to `packages.yml` and run `dbt deps`.

**2.** Add the dispatch block to your project's `dbt_project.yml` (required once; shared with `database_role_grants` if you use both):

```yaml
dispatch:
  - macro_namespace: dbt
    search_order: ['dbt_hacks', 'dbt']
```

**3.** Write your snapshot:

```sql
{{ config(
    unique_key='order_id',
    strategy='append',
    updated_at='loaded_at',
    target_schema='snapshots'
) }}
select *
from {{ source('raw', 'orders_append') }}
qualify row_number() over (
    partition by order_id, loaded_at
    order by loaded_at
) = 1
```

See `shims/snapshot_append/orders_snapshot_example.sql` for a complete example.

## Constraints

- `(unique_key, updated_at)` must be unique in the snapshot SELECT — use the `qualify` dedupe above.
- Classic meta column names only (`snapshot_meta_column_names`, `dbt_valid_to_current`, `hard_deletes: new_record` are not supported).
- Hard deletes are not invalidated.
- `select * replace` (used in the first-run build wrapper) requires Snowflake / BigQuery / Databricks / DuckDB — **not** Postgres/Redshift.

## Compatibility

| Adapter | Status |
|---|---|
| Snowflake | ✅ primary motivation — fixes nondeterministic merge |
| BigQuery, Databricks, DuckDB | ✅ |
| Postgres, Redshift | ❌ no `select * replace` |

## Tests

```bash
cd integration_tests && pytest tests/test_snapshot_append.py -v
```

6 scenarios (open-row uniqueness, validity chain, scd_id uniqueness, idempotency, intermediate versions, passthrough gate). DuckDB only, ~30 s.

## Maintenance

On major dbt-core upgrades, diff upstream `global_project/macros/materializations/snapshots/helpers.sql` against `snapshot_append_overrides.sql`. The staging→merge contract (`dbt_change_type`, `dbt_scd_id`, `dbt_valid_to`) has been stable for years; the smoke test fails loudly if it ever moves.
