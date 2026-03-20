{{ config(
    materialized='view'
) }}

select
    id,
    email,
    display_name,
    role,
    profile_visibility,
    website_url,
    age_verified,
    age_verified_at,
    age_verification_provider,
    country_code,
    city,
    consent_analytics,
    consent_analytics_at,
    onboarding_completed,
    notify_wishlist_availability,
    notify_marketplace,
    notify_group_invitations,
    notify_event_matches,
    email_confirmed,
    created_at,
    updated_at
from {{ source('op', 'users') }}
