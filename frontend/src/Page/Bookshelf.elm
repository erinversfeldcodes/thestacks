module Page.Bookshelf exposing
    ( Config
    , Model
    , Msg(..)
    , OutMsg(..)
    , Removal
    , ShelvesSource(..)
    , UndoToast(..)
    , antiLibraryConfig
    , init
    , libraryConfig
    , mutationToken
    , profileConfig
    , requestKey
    , shelvesSource
    , undoToastMillis
    , update
    , view
    , wishListConfig
    , withPendingUndo
    )

import Api
import Browser.Dom
import Components.AgeGate exposing (ageGate)
import Components.BookList as BookList
import Components.RSSLink as RSSLink
import Components.ShelfOrganiser as ShelfOrganiser
import Components.Spine exposing (WearLevel(..))
import Components.ViewModeToggle as ViewModeToggle exposing (ShelfViewMode(..))
import Html exposing (Html, a, button, div, h2, p, text)
import Html.Attributes exposing (attribute, class, disabled, href)
import Html.Events exposing (onClick)
import Http
import Navigation.Route exposing (Route(..))
import Page.Bookshelf.GridNav as GridNav
import Page.Bookshelf.Helpers
    exposing
        ( groupIntoRows
        , minShelfRows
        , placementSpineWidth
        , viewBookcase
        , viewEmptyShelfMessage
        , viewLoadingShelfRows
        , viewShelfLabel
        , viewShelfRowClickable
        )
import Process
import Task
import Types.Book exposing (Book)
import Types.RemoteData exposing (RemoteData(..))
import Types.Shelf exposing (BookshelfResponse, Shelf)
import Util.TestId exposing (testId)


{-| Configuration that differs between bookshelf pages; everything else is
identical. `readOnly` is the browse mode for another reader's shelf
(`/u/:handle/:bookshelf_name`): profile-endpoint fetch, all mutating
affordances stripped.

⚠️ Read-only is enforced at `mutationToken` (the credential source),
not just in the view — hiding a control is presentation, not security.

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
    , organiser : ShelfOrganiser.State
    , organiserBusy : Bool
    , organiserError : Maybe String
    , undoToast : UndoToast
    , focusedSpine : Maybe String
    }


{-| The removal an Undo would reverse.

`placementId` is the id of the row `DELETE /api/placements/:id` soft-deleted —
not the book's id — because the undo restores **that row**, keeping its
`placed_at`, formats, rating and notes. Passing a book id here would force the
server to guess which of a book's placements was meant.

-}
type alias Removal =
    { placementId : String
    , bookTitle : String
    }


{-| The four states the undo affordance can be in, as one type rather than a
`Maybe Removal` plus a `Bool` plus a `Maybe String` — that trio can spell
"restoring a removal that isn't there" and "offered and failed at once", and
neither is a state this page has any answer for.

`ToastOffered` is the only one `UndoRemove` acts on. That matters for the timer:
`Process.sleep` cannot be cancelled, so the expiry message always arrives, and
the only thing stopping it from wiping a request already in flight (or the
failure the reader still needs to read) is that `ToastExpired` matches
`ToastOffered` and nothing else.

-}
type UndoToast
    = ToastHidden
    | ToastOffered Removal
    | ToastRestoring Removal
    | ToastFailed String


type OutMsg
    = NoOut
    | NavigateTo Route
    | SessionExpired


{-| Identifies which bookshelf a `ShelvesLoaded` response was requested for.

Library, Antilibrary and Wish List all render through this one module and all
sit behind Main.elm's single `PageBookshelf` constructor, so Main's
constructor-match cannot tell them apart: a response for the shelf the user has
just left is still delivered to the shelf they landed on. Tagging the message
with the requesting config lets `update` drop it.

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


{-| Which read answers "what is on this bookshelf", as data rather than as a
`Cmd` nobody can look at.

The distinction is not cosmetic: `/library` and `/u/ada/library` are different
shelves belonging to different people, and both arrive here under the same
`apiName`. Naming the source in one place is what stops a second dispatch from
being written slightly differently from the first — which is how a refetch ends
up painting the VIEWER's own books onto the page of the profile they are
browsing, tagged with the profile's `requestKey` so nothing downstream can tell.

-}
type ShelvesSource
    = OwnShelf String String
    | ProfileShelf (Maybe String) String String
    | NoShelvesRequest


shelvesSource : Config -> Maybe String -> ShelvesSource
shelvesSource config maybeToken =
    case ( config.readOnly, config.profileHandle ) of
        ( True, Just handle ) ->
            ProfileShelf maybeToken handle config.apiName

        _ ->
            case maybeToken of
                Just token ->
                    OwnShelf token config.apiName

                Nothing ->
                    NoShelvesRequest


{-| The one shelf read in this module. `init` and every refetch go through it,
so there is no second place for the read-only dispatch above to be got wrong.
-}
fetchShelves : Config -> Maybe String -> Cmd Msg
fetchShelves config maybeToken =
    case shelvesSource config maybeToken of
        ProfileShelf token handle bookshelfName ->
            Api.getProfileShelf token
                handle
                bookshelfName
                (ShelvesLoaded (requestKey config) << Result.map (\shelves -> { shelves = shelves, visibility = "owner" }))

        OwnShelf token bookshelfName ->
            Api.getBookshelf bookshelfName token (ShelvesLoaded (requestKey config))

        NoShelvesRequest ->
            Cmd.none


type Msg
    = ShelvesLoaded String (Result Http.Error BookshelfResponse)
    | DismissAgeGate
    | BookClicked Book
    | RSSLinkMsg RSSLink.Msg
    | ViewModeChanged ShelfViewMode
    | SortColumnClicked BookList.SortColumn
    | OrganiserMsg ShelfOrganiser.Msg
    | ShelfMutated (Result Http.Error ())
    | ReloadRequested
    | UndoRemove
    | UndoCompleted (Result Http.Error ())
    | ToastExpired
    | SpineNavKey String GridNav.Key
    | SpineFocusAttempted


init : Config -> Maybe String -> String -> ( Model, Cmd Msg )
init config maybeToken userId =
    let
        apiCmd =
            fetchShelves config maybeToken

        initialShelves =
            case shelvesSource config maybeToken of
                NoShelvesRequest ->
                    NotAsked

                _ ->
                    Loading
    in
    ( { shelves = initialShelves
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
      , undoToast = ToastHidden
      , focusedSpine = Nothing
      }
    , apiCmd
    )


{-| How long the "Removed — Undo" toast stays offered, in milliseconds.

Exposed so a test can state the number it is asserting about rather than
re-typing it, and so the number lives next to the thing it governs.

-}
undoToastMillis : Float
undoToastMillis =
    8000


{-| Offer an undo on a page just built for a reader arriving straight off
a removal. Applied by `Main` AFTER `init`, deliberately — the undo
is not part of building a bookshelf, and a fourth argument would make
ten call sites pass `Nothing` forever. Composing over `( Model, Cmd)`
keeps the arrival-only concern at the one site where it can be true.
-}
withPendingUndo : Maybe Removal -> ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
withPendingUndo maybeRemoval ( model, cmd ) =
    case maybeRemoval of
        Just removal ->
            ( { model | undoToast = ToastOffered removal }
            , Cmd.batch [ cmd, expireToastAfterDelay ]
            )

        Nothing ->
            ( model, cmd )


expireToastAfterDelay : Cmd Msg
expireToastAfterDelay =
    Process.sleep undoToastMillis |> Task.perform (\_ -> ToastExpired)


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        ShelvesLoaded key result ->
            if key /= requestKey model.config then
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
            ( { model | organiserBusy = False, organiserError = Nothing }
            , reloadShelves model
            , NoOut
            )

        ShelfMutated (Err err) ->
            if Api.isUnauthorized err then
                ( model, Cmd.none, SessionExpired )

            else
                ( { model | organiserBusy = False, organiserError = Just (mutationError err) }
                , reloadShelves model
                , NoOut
                )

        ReloadRequested ->
            ( model, reloadShelves model, NoOut )

        UndoRemove ->
            case ( model.undoToast, mutationToken model ) of
                ( ToastOffered removal, Just token ) ->
                    ( { model | undoToast = ToastRestoring removal }
                    , Api.restoreBook removal.placementId token UndoCompleted
                    , NoOut
                    )

                _ ->
                    ( model, Cmd.none, NoOut )

        UndoCompleted (Ok ()) ->
            ( { model | undoToast = ToastHidden }
            , reloadShelves model
            , NoOut
            )

        UndoCompleted (Err err) ->
            if Api.isUnauthorized err then
                ( model, Cmd.none, SessionExpired )

            else
                ( { model | undoToast = ToastFailed (undoError model.config err) }
                , Cmd.none
                , NoOut
                )

        ToastExpired ->
            case model.undoToast of
                ToastOffered _ ->
                    ( { model | undoToast = ToastHidden }, Cmd.none, NoOut )

                _ ->
                    ( model, Cmd.none, NoOut )

        SpineNavKey originId key ->
            case model.shelves of
                Success shelves ->
                    case GridNav.nextFocus key originId (navRows shelves) of
                        Just nextId ->
                            ( { model | focusedSpine = Just nextId }
                            , Task.attempt (\_ -> SpineFocusAttempted)
                                (Browser.Dom.focus ("spine-" ++ nextId))
                            , NoOut
                            )

                        Nothing ->
                            ( model, Cmd.none, NoOut )

                _ ->
                    ( model, Cmd.none, NoOut )

        SpineFocusAttempted ->
            ( model, Cmd.none, NoOut )


{-| The packed rows as `GridNav` reasons about them: the SAME grouping the
SpineView renders, each spine as ( book id, the width the packer gave it).
-}
navRows : List Shelf -> List (List ( String, Int ))
navRows shelves =
    List.concatMap .placements shelves
        |> groupIntoRows bookcaseInnerWidth
        |> List.map
            (List.map
                (\placement ->
                    ( placement.book |> Maybe.map .id |> Maybe.withDefault ""
                    , placementSpineWidth placement
                    )
                )
            )


{-| The credential a MUTATING organiser branch requires. `Nothing` whenever
the page is read-only — whatever token the viewer carries — so every
`Just token` branch is unselectable and dispatch falls to the silent
catch-all.

⚠️ THE enforcement point for read-only, deliberately one place: it used
to be `model.token`, and only view-level hiding stood between a viewer
and mutating someone else's shelf. `read_only_undo_is_inert_SECURITY`
pins it.

-}
mutationToken : Model -> Maybe String
mutationToken model =
    if model.config.readOnly then
        Nothing

    else
        model.token


{-| Shelf organisation, split out so `update` stays flat.

Reorders are **optimistic** — the row moves immediately and the full order is sent — because
a reorder with a round trip of latency before anything moves feels broken. Create and delete
are not optimistic: both change positions the server assigns, so guessing would show a
number that is about to change.

Dispatches on `mutationToken` rather than `model.token`: see above for why the
difference matters. The drag-state branches match `_` because tracking which row is
mid-drag is local bookkeeping, not a mutation — a read-only page may hold a drag it
can never complete, because `DropOn` needs the credential it does not have.

-}
handleOrganiser : ShelfOrganiser.Msg -> Model -> ( Model, Cmd Msg, OutMsg )
handleOrganiser subMsg model =
    case ( subMsg, mutationToken model, model.shelves ) of
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
            ( model, Cmd.none, NoOut )

        ( ShelfOrganiser.DropOn targetId, Just token, Success shelves ) ->
            case model.organiser.dragging of
                Just draggedId ->
                    persistOrder
                        (moveToId draggedId targetId shelves)
                        token
                        { model | organiser = { dragging = Nothing } }

                Nothing ->
                    ( model, Cmd.none, NoOut )

        _ ->
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


{-| Refetch after a mutation — through `fetchShelves`, the SAME call as the
initial load, which is the point: the old `Api.getShelves` payload carried a
hardcoded empty `placements` per shelf, so every shelf mutation repainted the
bookcase placement-less (nineteen books vanished; the organiser called a full
shelf "empty"). One endpoint, one shape, no lying refetch.

Sharing `fetchShelves` rather than re-issuing `Api.getBookshelf` also carries
the read-only dispatch across: this used to re-read the viewer's OWN bookshelf
while browsing someone else's profile shelf.

-}
reloadShelves : Model -> Cmd Msg
reloadShelves model =
    fetchShelves model.config model.token


{-| A load failure in the reader's terms. The two cases split from
the generic copy are the two the reader can act on — `Timeout` (names
the wait) and `Offline` (names the cause) — and both only became
REACHABLE with this issue's timeout: a stalled connection used to sit in
`Loading` forever.
-}
loadError : Config -> Http.Error -> String
loadError config err =
    let
        shelf =
            String.toLower config.label
    in
    case err of
        Http.Timeout ->
            "Your " ++ shelf ++ " is taking too long to arrive. The library may be busy — please try again."

        Http.NetworkError ->
            "The library is unreachable. Your "
                ++ shelf
                ++ " will reload by itself as soon as the connection returns."

        _ ->
            "Could not load your " ++ shelf ++ ". Please try again."


{-| A failed undo in the reader's terms.

Split from `mutationError` because every case here says something different.
The 409 in particular is not an error at all from where the reader is standing —
they re-added the book themselves, so the shelf already looks the way pressing
Undo would have made it look, and the message says so instead of apologising.

-}
undoError : Config -> Http.Error -> String
undoError config err =
    case err of
        Http.BadStatus 409 ->
            "That book is already back on your " ++ config.label ++ "."

        Http.BadStatus 404 ->
            "That book is no longer in your collection, so there is nothing to put back."

        Http.BadStatus 403 ->
            "That removal is not yours to undo."

        Http.Timeout ->
            "Putting that book back is taking too long. The library may be busy — please try again."

        Http.NetworkError ->
            "The library is unreachable, so that book stayed removed. Check your connection."

        _ ->
            "Could not put that book back. Please try again."


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
                ++ [ viewUndoToast model
                   , div [ class "shelf-room__header" ]
                        (viewShelfLabel cfg.label
                            :: ViewModeToggle.view model.viewMode ViewModeChanged
                            :: (if cfg.readOnly then
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
                                    viewLoadingBookshelf model

                                Failure err ->
                                    if cfg.readOnly then
                                        p [ class "shelf-unavailable", testId "shelf-unavailable" ]
                                            [ text "Reader not found, or this shelf isn't available." ]

                                    else
                                        p [ class "error", testId "shelf-error" ]
                                            [ text (loadError cfg err) ]

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


{-| The "Removed — Undo" toast. Hidden under `readOnly` as the
SECOND line of defence: deleting this branch would make the page look
wrong, not act wrong — `mutationToken` in `UndoRemove` is what makes a
viewer's undo inert, and `read_only_undo_is_inert_SECURITY` asserts
that with the view out of the picture.
-}
viewUndoToast : Model -> Html Msg
viewUndoToast model =
    if model.config.readOnly then
        text ""

    else
        case model.undoToast of
            ToastHidden ->
                text ""

            ToastOffered removal ->
                div [ class "undo-toast", testId "undo-toast", attribute "role" "status", attribute "aria-live" "polite" ]
                    [ p [ class "undo-toast__message" ]
                        [ text ("Removed “" ++ removal.bookTitle ++ "”.") ]
                    , button
                        [ class "undo-toast__action"
                        , testId "undo-remove"
                        , onClick UndoRemove
                        ]
                        [ text "Undo" ]
                    ]

            ToastRestoring removal ->
                div [ class "undo-toast", testId "undo-toast", attribute "role" "status", attribute "aria-live" "polite" ]
                    [ p [ class "undo-toast__message" ]
                        [ text ("Putting “" ++ removal.bookTitle ++ "” back…") ]
                    , button
                        [ class "undo-toast__action"
                        , testId "undo-remove"
                        , disabled True
                        ]
                        [ text "Undo" ]
                    ]

            ToastFailed message ->
                div
                    [ class "undo-toast undo-toast--failed"
                    , testId "undo-toast-error"
                    , attribute "role" "status"
                    , attribute "aria-live" "polite"
                    ]
                    [ p [ class "undo-toast__message" ] [ text message ] ]


viewEmptyBookshelf : Model -> Html Msg
viewEmptyBookshelf model =
    div [ class "bookshelf", testId "bookshelf-empty" ]
        [ viewBookcase
            (minShelfRows 4 [ viewEmptyShelfMessage model.config.emptyMessage ])
        ]


{-| The shelves are on their way.

⛔ `Loading` used to share `NotAsked`'s empty-bookcase render — which is
also what `Success []` looks like: three facts, one picture. Offline
shelf navigation told the reader their library was empty when the
request simply never completed. Loading now has its own visibly-waiting
render, distinct from a genuinely empty shelf.

-}
viewLoadingBookshelf : Model -> Html Msg
viewLoadingBookshelf model =
    let
        whose =
            case model.config.profileHandle of
                Just handle ->
                    "@" ++ handle ++ "’s "

                Nothing ->
                    "your "
    in
    div
        [ class "bookshelf bookshelf--loading"
        , testId "bookshelf-loading"
        , attribute "role" "status"
        , attribute "aria-busy" "true"
        ]
        [ p [ class "bookshelf__loading-text" ]
            [ text ("Fetching " ++ whose ++ model.config.label ++ "…") ]
        , viewBookcase viewLoadingShelfRows
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
                packedRows =
                    List.concatMap .placements shelves
                        |> groupIntoRows bookcaseInnerWidth

                tabStopId =
                    let
                        gridIds =
                            List.concatMap (List.filterMap (.book >> Maybe.map .id)) packedRows
                    in
                    case model.focusedSpine of
                        Just focusedId ->
                            if List.member focusedId gridIds then
                                Just focusedId

                            else
                                List.head gridIds

                        Nothing ->
                            List.head gridIds

                shelfRows =
                    packedRows
                        |> List.map
                            (viewShelfRowClickable
                                { wearLevel = model.config.wearLevel
                                , onBookClicked = BookClicked
                                , onNavKey = SpineNavKey
                                , tabStopId = tabStopId
                                }
                            )
            in
            div [ class "bookshelf" ]
                [ viewBookcase (minShelfRows 4 shelfRows)
                , viewOrganiser model shelves
                ]


{-| The shelf organiser, owner only. A separate panel,
deliberately NOT a change to the spine layout: the bookcase auto-flows
placements and does not surface physical `op.shelves` boundaries (the
151 presentation choice) — per-shelf spine rendering would quietly
reverse that. This manages the physical shelves alongside.
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
