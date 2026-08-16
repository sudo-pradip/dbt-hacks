{% snapshot orders_snapshot %}

{{
    config(
        target_schema='snapshots',
        unique_key='order_id',
        strategy='append',
        updated_at='loaded_at'
    )
}}

-- Dedupe exact duplicate (order_id, loaded_at) pairs so the append strategy's
-- uniqueness pre-condition always holds.
select *
from {{ source('raw', 'orders_append') }}
qualify row_number() over (
    partition by order_id, loaded_at
    order by loaded_at
) = 1

{% endsnapshot %}
