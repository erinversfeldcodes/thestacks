{{ config(materialized='view') }}

select
    book_id,
    avg_rating,
    avg_sentiment_score,
    review_count
from {{ ref('int_review_sentiment') }}
