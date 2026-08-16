"""Test harness for dbt-hacks integration tests.

A session-scoped fixture builds the "production" environment once (seed the
catalogs, `dbt build --target prod`, snapshot the manifest as the --state
dir). Every test then starts from a known dev state: a stale 2-row local
copy of the source table present.
"""
import os
import shutil
import subprocess
import sys
from pathlib import Path

import duckdb
import pytest

ITEST_DIR = Path(__file__).resolve().parent.parent
ITEST_ROOT = ITEST_DIR / "target" / "itest"
STATE_DIR = ITEST_DIR / "target" / "state"
DBT = Path(sys.executable).with_name("dbt")


def dbt(*args: str) -> subprocess.CompletedProcess:
    """Run dbt exactly as a user would, from the integration project dir."""
    env = {**os.environ, "DBT_HACKS_ITEST_ROOT": str(ITEST_ROOT)}
    result = subprocess.run(
        [str(DBT), *args],
        cwd=ITEST_DIR,
        env=env,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, (
        f"dbt {' '.join(args)} failed"
        f"\n--- stdout ---\n{result.stdout}\n--- stderr ---\n{result.stderr}"
    )
    return result


def compiled(model: str) -> str:
    """The compiled SQL of a model from the most recent dbt compile."""
    path = ITEST_DIR / "target" / "compiled" / "itest" / "models" / f"{model}.sql"
    return path.read_text()


def set_local_source(exists: bool) -> None:
    """Create (or drop) the stale 2-row DEV copy of raw.customers."""
    with duckdb.connect(str(ITEST_ROOT / "dev.db")) as con:
        con.execute("create schema if not exists raw_data")
        con.execute("drop table if exists raw_data.customers")
        if exists:
            con.execute(
                "create table raw_data.customers as "
                "select range as id, 'DEV' as marker from range(2)"
            )


@pytest.fixture(scope="session", autouse=True)
def environments():
    """Build the prod environment once and snapshot its manifest as state."""
    shutil.rmtree(ITEST_ROOT, ignore_errors=True)
    shutil.rmtree(STATE_DIR, ignore_errors=True)
    ITEST_ROOT.mkdir(parents=True)
    STATE_DIR.mkdir(parents=True)

    with duckdb.connect(str(ITEST_ROOT / "prod.db")) as con:
        con.execute("create schema raw_data")
        con.execute(
            "create table raw_data.customers as "
            "select range as id, 'PROD' as marker from range(10)"
        )
    with duckdb.connect(str(ITEST_ROOT / "shared.db")) as con:
        con.execute("create table main.lookup as select 1 as id, 'SHARED' as marker")

    dbt("deps")
    dbt("build", "--target", "prod")
    shutil.copy(ITEST_DIR / "target" / "manifest.json", STATE_DIR / "manifest.json")


@pytest.fixture(autouse=True)
def local_source(environments):
    """Every test starts with the stale local copy of the source present."""
    set_local_source(True)
    yield
