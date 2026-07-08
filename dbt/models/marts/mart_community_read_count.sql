{{ config(
    materialized='incremental',
    unique_key='book_id',
    on_schema_change='sync_all_columns'
) }}

select
    bp.book_id,
    count(distinct bs.user_id) as read_count,
    current_timestamp as last_refreshed_at
from {{ ref('stg_bookshelf_placements') }} as bp
inner join {{ ref('stg_bookshelves') }} as bs
    on bp.bookshelf_id = bs.id
where
    bp.removed_at is null

{% if is_incremental() %}
and bp.book_id in (
    select bp2.book_id
    from
        {{ ref('stg_bookshelf_placements') }}
            as bp2
    where
        bp2.created_at > (
            select max(prev.last_refreshed_at)
            from {{ this }} as prev
        )
        or bp2.updated_at > (
            select max(prev.last_refreshed_at)
            from {{ this }} as prev
        )
)
{% endif %}

group by bp.book_id
