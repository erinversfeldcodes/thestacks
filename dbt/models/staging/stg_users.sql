{{ config(
    materialized='view'
) }}

select
    id,
    email,
    display_name,
    role,
    age_verified,
    age_verified_at,
    age_verification_provider,
    country_code,
    city,
    consent_analytics,
    consent_analytics_at,
    created_at,
    updated_at
from {{ source('op', 'users') }}
