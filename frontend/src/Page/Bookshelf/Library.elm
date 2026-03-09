module Page.Bookshelf.Library exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

import Api
import Components.AgeGate exposing (ageGate)
import Components.EmptyBookshelf exposing (emptyBookshelf)
import Components.Spine exposing (WearLevel(..), spine)
import Html exposing (Html, div, h1, p, text)
import Html.Attributes exposing (class)
import Http
import Navigation.Route exposing (Route(..))
import Types.Book exposing (Book)
import Types.Placement exposing (Placement)
import Types.RemoteData exposing (RemoteData(..))


type alias Model =
    { books : RemoteData Http.Error (List Placement)
    , selectedBook : Maybe Book
    , showAgeGate : Bool
    }


type OutMsg
    = NoOut
    | NavigateTo Route


type Msg
    = BooksLoaded (Result Http.Error (List Placement))
    | SelectBook Book
    | ClearSelection
    | VerifyAge
    | DismissAgeGate


init : Maybe String -> ( Model, Cmd Msg )
init maybeToken =
    let
        cmd =
            case maybeToken of
                Just token ->
                    Api.getBookshelf "library" token BooksLoaded

                Nothing ->
                    Cmd.none
    in
    ( { books = Loading, selectedBook = Nothing, showAgeGate = False }, cmd )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        BooksLoaded result ->
            case result of
                Ok placements ->
                    ( { model | books = Success placements }, Cmd.none, NoOut )

                Err (Http.BadStatus 403) ->
                    ( { model | books = Failure (Http.BadStatus 403), showAgeGate = True }, Cmd.none, NoOut )

                Err err ->
                    ( { model | books = Failure err }, Cmd.none, NoOut )

        SelectBook book ->
            ( { model | selectedBook = Just book }, Cmd.none, NoOut )

        ClearSelection ->
            ( { model | selectedBook = Nothing }, Cmd.none, NoOut )

        VerifyAge ->
            ( model, Cmd.none, NavigateTo SettingsAgeVerification )

        DismissAgeGate ->
            ( { model | showAgeGate = False }, Cmd.none, NoOut )


view : Model -> Html Msg
view model =
    div [ class "page page--shelf shelf-library" ]
        [ h1 [ class "page__title" ] [ text "Library" ]
        , if model.showAgeGate then
            ageGate
                { onVerify = VerifyAge
                , onDismiss = DismissAgeGate
                }

          else
            case model.books of
                NotAsked ->
                    text ""

                Loading ->
                    div [ class "loading" ] [ text "Loading your library..." ]

                Failure _ ->
                    p [ class "error" ] [ text "Could not load your library. Please try again." ]

                Success placements ->
                    if List.isEmpty placements then
                        emptyBookshelf
                            { bookshelf = "library"
                            , message =
                                "Your library is empty — start by adding some books you own."
                            }

                    else
                        div [ class "bookshelf" ]
                            [ div [ class "bookshelf__row" ]
                                (List.map viewSpine placements)
                            ]
        ]


viewSpine : Placement -> Html Msg
viewSpine placement =
    let
        ( title, author, pageCount ) =
            case placement.book of
                Just book ->
                    ( book.title, book.author.name, Maybe.withDefault 200 book.pageCount )

                Nothing ->
                    ( "Unknown Title", "Unknown Author", 200 )
    in
    div [ class "bookshelf__book" ]
        [ spine
            { pageCount = pageCount
            , wearLevel = Softened
            , title = title
            , author = author
            }
        ]
