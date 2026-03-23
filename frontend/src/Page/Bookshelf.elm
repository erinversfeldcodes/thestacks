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
import Html exposing (Html, div, p, text)
import Html.Attributes exposing (attribute, class)
import Http
import Navigation.Route exposing (Route(..))
import Page.Bookshelf.Helpers
    exposing
        ( groupIntoRows
        , minShelfRows
        , viewBookcase
        , viewEmptyShelfMessage
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
    { books : RemoteData Http.Error (List Placement)
    , showAgeGate : Bool
    , config : Config
    , userId : String
    , visibility : String
    , rssLink : RSSLink.Model
    , viewMode : ShelfViewMode
    , sortState : BookList.SortState
    }


type OutMsg
    = NoOut
    | NavigateTo Route


type Msg
    = BooksLoaded (Result Http.Error (List Placement))
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
                    Api.getBookshelf config.apiName token BooksLoaded

                Nothing ->
                    Cmd.none
    in
    ( { books = Loading
      , showAgeGate = False
      , config = config
      , userId = userId
      , visibility = "platform"
      , rssLink = RSSLink.init
      , viewMode = SpineView
      , sortState = { column = BookList.Title, direction = BookList.Asc }
      }
    , apiCmd
    )



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        BooksLoaded result ->
            case result of
                Ok placements ->
                    ( { model | books = Success placements }
                    , Cmd.none
                    , NoOut
                    )

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
    div [ class ("page page--shelf " ++ cfg.themeClass) ]
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
                    [ case model.books of
                        NotAsked ->
                            viewBookshelf model []

                        Loading ->
                            viewBookshelf model []

                        Failure _ ->
                            p [ class "error" ]
                                [ text ("Could not load your " ++ String.toLower cfg.label ++ ". Please try again.") ]

                        Success placements ->
                            if List.isEmpty placements then
                                viewEmptyBookshelf model

                            else
                                viewBookshelf model placements
                    ]
            ]
        ]


viewEmptyBookshelf : Model -> Html Msg
viewEmptyBookshelf model =
    div [ class "bookshelf" ]
        [ viewBookcase
            (minShelfRows 4 [ viewEmptyShelfMessage model.config.emptyMessage ])
        ]


viewBookshelf : Model -> List Placement -> Html Msg
viewBookshelf model placements =
    case model.viewMode of
        ListView ->
            div [ class "bookshelf bookshelf--list-view" ]
                [ BookList.view model.sortState SortColumnClicked BookClicked placements
                ]

        SpineView ->
            let
                rows =
                    groupIntoRows 990 placements

                shelfViews =
                    List.map (viewShelfRowClickable model.config.wearLevel BookClicked) rows
            in
            div [ class "bookshelf" ]
                [ viewBookcase (minShelfRows 4 shelfViews)
                ]
