{{ config(
    materialized='view'
) }}

select
    id,
    book_id,
    isbn,
    format_label,
    cover_image_url,
    page_count,
    publisher,
    publication_year,
    open_library_id,
    google_books_id,
    is_primary,
    created_at,
    updated_at
from {{ source('op', 'book_editions') }}
