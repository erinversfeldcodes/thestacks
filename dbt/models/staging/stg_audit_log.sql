{{ config(
    materialized='view'
) }}

select
    id,
    user_id,
    action,
    resource_type,
    resource_id,
    metadata,
    ip_address,
    occurred_at
from {{ source('audit', 'audit_log') }}
