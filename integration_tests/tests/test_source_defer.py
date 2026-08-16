"""Defer-aware source(): behavior matrix.

Each assertion inspects the compiled SQL in target/compiled, i.e. the
relation source() actually resolved to. Mirrors the matrix in the README.
"""
import json

import duckdb

from conftest import ITEST_DIR, ITEST_ROOT, STATE_DIR, compiled, dbt, set_local_source

DEV_SRC = '"dev"."raw_data"."customers"'
PROD_SRC = '"prod"."raw_data"."customers"'
SHARED_SRC = '"shared"."main"."lookup"'
PROD_LOOKUP = '"prod"."main"."lookup"'
DEV_REF = '"dev"."main"."stg_customers"'
PROD_REF = '"prod"."main"."stg_customers"'


def compile_dev(*extra_args: str) -> None:
    dbt("compile", "--target", "dev", *extra_args)


def test_no_defer_is_stock_passthrough():
    compile_dev()
    assert DEV_SRC in compiled("stg_customers")
    assert DEV_REF in compiled("fct")
    assert SHARED_SRC in compiled("shared_ref")


def test_defer_local_source_exists_wins():
    compile_dev("--defer", "--state", str(STATE_DIR))
    assert DEV_SRC in compiled("stg_customers")
    # witness: native ref deferral was active in this same invocation
    # (stg_customers is not built in dev, so fct's ref defers to prod)
    assert PROD_REF in compiled("fct")


def test_defer_local_source_missing_defers():
    set_local_source(False)
    compile_dev("--defer", "--state", str(STATE_DIR))
    assert PROD_SRC in compiled("stg_customers")


def test_favor_state_always_defers():
    compile_dev("--defer", "--favor-state", "--state", str(STATE_DIR))
    assert PROD_SRC in compiled("stg_customers")


def test_explicit_database_source_is_never_auto_deferred():
    # shared_src declares database: shared explicitly — a catalog shared by
    # every environment. Even --favor-state must not rewrite it.
    compile_dev("--defer", "--favor-state", "--state", str(STATE_DIR))
    assert SHARED_SRC in compiled("shared_ref")


def test_override_var_defers_all_sources_unconditionally():
    compile_dev(
        "--defer", "--favor-state", "--state", str(STATE_DIR),
        "--vars", '{"dbt_hacks__source_defer_database": "prod"}',
    )
    assert PROD_SRC in compiled("stg_customers")
    # the explicit-database gate is bypassed too
    assert PROD_LOOKUP in compiled("shared_ref")


def test_kill_switch_restores_stock_behavior():
    compile_dev(
        "--defer", "--favor-state", "--state", str(STATE_DIR),
        "--vars", '{"dbt_hacks__source_defer_enabled": false}',
    )
    assert DEV_SRC in compiled("stg_customers")


def test_run_executes_against_the_deferred_catalog():
    set_local_source(False)
    try:
        dbt("run", "--target", "dev", "--select", "stg_customers",
            "--defer", "--state", str(STATE_DIR))
        with duckdb.connect(str(ITEST_ROOT / "dev.db")) as con:
            con.execute(f"attach '{ITEST_ROOT / 'prod.db'}' as prod")
            rows = con.execute(
                "select marker, count(*) from main.stg_customers group by 1"
            ).fetchall()
        assert rows == [("PROD", 10)]
    finally:
        # leave dev.main clean: later ref-deferral witnesses rely on
        # stg_customers not existing locally
        with duckdb.connect(str(ITEST_ROOT / "dev.db")) as con:
            con.execute("drop view if exists main.stg_customers")


def test_parse_registers_the_source_dag_edge():
    dbt("parse", "--target", "dev")
    manifest = json.loads((ITEST_DIR / "target" / "manifest.json").read_text())
    node = manifest["nodes"]["model.itest.stg_customers"]
    assert "source.itest.raw.customers" in node["depends_on"]["nodes"]
