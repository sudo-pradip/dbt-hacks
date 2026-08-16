{#
    dbt_hacks :: defer_source — make source() respect --defer
    =========================================================

    dbt's --defer rewrites ref() to point at state-manifest ("production")
    locations, but never rewrites source(). This macro replays ref()'s defer
    decision for sources, using only what dbt already exposes to Jinja at
    execution time.

    ACTIVATION: ref/source/config are Jinja context properties, not
    dispatched macros, so dbt only lets ROOT-PROJECT macros shadow them —
    an installed package cannot override source() by itself
    (https://github.com/dbt-labs/dbt-core/issues/4491, and the note on
    https://docs.getdbt.com/reference/dbt-jinja-functions/builtins).
    Copy shims/source_defer/source.sql into your own project's macros/
    directory; it is a one-line hook that delegates here.

    WHY source() DOESN'T DEFER NATIVELY
    (dbt-core v1.12, core/dbt/contracts/graph/manifest.py):
        Manifest.merge_from_artifact() attaches a `defer_relation` (the node's
        resolved location in the --state manifest) only to non-ephemeral
        refable nodes — models, seeds, snapshots — that exist in BOTH the
        current and the state manifest. Sources are skipped entirely, so
        source() has nothing to defer to. Upstream: dbt-core#10912.

    THE DECISION RULE, mirrored from ref()
    (dbt-core v1.12, core/dbt/context/providers.py, RuntimeRefResolver.create_relation):
        defer when: target_model.defer_relation AND --defer AND (
            (--favor-state AND target_model.unique_id NOT IN selected_resources)
            OR NOT adapter.get_relation(database, schema, identifier)   -- local missing
        )
        Mapped to sources:
          * sources are never selected as buildable nodes, so --favor-state
            always defers them (same as an unselected ref)
          * "defer_relation exists" becomes "we know a deferred catalog":
            the var dbt_hacks__source_defer_database (explicit), or the
            majority database across all defer_relations dbt merged into the
            run graph (inferred — assumes deferred sources share a catalog
            with deferred models; one catalog per environment)

    WHAT THIS MACRO USES FROM THE JINJA CONTEXT:
      * builtins.source(...)   -> always called first: keeps parse-time DAG
                                  edges, native quoting, unit-test resolvers,
                                  and --empty / event-time handling intact
      * execute                -> graph/adapter only exist at execution time;
                                  at parse time this is a pure passthrough
      * invocation_args_dict   -> live per-command --defer / --favor-state
      * adapter.get_relation   -> the same existence check ref() uses
      * graph.nodes[*].defer_relation -> the state-manifest locations dbt
                                  merged at runtime (merge_from_artifact runs
                                  in before_run, i.e. execution time only)
      * target.database        -> the environment's default catalog; sources
                                  without an explicit database resolve here
                                  (dbt-core parser: `source.database or
                                  credentials.database`)

    SAFETY RAILS:
      * Pure no-op without --defer — stock dbt behavior, zero config impact.
      * Only "environment-derived" sources are auto-deferred: a source whose
        resolved database differs from target.database was given an explicit
        database by declaration (e.g. a RAW catalog shared by every
        environment) and is left untouched. Set the var
        dbt_hacks__source_defer_database to defer ALL sources to one catalog.
      * Deterministic: ties in the majority vote break alphabetically.
      * replace_path() preserves everything else on the relation (quoting,
        limit=0 from --empty, event-time filters) — it is a dataclass replace
        (dbt-adapters BaseRelation.replace_path).

    VARS:
      dbt_hacks__source_defer_enabled   (bool, default true)  — kill switch
      dbt_hacks__source_defer_database  (string, default none) — explicit
        deferred catalog; skips inference and applies to every source.

    LIMITATIONS (full list in README):
      * Only database/catalog is deferred; schema + identifier are assumed
        identical across environments (sources never get per-env
        generate_schema_name treatment anyway).
      * Inference assumes deferred sources share a catalog with deferred
        models. Raw data in a different catalog => set the var above.
      * Sources with Jinja-driven databases (env_var) look "explicit" and are
        not auto-deferred => set the var above.
      * dbt docs generate bypasses source() overrides when building the
        catalog (dbt-core#6308).
      * dbt Fusion (v2): untested — issue #10912 is labeled engine:v1.

    REMOVE THIS HACK when either lands in dbt-core:
      * https://github.com/dbt-labs/dbt-core/issues/10912  (allow defer of sources)
      * https://github.com/dbt-labs/dbt-core/issues/9395   (project-level source database)

    Pattern provenance (community-standard builtins override):
      * https://docs.getdbt.com/reference/dbt-jinja-functions/builtins
      * https://github.com/dbt-labs/dbt-core/issues/6308  (also documents the
        docs-generate caveat)
      * https://discourse.getdbt.com/t/create-custom-ref-source-macro/431
#}

{% macro defer_source(source_name, table_name) %}

    {# Always resolve natively first: registers the DAG edge at parse time
       and preserves quoting, unit-test, --empty, and event-time behavior. #}
    {% set rel = builtins.source(source_name, table_name) %}

    {% if execute
          and var('dbt_hacks__source_defer_enabled', true)
          and invocation_args_dict.get('defer') %}

        {% set override_db = var('dbt_hacks__source_defer_database', none) %}

        {# An explicit override applies to every source; otherwise only
           environment-derived sources are candidates (see header). #}
        {% if override_db or rel.database == target.database %}

            {# Same short-circuit as ref(): favor-state skips the local
               existence check entirely. The check runs before the inference
               so a locally-existing source never pays for the graph scan. #}
            {% if invocation_args_dict.get('favor_state')
                  or not adapter.get_relation(rel.database, rel.schema, rel.identifier) %}

                {% set deferred_db = override_db or dbt_hacks.dbt_hacks__infer_defer_database() %}
                {% if deferred_db %}
                    {% set rel = rel.replace_path(database=deferred_db) %}
                {% endif %}

            {% endif %}

        {% endif %}

    {% endif %}

    {% do return(rel) %}

{% endmacro %}


{% macro dbt_hacks__infer_defer_database() %}
    {# Majority database across the defer_relations dbt merged into the run
       graph from the --state manifest. dictsort (by name) followed by a
       stable sort on the count makes ties break alphabetically, so the
       result is deterministic within a run. Returns none when the state
       manifest contributed no defer_relations (no overlap with this project)
       — in that case source() stays local, matching ref()'s behavior for
       nodes without a defer_relation. #}
    {% set defer_dbs = graph.nodes.values()
          | map(attribute='defer_relation') | select
          | map(attribute='database') | select | list %}
    {% if defer_dbs %}
        {% set counts = {} %}
        {% for d in defer_dbs %}{% do counts.update({d: counts.get(d, 0) + 1}) %}{% endfor %}
        {% do return((counts | dictsort | sort(attribute=1) | last)[0]) %}
    {% endif %}
    {% do return(none) %}
{% endmacro %}
