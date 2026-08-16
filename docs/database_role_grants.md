# `database_role_grants` — Snowflake DATABASE ROLE grants

**Fixes:** [dbt-core#13756](https://github.com/dbt-labs/dbt-core/issues/13756) · **Remove when:** #13756 ships native DATABASE ROLE support

## The problem

dbt's native `grants` config issues `GRANT ... TO ROLE <name>`. Snowflake also supports `DATABASE ROLE` as a distinct recipient type — scoped to a single database — but dbt has no way to express the distinction. You're left with manual DCL, post-hooks, or `meta`-driven workarounds.

## The fix

A parallel config key `database_role_grants` with the **same shape as `grants`**, hooked into dbt's existing grant lifecycle via a `snowflake__apply_grants` dispatch override. No custom materializations, no hooks, no `meta`.

- **`macros/database_role_grants/database_role_grants.sql`** — SQL generators, SHOW GRANTS reader, add/revoke diff logic, and the `apply_database_role_grants` entry point.
- **`macros/database_role_grants/snowflake__apply_grants.sql`** — dispatch override. Calls the stock Snowflake adapter macro for normal ROLE grants, then `apply_database_role_grants` for DATABASE ROLEs. Gated: if `database_role_grants` is absent from config, it's a pure passthrough. Non-Snowflake adapters never dispatch here.

## Installation

**1.** Add to `packages.yml` and run `dbt deps`.

**2.** Add the dispatch block to your project's `dbt_project.yml` (shared with `snapshot_append` if you use both):

```yaml
dispatch:
  - macro_namespace: dbt
    search_order: ['dbt_hacks', 'dbt']
```

**3.** Configure your models:

```yaml
models:
  my_project:
    dim_customers:
      +grants:
        select:
          - ANALYST_ROLE            # standard ROLE — handled by native dbt
      +database_role_grants:
        select:
          - REPORTING_DB_ROLE       # → mydb.REPORTING_DB_ROLE (inherits relation's database)
          - other_db.AUDIT_ROLE     # explicit database-qualified name
```

## Behaviour

| Scenario | Result |
|---|---|
| `database_role_grants` absent | pure no-op |
| Non-Snowflake adapter | never dispatched — no effect |
| `should_revoke=False` | GRANT all configured roles (no SHOW, no diff) |
| `should_revoke=True` | `SHOW GRANTS ON <relation>` → diff → GRANT/REVOKE as needed |
| Bare role name | auto-qualified with the relation's database |
| `db.role` name | passed through as-is |

## Revoke / diff semantics

Mirrors `default__apply_grants`:
- `should_revoke=True` (full-refresh with `copy_grants` on Snowflake): reads existing DATABASE ROLE grants via `SHOW GRANTS ON <relation>`, diffs against config, issues only the necessary statements.
- `SHOW GRANTS` output is filtered to `granted_to = 'DATABASE_ROLE'`; normal ROLE grants are left to the stock macro.

## Compatibility

| Adapter | Status |
|---|---|
| Snowflake | ✅ primary target |
| BigQuery, Databricks, DuckDB, Postgres | ✅ no-op — `snowflake__apply_grants` is never dispatched |

## Tests

```bash
cd integration_tests && pytest tests/test_database_role_grants.py -v
```

10 tests covering: grant/revoke SQL generation, database-prefix defaulting, diff logic (add-only, revoke-only, mixed, no-op, case-insensitive, prefix-stripping), and a parse smoke test. DuckDB only, no Snowflake credentials needed.
