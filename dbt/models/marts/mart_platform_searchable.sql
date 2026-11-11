{{ config(
    materialized='incremental',
    unique_key='book_id',
    on_schema_change='sync_all_columns',
    post_hook="{{ prune_absent_keys('book_id', ref('int_book_detail_view')) }}"
) }}

{#
  The post-hook is load-bearing, not hygiene. This model's `is_incremental()`
  window keys on `updated_at` of SURVIVING rows, so a deleted book never enters
  it and would stay searchable forever on the event-driven refresh path. The
  daily `--full-refresh` would eventually correct it; the hook closes the gap in
  between.

  This mart is one row per book, so unlike the community-read count there is no
  second half: a book either exists upstream or it does not, and the hook
  handles the second case exactly.
#}

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
where
    updated_at > (
        select max(prev.last_refreshed_at)
        from {{ this }} as prev
    )
{% endif %}
