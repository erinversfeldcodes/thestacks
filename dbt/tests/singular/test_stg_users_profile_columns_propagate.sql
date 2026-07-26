-- Issue #126 punch #11: the settings profile and location writes land in
-- op.users.{display_name, website_url, country_code, city}. stg_users is an
-- unfiltered projection of op.users, so two guarantees must hold for the
-- downstream profile / geographic marts:
--   1. every source user row survives the staging transform (a row dropped
--      here silently removes a user from every mart built on stg_users), and
--   2. those four profile columns carry through unchanged (a rename, drop, or
--      accidental transform would silently blank or corrupt the mart values).
--
-- Referencing all four columns on BOTH sides makes a rename/drop a compile
-- error; `is distinct from` compares them null-safely so a value that fails to
-- propagate is flagged. A non-empty result is a failure.
select s.id
from {{ source('op', 'users') }} as s
left join {{ ref('stg_users') }} as u
    on s.id = u.id
where
    u.id is null
    or u.display_name is distinct from s.display_name
    or u.website_url is distinct from s.website_url
    or u.country_code is distinct from s.country_code
    or u.city is distinct from s.city
