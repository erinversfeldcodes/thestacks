{{ config(materialized='view') }}

select
    source,
    count(*) as total_associations,
    count(*) filter (
        where confidence >= 0.9
    ) as high_confidence,
    count(*) filter (
        where confidence >= 0.7
        and confidence < 0.9
    ) as medium_confidence,
    count(*) filter (
        where confidence < 0.7
    ) as low_confidence,
    round(
        avg(confidence)::numeric, 3
    ) as avg_confidence,
    round(
        min(confidence)::numeric, 3
    ) as min_confidence,
    round(
        max(confidence)::numeric, 3
    ) as max_confidence
from {{ ref('stg_post_book_associations') }}
group by source
