{{ config(materialized='view') }}

select
    post_id,
    title,
    visibility,
    book_association_count,
    published_at,
    created_at
from {{ ref('int_blog_engagement') }}
