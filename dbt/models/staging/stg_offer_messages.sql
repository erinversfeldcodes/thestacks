{{ config(
    materialized='view'
) }}

select
    id,
    thread_id,
    sender_id,
    type,
    body,
    amount_cents,
    created_at
from {{ source('op', 'offer_messages') }}
