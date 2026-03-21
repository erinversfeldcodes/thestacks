{{ config(materialized='view') }}

select
    book_id,
    title,
    author_name,
    primary_isbn,
    primary_cover_image_url,
    description,
    language,
    visibility_tier
from {{ ref('int_book_detail_view') }}
