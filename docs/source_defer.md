# `source()` respects `--defer`

**Fixes:** [dbt-core#10912](https://github.com/dbt-labs/dbt-core/issues/10912) · **Remove when:** #10912 or #9395 ships

## The problem

When you run `dbt build --select my_model+ --defer --state prod_artifacts`:
- Every `ref()` correctly resolves to **production**. ✓
- Every `source()` still resolves to your **dev database** — where raw tables usually don't exist. ✗

Result: your run fails with "relation does not exist", or silently reads a stale dev copy.

The root cause: dbt's `Manifest.merge_from_artifact` only defers *refable* nodes (models, seeds, snapshots). Sources are skipped ([dbt-core#10912](https://github.com/dbt-labs/dbt-core/issues/10912)).

## The fix

`dbt_hacks.defer_source()` replays `ref()`'s exact defer decision for sources, inferring the production catalog from where your deferred models live.

**One caveat:** `source()` is a Jinja context property, not a dispatched macro — only root-project macros can override it ([dbt-core#4491](https://github.com/dbt-labs/dbt-core/issues/4491)). Activation requires a one-time 3-line shim in your project; the package carries all the logic.

## Installation

**1.** Add to `packages.yml` and run `dbt deps`.

**2.** Copy `shims/source_defer/source.sql` into your project's `macros/` directory:

```jinja
{# macros/source.sql #}
{% macro source(source_name, table_name) %}
    {% do return(dbt_hacks.defer_source(source_name, table_name)) %}
{% endmacro %}
```

Done. No other changes needed.

> If you already override `source()`, merge the single delegation line into your existing macro instead.

## Configuration

Zero-config by default. Two optional vars in `dbt_project.yml`:

```yaml
vars:
  dbt_hacks__source_defer_enabled: true          # kill switch (default: true)
  dbt_hacks__source_defer_database: "RAW_PROD"   # explicit catalog override
```

## Behaviour

| Invocation | `source()` resolves to |
|---|---|
| no `--defer` | stock dbt — pure no-op |
| `--defer`, source exists locally | local relation |
| `--defer`, source missing locally | production (inferred) catalog |
| `--defer --favor-state` | production catalog, always |

## Safety rails

- **No-op without `--defer`** — normal runs are completely untouched.
- **Explicit-database sources are never auto-deferred.** A source with `database: RAW` declared in `sources.yml` points at a shared catalog; rewriting it would be wrong.
- **DAG is intact** — `builtins.source()` is called first, so parse-time tracking and native error messages behave exactly as stock dbt.
- **Deterministic** — ties in the catalog inference break alphabetically.

## Limitations

1. Only the **database/catalog** is deferred — schema and identifier are assumed identical across environments.
2. If prod models live in `ANALYTICS_PROD` but raw lives in `RAW_PROD`, set `dbt_hacks__source_defer_database: RAW_PROD`.
3. Sources with Jinja-driven databases (`{{ env_var('RAW_DB') }}`) look explicit to the gate — set the var to override.
4. Cross-catalog reads must be legal on your warehouse (Postgres has no cross-db reads).
5. `dbt docs generate` bypasses `source()` overrides — docs show local location; runs defer.
6. dbt Fusion (v2) is untested.

## Compatibility

| Adapter | Status |
|---|---|
| Snowflake, BigQuery, Databricks, DuckDB | ✅ |
| Redshift | ⚠️ cross-db read restrictions |
| Postgres | ⚠️ no cross-db reads |
| Spark | ➖ no database concept |

dbt versions: `>=1.3.0, <2.0.0`

## Tests

```bash
cd integration_tests && pytest tests/test_source_defer.py -v
```

9 scenarios, DuckDB only, ~30 s, no warehouse needed.
