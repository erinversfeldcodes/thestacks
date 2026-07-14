module Types.Visibility exposing
    ( PlacementOption
    , Visibility(..)
    , exceedsCeiling
    , fromString
    , placementOptions
    , rank
    , toString
    )

{-| Placement / bookshelf visibility and the client-side ceiling rule.

This mirrors the server-side `Stacks.Visibility.validate_visibility_ceiling/3`
(ranking `public(0) < platform(1) < owner(2)`, where a higher rank is more
restrictive). A placement may not be _more visible_ (lower rank) than its parent
bookshelf — the server returns 422 if it is. We reproduce the rule here so the
UI can grey out the offending options before the user ever hits the 422.

The named categories deliberately match the three the placement/shelf ceiling
rule ranks; group visibility is handled elsewhere (shelf settings) and is out of
scope for the per-placement override.

-}


type Visibility
    = Public
    | Platform
    | Owner


{-| Parse a wire string into a Visibility. Unknown values return Nothing so
callers fall back explicitly rather than silently mis-classifying.
-}
fromString : String -> Maybe Visibility
fromString s =
    case s of
        "public" ->
            Just Public

        "platform" ->
            Just Platform

        "owner" ->
            Just Owner

        _ ->
            Nothing


{-| The wire string for a Visibility (matches the server enum).
-}
toString : Visibility -> String
toString v =
    case v of
        Public ->
            "public"

        Platform ->
            "platform"

        Owner ->
            "owner"


{-| Human-readable label for the dropdown.
-}
label : Visibility -> String
label v =
    case v of
        Public ->
            "Public"

        Platform ->
            "Platform"

        Owner ->
            "Only me"


{-| Restrictiveness rank: 0 = most permissive (public), 2 = most restrictive
(owner). Matches the server `@visibility_rank`.
-}
rank : Visibility -> Int
rank v =
    case v of
        Public ->
            0

        Platform ->
            1

        Owner ->
            2


{-| True when `option` is more permissive than the shelf `ceiling` allows — i.e.
it would be rejected by the server 422. Such an option must be greyed out.
-}
exceedsCeiling : Visibility -> Visibility -> Bool
exceedsCeiling ceiling option =
    rank option < rank ceiling


{-| A single dropdown option, pre-computed against the shelf ceiling.
-}
type alias PlacementOption =
    { visibility : Visibility
    , label : String
    , disabled : Bool
    , tooltip : Maybe String
    }


{-| The three placement-visibility options, ordered most→least permissive, each
flagged disabled (with an explanatory tooltip) when it exceeds the shelf
`ceiling`.
-}
placementOptions : Visibility -> List PlacementOption
placementOptions ceiling =
    List.map
        (\v ->
            let
                disabled =
                    exceedsCeiling ceiling v
            in
            { visibility = v
            , label = label v
            , disabled = disabled
            , tooltip =
                if disabled then
                    Just ("Can’t be more visible than its shelf (" ++ label ceiling ++ ")")

                else
                    Nothing
            }
        )
        [ Public, Platform, Owner ]
