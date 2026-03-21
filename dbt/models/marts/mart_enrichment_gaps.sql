{{ config(materialized='view') }}

with books as (
    select
        book_id,
        title,
        primary_cover_image_url,
        created_at
    from {{ ref('int_book_detail_view') }}
),

price_coverage as (
    select distinct book_id
    from {{ ref('int_price_trends') }}
),

review_coverage as (
    select distinct book_id
    from {{ ref('int_review_sentiment') }}
)

select
    books.book_id,
    books.title,
    books.created_at,
    books.primary_cover_image_url is null as missing_cover,
    price_coverage.book_id is null as missing_prices,
    review_coverage.book_id is null as missing_reviews,
    (
        case
            when books.primary_cover_image_url is null
                then 1
            else 0
        end
        + case
            when price_coverage.book_id is null
                then 1
            else 0
        end
        + case
            when review_coverage.book_id is null
                then 1
            else 0
        end
    ) as gap_count
from books
left join price_coverage
    on books.book_id = price_coverage.book_id
left join review_coverage
    on books.book_id = review_coverage.book_id
where
    books.primary_cover_image_url is null
    or price_coverage.book_id is null
    or review_coverage.book_id is null
