select * from {{ source('shared_src', 'lookup') }}
