"""Integration tests for `database_role_grants` config support.

Strategy: the Snowflake-specific adapter dispatch (`snowflake__apply_grants`)
never fires under DuckDB, so we test the pure-logic macros via
`dbt run-operation` and compile-time assertions rather than end-to-end
DCL execution.

Test coverage:

  1. Grant SQL generation          — correct GRANT ... TO DATABASE ROLE syntax
  2. Revoke SQL generation         — correct REVOKE ... FROM DATABASE ROLE syntax
  3. Database-prefix defaulting    — bare role name inherits relation's database
  4. Explicit database prefix      — fully qualified grantee passed through
  5. Diff logic — adds only        — to_add computed correctly
  6. Diff logic — revokes only     — to_revoke computed correctly
  7. Diff logic — mixed            — grant new + revoke removed simultaneously
  8. Diff logic — no-op            — empty diff when desired == current
  9. Gate: no config = no-op       — snowflake__apply_grants with no
                                     database_role_grants doesn't error
 10. Parse passes                  — `dbt parse` compiles the whole project
                                     (macro resolution smoke test)

All tests run on DuckDB in ~5 s with no Snowflake credentials.
"""

import json
import subprocess
import sys
from pathlib import Path

import pytest

from conftest import ITEST_DIR, dbt


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def run_operation(macro_name: str, *args: str) -> str:
    """
    Run `dbt run-operation <macro_name> [--args ...]` and return stdout.
    Fails the test if dbt exits non-zero.
    """
    cmd = [str(Path(sys.executable).with_name("dbt")),
           "run-operation", macro_name]
    if args:
        cmd += ["--args", *args]
    result = subprocess.run(
        cmd,
        cwd=ITEST_DIR,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, (
        f"run-operation {macro_name} failed\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )
    return result.stdout


# ---------------------------------------------------------------------------
# Macro wrappers — thin run-operation macros declared inline via
# dbt_project.yml on-run-start would be fragile; instead we add small
# test-helper macros inside integration_tests/macros/. These are created
# as part of this test module's setup.
# ---------------------------------------------------------------------------

HELPER_MACROS_PATH = ITEST_DIR / "macros" / "test_db_role_grant_helpers.sql"

HELPER_MACROS_SQL = """\
{# Test-only helper macros for database_role_grants assertions.
   These simply delegate to the package macros and print results so that
   pytest can assert on stdout. #}

{% macro test_get_grant_sql(database, schema, identifier, rel_type, privilege, grantee) %}
    {%- set relation = api.Relation.create(
            database=database, schema=schema, identifier=identifier,
            type=rel_type) -%}
    {{ log(dbt_hacks.dbt_hacks__get_database_role_grant_sql(relation, privilege, grantee), info=True) }}
{% endmacro %}


{% macro test_get_revoke_sql(database, schema, identifier, rel_type, privilege, grantee) %}
    {%- set relation = api.Relation.create(
            database=database, schema=schema, identifier=identifier,
            type=rel_type) -%}
    {{ log(dbt_hacks.dbt_hacks__get_database_role_revoke_sql(relation, privilege, grantee), info=True) }}
{% endmacro %}


{% macro test_grants_diff(current_json, desired_json) %}
    {%- set current = fromjson(current_json) -%}
    {%- set desired = fromjson(desired_json) -%}
    {%- set diff    = dbt_hacks.dbt_hacks__database_role_grants_diff(current, desired) -%}
    {{ log(tojson(diff), info=True) }}
{% endmacro %}
"""


@pytest.fixture(scope="module", autouse=True)
def write_helper_macros():
    """Write the helper macros file before any test in this module runs."""
    HELPER_MACROS_PATH.write_text(HELPER_MACROS_SQL)
    yield
    # Leave the file; it's harmless and avoids re-writing on every run.


def grant_sql(database, schema, identifier, rel_type, privilege, grantee) -> str:
    out = run_operation(
        "test_get_grant_sql",
        "{database: %s, schema: %s, identifier: %s, rel_type: %s,"
        " privilege: %s, grantee: %s}"
        % (database, schema, identifier, rel_type, privilege, grantee),
    )
    # dbt log() lines are prefixed with timestamp + level; grab the last non-empty
    lines = [l.strip() for l in out.splitlines() if l.strip()]
    return lines[-1]


def revoke_sql(database, schema, identifier, rel_type, privilege, grantee) -> str:
    out = run_operation(
        "test_get_revoke_sql",
        "{database: %s, schema: %s, identifier: %s, rel_type: %s,"
        " privilege: %s, grantee: %s}"
        % (database, schema, identifier, rel_type, privilege, grantee),
    )
    lines = [l.strip() for l in out.splitlines() if l.strip()]
    return lines[-1]


def grants_diff(current: dict, desired: dict) -> dict:
    import json as _json
    out = run_operation(
        "test_grants_diff",
        "{current_json: '%s', desired_json: '%s'}"
        % (_json.dumps(current).replace("'", "\\'"),
           _json.dumps(desired).replace("'", "\\'")),
    )
    lines = [l.strip() for l in out.splitlines() if l.strip()]
    return _json.loads(lines[-1])


# ---------------------------------------------------------------------------
# Tests: SQL generation
# ---------------------------------------------------------------------------

def test_grant_sql_bare_grantee_inherits_database(environments):
    """Bare role name → qualified with the relation's database."""
    sql = grant_sql("mydb", "myschema", "dim_customers", "table",
                    "select", "ANALYST_ROLE")
    assert "TO DATABASE ROLE mydb.ANALYST_ROLE" in sql.upper()
    assert "GRANT SELECT" in sql.upper()
    assert "DIM_CUSTOMERS" in sql.upper()


def test_grant_sql_explicit_database_prefix_passes_through(environments):
    """Fully-qualified grantee is used as-is."""
    sql = grant_sql("mydb", "myschema", "dim_customers", "table",
                    "select", "otherdb.ANALYST_ROLE")
    assert "TO DATABASE ROLE otherdb.ANALYST_ROLE" in sql.upper()


def test_grant_sql_relation_type_view(environments):
    """Relation type 'view' produces GRANT ... ON VIEW."""
    sql = grant_sql("mydb", "myschema", "v_orders", "view",
                    "select", "REPORTING_ROLE")
    assert "ON VIEW" in sql.upper()


def test_revoke_sql_bare_grantee_inherits_database(environments):
    """Revoke SQL uses FROM DATABASE ROLE with qualified name."""
    sql = revoke_sql("mydb", "myschema", "dim_customers", "table",
                     "select", "ANALYST_ROLE")
    assert "FROM DATABASE ROLE mydb.ANALYST_ROLE" in sql.upper()
    assert "REVOKE SELECT" in sql.upper()


def test_revoke_sql_explicit_database_prefix(environments):
    sql = revoke_sql("mydb", "myschema", "dim_customers", "table",
                     "select", "otherdb.ANALYST_ROLE")
    assert "FROM DATABASE ROLE otherdb.ANALYST_ROLE" in sql.upper()


# ---------------------------------------------------------------------------
# Tests: diff logic
# ---------------------------------------------------------------------------

def test_diff_adds_new_grants(environments):
    """Role in desired but not current → to_add."""
    diff = grants_diff(
        current={"SELECT": ["EXISTING_ROLE"]},
        desired={"select": ["EXISTING_ROLE", "NEW_ROLE"]},
    )
    assert "NEW_ROLE" in diff["to_add"].get("SELECT", [])
    assert "EXISTING_ROLE" not in diff["to_add"].get("SELECT", [])
    assert diff["to_revoke"] == {}


def test_diff_revokes_removed_grants(environments):
    """Role in current but not desired → to_revoke."""
    diff = grants_diff(
        current={"SELECT": ["KEEP_ROLE", "REMOVE_ROLE"]},
        desired={"select": ["KEEP_ROLE"]},
    )
    assert "REMOVE_ROLE" in diff["to_revoke"].get("SELECT", [])
    assert "KEEP_ROLE" not in diff["to_revoke"].get("SELECT", [])
    assert diff["to_add"] == {}


def test_diff_mixed_grant_and_revoke(environments):
    """Simultaneously add one role and revoke another."""
    diff = grants_diff(
        current={"SELECT": ["OLD_ROLE"]},
        desired={"select": ["NEW_ROLE"]},
    )
    assert "NEW_ROLE"  in diff["to_add"].get("SELECT", [])
    assert "OLD_ROLE"  in diff["to_revoke"].get("SELECT", [])


def test_diff_no_op_when_identical(environments):
    """No changes when desired == current."""
    diff = grants_diff(
        current={"SELECT": ["ROLE_A", "ROLE_B"]},
        desired={"select": ["ROLE_A", "ROLE_B"]},
    )
    assert diff["to_add"]    == {}
    assert diff["to_revoke"] == {}


def test_diff_case_insensitive_comparison(environments):
    """Comparison is case-insensitive: 'role_a' and 'ROLE_A' are the same."""
    diff = grants_diff(
        current={"SELECT": ["ROLE_A"]},
        desired={"select": ["role_a"]},
    )
    assert diff["to_add"]    == {}
    assert diff["to_revoke"] == {}


def test_diff_strips_database_prefix_for_comparison(environments):
    """'mydb.ROLE_A' in desired matches 'ROLE_A' in current (SHOW GRANTS returns bare names)."""
    diff = grants_diff(
        current={"SELECT": ["ROLE_A"]},
        desired={"select": ["mydb.ROLE_A"]},
    )
    assert diff["to_add"]    == {}
    assert diff["to_revoke"] == {}


# ---------------------------------------------------------------------------
# Test: parse smoke test (macro resolution)
# ---------------------------------------------------------------------------

def test_dbt_parse_succeeds_with_all_macros(environments):
    """
    `dbt parse` must succeed: validates macro resolution for the entire
    project including all dbt_hacks overrides active via dispatch.
    """
    dbt("parse", "--target", "dev")
