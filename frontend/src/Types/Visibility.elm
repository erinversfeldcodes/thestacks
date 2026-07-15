module Types.Visibility exposing
    ( PlacementOption
    , Visibility(..)
    , ceilingHelperText
    , exceedsCeiling
    , fromString
    , placementOptions
    , rank
    , toString
    )

{-| Placement / bookshelf / profile visibility and the client-side ceiling rule.

Mirrors the canonical Audience ladder (`proto/…/visibility.proto`,
`Stacks.Visibility`), ordered by EXPOSURE — ascending = more exposed:

    owner (0)  only me
    group (1)  a chosen group ("friends")   — shelf-level; not a per-placement option
    platform (2) "Members" — any signed-in user
    public (3) anyone with the link, signed in or not

A placement may not be _more exposed_ than its parent bookshelf — the server
returns 422 if it is. We reproduce the rule so the UI greys the offending options
before the user hits the 422. (Server-side is authoritative; this is UX only.)

-}


type Visibility
    = Owner
    | Group
    | Platform
    | Public


{-| Parse a wire string into a Visibility. Unknown values return Nothing so
callers fall back explicitly rather than silently mis-classifying.
-}
fromString : String -> Maybe Visibility
fromString s =
    case s of
        "owner" ->
            Just Owner

        "group" ->
            Just Group

        "platform" ->
            Just Platform

        "public" ->
            Just Public

        _ ->
            Nothing


{-| The wire string for a Visibility (matches the server enum / DB value).
-}
toString : Visibility -> String
toString v =
    case v of
        Owner ->
            "owner"

        Group ->
            "group"

        Platform ->
            "platform"

        Public ->
            "public"


{-| Human-readable label. "Members" = any signed-in user (not a logged-out
visitor); "Anyone with the link" = public (still not search-indexed).
-}
label : Visibility -> String
label v =
    case v of
        Owner ->
            "Only me"

        Group ->
            "Group"

        Platform ->
            "Members"

        Public ->
            "Anyone with the link"


{-| Exposure rank: 0 = least exposed (owner), 3 = most exposed (public). Matches
the server `@audience_exposure` (owner < group < platform < public).
-}
rank : Visibility -> Int
rank v =
    case v of
        Owner ->
            0

        Group ->
            1

        Platform ->
            2

        Public ->
            3


{-| True when `option` is MORE exposed than the shelf `ceiling` allows — i.e. the
server would reject it (422). Such an option must be greyed out.
-}
exceedsCeiling : Visibility -> Visibility -> Bool
exceedsCeiling ceiling option =
    rank option > rank ceiling


{-| A single dropdown option, pre-computed against the shelf ceiling. Disabled
options carry no per-option tooltip — browsers don't render `title` on a disabled
`<option>` — so the ceiling is explained once via `ceilingHelperText` below the
select instead.
-}
type alias PlacementOption =
    { visibility : Visibility
    , label : String
    , disabled : Bool
    }


{-| The per-placement visibility options, ordered most→least exposed, each flagged
disabled when it exceeds the shelf `ceiling`. `Group` is a shelf-level setting, not
a per-placement override, so it is intentionally not offered here.
-}
placementOptions : Visibility -> List PlacementOption
placementOptions ceiling =
    List.map
        (\v ->
            { visibility = v
            , label = label v
            , disabled = exceedsCeiling ceiling v
            }
        )
        [ Public, Platform, Owner ]


{-| Always-visible helper text explaining why some options are greyed out. Present
only when the shelf `ceiling` actually restricts an offered option — i.e. the
ceiling is less exposed than the most-exposed option (`Public`). A public shelf
greys nothing, so no text is shown.
-}
ceilingHelperText : Visibility -> Maybe String
ceilingHelperText ceiling =
    if rank ceiling < rank Public then
        Just
            ("This shelf is set to "
                ++ label ceiling
                ++ " — a book can’t be more visible than its shelf."
            )

    else
        Nothing
