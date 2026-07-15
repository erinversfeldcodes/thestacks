module Page.Bookshelf exposing
    ( Config
    , Model
    , Msg(..)
    , OutMsg(..)
    , antiLibraryConfig
    , init
    , libraryConfig
    , profileConfig
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
import Types.RemoteData exposing (RemoteData(..))
import Types.Shelf exposing (Shelf)
import Util.TestId exposing (testId)


{-| Configuration that differs between bookshelf pages.
Everything else (model, update, view structure) is identical.

`readOnly` toggles the browse mode used when viewing _another_ reader's shelf at
`/u/:handle/:bookshelf_name`: the fetch targets the profile endpoint (via
`profileHandle`) and all mutating affordances (add shelf, RSS feed, the
per-placement visibility / move / remove controls) are stripped. See US-10.5.3.

-}
type alias Config =
    { apiName : String
    , label : String
    , themeClass : String
    , wallpaperClass : String
    , wearLevel : WearLevel
    , emptyMessage : String
    , readOnly : Bool
    , profileHandle : Maybe String
    }


libraryConfig : Config
libraryConfig =
    { apiName = "library"
    , label = "Library"
    , themeClass = "shelf-library"
    , wallpaperClass = "wallpaper--damask"
    , wearLevel = Softened
    , emptyMessage = "Your library is waiting. Move a book here when you've finished reading it."
    , readOnly = False
    , profileHandle = Nothing
    }


antiLibraryConfig : Config
antiLibraryConfig =
    { apiName = "antilibrary"
    , label = "Antilibrary"
    , themeClass = "shelf-antilibrary"
    , wallpaperClass = "wallpaper--botanical"
    , wearLevel = Pristine
    , emptyMessage = "Books you own but haven't read yet. Upload a photo to start building your collection."
    , readOnly = False
    , profileHandle = Nothing
    }


wishListConfig : Config
wishListConfig =
    { apiName = "wishlist"
    , label = "Wish List"
    , themeClass = "shelf-wishlist"
    , wallpaperClass = "wallpaper--floral"
    , wearLevel = Pristine
    , emptyMessage = "Books you're dreaming about. Add one from a photo, a screenshot, or an ISBN."
    , readOnly = False
    , profileHandle = Nothing
    }


{-| Read-only config for browsing another reader's shelf at
`/u/:handle/:bookshelf_name`. Starts from the matching owner-view config (for
theme / wallpaper / wear-level) then flips `readOnly` on and records the target
handle so `init` fetches the profile endpoint instead of the viewer's own shelf.
-}
profileConfig : String -> String -> Config
profileConfig handle bookshelfName =
    let
        base =
            case bookshelfName of
                "library" ->
                    libraryConfig

                "antilibrary" ->
                    antiLibraryConfig

                "wishlist" ->
                    wishListConfig

                _ ->
                    { libraryConfig | apiName = bookshelfName, label = bookshelfName }
    in
    { base
        | apiName = bookshelfName
        , readOnly = True
        , profileHandle = Just handle
        , emptyMessage = "This shelf has no books to show."
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
    | SessionExpired


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
            case ( config.readOnly, config.profileHandle ) of
                ( True, Just handle ) ->
                    -- Browsing another reader's shelf: optional-auth GET so the
                    -- backend visibility-filters against the viewer (even anon).
                    Api.getProfileShelf maybeToken handle config.apiName ShelvesLoaded

                _ ->
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
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | shelves = Failure err }, Cmd.none, NoOut )

        AddShelf ->
            -- Defence in depth: no mutation is ever issued in read-only browse
            -- mode, even if this Msg were somehow constructed.
            if model.config.readOnly then
                ( model, Cmd.none, NoOut )

            else
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
                (viewShelfLabel cfg.label
                    :: ViewModeToggle.view model.viewMode ViewModeChanged
                    :: (if cfg.readOnly then
                            -- The RSS feed link is an owner affordance; a viewer
                            -- browsing another reader's shelf gets no feed control.
                            []

                        else
                            [ Html.map RSSLinkMsg
                                (RSSLink.view
                                    { visibility = model.visibility
                                    , userId = model.userId
                                    , bookshelfName = cfg.apiName
                                    }
                                    model.rssLink
                                )
                            ]
                       )
                )
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
                            if cfg.readOnly then
                                p [ class "shelf-unavailable", testId "shelf-unavailable" ]
                                    [ text "Reader not found, or this shelf isn't available." ]

                            else
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
        (viewBookcase
            (minShelfRows 4 [ viewEmptyShelfMessage model.config.emptyMessage ])
            :: viewAddShelfControls model.config
        )


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
                (viewBookcase (minShelfRows 4 shelfViews)
                    :: viewAddShelfControls model.config
                )


{-| The "Add shelf" affordance is owner-only — a read-only browse view of another
reader's shelf renders none of it (and cannot dispatch `AddShelf`).
-}
viewAddShelfControls : Config -> List (Html Msg)
viewAddShelfControls config =
    if config.readOnly then
        []

    else
        [ viewAddShelfButton ]


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
