module Page.Home exposing
    ( Model(..)
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

{-| The root URL (`/`) — two faces of one route.

⛔ `/` never dead-ends and never redirects; content branches on auth:
`Landing` (signed-out: title, subtitle, About/Marketplace CTAs) or
`Collection` (signed-in: the doorway to the reader's shelves). One
route, one URL, no bounce that would break the back button or make the
root unlinkable.

-}

import Api
import Components.Spine exposing (WearLevel(..))
import Html exposing (Html, a, div, h1, p, section, text)
import Html.Attributes exposing (class, href)
import Http
import Navigation.Route as Route exposing (Route(..))
import Page.Bookshelf.Helpers exposing (viewShelfLabel, viewShelfRow)
import Types.Placement exposing (Placement)
import Types.RemoteData exposing (RemoteData(..))
import Types.Shelf exposing (Shelf)
import Util.TestId exposing (testId)


{-| The two faces of `/`. `Landing` holds no data (nothing is fetched); the
authenticated `Collection` carries the shelf-preview read.
-}
type Model
    = Landing
    | Collection { preview : RemoteData Http.Error (List Placement) }


type OutMsg
    = NoOut
    | SessionExpired


type Msg
    = PreviewLoaded (Result Http.Error (List Shelf))


{-| Signed out (`Nothing`) → the static `Landing`, no request. Signed in → the
`Collection` face with the Library shelf-preview read in flight, reusing the same
`GET /api/bookshelves/:name` every bookshelf page already uses.
-}
init : Maybe String -> ( Model, Cmd Msg )
init maybeToken =
    case maybeToken of
        Nothing ->
            ( Landing, Cmd.none )

        Just token ->
            ( Collection { preview = Loading }
            , Api.getBookshelf "library" token (PreviewLoaded << Result.map .shelves)
            )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case ( msg, model ) of
        ( PreviewLoaded result, Collection data ) ->
            case result of
                Ok shelves ->
                    ( Collection { data | preview = Success (List.concatMap .placements shelves) }
                    , Cmd.none
                    , NoOut
                    )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( Collection { data | preview = Failure err }, Cmd.none, NoOut )

        ( PreviewLoaded _, Landing ) ->
            ( model, Cmd.none, NoOut )


{-| How many preview spines the glimpse shows. A glimpse, not the whole shelf —
enough to say "this is yours" without re-rendering the Library page on the home.
-}
previewLimit : Int
previewLimit =
    12


view : Model -> Html Msg
view model =
    case model of
        Landing ->
            viewLanding

        Collection { preview } ->
            viewCollection preview


{-| The signed-out landing — the shipped surface (title, subtitle, About +
Marketplace CTAs). Model-light and static; kept intact as the welcoming face.
-}
viewLanding : Html Msg
viewLanding =
    div [ class "page page--home", testId "home-landing" ]
        [ h1 [ class "home__title" ] [ text "The Stacks" ]
        , p [ class "home__subtitle" ]
            [ text "Your personal collection, beautifully organised." ]
        , div [ class "home__actions" ]
            [ a [ href (Route.toPath About), class "btn btn--primary home__link--about" ]
                [ text "About The Stacks" ]
            , a [ href (Route.toPath MarketplaceBrowse), class "btn btn--secondary home__link--marketplace" ]
                [ text "Browse the Marketplace" ]
            ]
        , p [ class "home__questions" ]
            [ text "Wondering how any of this works, or what happens to your data? "
            , a
                [ href (Route.toPath Faq)
                , class "home__link--faq"
                , testId "home-faq-link"
                ]
                [ text "Questions, answered" ]
            , text "."
            ]
        ]


{-| The signed-in doorway: a greeting, a glimpse of the Library shelf in the
shelf-room aesthetic, and the always-present onward actions. The actions render
in every preview state — including `Failure` — so the home is never a wall.
-}
viewCollection : RemoteData Http.Error (List Placement) -> Html Msg
viewCollection preview =
    div [ class "page page--home page--home-collection", testId "home-authed" ]
        [ div [ class "home-collection" ]
            [ h1 [ class "home__title" ] [ text "Welcome back" ]
            , p [ class "home__subtitle" ]
                [ text "Step back into your collection." ]
            , viewPreview preview
            , viewActions
            ]
        ]


{-| The shelf glimpse. Reuses the shelf-room family — a wallpapered, lamplit room
carrying the brass-plate label and a real 3D shelf row — so the home feels like
_theirs_ the moment it loads, rather than a marketing hero.
-}
viewPreview : RemoteData Http.Error (List Placement) -> Html Msg
viewPreview preview =
    case preview of
        NotAsked ->
            text ""

        Loading ->
            p [ class "home-collection__status" ]
                [ text "Fetching a glimpse of your shelves…" ]

        Failure _ ->
            p [ class "home-collection__status" ]
                [ text "We couldn't reach your shelves just now — your collection is still there." ]

        Success placements ->
            if List.isEmpty placements then
                p [ class "home-collection__status" ]
                    [ text "Your shelves are waiting. Add your first book to start furnishing the room." ]

            else
                a
                    [ href (Route.toPath Library)
                    , class "shelf-library home-collection__room"
                    , testId "home-shelf-preview"
                    ]
                    [ div [ class "wallpaper wallpaper--damask" ] []
                    , div [ class "lighting" ] []
                    , div [ class "home-collection__glimpse" ]
                        [ viewShelfLabel "Your Library"
                        , viewShelfRow Softened (List.take previewLimit placements)
                        ]
                    ]


{-| The onward actions, present in every state. Add-Book is the primary,
persistent affordance; continue-reading routes back into the Reading
Pile. Plain links — the home issues no call of its own beyond the glimpse read.

The blog sits here because the home is where a signed-in reader starts, and
until now the writing on this platform was reachable only by typing the URL.
It is the quietest of the three: reading what others wrote is an invitation,
not the errand someone came here to run.

-}
viewActions : Html Msg
viewActions =
    section [ class "home-collection__actions" ]
        [ a
            [ href (Route.toPath Upload)
            , class "btn btn--primary home-collection__add"
            , testId "home-add-book"
            ]
            [ text "Add a book" ]
        , a
            [ href (Route.toPath ReadingPile)
            , class "btn btn--secondary home-collection__continue"
            , testId "home-continue-reading"
            ]
            [ text "Continue reading" ]
        , a
            [ href (Route.toPath BlogArchive)
            , class "home-collection__blog"
            , testId "home-blog"
            ]
            [ text "Read the blog" ]
        ]
