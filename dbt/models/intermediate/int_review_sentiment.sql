{{ config(materialized='view') }}

select
    book_id,
    count(*) as review_count,
    coalesce(avg(rating), 0) as avg_rating,
    coalesce(avg(sentiment_score), 0) as avg_sentiment_score,
    max(scraped_at) as latest_scraped_at
from {{ source('op', 'review_snapshots') }}
group by book_id
