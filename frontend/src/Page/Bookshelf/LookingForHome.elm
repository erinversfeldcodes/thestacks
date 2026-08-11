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
    | DismissAgeGate


init : Maybe String -> ( Model, Cmd Msg )
init maybeToken =
    let
        cmd =
            case maybeToken of
                Just token ->
                    Api.getBookshelf "looking_for_home" token (BooksLoaded << Result.map .shelves)

                Nothing ->
                    Cmd.none
    in
    ( { books = Loading, showAgeGate = False }, cmd )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        BooksLoaded result ->
            case result of
                Ok shelves ->
                    ( { model | books = Success (List.concatMap .placements shelves) }, Cmd.none, NoOut )

                Err (Http.BadStatus 403) ->
                    ( { model | books = Failure (Http.BadStatus 403), showAgeGate = True }, Cmd.none, NoOut )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | books = Failure err }, Cmd.none, NoOut )

        DismissAgeGate ->
            ( { model | showAgeGate = False }, Cmd.none, NoOut )


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
