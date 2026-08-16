{#
    snowflake__apply_grants.sql
    ---------------------------
    Dispatch override that extends dbt's native grant lifecycle with
    DATABASE ROLE support (dbt-core#13756).

    HOW THE DISPATCH WORKS
    ----------------------
    Materializations call:

        {% do apply_grants(target_relation, grant_config, should_revoke=should_revoke) %}

    dbt resolves that to:

        adapter.dispatch('apply_grants', 'dbt')(...)

    Which, on Snowflake, normally picks up `snowflake__apply_grants` from the
    dbt-snowflake adapter. With the `dispatch` block below active in the
    consuming project, dbt_hacks wins the lookup first — so this macro runs
    instead, then delegates back to the real adapter macro for the standard
    ROLE path.

    GATE
    ----
    If `database_role_grants` is absent from the model config, this macro is
    a pure passthrough — identical behaviour to the stock adapter macro.
    Non-Snowflake adapters never dispatch here (they use their own adapter
    prefix), so non-Snowflake snapshots/models are completely unaffected.

    CONSUMING PROJECT SETUP (one time)
    -----------------------------------
    Add to your project's dbt_project.yml:

        dispatch:
          - macro_namespace: dbt
            search_order: ['dbt_hacks', 'dbt']

    If you also use the snapshot_append feature, this block is shared — you
    only need it once.
#}

{% macro snowflake__apply_grants(relation, grant_config, should_revoke=True) %}

    {#- Step 1: run native dbt ROLE grants (standard Snowflake adapter path). -#}
    {#- We call the adapter-namespaced macro directly to avoid re-dispatching  -#}
    {#- through ourselves and causing infinite recursion.                       -#}
    {{ dbt.default__apply_grants(relation, grant_config, should_revoke) }}

    {#- Step 2: DATABASE ROLE grants — only if the config key is present. -#}
    {%- set db_role_grants = config.get('database_role_grants') -%}
    {%- if db_role_grants -%}
        {{ dbt_hacks.apply_database_role_grants(relation, db_role_grants, should_revoke) }}
    {%- endif -%}

{% endmacro %}
