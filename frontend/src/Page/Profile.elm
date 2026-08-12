module Page.Profile exposing (Model, Msg(..), OutMsg(..), init, update, view, viewShelvesFor)

{-| A user's public profile hub at `/u/:handle`. Fetches the
visibility-filtered profile for the current viewer and renders the reader's
identity plus links to each bookshelf they are allowed to browse. A hidden or
non-existent profile comes back as a 404 and renders a neutral "not found" — a
ghost and an absent user are indistinguishable, by design.
-}

import Api exposing (ProfileShelfSummary, PublicProfile)
import Html exposing (Html, a, div, h1, h2, header, li, p, section, span, text, ul)
import Html.Attributes exposing (attribute, class, href, title, type_)
import Http
import Navigation.Route as Route
import Types.RemoteData exposing (RemoteData(..))


type alias Model =
    { handle : String
    , token : Maybe String
    , profile : RemoteData Http.Error PublicProfile
    }


type Msg
    = GotProfile (Result Http.Error PublicProfile)


type OutMsg
    = NoOut
    | SessionExpired


{-| `maybeToken` is the viewer's session token when signed in (so the server
resolves what THIS viewer may see), or `Nothing` for an anonymous viewer.
-}
init : Maybe String -> String -> ( Model, Cmd Msg )
init maybeToken handle =
    ( { handle = handle, token = maybeToken, profile = Loading }
    , Api.getProfile maybeToken handle GotProfile
    )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        GotProfile (Ok profile) ->
            ( { model | profile = Success profile }, Cmd.none, NoOut )

        GotProfile (Err err) ->
            if Api.isUnauthorized err then
                ( model, Cmd.none, SessionExpired )

            else
                ( { model | profile = Failure err }, Cmd.none, NoOut )


view : Model -> Html Msg
view model =
    case model.profile of
        NotAsked ->
            text ""

        Loading ->
            div [ class "profile profile--loading" ] [ text "Loading…" ]

        Failure _ ->
            div [ class "profile profile--not-found" ]
                [ h1 [ class "profile__name" ] [ text "Reader not found" ]
                , p [] [ text "This profile doesn’t exist or isn’t available to you." ]
                ]

        Success profile ->
            viewProfile profile


viewProfile : PublicProfile -> Html Msg
viewProfile profile =
    div [ class "profile" ]
        [ header [ class "profile__header" ]
            [ h1 [ class "profile__name" ] [ text profile.displayName ]
            , p [ class "profile__handle" ] [ text ("@" ++ profile.handle) ]
            , viewMeta profile
            ]
        , section [ class "profile__shelves" ]
            [ h2 [ class "profile__shelves-title" ] [ text "Bookshelves" ]
            , viewShelves profile
            ]
        ]


viewMeta : PublicProfile -> Html Msg
viewMeta profile =
    let
        location =
            [ profile.city, profile.countryCode ]
                |> List.filter (\s -> s /= "")
                |> String.join ", "

        locationEl =
            if location /= "" then
                Just (span [ class "profile__location" ] [ text location ])

            else
                Nothing

        websiteEl =
            if profile.websiteUrl /= "" then
                Just
                    (a
                        [ class "profile__website"
                        , href profile.websiteUrl
                        , Html.Attributes.target "_blank"
                        , Html.Attributes.rel "noopener noreferrer nofollow"
                        ]
                        [ text profile.websiteUrl ]
                    )

            else
                Nothing
    in
    div [ class "profile__meta" ] (List.filterMap identity [ locationEl, websiteEl ])


viewShelves : PublicProfile -> Html Msg
viewShelves profile =
    viewShelvesFor profile.handle profile.bookshelves


{-| The shelf list, taking only what it needs.

Split out from `viewShelves` so it is testable without constructing a whole
`PublicProfile`: the feed-link rules (present only when a feed exists, handle-addressed)
are the part worth guarding, and they depend on nothing else on the profile.

-}
viewShelvesFor : String -> List ProfileShelfSummary -> Html Msg
viewShelvesFor handle bookshelves =
    if List.isEmpty bookshelves then
        p [ class "profile__empty" ] [ text "This reader hasn’t shared any bookshelves yet." ]

    else
        ul [ class "profile__shelf-list" ]
            (List.map (viewShelfLink handle) bookshelves)


viewShelfLink : String -> ProfileShelfSummary -> Html Msg
viewShelfLink handle shelf =
    li [ class "profile__shelf" ]
        (a [ href (Route.toPath (Route.ProfileShelf handle shelf.name)) ]
            [ text (shelfLabel shelf.name) ]
            :: viewFeedLink handle shelf
        )


{-| A subscribe link for a bookshelf that has an Atom feed.

Deliberately an anchor and not a fetch. A feed is something a reader copies into their
own feed reader, so the useful artefact is a URL they can see, right-click and trust —
fetching the XML into the SPA would produce nothing anyone wants.

`download` is not set and the link opens normally: feed readers accept a pasted URL, and
browsers that understand `application/atom+xml` will offer to subscribe.

Rendered only when `shelf.hasFeed`, because only platform-visible bookshelves have a
feed and the endpoint 403s otherwise. A subscribe link that fails is worse than no link.

-}
viewFeedLink : String -> ProfileShelfSummary -> List (Html Msg)
viewFeedLink handle shelf =
    if shelf.hasFeed then
        [ a
            [ class "profile__shelf-feed"
            , href (feedUrl handle shelf.name)
            , type_ "application/atom+xml"
            , title ("Subscribe to " ++ shelfLabel shelf.name ++ " as an Atom feed")
            , attribute "rel" "alternate"
            ]
            [ text "Feed" ]
        ]

    else
        []


{-| The canonical, handle-addressed feed URL.

Handle-addressed on purpose: the UUID form exists but a page showing someone's
bookshelves knows their handle and not their id, which is precisely why this link could
not be built before. It also gives the reader a URL they can read.

-}
feedUrl : String -> String -> String
feedUrl handle bookshelfName =
    "/api/feeds/u/" ++ handle ++ "/" ++ bookshelfName


shelfLabel : String -> String
shelfLabel name =
    case name of
        "library" ->
            "Library"

        "antilibrary" ->
            "Antilibrary"

        "wishlist" ->
            "Wish List"

        "reading_pile" ->
            "Reading Pile"

        "looking_for_home" ->
            "Looking for a Home"

        other ->
            other
