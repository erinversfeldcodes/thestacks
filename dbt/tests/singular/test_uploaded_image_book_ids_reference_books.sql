select
    ui.id as uploaded_image_id,
    elem.book_id as missing_book_id
from {{ ref('stg_uploaded_images') }} as ui
cross join lateral unnest(ui.book_ids) as elem (book_id)
left join {{ ref('stg_books') }} as b
    on elem.book_id = b.id
where
    ui.status = 'resolved'
    and b.id is null
