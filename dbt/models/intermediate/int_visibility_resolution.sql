{{ config(materialized='view') }}

select
    bs.id as bookshelf_id,
    bs.user_id,
    bs.name as bookshelf_name,
    bs.visibility as bookshelf_visibility,
    count(bp.id) as placement_count,
    count(bp.id) filter (
        where bp.visibility = 'platform'
    ) as platform_placement_count,
    count(bp.id) filter (
        where bp.visibility = 'owner'
    ) as owner_placement_count
from {{ ref('stg_bookshelves') }} as bs
left join {{ ref('stg_bookshelf_placements') }} as bp
    on
        bs.id = bp.bookshelf_id
        and bp.removed_at is null
group by
    bs.id,
    bs.user_id,
    bs.name,
    bs.visibility
