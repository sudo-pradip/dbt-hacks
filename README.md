# dbt-hacks

dbt-hacks fills the gaps when dbt doesn't support the pattern you need, doesn't fit your project's workflow, or simply hasn't gotten there yet.

## Available hacks

| Hack | Fixes | Status | Detail |
|---|---|---|---|
| `source()` respects `--defer` | [dbt-core#10912](https://github.com/dbt-labs/dbt-core/issues/10912) | Stable | [docs/source_defer.md](docs/source_defer.md) |
| `strategy: append` for snapshots | [dbt-core#3878](https://github.com/dbt-labs/dbt-core/issues/3878) | Stable | [docs/snapshot_append.md](docs/snapshot_append.md) |
| `database_role_grants` (Snowflake) | [dbt-core#13756](https://github.com/dbt-labs/dbt-core/issues/13756) | **Experimental** | [docs/database_role_grants.md](docs/database_role_grants.md) |

---

## Quick install

```yaml
# packages.yml
packages:
  - git: "https://github.com/sudo-pradip/dbt-hacks.git"
    revision: v0.1.0
```

```bash
dbt deps
```

For `strategy: append` and `database_role_grants`, also add this once to your `dbt_project.yml`:

```yaml
dispatch:
  - macro_namespace: dbt
    search_order: ['dbt_hacks', 'dbt']
```

---

## Hacks at a glance

### `source()` respects `--defer`

Makes `source()` defer to the production catalog under `--defer`, exactly like `ref()` does. Requires a one-time 3-line shim in your project's `macros/` directory.

→ [Full docs](docs/source_defer.md)

### `strategy: append`

Adds a custom snapshot strategy for append-only sources where the same key arrives multiple times per run. Fixes `ERROR_ON_NONDETERMINISTIC_MERGE` on Snowflake and silent history loss on other adapters.

```sql
{{ config(unique_key='id', strategy='append', updated_at='loaded_at') }}
select * from {{ source('raw', 'my_table') }}
qualify row_number() over (partition by id, loaded_at order by loaded_at) = 1
```

→ [Full docs](docs/snapshot_append.md)

### `database_role_grants`

Extends dbt's native `grants` config to support Snowflake `DATABASE ROLE` as a recipient — with the same diff/revoke semantics, no hooks or `meta` required.

```yaml
+database_role_grants:
  select:
    - MY_DATABASE_ROLE      # → relation.database.MY_DATABASE_ROLE
    - other_db.AUDIT_ROLE   # explicit database-qualified name
```

→ [Full docs](docs/database_role_grants.md)

---

## Tests

```bash
cd integration_tests
pytest tests -v   # ~30 s, DuckDB only, no warehouse needed
```

## Requirements

- dbt-core `>=1.3.0, <2.0.0`
- No extra Python dependencies

## Contributing checklist (per hack)

- [ ] Pure Jinja/macros, no Python, no adapter-specific SQL without dispatch
- [ ] Strict no-op when its trigger condition isn't met
- [ ] Upstream issue linked; removal criteria stated in `docs/`
- [ ] License file (Apache-2.0 recommended) before publishing to hub.getdbt.com
