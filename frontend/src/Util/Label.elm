module Util.Label exposing (humanize)

{-| Render a stored enum atom as reader/operator copy.

A status column that prints `pending_review` verbatim is leaking a storage
literal onto a surface a person reads. `humanize` turns the atom into a phrase —
underscores become spaces and the first letter is capitalised — so the same value
reads "Pending review".

@docs humanize

-}


{-| `humanize "pending_review" == "Pending review"`; `humanize "healthy" == "Healthy"`.
An empty string is returned unchanged.
-}
humanize : String -> String
humanize raw =
    case String.uncons (String.replace "_" " " raw) of
        Just ( first, rest ) ->
            String.toUpper (String.fromChar first) ++ rest

        Nothing ->
            raw
