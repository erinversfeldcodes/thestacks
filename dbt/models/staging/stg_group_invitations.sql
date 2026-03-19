{{ config(
    materialized='view'
) }}

select
    id,
    group_id,
    invited_by_id,
    invited_user_id,
    status,
    responded_at,
    created_at
from {{ source('op', 'group_invitations') }}
