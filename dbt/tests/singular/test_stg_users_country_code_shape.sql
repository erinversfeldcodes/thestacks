-- Issue #126 punch #12: users.country_code is an ISO 3166-1 alpha-2 code —
-- exactly two characters — or null for a user who has not set a location.
-- Nothing in the op-schema constrains its length (the field_override is a
-- default only, no CHECK), so a malformed 3-letter code, or a city name
-- written to the wrong column, would flow silently into every geographic
-- discovery mart built on stg_users. The `location_changeset` enforces the
-- 2-char shape on write; this guards the same invariant at the warehouse
-- boundary, independent of the OLTP validation.
--
-- A non-empty result is a failure.
select
    id,
    country_code
from {{ ref('stg_users') }}
where
    country_code is not null
    and length(country_code) <> 2
