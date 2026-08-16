{#
    database_role_grants.sql
    ------------------------
    Core macros for managing Snowflake DATABASE ROLE grants from dbt.

    Gap being filled: dbt's native `grants` config passes grantees to
    `GRANT ... TO ROLE <name>`. Snowflake also supports a separate recipient
    type — `DATABASE ROLE` — which scopes privileges to a single database.
    dbt has no way to distinguish the two recipient types today.
    (dbt-core#13756)

    Design: a parallel config key `database_role_grants` with the same shape
    as `grants`:

        database_role_grants:
          select:
            - MY_ROLE              # → relation.database.MY_ROLE
            - OTHER_DB.OTHER_ROLE  # → explicit database-qualified reference

    Grantees without a database prefix inherit the relation's database, which
    is the common case (database roles can only be granted on objects within
    their own database anyway).

    Entry point: apply_database_role_grants() — called from
    snowflake__apply_grants (see snowflake__apply_grants.sql), which hooks
    into dbt's existing grant lifecycle without requiring custom
    materializations or post-hooks.

    Revoke/diff behaviour mirrors default__apply_grants:
      * should_revoke=False  → append-only GRANT (no SHOW, no diff)
      * should_revoke=True   → SHOW GRANTS → diff → GRANT/REVOKE as needed

    Limitations:
      * Snowflake only — the companion override (snowflake__apply_grants) is
        never dispatched on other adapters.
      * `select * replace` / `SHOW GRANTS ON TABLE` syntax unsupported on
        Postgres/Redshift — those adapters ignore this macro entirely.
      * `hard_deletes`, `dbt_valid_to_current`, `snapshot_meta_column_names`
        customizations are not wired in (same scope as snapshot_append).
#}


{# -------------------------------------------------------------------- #}
{# SQL generators                                                         #}
{# -------------------------------------------------------------------- #}

{%- macro get_database_role_grant_sql(relation, privilege, grantee) -%}
    {#- Qualify the grantee with the relation's database when no prefix given. -#}
    {%- if '.' not in grantee -%}
        {%- set qualified = relation.database ~ '.' ~ grantee -%}
    {%- else -%}
        {%- set qualified = grantee -%}
    {%- endif -%}
    {%- set rel_type = relation.type | upper if relation.type else 'TABLE' -%}
    grant {{ privilege | upper }} on {{ rel_type }} {{ relation }} to database role {{ qualified }}
{%- endmacro -%}


{%- macro get_database_role_revoke_sql(relation, privilege, grantee) -%}
    {%- if '.' not in grantee -%}
        {%- set qualified = relation.database ~ '.' ~ grantee -%}
    {%- else -%}
        {%- set qualified = grantee -%}
    {%- endif -%}
    {%- set rel_type = relation.type | upper if relation.type else 'TABLE' -%}
    revoke {{ privilege | upper }} on {{ rel_type }} {{ relation }} from database role {{ qualified }}
{%- endmacro -%}


{# -------------------------------------------------------------------- #}
{# SHOW GRANTS reader                                                     #}
{# -------------------------------------------------------------------- #}

{% macro get_existing_database_role_grants(relation) %}
    {#
    Runs `SHOW GRANTS ON <type> <relation>` and returns a dict of the form:
        { 'SELECT': ['ROLE_A', 'ROLE_B'], 'INSERT': ['ROLE_C'] }
    for DATABASE_ROLE recipients only.  Grantee names are returned exactly
    as Snowflake stores them (bare role name, upper-case, no database prefix).
    Returns {} when not in execute context (e.g. during compile).
    #}
    {%- set existing = {} -%}
    {%- if execute -%}
        {%- set rel_type = relation.type | upper if relation.type else 'TABLE' -%}
        {%- set show_sql -%}
            show grants on {{ rel_type }} {{ relation }}
        {%- endset -%}
        {%- set result = run_query(show_sql) -%}
        {%- for row in result.rows -%}
            {%- if (row['granted_to'] | string | upper) == 'DATABASE_ROLE' -%}
                {%- set priv = row['privilege'] | upper -%}
                {%- set grantee = row['grantee_name'] | string -%}
                {%- if priv not in existing -%}
                    {%- do existing.update({priv: []}) -%}
                {%- endif -%}
                {%- do existing[priv].append(grantee) -%}
            {%- endif -%}
        {%- endfor -%}
    {%- endif -%}
    {{ return(existing) }}
{% endmacro %}


{# -------------------------------------------------------------------- #}
{# Diff helper                                                            #}
{# -------------------------------------------------------------------- #}

{% macro database_role_grants_diff(current, desired) %}
    {#
    Computes what needs granting and revoking given:
      current  — {PRIVILEGE: [GRANTEE, ...]} from SHOW GRANTS (bare names, upper)
      desired  — {privilege: [grantee, ...]} from config (raw case, optional prefix)

    Returns: {"to_add": {...}, "to_revoke": {...}}

    Comparison is case-insensitive on bare grantee name (the database prefix
    is stripped for comparison; Snowflake SHOW GRANTS returns bare names).
    #}
    {%- set to_add    = {} -%}
    {%- set to_revoke = {} -%}

    {#- Normalise desired: upper priv, upper bare grantee name -#}
    {%- set desired_norm = {} -%}
    {%- for priv, grantees in desired.items() -%}
        {%- set normed = [] -%}
        {%- for g in grantees -%}
            {%- do normed.append(g.split('.')[-1] | upper) -%}
        {%- endfor -%}
        {%- do desired_norm.update({priv | upper: normed}) -%}
    {%- endfor -%}

    {#- Normalise current: upper priv, upper bare grantee name -#}
    {%- set current_norm = {} -%}
    {%- for priv, grantees in current.items() -%}
        {%- set normed = [] -%}
        {%- for g in grantees -%}
            {%- do normed.append(g.split('.')[-1] | upper) -%}
        {%- endfor -%}
        {%- do current_norm.update({priv | upper: normed}) -%}
    {%- endfor -%}

    {#- Grants to add: desired − current -#}
    {%- for priv, grantees in desired_norm.items() -%}
        {%- set cur = current_norm.get(priv, []) -%}
        {%- set add_list = [] -%}
        {%- for g in grantees -%}
            {%- if g not in cur -%}{%- do add_list.append(g) -%}{%- endif -%}
        {%- endfor -%}
        {%- if add_list -%}{%- do to_add.update({priv: add_list}) -%}{%- endif -%}
    {%- endfor -%}

    {#- Grants to revoke: current − desired -#}
    {%- for priv, grantees in current_norm.items() -%}
        {%- set des = desired_norm.get(priv, []) -%}
        {%- set rev_list = [] -%}
        {%- for g in grantees -%}
            {%- if g not in des -%}{%- do rev_list.append(g) -%}{%- endif -%}
        {%- endfor -%}
        {%- if rev_list -%}{%- do to_revoke.update({priv: rev_list}) -%}{%- endif -%}
    {%- endfor -%}

    {{ return({"to_add": to_add, "to_revoke": to_revoke}) }}
{% endmacro %}


{# -------------------------------------------------------------------- #}
{# Main entry point                                                       #}
{# -------------------------------------------------------------------- #}

{% macro apply_database_role_grants(relation, grant_config, should_revoke) %}
    {#
    Applies DATABASE ROLE grants for `grant_config` on `relation`.
    Mirrors the pattern of default__apply_grants:
      should_revoke=False  → grant everything in config (first build or full-refresh
                             without copy_grants — no prior grants to worry about)
      should_revoke=True   → show existing DATABASE ROLE grants, diff, grant/revoke
    #}
    {%- if not grant_config -%}
        {#- Nothing to do -#}
        {{ return('') }}
    {%- endif -%}

    {%- if should_revoke -%}
        {%- set existing = dbt_hacks.get_existing_database_role_grants(relation) -%}
        {%- set diff = dbt_hacks.database_role_grants_diff(existing, grant_config) -%}
        {%- set needs_granting = diff['to_add'] -%}
        {%- set needs_revoking = diff['to_revoke'] -%}
        {%- if not (needs_granting or needs_revoking) -%}
            {{ log('On ' ~ relation.render() ~ ': All database role grants are in place, no changes needed.') }}
        {%- endif -%}
    {%- else -%}
        {%- set needs_granting = grant_config -%}
        {%- set needs_revoking = {} -%}
    {%- endif -%}

    {%- set dcl = [] -%}

    {%- for priv, grantees in needs_revoking.items() -%}
        {%- for grantee in grantees -%}
            {%- do dcl.append(dbt_hacks.get_database_role_revoke_sql(relation, priv, grantee)) -%}
        {%- endfor -%}
    {%- endfor -%}

    {%- for priv, grantees in needs_granting.items() -%}
        {%- for grantee in grantees -%}
            {%- do dcl.append(dbt_hacks.get_database_role_grant_sql(relation, priv, grantee)) -%}
        {%- endfor -%}
    {%- endfor -%}

    {%- if dcl -%}
        {%- call statement('database_role_grants') -%}
            {%- for stmt in dcl -%}
                {{ stmt }};
            {%- endfor -%}
        {%- endcall -%}
    {%- endif -%}

{% endmacro %}
