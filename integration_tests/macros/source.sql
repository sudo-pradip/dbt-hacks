{#
    dbt-hacks shim: defer-aware source()
    ====================================
    COPY THIS FILE into your own dbt project's macros/ directory
    (e.g. macros/dbt_hacks/source.sql). It does not work from inside the
    installed package: ref/source/config are Jinja context properties, and
    only ROOT-PROJECT macros may shadow them
    (https://github.com/dbt-labs/dbt-core/issues/4491).

    All logic lives in dbt_hacks.defer_source — this file is just the hook.
    If your project already overrides source(), merge the one line below
    into your existing macro instead of adding this file (only one macro
    named `source` can exist per project).
#}

{% macro source(source_name, table_name) %}
    {% do return(dbt_hacks.defer_source(source_name, table_name)) %}
{% endmacro %}
