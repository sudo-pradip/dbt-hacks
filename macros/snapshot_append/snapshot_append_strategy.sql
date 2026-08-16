{#
    Custom snapshot strategy: `append`
    ----------------------------------
    The snapshot equivalent of a user-defined incremental strategy
    (get_incremental_STRATEGY_sql). dbt resolves `strategy: <name>` in a
    snapshot config by looking for a macro called `snapshot_<name>_strategy`
    in your project or installed packages — so simply defining this macro
    makes `strategy: append` valid.

    Purpose: snapshot APPEND-ONLY sources where the same unique_key can
    appear multiple times per run (dbt-core issue #3878). The stock
    timestamp/check strategies assume one row per key per run and blow up
    on Snowflake with ERROR_ON_NONDETERMINISTIC_MERGE.

    This macro only defines the change-detection expressions. The heavy
    lifting (handling N versions per key in one run) happens in the
    overridden staging/build macros in snapshot_append_overrides.sql.
#}

{% macro snapshot_append_strategy(node, snapshotted_rel, current_rel, model_config, target_exists) %}

    {#- prefer node.config; model_config is the deprecated legacy param -#}
    {% set primary_key = node.config.get('unique_key') %}
    {% set updated_at = node.config.get('updated_at') %}

    {% if not primary_key or not updated_at %}
        {% do exceptions.raise_compiler_error(
            "snapshot strategy 'append' requires both `unique_key` and `updated_at` configs"
        ) %}
    {% endif %}

    {#- a source version is "new" if it is strictly later than the currently
        open (dbt_valid_to is null) row in the snapshot -#}
    {% set row_changed_expr -%}
        ({{ snapshotted_rel }}.{{ updated_at }} < {{ current_rel }}.{{ updated_at }})
    {%- endset %}

    {#- scd_id must be unique PER VERSION, not per key, so multiple inserts
        for the same key never collide in the merge -#}
    {% set scd_id_expr = snapshot_hash_arguments([primary_key, updated_at]) %}

    {% do return({
        "unique_key": primary_key,
        "updated_at": updated_at,
        "row_changed": row_changed_expr,
        "scd_id": scd_id_expr,
        "invalidate_hard_deletes": false
    }) %}

{% endmacro %}
