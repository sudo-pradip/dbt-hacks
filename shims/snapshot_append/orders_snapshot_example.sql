{% snapshot orders_snapshot %}

{{
    config(
        target_schema='snapshots',
        unique_key='order_id',
        strategy='append',
        updated_at='loaded_at'
    )
}}

-- Append-only source: the same order_id may appear many times per run.
-- Only requirement: (order_id, loaded_at) must be unique, so exact
-- duplicate loads are collapsed here.
select *
from {{ source('raw', 'orders_append') }}
qualify row_number() over (
    partition by order_id, loaded_at
    order by loaded_at
) = 1

{% endsnapshot %}
