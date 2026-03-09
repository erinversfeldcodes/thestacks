module Page.Bookshelf.Library exposing
    ( Model
    , Msg
    , init
    , update
    , view
    )

import Api
import Components.EmptyBookshelf exposing (emptyBookshelf)
import Components.Spine exposing (WearLevel(..), spine)
import Html exposing (Html, div, h1, p, text)
import Html.Attributes exposing (class)
import Http
import Types.Book exposing (Book)
import Types.Placement exposing (Placement)
import Types.RemoteData exposing (RemoteData(..))


type alias Model =
    { books : RemoteData Http.Error (List Placement)
    , selectedBook : Maybe Book
    }


type Msg
    = BooksLoaded (Result Http.Error (List Placement))
    | SelectBook Book
    | ClearSelection


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
    ( { books = Loading, selectedBook = Nothing }, cmd )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        BooksLoaded result ->
            case result of
                Ok placements ->
                    ( { model | books = Success placements }, Cmd.none )

                Err err ->
                    ( { model | books = Failure err }, Cmd.none )

        SelectBook book ->
            ( { model | selectedBook = Just book }, Cmd.none )

        ClearSelection ->
            ( { model | selectedBook = Nothing }, Cmd.none )


view : Model -> Html Msg
view model =
    div [ class "page page--shelf shelf-library" ]
        [ h1 [ class "page__title" ] [ text "Library" ]
        , case model.books of
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
viewSpine _ =
    div [ class "bookshelf__book" ]
        [ spine
            { pageCount = 300
            , wearLevel = Softened
            , title = "Book"
            , author = "Author"
            }
        ]
