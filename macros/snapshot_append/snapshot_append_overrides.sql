{#
    Root-project overrides of dbt's internal snapshot machinery
    ------------------------------------------------------------
    dbt dispatches its global snapshot macros (adapter.dispatch(..., 'dbt')),
    and macros named `default__<name>` defined in YOUR project win over the
    built-ins. That's the sanctioned "hijack" — no fork of dbt required.

    Both overrides are GATED: they only change behavior when the snapshot is
    configured with `strategy: append`. Every other snapshot in the project
    falls through to the stock implementation via the explicit
    `dbt.default__...` call — resolved LIVE at runtime, so upstream updates
    keep applying to all non-append snapshots with zero action from you.

    Maintenance surface, smallest dbt allows:
      * snapshot_append_strategy ......... official extension API, not an
                                           override — never needs maintenance
      * default__build_snapshot_table .... thin wrapper: calls the stock macro
                                           and patches only dbt_valid_to, so
                                           upstream column changes flow through
      * default__snapshot_staging_table .. fully owned for the append path.
                                           dbt exposes no finer hook (no
                                           per-CTE sub-macros), so this is the
                                           minimum possible. Re-diff against
                                           upstream helpers.sql on major dbt
                                           upgrades, or keep the DuckDB smoke
                                           test in CI as a tripwire.

    What changes for `append`:
      * staging table computes dbt_valid_from / dbt_valid_to per VERSION with
        lead() over (partition by unique_key order by updated_at), so N rows
        per key per run insert cleanly (each has a distinct dbt_scd_id, so the
        merge stays deterministic);
      * exactly ONE update row per key closes the previously open snapshot
        row at the FIRST new version's timestamp;
      * first-run build uses the same lead() logic instead of marking every
        historical version as currently valid.

    Assumptions / limitations:
      * (unique_key, updated_at) is unique in the snapshot's SELECT — dedupe
        exact duplicates in the snapshot query itself if needed;
      * classic meta column names (dbt_valid_from / dbt_valid_to / dbt_scd_id /
        dbt_updated_at) — snapshot_meta_column_names, dbt_valid_to_current and
        hard_deletes='new_record' are not wired into the append path;
      * hard deletes are not invalidated (append-only sources rarely delete).

    Package installation note:
      root projects don't pick up a package's `default__` overrides implicitly.
      Each consuming project must add to its `dbt_project.yml`:

        dispatch:
          - macro_namespace: dbt
            search_order: ['dbt_hacks', 'dbt']

      The strategy macro needs no dispatch config — dbt finds
      `snapshot_<name>_strategy` across installed packages automatically.
#}


{% macro default__snapshot_staging_table(strategy, source_sql, target_relation) -%}

    {%- if config.get('strategy') != 'append' -%}
        {{ return(dbt.default__snapshot_staging_table(strategy, source_sql, target_relation)) }}
    {%- endif -%}

    with snapshot_query as (

        {{ source_sql }}

    ),

    snapshotted_data as (

        select *, {{ strategy.unique_key }} as dbt_unique_key
        from {{ target_relation }}
        where dbt_valid_to is null

    ),

    insertions_source_data as (

        select
            *,
            {{ strategy.unique_key }} as dbt_unique_key,
            {{ strategy.updated_at }} as dbt_updated_at,
            {{ strategy.updated_at }} as dbt_valid_from,
            lead({{ strategy.updated_at }}) over (
                partition by {{ strategy.unique_key }}
                order by {{ strategy.updated_at }}
            ) as dbt_valid_to,
            {{ strategy.scd_id }} as dbt_scd_id
        from snapshot_query

    ),

    updates_source_data as (

        select
            *,
            {{ strategy.unique_key }} as dbt_unique_key,
            {{ strategy.updated_at }} as dbt_updated_at,
            {{ strategy.updated_at }} as dbt_valid_from
        from snapshot_query

    ),

    {#- every source version strictly newer than the open snapshot row (or
        belonging to a brand-new key) becomes an insert; lead() has already
        chained their validity windows -#}
    insertions as (

        select
            'insert' as dbt_change_type,
            source_data.*
        from insertions_source_data as source_data
        left outer join snapshotted_data
            on snapshotted_data.dbt_unique_key = source_data.dbt_unique_key
        where snapshotted_data.dbt_unique_key is null
           or ({{ strategy.row_changed }})

    ),

    {#- per key: timestamp of the EARLIEST new version — this is when the
        previously open row stops being valid -#}
    first_new_version as (

        select
            source_data.dbt_unique_key as dbt_unique_key,
            min(source_data.dbt_valid_from) as dbt_first_new_valid_from
        from updates_source_data as source_data
        join snapshotted_data
            on snapshotted_data.dbt_unique_key = source_data.dbt_unique_key
        where ({{ strategy.row_changed }})
        group by source_data.dbt_unique_key

    ),

    {#- exactly one update row per key: carries the DESTINATION's dbt_scd_id
        so the merge closes the open row, never more than one match -#}
    updates as (

        select
            'update' as dbt_change_type,
            source_data.*,
            first_new_version.dbt_first_new_valid_from as dbt_valid_to,
            snapshotted_data.dbt_scd_id
        from updates_source_data as source_data
        join snapshotted_data
            on snapshotted_data.dbt_unique_key = source_data.dbt_unique_key
        join first_new_version
            on first_new_version.dbt_unique_key = source_data.dbt_unique_key
           and first_new_version.dbt_first_new_valid_from = source_data.dbt_valid_from

    )

    select * from insertions
    union all
    select * from updates

{%- endmacro %}


{% macro default__build_snapshot_table(strategy, sql) %}

    {%- if config.get('strategy') != 'append' -%}
        {{ return(dbt.default__build_snapshot_table(strategy, sql)) }}
    {%- endif -%}

    {#- THIN WRAPPER: reuse the stock upstream macro verbatim and patch ONLY
        dbt_valid_to on top of its output. If upstream adds/changes columns,
        they flow through untouched. `select * replace` is supported on
        Snowflake / BigQuery / Databricks / DuckDB (not Postgres/Redshift).

        First run: chain validity per version instead of the stock behavior
        of marking every historical version as currently open. -#}
    select * replace (
        lead({{ strategy.updated_at }}) over (
            partition by {{ strategy.unique_key }}
            order by {{ strategy.updated_at }}
        ) as dbt_valid_to
    )
    from (
        {{ dbt.default__build_snapshot_table(strategy, sql) }}
    ) as dbt_stock_build

{% endmacro %}
