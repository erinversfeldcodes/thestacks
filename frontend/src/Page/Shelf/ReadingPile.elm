module Page.Shelf.ReadingPile exposing
    ( Model
    , Msg
    , init
    , update
    , view
    )

import Api
import Components.EmptyShelf exposing (emptyShelf)
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
                    Api.getShelf "reading_pile" token BooksLoaded

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
    div [ class "page page--shelf shelf-reading-pile" ]
        [ h1 [ class "page__title" ] [ text "Reading Pile" ]
        , case model.books of
            NotAsked ->
                text ""

            Loading ->
                div [ class "loading" ] [ text "Loading your reading pile..." ]

            Failure _ ->
                p [ class "error" ]
                    [ text "Could not load your reading pile. Please try again." ]

            Success placements ->
                if List.isEmpty placements then
                    emptyShelf
                        { shelf = "reading_pile"
                        , message =
                            "Your reading pile is empty — time to pick something up."
                        }

                else
                    div [ class "pile-view" ]
                        (List.map viewCover placements)
        ]


viewCover : Placement -> Html Msg
viewCover _ =
    div [ class "pile-view__book" ]
        [ div [ class "pile-view__cover" ]
            [ text "📖" ]
        ]
