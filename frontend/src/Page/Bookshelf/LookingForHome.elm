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
import Html exposing (Html, div, h1, p, text)
import Html.Attributes exposing (class)
import Http
import Navigation.Route exposing (Route(..))
import Types.Book exposing (authorName)
import Types.Placement exposing (Placement)
import Types.RemoteData exposing (RemoteData(..))
import Util.TestId exposing (testId)


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
                    Api.getBookshelf "looking_for_home" token BooksLoaded

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
    div [ class "page page--bookshelf shelf-looking-for-home", testId "looking-for-home-page" ]
        [ h1 [ class "page__title" ] [ text "Looking for a Home" ]
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
        ]


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
