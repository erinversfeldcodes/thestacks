module Types.ProtoHelpers exposing (emptyToNothing, zeroToNothing)

{-| Shared helpers for mapping proto3 default values to Maybe.

Proto3 uses "" for absent strings and 0 for absent integers. These helpers
convert those sentinel defaults into Nothing so the rest of the app can
work with Maybe types idiomatically.

-}


{-| Convert a proto3 empty string to Nothing.
-}
emptyToNothing : String -> Maybe String
emptyToNothing s =
    if s == "" then
        Nothing

    else
        Just s


{-| Maps proto3 zero-default integers to Maybe Nothing.
Zero is treated as "not set" — this is correct for fields like pageCount
(a real book cannot have 0 pages) and publicationYear (0 means unknown).
-}
zeroToNothing : Int -> Maybe Int
zeroToNothing n =
    if n == 0 then
        Nothing

    else
        Just n
