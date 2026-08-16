"""Integration tests for `strategy: append` snapshot support.

Covers the four correctness assertions from HANDOFF.md §3-A, plus an
idempotency (run 3) and a non-append passthrough guard:

  1. Exactly one open row per key     (dbt_valid_to is null)
  2. No gaps / overlaps in chains     (lead validity == next valid_from)
  3. No duplicate dbt_scd_ids
  4. Idempotency                      (row count unchanged after a no-op run)
  5. Non-append snapshot passthrough  (strategy != 'append' still works)

Scenario driven by three dbt snapshot runs:
  Run 1 — initial load:  orders {1,2,3} each with ONE version
  Run 2 — incremental:   order 1 gets TWO more versions; new order 4 appears
  Run 3 — no-op:         source unchanged; snapshot must be idempotent

DuckDB (dev.db / raw_data.orders_append) is the only warehouse used.
No internet access required; total runtime is ~30 s.
"""

import duckdb
import pytest

from conftest import ITEST_DIR, ITEST_ROOT, dbt

SNAPSHOT_TABLE = "dev.snapshots.orders_snapshot"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def seed_run1(con: duckdb.DuckDBPyConnection) -> None:
    """Initial load: orders 1, 2, 3 — one version each."""
    con.execute("create schema if not exists raw_data")
    con.execute("drop table if exists raw_data.orders_append")
    con.execute(
        """
        create table raw_data.orders_append as
        select * from (values
            (1, 'placed',   '2024-01-01 00:00:00'::timestamp),
            (2, 'placed',   '2024-01-01 00:00:00'::timestamp),
            (3, 'placed',   '2024-01-01 00:00:00'::timestamp)
        ) t(order_id, status, loaded_at)
        """
    )


def seed_run2(con: duckdb.DuckDBPyConnection) -> None:
    """Incremental load: order 1 gains 2 new versions; order 4 is brand new."""
    con.execute(
        """
        insert into raw_data.orders_append values
            (1, 'shipped',   '2024-01-02 00:00:00'::timestamp),
            (1, 'delivered', '2024-01-03 00:00:00'::timestamp),
            (4, 'placed',    '2024-01-02 00:00:00'::timestamp)
        """
    )


def snapshot_table_rows(con: duckdb.DuckDBPyConnection) -> list[tuple]:
    return con.execute(f"select * from {SNAPSHOT_TABLE} order by order_id, loaded_at").fetchall()


# ---------------------------------------------------------------------------
# Fixture: three-run scenario
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def three_run_scenario(environments):
    """
    Populates raw_data.orders_append, runs `dbt snapshot` three times, and
    returns a DuckDB connection to dev.db with prod.db attached.

    The fixture is module-scoped so the scenario runs once and all test
    functions in this module share the final snapshot state.
    """
    db_path = ITEST_ROOT / "dev.db"

    with duckdb.connect(str(db_path)) as con:
        seed_run1(con)

    dbt("snapshot", "--target", "dev")          # run 1 — initial build

    with duckdb.connect(str(db_path)) as con:
        seed_run2(con)

    dbt("snapshot", "--target", "dev")          # run 2 — incremental
    dbt("snapshot", "--target", "dev")          # run 3 — idempotency

    yield db_path


# ---------------------------------------------------------------------------
# Test: assertion 1 — exactly one open row per key
# ---------------------------------------------------------------------------

def test_exactly_one_open_row_per_key(three_run_scenario):
    """After all runs every order_id has exactly one row with dbt_valid_to IS NULL."""
    with duckdb.connect(str(three_run_scenario)) as con:
        violators = con.execute(
            f"""
            select order_id, count(*) as cnt
            from {SNAPSHOT_TABLE}
            where dbt_valid_to is null
            group by order_id
            having count(*) > 1
            """
        ).fetchall()
    assert violators == [], (
        f"Keys with multiple open rows: {violators}"
    )


# ---------------------------------------------------------------------------
# Test: assertion 2 — no gaps or overlaps in validity chains
# ---------------------------------------------------------------------------

def test_no_gaps_or_overlaps_in_validity_chains(three_run_scenario):
    """For each key, dbt_valid_to of row N equals dbt_valid_from of row N+1."""
    with duckdb.connect(str(three_run_scenario)) as con:
        gaps = con.execute(
            f"""
            select order_id, dbt_valid_to, nxt_valid_from
            from (
                select
                    order_id,
                    dbt_valid_to,
                    lead(dbt_valid_from) over (
                        partition by order_id
                        order by dbt_valid_from
                    ) as nxt_valid_from
                from {SNAPSHOT_TABLE}
            )
            where nxt_valid_from is not null
              and dbt_valid_to != nxt_valid_from
            """
        ).fetchall()
    assert gaps == [], (
        f"Gaps/overlaps detected: {gaps}"
    )


# ---------------------------------------------------------------------------
# Test: assertion 3 — no duplicate dbt_scd_ids
# ---------------------------------------------------------------------------

def test_no_duplicate_scd_ids(three_run_scenario):
    """Every row in the snapshot has a globally unique dbt_scd_id."""
    with duckdb.connect(str(three_run_scenario)) as con:
        dupes = con.execute(
            f"""
            select dbt_scd_id, count(*) as cnt
            from {SNAPSHOT_TABLE}
            group by dbt_scd_id
            having count(*) > 1
            """
        ).fetchall()
    assert dupes == [], (
        f"Duplicate scd_ids: {dupes}"
    )


# ---------------------------------------------------------------------------
# Test: assertion 4 — idempotency (run 3 changed nothing)
# ---------------------------------------------------------------------------

def test_idempotency_run3_adds_no_rows(three_run_scenario):
    """
    After run 2 the snapshot has the correct row count. Run 3 (no source
    change) must not add or remove any rows.
    """
    with duckdb.connect(str(three_run_scenario)) as con:
        total = con.execute(
            f"select count(*) from {SNAPSHOT_TABLE}"
        ).fetchone()[0]

    # Expected rows after run 2:
    #   order 1: 3 versions (placed→shipped→delivered)
    #   order 2: 1 version
    #   order 3: 1 version
    #   order 4: 1 version (brand-new in run 2)
    # Total = 6
    assert total == 6, (
        f"Expected 6 snapshot rows after idempotency run, got {total}"
    )


# ---------------------------------------------------------------------------
# Test: assertion 5 — intermediate versions captured with correct windows
# ---------------------------------------------------------------------------

def test_intermediate_versions_captured(three_run_scenario):
    """
    Order 1 must have all three versions, each with a correct validity window.
      placed    → 2024-01-01: open window closes at 2024-01-02
      shipped   → 2024-01-02: open window closes at 2024-01-03
      delivered → 2024-01-03: still open (dbt_valid_to IS NULL)
    """
    with duckdb.connect(str(three_run_scenario)) as con:
        rows = con.execute(
            f"""
            select status, dbt_valid_from::date::varchar, dbt_valid_to::date::varchar
            from {SNAPSHOT_TABLE}
            where order_id = 1
            order by dbt_valid_from
            """
        ).fetchall()

    assert len(rows) == 3, f"Expected 3 rows for order 1, got {len(rows)}: {rows}"
    assert rows[0] == ("placed",    "2024-01-01", "2024-01-02")
    assert rows[1] == ("shipped",   "2024-01-02", "2024-01-03")
    assert rows[2] == ("delivered", "2024-01-03", None)


# ---------------------------------------------------------------------------
# Test: guard — non-append snapshots are unaffected (passthrough gate check)
# ---------------------------------------------------------------------------

def test_strategy_gate_non_append_snapshots_unaffected(environments):
    """
    A quick compile-time check that the overrides are gated: if another
    snapshot using 'timestamp' strategy exists, dbt should compile without
    errors (the gate falls through to the stock implementation).

    This test verifies that installing dbt_hacks does not break existing
    timestamp/check snapshots by checking dbt parse succeeds with the
    dispatch config active.
    """
    # `dbt parse` exercises macro resolution for the entire project including
    # all snapshot definitions. A compile error here means the gate is broken.
    dbt("parse", "--target", "dev")
