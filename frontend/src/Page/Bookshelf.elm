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
import Components.BookList as BookList
import Components.RSSLink as RSSLink
import Components.Spine exposing (WearLevel(..))
import Components.ViewModeToggle as ViewModeToggle exposing (ShelfViewMode(..))
import Html exposing (Html, button, div, p, text)
import Html.Attributes exposing (attribute, class)
import Html.Events exposing (onClick)
import Http
import Navigation.Route exposing (Route(..))
import Page.Bookshelf.Helpers
    exposing
        ( minShelfRows
        , viewBookcase
        , viewEmptyShelfMessage
        , viewShelfLabel
        , viewShelfRowClickable
        )
import Types.Book exposing (Book)
import Types.Placement exposing (Placement)
import Types.RemoteData exposing (RemoteData(..))
import Types.Shelf exposing (Shelf, shelvesResponseDecoder)
import Util.TestId exposing (testId)


{-| Configuration that differs between bookshelf pages.
Everything else (model, update, view structure) is identical.
-}
type alias Config =
    { apiName : String
    , label : String
    , themeClass : String
    , wallpaperClass : String
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
    { shelves : RemoteData Http.Error (List Shelf)
    , showAgeGate : Bool
    , config : Config
    , userId : String
    , visibility : String
    , rssLink : RSSLink.Model
    , viewMode : ShelfViewMode
    , sortState : BookList.SortState
    , token : Maybe String
    }


type OutMsg
    = NoOut
    | NavigateTo Route


type Msg
    = ShelvesLoaded (Result Http.Error (List Shelf))
    | AddShelf
    | ShelfAdded (Result Http.Error Shelf)
    | VerifyAge
    | DismissAgeGate
    | BookClicked Book
    | RSSLinkMsg RSSLink.Msg
    | ViewModeChanged ShelfViewMode
    | SortColumnClicked BookList.SortColumn


init : Config -> Maybe String -> String -> ( Model, Cmd Msg )
init config maybeToken userId =
    let
        apiCmd =
            case maybeToken of
                Just token ->
                    Api.getBookshelf config.apiName token ShelvesLoaded

                Nothing ->
                    Cmd.none
    in
    ( { shelves = Loading
      , showAgeGate = False
      , config = config
      , userId = userId
      , visibility = "platform"
      , rssLink = RSSLink.init
      , viewMode = SpineView
      , sortState = { column = BookList.Title, direction = BookList.Asc }
      , token = maybeToken
      }
    , apiCmd
    )



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        ShelvesLoaded result ->
            case result of
                Ok shelves ->
                    ( { model | shelves = Success shelves }
                    , Cmd.none
                    , NoOut
                    )

                Err (Http.BadStatus 403) ->
                    ( { model | shelves = Failure (Http.BadStatus 403), showAgeGate = True }, Cmd.none, NoOut )

                Err err ->
                    ( { model | shelves = Failure err }, Cmd.none, NoOut )

        AddShelf ->
            let
                cmd =
                    case model.token of
                        Just token ->
                            Api.addShelf model.config.apiName token ShelfAdded

                        Nothing ->
                            Cmd.none
            in
            ( model, cmd, NoOut )

        ShelfAdded result ->
            case result of
                Ok shelf ->
                    case model.shelves of
                        Success shelves ->
                            ( { model | shelves = Success (shelves ++ [ shelf ]) }, Cmd.none, NoOut )

                        _ ->
                            ( { model | shelves = Success [ shelf ] }, Cmd.none, NoOut )

                Err _ ->
                    ( model, Cmd.none, NoOut )

        VerifyAge ->
            ( model, Cmd.none, NavigateTo SettingsAgeVerification )

        DismissAgeGate ->
            ( { model | showAgeGate = False }, Cmd.none, NoOut )

        BookClicked bk ->
            ( model, Cmd.none, NavigateTo (BookDetail bk.id) )

        RSSLinkMsg subMsg ->
            ( { model | rssLink = RSSLink.update subMsg model.rssLink }, Cmd.none, NoOut )

        ViewModeChanged mode ->
            ( { model | viewMode = mode }, Cmd.none, NoOut )

        SortColumnClicked column ->
            let
                newDirection =
                    if model.sortState.column == column then
                        case model.sortState.direction of
                            BookList.Asc ->
                                BookList.Desc

                            BookList.Desc ->
                                BookList.Asc

                    else
                        BookList.Asc
            in
            ( { model | sortState = { column = column, direction = newDirection } }, Cmd.none, NoOut )



-- VIEW


view : Model -> Html Msg
view model =
    let
        cfg =
            model.config
    in
    div [ class ("page page--shelf " ++ cfg.themeClass), testId "bookshelf-page" ]
        [ div [ class ("wallpaper " ++ cfg.wallpaperClass) ] []
        , div [ class "lighting" ] []
        , div [ class "shelf-room" ]
            [ div [ class "shelf-room__header" ]
                [ viewShelfLabel cfg.label
                , ViewModeToggle.view model.viewMode ViewModeChanged
                , Html.map RSSLinkMsg
                    (RSSLink.view
                        { visibility = model.visibility
                        , userId = model.userId
                        , bookshelfName = cfg.apiName
                        }
                        model.rssLink
                    )
                ]
            , if model.showAgeGate then
                ageGate
                    { onVerify = VerifyAge
                    , onDismiss = DismissAgeGate
                    }

              else
                div [ attribute "aria-live" "polite" ]
                    [ case model.shelves of
                        NotAsked ->
                            viewBookshelfFromShelves model []

                        Loading ->
                            viewBookshelfFromShelves model []

                        Failure _ ->
                            p [ class "error" ]
                                [ text ("Could not load your " ++ String.toLower cfg.label ++ ". Please try again.") ]

                        Success shelves ->
                            let
                                allPlacements =
                                    List.concatMap .placements shelves
                            in
                            if List.isEmpty allPlacements then
                                viewEmptyBookshelf model

                            else
                                viewBookshelfFromShelves model shelves
                    ]
            ]
        ]


viewEmptyBookshelf : Model -> Html Msg
viewEmptyBookshelf model =
    div [ class "bookshelf", testId "bookshelf-empty" ]
        [ viewBookcase
            (minShelfRows 4 [ viewEmptyShelfMessage model.config.emptyMessage ])
        , viewAddShelfButton
        ]


viewBookshelfFromShelves : Model -> List Shelf -> Html Msg
viewBookshelfFromShelves model shelves =
    case model.viewMode of
        ListView ->
            let
                allPlacements =
                    List.concatMap .placements shelves
            in
            div [ class "bookshelf bookshelf--list-view" ]
                [ BookList.view model.sortState SortColumnClicked BookClicked allPlacements
                ]

        SpineView ->
            let
                shelfViews =
                    List.map (viewShelf model.config.wearLevel) shelves
            in
            div [ class "bookshelf" ]
                [ viewBookcase (minShelfRows 4 shelfViews)
                , viewAddShelfButton
                ]


viewShelf : WearLevel -> Shelf -> Html Msg
viewShelf wearLevel shelf =
    div
        [ class "bookcase__shelf"
        , attribute "data-shelf-id" shelf.id
        ]
        [ viewShelfRowClickable wearLevel BookClicked shelf.placements
        ]


viewAddShelfButton : Html Msg
viewAddShelfButton =
    button [ class "bookshelf__add-shelf", onClick AddShelf ]
        [ text "Add shelf" ]
