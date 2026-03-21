{{ config(
    materialized='incremental',
    unique_key='book_id',
    on_schema_change='sync_all_columns'
) }}

select
    book_id,
    title,
    author_name,
    primary_isbn,
    primary_cover_image_url,
    description,
    language,
    visibility_tier,
    current_timestamp as last_refreshed_at
from {{ ref('int_book_detail_view') }}

{% if is_incremental() %}
    where updated_at > (
        select max(prev.last_refreshed_at)
        from {{ this }} as prev
    )
{% endif %}
