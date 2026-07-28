module Page.Bookshelf exposing
    ( Config
    , Model
    , Msg(..)
    , OutMsg(..)
    , antiLibraryConfig
    , init
    , libraryConfig
    , profileConfig
    , requestKey
    , update
    , view
    , wishListConfig
    )

import Api
import Components.AgeGate exposing (ageGate)
import Components.BookList as BookList
import Components.RSSLink as RSSLink
import Components.ShelfOrganiser as ShelfOrganiser
import Components.Spine exposing (WearLevel(..))
import Components.ViewModeToggle as ViewModeToggle exposing (ShelfViewMode(..))
import Html exposing (Html, a, div, h2, p, text)
import Html.Attributes exposing (attribute, class, href)
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
import Types.RemoteData exposing (RemoteData(..))
import Types.Shelf exposing (BookshelfResponse, Shelf)
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

                "reading_pile" ->
                    { libraryConfig | label = "Reading Pile" }

                "looking_for_home" ->
                    { libraryConfig | label = "Looking for a Home" }

                _ ->
                    { libraryConfig | apiName = bookshelfName, label = bookshelfName }
    in
    { base
        | apiName = bookshelfName
        , readOnly = True
        , profileHandle = Just handle
        , emptyMessage = "Nothing on this shelf to show right now."
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

    -- Shelf organisation (US-1.7.1 / #190, G5). `organiserBusy` gates every control while
    -- a mutation is in flight, so two conflicting orders cannot be queued.
    , organiser : ShelfOrganiser.State
    , organiserBusy : Bool
    , organiserError : Maybe String
    }


type OutMsg
    = NoOut
    | NavigateTo Route
    | SessionExpired


{-| Identifies which bookshelf a `ShelvesLoaded` response was requested for.

Library, Antilibrary and Wish List all render through this one module and all
sit behind Main.elm's single `PageBookshelf` constructor, so Main's
constructor-match cannot tell them apart: a response for the shelf the user has
just left is still delivered to the shelf they landed on. Tagging the message
with the requesting config lets `update` drop it (Issue #274, US-1.2.5).

The handle is part of the key because the same `apiName` is also fetched in
read-only mode for another reader's profile shelf — `/library` and
`/u/ada/library` are different requests.

-}
requestKey : Config -> String
requestKey config =
    case config.profileHandle of
        Just handle ->
            "@" ++ handle ++ "/" ++ config.apiName

        Nothing ->
            config.apiName


type Msg
    = ShelvesLoaded String (Result Http.Error BookshelfResponse)
    | DismissAgeGate
    | BookClicked Book
    | RSSLinkMsg RSSLink.Msg
    | ViewModeChanged ShelfViewMode
    | SortColumnClicked BookList.SortColumn
    | OrganiserMsg ShelfOrganiser.Msg
    | ShelfMutated (Result Http.Error ())


init : Config -> Maybe String -> String -> ( Model, Cmd Msg )
init config maybeToken userId =
    let
        apiCmd =
            case ( config.readOnly, config.profileHandle ) of
                ( True, Just handle ) ->
                    -- Browsing another reader's shelf: optional-auth GET so the
                    -- backend visibility-filters against the viewer (even anon).
                    -- The read-only path never renders RSS, so the profile
                    -- payload carries no visibility; default it to "owner" to
                    -- reuse the shared ShelvesLoaded response shape.
                    Api.getProfileShelf maybeToken
                        handle
                        config.apiName
                        (ShelvesLoaded (requestKey config) << Result.map (\shelves -> { shelves = shelves, visibility = "owner" }))

                _ ->
                    case maybeToken of
                        Just token ->
                            Api.getBookshelf config.apiName token (ShelvesLoaded (requestKey config))

                        Nothing ->
                            Cmd.none
    in
    ( { shelves = Loading
      , showAgeGate = False
      , config = config
      , userId = userId

      -- Loading-state placeholder only: the real value arrives with
      -- ShelvesLoaded. "owner" (the enum default) keeps the RSS affordance
      -- hidden until the server's actual visibility is known.
      , visibility = "owner"
      , rssLink = RSSLink.init
      , viewMode = SpineView
      , sortState = { column = BookList.Title, direction = BookList.Asc }
      , token = maybeToken
      , organiser = ShelfOrganiser.init
      , organiserBusy = False
      , organiserError = Nothing
      }
    , apiCmd
    )



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        ShelvesLoaded key result ->
            if key /= requestKey model.config then
                -- Stale: this response belongs to a bookshelf the user has since
                -- navigated away from. Because Library / Antilibrary / Wish List
                -- share Main's single `PageBookshelf` constructor, it still lands
                -- here — applying it would paint the previous shelf's books onto
                -- this one (Issue #274). Drop it; this page's own request is still
                -- in flight and will resolve on its own.
                ( model, Cmd.none, NoOut )

            else
                case result of
                    Ok response ->
                        ( { model
                            | shelves = Success response.shelves
                            , visibility = response.visibility
                          }
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

        DismissAgeGate ->
            ( { model | showAgeGate = False }, Cmd.none, NoOut )

        BookClicked bk ->
            if model.config.readOnly then
                -- Read-only browse is look-only (US-10.5.3): a spine click must not
                -- escape into the viewer's OWN owner-mode BookDetail (Add/move/remove).
                ( model, Cmd.none, NoOut )

            else
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

        OrganiserMsg subMsg ->
            handleOrganiser subMsg model

        ShelfMutated (Ok ()) ->
            -- Refetch rather than trusting the local order. A create assigns a position the
            -- client never chose, and a delete renumbers — so the server's answer is the
            -- only trustworthy one, and the extra round trip is cheap on a rare action.
            ( { model | organiserBusy = False, organiserError = Nothing }
            , reloadShelves model
            , NoOut
            )

        ShelfMutated (Err err) ->
            if Api.isUnauthorized err then
                ( model, Cmd.none, SessionExpired )

            else
                -- Refetch on failure too: the optimistic reorder below already moved the
                -- row, so leaving it there would show an order the server rejected.
                ( { model | organiserBusy = False, organiserError = Just (mutationError err) }
                , reloadShelves model
                , NoOut
                )


{-| Shelf organisation, split out so `update` stays flat.

Reorders are **optimistic** — the row moves immediately and the full order is sent — because
a reorder with a round trip of latency before anything moves feels broken. Create and delete
are not optimistic: both change positions the server assigns, so guessing would show a
number that is about to change.

-}
handleOrganiser : ShelfOrganiser.Msg -> Model -> ( Model, Cmd Msg, OutMsg )
handleOrganiser subMsg model =
    case ( subMsg, model.token, model.shelves ) of
        ( ShelfOrganiser.AddShelf, Just token, _ ) ->
            ( { model | organiserBusy = True }
            , Api.createShelf model.config.apiName token ShelfMutated
            , NoOut
            )

        ( ShelfOrganiser.RemoveShelf id, Just token, _ ) ->
            ( { model | organiserBusy = True }
            , Api.deleteShelf id token ShelfMutated
            , NoOut
            )

        ( ShelfOrganiser.MoveUp id, Just token, Success shelves ) ->
            persistOrder (ShelfOrganiser.moveUp id shelves) token model

        ( ShelfOrganiser.MoveDown id, Just token, Success shelves ) ->
            persistOrder (ShelfOrganiser.moveDown id shelves) token model

        ( ShelfOrganiser.DragStart id, _, _ ) ->
            ( { model | organiser = { dragging = Just id } }, Cmd.none, NoOut )

        ( ShelfOrganiser.DragEnd, _, _ ) ->
            ( { model | organiser = { dragging = Nothing } }, Cmd.none, NoOut )

        ( ShelfOrganiser.DragOver, _, _ ) ->
            -- ⚠️ Must leave `dragging` alone. `dragover` fires continuously while a row is
            -- hovered, so anything that clears the drag state here makes every drop a
            -- silent no-op — which is exactly the bug this clause replaced.
            ( model, Cmd.none, NoOut )

        ( ShelfOrganiser.DropOn targetId, Just token, Success shelves ) ->
            case model.organiser.dragging of
                Just draggedId ->
                    -- Drop resolves to the same pure move the buttons use, so the two
                    -- affordances cannot disagree about what a move means.
                    persistOrder
                        (moveToId draggedId targetId shelves)
                        token
                        { model | organiser = { dragging = Nothing } }

                Nothing ->
                    ( model, Cmd.none, NoOut )

        _ ->
            -- No token, or shelves not loaded: nothing to organise. Silent because the
            -- controls are not rendered in that state, so reaching here is a stale click.
            ( model, Cmd.none, NoOut )


{-| Apply an already-computed order locally and persist the whole list.
-}
persistOrder : List Shelf -> String -> Model -> ( Model, Cmd Msg, OutMsg )
persistOrder reordered token model =
    ( { model | shelves = Success reordered, organiserBusy = True, organiserError = Nothing }
    , Api.reorderShelves
        model.config.apiName
        (ShelfOrganiser.orderedIds reordered)
        token
        ShelfMutated
    , NoOut
    )


{-| Move `draggedId` to wherever `targetId` currently sits.
-}
moveToId : String -> String -> List Shelf -> List Shelf
moveToId draggedId targetId shelves =
    let
        indexOf id =
            shelves
                |> List.indexedMap (\i shelf -> ( i, shelf.id ))
                |> List.filter (\( _, shelfId ) -> shelfId == id)
                |> List.head
                |> Maybe.map Tuple.first
    in
    case ( indexOf draggedId, indexOf targetId ) of
        ( Just from, Just to ) ->
            ShelfOrganiser.moveTo from to shelves

        _ ->
            shelves


{-| Refetch after a shelf mutation.

⚠️ **Uses `getBookshelf` — the same call as the initial load — and that is the whole point.**
This used to call `Api.getShelves` (`GET /api/bookshelves/:name/shelves`), whose payload
carried a hardcoded empty `placements` list for every shelf. So adding, removing or
reordering a shelf repainted the bookcase from placement-less shelves: nineteen books
vanished, the organiser labelled a full shelf "empty", and `Remove` became enabled on a
shelf the server would refuse to delete. Found by driving a preview; no unit test on either
side of the wire could see it, because each half was self-consistent.

Refetching the whole bookshelf also picks up `visibility` rather than carrying the stale
value forward, and means there is exactly one shape and one decoder for "this bookshelf's
shelves" — the two paths cannot drift apart again.

-}
reloadShelves : Model -> Cmd Msg
reloadShelves model =
    case model.token of
        Just token ->
            Api.getBookshelf model.config.apiName token (ShelvesLoaded (requestKey model.config))

        Nothing ->
            Cmd.none


{-| A mutation failure in the reader's terms.
-}
mutationError : Http.Error -> String
mutationError err =
    case err of
        Http.BadStatus 422 ->
            "That shelf still has books on it. Move them elsewhere first."

        Http.BadStatus 403 ->
            "That shelf is not yours to change."

        Http.BadStatus 404 ->
            "That shelf no longer exists."

        _ ->
            "Could not save that change. Please try again."



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
            (viewReadOnlyAttribution cfg
                ++ [ div [ class "shelf-room__header" ]
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
                            { onDismiss = DismissAgeGate }

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
            )
        ]


viewEmptyBookshelf : Model -> Html Msg
viewEmptyBookshelf model =
    div [ class "bookshelf", testId "bookshelf-empty" ]
        [ viewBookcase
            (minShelfRows 4 [ viewEmptyShelfMessage model.config.emptyMessage ])
        ]


{-| In read-only browse, orient the viewer: who owns this shelf and a link back
to their profile hub. Empty for the owner's own view. Uses the handle (the
profile-shelf payload carries no display name), matching the hub's @handle style.
-}
viewReadOnlyAttribution : Config -> List (Html Msg)
viewReadOnlyAttribution cfg =
    case ( cfg.readOnly, cfg.profileHandle ) of
        ( True, Just handle ) ->
            [ a
                [ class "shelf-room__attribution"
                , testId "shelf-attribution"
                , href (Navigation.Route.toPath (Profile handle))
                ]
                [ text ("← @" ++ handle ++ "’s shelves") ]
            ]

        _ ->
            []


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
                -- Auto-flow: flatten every placement across the server's shelves
                -- and re-group into rows that fill the bookcase inner width, so the
                -- bookcase grows a new row only as books demand it. This is a
                -- deliberate presentation choice — the frontend does not surface the
                -- physical op.shelves boundaries (#151). The shelves themselves are
                -- live backend infrastructure (place_book assigns each placement a
                -- shelf); we simply render across them rather than per-shelf.
                shelfRows =
                    List.concatMap .placements shelves
                        |> groupIntoRows bookcaseInnerWidth
                        |> List.map (viewShelfRowClickable model.config.wearLevel BookClicked)
            in
            div [ class "bookshelf" ]
                [ viewBookcase (minShelfRows 4 shelfRows)
                , viewOrganiser model shelves
                ]


{-| The shelf organiser (US-1.7.1 / #190), for the owner only.

⚠️ **A separate panel, deliberately not a change to the spine layout.** The bookcase
auto-flows placements into visual rows and does _not_ surface the physical `op.shelves`
boundaries — a documented presentation choice (#151), noted in `SpineView` above. Rendering
spines per shelf to make organisation visible would quietly reverse that decision. So this
manages the physical shelves alongside the bookcase instead of reshaping it.

Hidden when `readOnly` (someone else's bookshelf) or when there is no token: organising
another reader's shelves is not a thing, and the controls would 403.

-}
viewOrganiser : Model -> List Shelf -> Html Msg
viewOrganiser model shelves =
    if model.config.readOnly || model.token == Nothing then
        text ""

    else
        div [ class "bookshelf__organiser", testId "shelf-organiser" ]
            [ h2 [ class "bookshelf__organiser-title" ] [ text "Shelves" ]
            , p [ class "bookshelf__organiser-hint" ]
                [ text
                    ("These are the physical shelves in this bookcase. Drag a row, or use "
                        ++ "the arrows, to reorder them."
                    )
                ]
            , case model.organiserError of
                Just message ->
                    p [ class "bookshelf__organiser-error", testId "shelf-organiser-error" ]
                        [ text message ]

                Nothing ->
                    text ""
            , Html.map OrganiserMsg
                (ShelfOrganiser.view
                    { shelves = shelves
                    , state = model.organiser
                    , busy = model.organiserBusy
                    }
                )
            ]


{-| The bookcase inner width (~996px) used to pack book spines into rows. A new
row is started once the accumulated spine width would exceed this.
-}
bookcaseInnerWidth : Int
bookcaseInnerWidth =
    990
