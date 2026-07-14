module Page.Profile exposing (Model, Msg, OutMsg(..), init, update, view)

{-| A user's public profile hub at `/u/:handle` (#214). Fetches the
visibility-filtered profile for the current viewer and renders the reader's
identity plus links to each bookshelf they are allowed to browse. A hidden or
non-existent profile comes back as a 404 and renders a neutral "not found" — a
ghost and an absent user are indistinguishable, by design.
-}

import Api exposing (ProfileShelfSummary, PublicProfile)
import Html exposing (Html, a, div, h1, h2, header, li, p, section, span, text, ul)
import Html.Attributes exposing (class, href)
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
                Just (a [ class "profile__website", href profile.websiteUrl ] [ text profile.websiteUrl ])

            else
                Nothing
    in
    div [ class "profile__meta" ] (List.filterMap identity [ locationEl, websiteEl ])


viewShelves : PublicProfile -> Html Msg
viewShelves profile =
    if List.isEmpty profile.bookshelves then
        p [ class "profile__empty" ] [ text "No public bookshelves." ]

    else
        ul [ class "profile__shelf-list" ]
            (List.map (viewShelfLink profile.handle) profile.bookshelves)


viewShelfLink : String -> ProfileShelfSummary -> Html Msg
viewShelfLink handle shelf =
    li [ class "profile__shelf" ]
        [ a [ href (Route.toPath (Route.ProfileShelf handle shelf.name)) ]
            [ text (shelfLabel shelf.name) ]
        ]


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
