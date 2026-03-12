{{ config(
    materialized='view'
) }}

select
    id,
    book_id,
    status,
    rejection_reason,
    uploaded_at,
    expires_at
from {{ source('op', 'uploaded_images') }}
