{{ config(materialized='view') }}

select
    b.id as book_id,
    b.title,
    b.description,
    b.language,
    b.subjects,
    b.bisac_codes,
    b.visibility_tier,
    a.name as author_name,
    a.id as author_id,
    e.isbn as primary_isbn,
    e.format_label as primary_format,
    e.cover_image_url as primary_cover_image_url,
    e.page_count as primary_page_count,
    e.publisher as primary_publisher,
    e.publication_year as primary_publication_year,
    b.created_at,
    b.updated_at
from {{ ref('stg_books') }} as b
left join {{ ref('stg_authors') }} as a
    on b.author_id = a.id
left join {{ ref('stg_book_editions') }} as e
    on
        b.id = e.book_id
        and e.is_primary = true
