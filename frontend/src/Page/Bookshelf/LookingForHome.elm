module Page.Bookshelf.LookingForHome exposing
    ( Model
    , Msg
    , OutMsg(..)
    , init
    , update
    , view
    )

import Api
import Components.AgeGate exposing (ageGate)
import Components.EmptyBookshelf exposing (emptyBookshelf)
import Effect exposing (Effect)
import Html exposing (Html, div, p, text)
import Html.Attributes exposing (class)
import Http
import Page.Bookshelf.Helpers exposing (viewShelfLabel)
import Types.Book exposing (authorName)
import Types.Placement exposing (Placement)
import Types.RemoteData exposing (RemoteData(..))
import Types.Shelf exposing (Shelf)
import Util.TestId exposing (testId)


type alias Model =
    { books : RemoteData Http.Error (List Placement)
    , showAgeGate : Bool
    }


type OutMsg
    = NoOut
    | SessionExpired


type Msg
    = BooksLoaded (Result Http.Error (List Shelf))
    | SessionExpiryDetected
    | DismissAgeGate


init : Maybe Api.Credentials -> ( Model, Cmd Msg )
init maybeToken =
    let
        ( model, effect ) =
            initWithEffect maybeToken
    in
    ( model, Effect.perform effect )


{-| `init`, with its request as data so a harness can answer it.
-}
initWithEffect : Maybe Api.Credentials -> ( Model, Effect Msg )
initWithEffect maybeToken =
    let
        effect =
            case maybeToken of
                Just token ->
                    Effect.authed (Api.getBookshelfRequest "looking_for_home")
                        token
                        { onExpired = SessionExpiryDetected
                        , onResponse =
                            Api.resolveJson Types.Shelf.bookshelfResponseDecoder
                                >> Result.map .shelves
                                >> BooksLoaded
                        }

                Nothing ->
                    Effect.none
    in
    ( { books = Loading, showAgeGate = False }, effect )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    let
        ( newModel, effect, out ) =
            updateWithEffect msg model
    in
    ( newModel, Effect.perform effect, out )


{-| `update`, with its effects as data.
-}
updateWithEffect : Msg -> Model -> ( Model, Effect Msg, OutMsg )
updateWithEffect msg model =
    case msg of
        SessionExpiryDetected ->
            ( model, Effect.none, SessionExpired )

        BooksLoaded result ->
            case result of
                Ok shelves ->
                    ( { model | books = Success (List.concatMap .placements shelves) }, Effect.none, NoOut )

                -- ⚠️ KEPT, and it is not the expiry case. A 403 here is the
                -- age gate, which is a thing to SHOW the reader rather than a
                -- reason to sign them out — the plan claims 401 only.
                Err (Http.BadStatus 403) ->
                    ( { model | books = Failure (Http.BadStatus 403), showAgeGate = True }, Effect.none, NoOut )

                Err err ->
                    -- ⛔ The plan claims the 401 first, so no re-test here.
                    ( { model | books = Failure err }, Effect.none, NoOut )

        DismissAgeGate ->
            ( { model | showAgeGate = False }, Effect.none, NoOut )


{-| Looking for a Home is a **real room in the shelf-room family** (,
), not a flat page: the same wallpaper / lamplight / brass-plate
label treatment the other bookshelves use (see `Page.Bookshelf.view`), with the
face-out `pile-view` of cover cards staged _inside_ that room. The room framing
is what makes the pile read as staged — books set out to catch a passing
reader's eye — rather than listed on a blank page.
-}
view : Model -> Html Msg
view model =
    div [ class "page page--bookshelf shelf-looking-for-home", testId "looking-for-home-page" ]
        [ div [ class "wallpaper wallpaper--botanical" ] []
        , div [ class "lighting" ] []
        , div [ class "shelf-room" ]
            [ div [ class "shelf-room__header" ]
                [ viewShelfLabel "Looking for a Home" ]
            , viewRoomContents model
            ]
        ]


{-| The room's changing contents — age gate, load/error state, or the staged
pile — always rendered _within_ the room scaffold above.
-}
viewRoomContents : Model -> Html Msg
viewRoomContents model =
    if model.showAgeGate then
        ageGate
            { onDismiss = DismissAgeGate }

    else
        case model.books of
            NotAsked ->
                text ""

            Loading ->
                div [ class "loading" ] [ text "Loading your books looking for a home..." ]

            Failure _ ->
                p [ class "error" ]
                    [ text "Could not load your books looking for a home. Please try again." ]

            Success placements ->
                if List.isEmpty placements then
                    emptyBookshelf
                        { bookshelf = "looking_for_home"
                        , message =
                            "Nothing here yet — these are books looking for a new home."
                        }

                else
                    div [ class "pile-view" ]
                        (List.map viewCover placements)


viewCover : Placement -> Html Msg
viewCover placement =
    let
        ( title, author ) =
            case placement.book of
                Just book ->
                    ( book.title, authorName book )

                Nothing ->
                    ( "Unknown Title", "Unknown Author" )
    in
    div [ class "pile-view__book" ]
        [ div [ class "pile-view__cover" ]
            [ p [ class "pile-view__title" ] [ text title ]
            , p [ class "pile-view__author" ] [ text author ]
            ]
        ]
