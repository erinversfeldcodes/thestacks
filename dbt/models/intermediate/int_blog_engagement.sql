{{ config(materialized='view') }}

with association_counts as (
    select
        post_id,
        count(*) as association_count
    from {{ ref('stg_post_book_associations') }}
    group by post_id
)

select
    bp.id as post_id,
    bp.user_id,
    bp.title,
    bp.visibility,
    bp.published_at,
    bp.created_at,
    bp.updated_at,
    coalesce(
        ac.association_count, 0
    ) as book_association_count
from {{ ref('stg_blog_posts') }} as bp
left join association_counts as ac
    on bp.id = ac.post_id
