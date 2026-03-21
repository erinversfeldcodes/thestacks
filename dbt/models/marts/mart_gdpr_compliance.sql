{{ config(materialized='view') }}

select
    count(*) as total_users,
    count(*) filter (where consent_analytics = true) as analytics_consented,
    count(*) filter (where email_confirmed = true) as email_confirmed,
    count(*) filter (where age_verified = true) as age_verified
from {{ ref('stg_users') }}
