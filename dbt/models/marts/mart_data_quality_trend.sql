{{ config(
    materialized='incremental',
    unique_key='snapshot_date',
    on_schema_change='sync_all_columns',
    post_hook="delete from {{ this }} where snapshot_date < current_date - interval '84 days'"
) }}

with book_counts as (
    select
        count(*) as total_books,
        count(*) filter (
            where primary_cover_image_url is not null
        ) as books_with_covers
    from {{ ref('int_book_detail_view') }}
),

price_counts as (
    select
        count(
            distinct book_id
        ) as books_with_prices
    from {{ ref('int_price_trends') }}
),

review_counts as (
    select
        count(
            distinct book_id
        ) as books_with_reviews
    from {{ ref('int_review_sentiment') }}
),

source_counts as (
    select
        count(*) as total_sources,
        count(*) filter (
            where status = 'healthy'
        ) as healthy_sources
    from {{ ref('int_source_health') }}
),

daily_snapshot as (
    select
        bc.total_books,
        bc.books_with_covers,
        pc.books_with_prices,
        rc.books_with_reviews,
        sc.total_sources,
        sc.healthy_sources,
        current_date as snapshot_date
    from book_counts as bc
    cross join price_counts as pc
    cross join review_counts as rc
    cross join source_counts as sc
)

select
    ds.snapshot_date,
    ds.total_books,
    ds.books_with_covers,
    ds.books_with_prices,
    ds.books_with_reviews,
    ds.total_sources,
    ds.healthy_sources,
    case
        when ds.total_books > 0
            then round(
                ds.books_with_covers::numeric
                / ds.total_books * 100,
                1
            )
        else 0
    end as cover_pct,
    case
        when ds.total_books > 0
            then round(
                ds.books_with_prices::numeric
                / ds.total_books * 100,
                1
            )
        else 0
    end as price_pct,
    case
        when ds.total_books > 0
            then round(
                ds.books_with_reviews::numeric
                / ds.total_books * 100,
                1
            )
        else 0
    end as review_pct
from daily_snapshot as ds

{% if is_incremental() %}
where
    ds.snapshot_date >= (
        select max(dqt.snapshot_date)
        from {{ this }} as dqt
    )
{% endif %}
