module Page.Bookshelf.AntiLibrary exposing
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
import Components.Spine exposing (WearLevel(..))
import Html exposing (Html, div, p, text)
import Html.Attributes exposing (class)
import Http
import Navigation.Route exposing (Route(..))
import Page.Bookshelf.Helpers exposing (groupIntoRows, viewShelfLabel, viewShelfRow)
import Types.Placement exposing (Placement)
import Types.RemoteData exposing (RemoteData(..))


type alias Model =
    { books : RemoteData Http.Error (List Placement)
    , showAgeGate : Bool
    }


type OutMsg
    = NoOut
    | NavigateTo Route


type Msg
    = BooksLoaded (Result Http.Error (List Placement))
    | VerifyAge
    | DismissAgeGate


init : Maybe String -> ( Model, Cmd Msg )
init maybeToken =
    let
        cmd =
            case maybeToken of
                Just token ->
                    Api.getBookshelf "antilibrary" token BooksLoaded

                Nothing ->
                    Cmd.none
    in
    ( { books = Loading, showAgeGate = False }, cmd )


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

        VerifyAge ->
            ( model, Cmd.none, NavigateTo SettingsAgeVerification )

        DismissAgeGate ->
            ( { model | showAgeGate = False }, Cmd.none, NoOut )


view : Model -> Html Msg
view model =
    div [ class "page page--shelf shelf-antilibrary" ]
        [ viewWallpaper
        , div [ class "shelf-room" ]
            [ viewShelfLabel "Antilibrary"
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
                        div [ class "loading" ] [ text "Loading your antilibrary..." ]

                    Failure _ ->
                        p [ class "error" ]
                            [ text "Could not load your antilibrary. Please try again." ]

                    Success placements ->
                        if List.isEmpty placements then
                            emptyBookshelf
                                { bookshelf = "antilibrary"
                                , message =
                                    "Books you own but haven't read yet. Upload a photo to start building your collection."
                                }

                        else
                            viewBookshelf placements
            ]
        ]


viewWallpaper : Html msg
viewWallpaper =
    div [ class "wallpaper wallpaper--botanical" ] []


viewBookshelf : List Placement -> Html Msg
viewBookshelf placements =
    let
        rows =
            groupIntoRows 12 placements
    in
    div [ class "bookshelf bookshelf--oak" ]
        (List.map (viewShelfRow Pristine) rows)
