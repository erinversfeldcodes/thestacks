{{ config(
    materialized='view'
) }}

select
    id,
    isbn,
    title,
    author_id,
    description,
    cover_image_url,
    page_count,
    publisher,
    publication_year,
    language,
    subjects,
    bisac_codes,
    visibility_tier,
    open_library_id,
    google_books_id,
    created_at,
    updated_at
from {{ source('op', 'books') }}
