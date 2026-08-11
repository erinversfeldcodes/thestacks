select
    id,
    country_code
from {{ ref('stg_users') }}
where
    country_code is not null
    and length(country_code) <> 2
