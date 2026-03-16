module Page.Bookshelf.WishList exposing
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
import Page.Bookshelf.Helpers exposing (groupIntoRows, minShelfRows, viewBookcase, viewShelfLabel, viewShelfRowClickable)
import Types.Book exposing (Book)
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
    | BookClicked Book


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

        BookClicked bk ->
            ( model, Cmd.none, NavigateTo (BookDetail bk.id) )


view : Model -> Html Msg
view model =
    div [ class "page page--shelf shelf-wishlist" ]
        [ viewWallpaper
        , div [ class "shelf-room" ]
            [ viewShelfLabel "Wish List"
            , if model.showAgeGate then
                ageGate
                    { onVerify = VerifyAge
                    , onDismiss = DismissAgeGate
                    }

              else
                case model.books of
                    NotAsked ->
                        viewBookshelf []

                    Loading ->
                        viewBookshelf []

                    Failure _ ->
                        p [ class "error" ]
                            [ text "Could not load your wish list. Please try again." ]

                    Success placements ->
                        if List.isEmpty placements then
                            emptyBookshelf
                                { bookshelf = "wishlist"
                                , message =
                                    "Books you're dreaming about. Add one from a photo, a screenshot, or an ISBN."
                                }

                        else
                            viewBookshelf placements
            ]
        ]


viewWallpaper : Html msg
viewWallpaper =
    div [ class "wallpaper wallpaper--floral" ] []


viewBookshelf : List Placement -> Html Msg
viewBookshelf placements =
    let
        rows =
            groupIntoRows 990 placements

        shelfViews =
            List.map (viewShelfRowClickable Pristine BookClicked) rows
    in
    div [ class "bookshelf" ]
        [ viewBookcase (minShelfRows 4 shelfViews)
        ]
