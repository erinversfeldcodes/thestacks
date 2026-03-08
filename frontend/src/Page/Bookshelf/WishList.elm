module Page.Bookshelf.WishList exposing
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
import Types.Placement exposing (Placement)
import Types.RemoteData exposing (RemoteData(..))


type alias Model =
    { books : RemoteData Http.Error (List Placement)
    }


type Msg
    = BooksLoaded (Result Http.Error (List Placement))


init : Maybe String -> ( Model, Cmd Msg )
init maybeToken =
    let
        cmd =
            case maybeToken of
                Just token ->
                    Api.getBookshelf "wishlist" token BooksLoaded

                Nothing ->
                    Cmd.none
    in
    ( { books = Loading }, cmd )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        BooksLoaded result ->
            case result of
                Ok placements ->
                    ( { model | books = Success placements }, Cmd.none )

                Err err ->
                    ( { model | books = Failure err }, Cmd.none )


view : Model -> Html Msg
view model =
    div [ class "page page--shelf shelf-wishlist" ]
        [ h1 [ class "page__title" ] [ text "Wish List" ]
        , case model.books of
            NotAsked ->
                text ""

            Loading ->
                div [ class "loading" ] [ text "Loading your wish list..." ]

            Failure _ ->
                p [ class "error" ]
                    [ text "Could not load your wish list. Please try again." ]

            Success placements ->
                if List.isEmpty placements then
                    emptyBookshelf
                        { bookshelf = "wishlist"
                        , message =
                            "Nothing on your wishlist yet — snap photos of books you want to remember."
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
            { pageCount = 200
            , wearLevel = Pristine
            , title = "Book"
            , author = "Author"
            }
        ]
