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
