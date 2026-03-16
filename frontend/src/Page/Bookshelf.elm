module Page.Bookshelf exposing
    ( Config
    , Model
    , Msg(..)
    , OutMsg(..)
    , antiLibraryConfig
    , init
    , libraryConfig
    , update
    , view
    , wishListConfig
    )

import Api
import Components.AgeGate exposing (ageGate)
import Components.EmptyBookshelf exposing (emptyBookshelf)
import Components.Spine exposing (WearLevel(..))
import Html exposing (Html, div, p, text)
import Html.Attributes exposing (attribute, class)
import Http
import Navigation.Route exposing (Route(..))
import Page.Bookshelf.Helpers
    exposing
        ( groupIntoRows
        , minShelfRows
        , viewBookcase
        , viewShelfLabel
        , viewShelfRowClickable
        )
import Types.Book exposing (Book)
import Types.Placement exposing (Placement)
import Types.RemoteData exposing (RemoteData(..))


{-| Configuration that differs between bookshelf pages.
Everything else (model, update, view structure) is identical.
-}
type alias Config =
    { apiName : String -- "library", "antilibrary", "wishlist"
    , label : String -- "Library", "Antilibrary", "Wish List"
    , themeClass : String -- "shelf-library", "shelf-antilibrary", "shelf-wishlist"
    , wallpaperClass : String -- "wallpaper--damask", "wallpaper--botanical", "wallpaper--floral"
    , wearLevel : WearLevel
    , emptyMessage : String
    }


libraryConfig : Config
libraryConfig =
    { apiName = "library"
    , label = "Library"
    , themeClass = "shelf-library"
    , wallpaperClass = "wallpaper--damask"
    , wearLevel = Softened
    , emptyMessage = "Your library is waiting. Move a book here when you've finished reading it."
    }


antiLibraryConfig : Config
antiLibraryConfig =
    { apiName = "antilibrary"
    , label = "Antilibrary"
    , themeClass = "shelf-antilibrary"
    , wallpaperClass = "wallpaper--botanical"
    , wearLevel = Pristine
    , emptyMessage = "Books you own but haven't read yet. Upload a photo to start building your collection."
    }


wishListConfig : Config
wishListConfig =
    { apiName = "wishlist"
    , label = "Wish List"
    , themeClass = "shelf-wishlist"
    , wallpaperClass = "wallpaper--floral"
    , wearLevel = Pristine
    , emptyMessage = "Books you're dreaming about. Add one from a photo, a screenshot, or an ISBN."
    }



-- MODEL


type alias Model =
    { books : RemoteData Http.Error (List Placement)
    , showAgeGate : Bool
    , config : Config
    }


type OutMsg
    = NoOut
    | NavigateTo Route


type Msg
    = BooksLoaded (Result Http.Error (List Placement))
    | VerifyAge
    | DismissAgeGate
    | BookClicked Book


init : Config -> Maybe String -> ( Model, Cmd Msg )
init config maybeToken =
    let
        cmd =
            case maybeToken of
                Just token ->
                    Api.getBookshelf config.apiName token BooksLoaded

                Nothing ->
                    Cmd.none
    in
    ( { books = Loading, showAgeGate = False, config = config }, cmd )



-- UPDATE


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



-- VIEW


view : Model -> Html Msg
view model =
    let
        cfg =
            model.config
    in
    div [ class ("page page--shelf " ++ cfg.themeClass) ]
        [ div [ class ("wallpaper " ++ cfg.wallpaperClass) ] []
        , div [ class "shelf-room" ]
            [ viewShelfLabel cfg.label
            , if model.showAgeGate then
                ageGate
                    { onVerify = VerifyAge
                    , onDismiss = DismissAgeGate
                    }

              else
                div [ attribute "aria-live" "polite" ]
                    [ case model.books of
                        NotAsked ->
                            viewBookshelf cfg []

                        Loading ->
                            viewBookshelf cfg []

                        Failure _ ->
                            p [ class "error" ]
                                [ text ("Could not load your " ++ String.toLower cfg.label ++ ". Please try again.") ]

                        Success placements ->
                            if List.isEmpty placements then
                                emptyBookshelf
                                    { bookshelf = cfg.apiName
                                    , message = cfg.emptyMessage
                                    }

                            else
                                viewBookshelf cfg placements
                    ]
            ]
        ]


viewBookshelf : Config -> List Placement -> Html Msg
viewBookshelf cfg placements =
    let
        rows =
            groupIntoRows 990 placements

        shelfViews =
            List.map (viewShelfRowClickable cfg.wearLevel BookClicked) rows
    in
    div [ class "bookshelf" ]
        [ viewBookcase (minShelfRows 4 shelfViews)
        ]
