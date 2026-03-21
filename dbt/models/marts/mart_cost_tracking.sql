{{ config(materialized='view') }}

select
    id,
    category,
    service,
    description,
    amount_cents,
    currency,
    period_start,
    period_end
from {{ source('op', 'platform_costs') }}
