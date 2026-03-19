{{ config(
    materialized='view'
) }}

select
    id,
    user_id,
    title,
    body,
    visibility,
    visibility_group_id,
    published_at,
    created_at,
    updated_at
from {{ source('op', 'blog_posts') }}
