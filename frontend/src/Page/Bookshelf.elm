module Page.Bookshelf exposing
    ( Config
    , Model
    , Msg(..)
    , OutMsg(..)
    , Removal
    , UndoToast(..)
    , antiLibraryConfig
    , init
    , libraryConfig
    , mutationToken
    , profileConfig
    , requestKey
    , undoToastMillis
    , update
    , view
    , wishListConfig
    , withPendingUndo
    )

import Api
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
import Page.Bookshelf.Helpers
    exposing
        ( groupIntoRows
        , minShelfRows
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


{-| Configuration that differs between bookshelf pages.
Everything else (model, update, view structure) is identical.

`readOnly` toggles the browse mode used when viewing _another_ reader's shelf at
`/u/:handle/:bookshelf_name`: the fetch targets the profile endpoint (via
`profileHandle`) and all mutating affordances (add shelf, RSS feed, the
per-placement visibility / move / remove controls) are stripped. See US-10.5.3.

⚠️ **Read-only is enforced in `update`, not only in `view`.** Not rendering a
control is a convention; `mutationToken` below is the structure. Every mutating
organiser branch takes its credential from there, so a message that reaches this
page by any other route — a stale click, a `Html.map` from a future caller, a
test — still cannot produce a mutating effect. See `handleOrganiser`.

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

    -- Undo-remove (US-1.6.4 extension, #375). Seeded by `withPendingUndo` when the
    -- reader arrives here straight off a removal; see `UndoToast` below.
    , undoToast : UndoToast
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
    | UndoRemove
    | UndoCompleted (Result Http.Error ())
    | ToastExpired


init : Config -> Maybe String -> String -> ( Model, Cmd Msg )
init config maybeToken userId =
    let
        -- ⛔ The state and the command are decided TOGETHER, and that is the
        -- point. `shelves` used to be an unconditional `Loading` while the
        -- command below could be `Cmd.none` — a page claiming a request was in
        -- flight when none had been made. Nothing would ever resolve it, so the
        -- loading view (below) would have become a skeleton that shimmers
        -- forever. `Loading` is a promise; only issue it with the request that
        -- keeps it.
        ( apiCmd, initialShelves ) =
            case ( config.readOnly, config.profileHandle ) of
                ( True, Just handle ) ->
                    -- Browsing another reader's shelf: optional-auth GET so the
                    -- backend visibility-filters against the viewer (even anon).
                    -- The read-only path never renders RSS, so the profile
                    -- payload carries no visibility; default it to "owner" to
                    -- reuse the shared ShelvesLoaded response shape.
                    ( Api.getProfileShelf maybeToken
                        handle
                        config.apiName
                        (ShelvesLoaded (requestKey config) << Result.map (\shelves -> { shelves = shelves, visibility = "owner" }))
                    , Loading
                    )

                _ ->
                    case maybeToken of
                        Just token ->
                            ( Api.getBookshelf config.apiName token (ShelvesLoaded (requestKey config))
                            , Loading
                            )

                        Nothing ->
                            ( Cmd.none, NotAsked )
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

      -- No toast by default: a plain visit to a bookshelf has nothing to undo.
      -- `withPendingUndo` is the only way in.
      , undoToast = ToastHidden
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


{-| Offer an undo on a page that has just been built for a reader arriving
straight off a removal (US-1.6.4 extension, #375).

Applied by `Main` **after** `init`, deliberately, rather than becoming a seventh
argument to it: `init` already takes three, ten call sites pass them, and the
undo is not part of building a bookshelf — it is one extra thing that is
sometimes true about the moment of arrival. Composing over `( Model, Cmd Msg )`
means the auto-dismiss timer is issued with the state it dismisses, the same
discipline `init` states for `Loading`.

⚠️ **No `readOnly` check here, and that is not an oversight.** The guard for
this feature is `mutationToken`, in `update`, and putting a second one here
would make `read_only_undo_is_inert_SECURITY` unfalsifiable — it would be
asserting that a toast which was never seeded cannot mutate. See #332's lesson
in `mutationToken` below: one enforcement point, reachable by the test.

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

        UndoRemove ->
            -- ⚠️ Dispatches on `mutationToken`, not `model.token` — an undo is a
            -- write, so it goes through the read-only guard rather than round it
            -- (Issue #332). The tuple match is the structure: with `Nothing` for
            -- the token there is no branch to take and this falls through to the
            -- silent catch-all, exactly as `handleOrganiser` does.
            --
            -- Matching `ToastOffered` and no other state is what makes a second
            -- click during a slow undo (or after a failure) inert, without a
            -- separate `busy` flag to keep in step.
            case ( model.undoToast, mutationToken model ) of
                ( ToastOffered removal, Just token ) ->
                    ( { model | undoToast = ToastRestoring removal }
                    , Api.restoreBook removal.placementId token UndoCompleted
                    , NoOut
                    )

                _ ->
                    ( model, Cmd.none, NoOut )

        UndoCompleted (Ok ()) ->
            -- Refetch rather than re-inserting the spine locally, for
            -- `reloadShelves`' reason: the server decides which shelf row the
            -- restored placement sits on and in what position, and a client that
            -- guessed would paint a bookcase the server disagrees with.
            ( { model | undoToast = ToastHidden }
            , reloadShelves model
            , NoOut
            )

        UndoCompleted (Err err) ->
            if Api.isUnauthorized err then
                ( model, Cmd.none, SessionExpired )

            else
                -- The failure REPLACES the offer and does not auto-dismiss: a
                -- toast that says "couldn't undo that" and then vanishes before
                -- it is read leaves the reader believing the undo worked.
                ( { model | undoToast = ToastFailed (undoError model.config err) }
                , Cmd.none
                , NoOut
                )

        ToastExpired ->
            case model.undoToast of
                ToastOffered _ ->
                    ( { model | undoToast = ToastHidden }, Cmd.none, NoOut )

                _ ->
                    -- `Process.sleep` cannot be cancelled, so this message arrives
                    -- whatever happened in the meantime. Restoring, already
                    -- hidden, or showing a failure: none of those are the offer
                    -- this timer was started for, so it has nothing to retract.
                    ( model, Cmd.none, NoOut )


{-| The credential a **mutating** organiser branch requires.

`Nothing` whenever the page is read-only, whatever token the viewer happens to be
carrying — so in read-only mode every `Just token` branch below is simply not
selectable and the dispatch falls through to the silent catch-all.

⚠️ **This is the enforcement point for read-only, and it is deliberately one place.**
It used to be `model.token`, and the only thing stopping a viewer's browse of
someone else's shelf from issuing `POST /api/bookshelves/:name/shelves` was that
`viewOrganiser` does not render the button (Issue #332, found by #330). That is a
guarantee living in the view: strip the view, dispatch a synthetic `OrganiserMsg`,
and the update function mutated happily. The blast radius was bounded — the request
carries the _viewer's_ token, so the server scoped the write to the viewer's own
bookshelf of that name rather than the owner's — but "the button isn't drawn" is a
convention, not a structure.

Reading the credential through one function rather than checking `config.readOnly`
in five branches means a **new** mutating branch inherits the guard by construction:
to issue a request it needs a token, and this is the only place a token comes from.
A branch that reached past this into `model.token` would be reintroducing the bug.

`view` keeps its own check (`viewOrganiser`, and the RSS/attribution branches):
hiding an affordance a viewer cannot use is a separate, legitimate job — it just is
no longer the thing standing between a read-only page and a write.

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
            -- Read-only, no token, or shelves not loaded: nothing this page may organise.
            -- Silent because the controls are not rendered in any of those states, so
            -- reaching here is a stale click — or, in read-only, a message that had no
            -- business arriving at all.
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


{-| A load failure in the reader's terms (Issue #362).

The two cases split out from the generic "Please try again" are the two the
reader can do something about, and both only became REACHABLE with this issue's
timeout: before it, a stalled connection sat in `Loading` forever and never
arrived here at all.

  - `Timeout` — the request was given up on after `Api.standardTimeout`. Saying
    "could not load" would be a shrug; naming the wait is what tells the reader
    the shelf is not empty, the answer just never came.
  - `NetworkError` — there is no connection. "Try again" alone would send them
    round the same loop; the fix is upstream of the app.

Everything else stays generic on purpose. A reader cannot act on a 500, and
inventing detail for it would be noise dressed as helpfulness.

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
            "The library is unreachable. Check your connection, then try again."

        _ ->
            "Could not load your " ++ shelf ++ ". Please try again."


{-| A failed undo in the reader's terms (#375).

Split from `mutationError` because every case here says something different.
The 409 in particular is not an error at all from where the reader is standing —
they re-added the book themselves, so the shelf already looks the way pressing
Undo would have made it look, and the message says so instead of apologising.

-}
undoError : Config -> Http.Error -> String
undoError config err =
    case err of
        Http.BadStatus 409 ->
            -- `Shelving.restore_placement/2` refuses rather than reconciling two
            -- rows; the reason it can refuse safely is exactly what this says.
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
                ++ [ viewUndoToast model
                   , div [ class "shelf-room__header" ]
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
                                    -- No request was issued (no credential), so
                                    -- there is nothing to wait for and nothing
                                    -- to report: the bare bookcase frame.
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


{-| The "Removed — Undo" toast (US-1.6.4 extension, #375).

⚠️ **Hidden under `readOnly`, and that is the _second_ line of defence, not the
first.** The same split as `viewOrganiser`: a control a viewer cannot use should
not be drawn, but if this branch were deleted tomorrow the page would look wrong
rather than act wrong — `mutationToken` in `UndoRemove` is what makes it inert,
and `read_only_undo_is_inert_SECURITY` asserts that with the view out of the
picture entirely.

`role="status"` + `aria-live="polite"` because this appears without the reader
asking and then leaves on a timer: a screen-reader user has to be told the offer
exists while it still exists. Polite rather than assertive — it must not cut
across whatever the shelf's own `aria-live` region is saying about the load that
is running at the same moment.

The failure state keeps the toast on screen with no Undo button: there is
nothing left to press (the state machine has moved past `ToastOffered`), and a
button that no longer does anything is worse than none.

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


{-| The shelves are on their way (Issue #362).

⛔ **`Loading` used to share `NotAsked`'s branch — an empty bookcase — which is
also what `Success []` looks like.** Three different facts, one picture. Driven
live on 2026-07-30, offline shelf navigation rendered a serene empty bookcase:
the page told the reader their library was empty when the truth was that the
request never completed.

Every difference below is deliberate, because the two states have to be
distinguishable by whatever a person or a test is actually looking at:

  - **by structure** — `data-testid="bookshelf-loading"` against the empty
    state's `bookshelf-empty`, so a test cannot pass in the wrong one;
  - **by markup** — `role="status"` + `aria-busy="true"`, so a screen reader is
    told a fetch is running rather than reading an empty shelf;
  - **by words** — the shelf is named ("Fetching your Library…") where the empty
    state offers an invitation to fill it;
  - **by picture** — spine-shaped placeholders where the empty state has a
    centred message on a bare plank.

Any one of those alone would be a detail. Together they are the reason a reader
who glances at the page for half a second draws the right conclusion.

-}
viewLoadingBookshelf : Model -> Html Msg
viewLoadingBookshelf model =
    let
        -- Whose shelf is being fetched. "your Library" is wrong on someone
        -- else's shelf, and read-only browse reaches this same view.
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

⚠️ **This check hides the affordance; it no longer _is_ the guard.** `mutationToken`
is (Issue #332). Both are wanted — a control that cannot work should not be drawn —
but if this one were deleted tomorrow the page would look wrong, not act wrong.

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
