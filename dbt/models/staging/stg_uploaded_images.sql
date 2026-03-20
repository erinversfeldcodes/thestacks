{{ config(
    materialized='view'
) }}

select
    id,
    book_id,
    storage_path,
    status,
    rejection_reason,
    uploaded_at,
    expires_at,
    created_at,
    updated_at,
    book_ids,
    book_edition_id
from {{ source('op', 'uploaded_images') }}
