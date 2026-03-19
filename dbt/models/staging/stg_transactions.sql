{{ config(
    materialized='view'
) }}

select
    id,
    listing_id,
    offer_id,
    buyer_id,
    seller_id,
    amount_cents,
    currency,
    payment_provider_ref,
    payment_status,
    shipping_provider_ref,
    shipping_status,
    shipping_cost_cents,
    completed_at,
    created_at
from {{ source('op', 'transactions') }}
