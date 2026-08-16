# integration_tests

DuckDB-based integration tests for `dbt-hacks`. Three local catalogs
simulate the environments:

| catalog | file | role |
|---|---|---|
| `dev` | `dev.db` | the sandbox target you develop in |
| `prod` | `prod.db` | "production" — its manifest becomes the `--state` for deferral |
| `shared` | `shared.db` | catalog shared by all envs — the safety-gate case |

## Run

```bash
cd integration_tests
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
pytest tests -v
```

## How it works

- A session fixture (`tests/conftest.py`) seeds the catalogs, runs
  `dbt build --target prod`, and snapshots the prod manifest into
  `target/state/` — the `--state` dir every deferred invocation uses.
- An autouse fixture restores the stale 2-row local copy of
  `raw.customers` before each test, so tests are order-independent.
- Each test runs `dbt compile` (or one `dbt run`) against the dev target
  and asserts on the relations in `target/compiled/` — i.e. what
  `source()` actually resolved to.
- `macros/source.sql` here is the package's own shim, installed exactly
  as a user would (see `shims/` at the repo root).

The test matrix maps 1:1 to "How it was verified" in the root README.
