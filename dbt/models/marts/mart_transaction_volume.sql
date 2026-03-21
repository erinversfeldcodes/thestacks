{{ config(materialized='view') }}

select
    payment_status,
    count(*) as transaction_count,
    coalesce(sum(amount_cents), 0) as total_amount_cents
from {{ ref('stg_transactions') }}
group by payment_status
