module Page.BookshelfReadOnlyTest exposing (suite)

{-| Program tests for read-only shelf browsing (Issue #215 / US-10.5.3).

A viewer browsing `/u/:handle/:bookshelf_name` sees the target reader's shelf
rendered read-only:

  - the fetch targets the profile endpoint (`/api/u/:handle/bookshelves/:name`),
    NOT the viewer's own `/api/bookshelves/:name`;
  - the received placements render as spines;
  - NO mutating affordance is exposed (no "Add shelf" button), so no mutating
    request can be issued through the UI — a SECURITY guarantee;
  - **and no organiser message can mutate even if it bypasses the UI entirely**;
  - a failed load (hidden shelf / ghost / bad name → 404) shows a neutral
    "not available" state, not the owner's "could not load your library" error.

⚠️ **Scope of the SECURITY guarantee, measured — and then moved (#330, #332).**
Until Issue #332 it held at the VIEW layer only: `Page.Bookshelf.handleOrganiser`
matched on `( ShelfOrganiser.AddShelf, Just token, _ )` with no `config.readOnly`
check, so a synthetic `OrganiserMsg` dispatched into a read-only model still
issued `POST /api/bookshelves/:apiName/shelves` — confirmed by probe by #330,
which found this file's negative assertion unfalsifiable and could not fix the
production side under its own scope lock. The blast radius was always bounded
(the request carries the _viewer's_ token, so the server scoped the write to the
viewer's own bookshelf of that name, not the owner's) — the defect was that the
guarantee lived in a convention rather than in the code that enforces it.

`handleOrganiser` now dispatches on `Bookshelf.mutationToken`, which is `Nothing`
under `readOnly`, so the mutating branches are not selectable at all.
`read_only_organiser_is_inert_SECURITY` below asserts that against the `Cmd` that
`Page.Bookshelf.update` actually returns — no effect translator in the path — and
`owner_organiser_drive_is_observable` runs the identical drive under the owner
config to prove those assertions can fail.

-}

import Components.ShelfOrganiser as ShelfOrganiser
import Dict
import Expect
import Html.Attributes
import Http
import Json.Encode as Encode
import Page.Bookshelf as Bookshelf
import ProgramTest
import Test exposing (Test, describe, test)
import Test.Html.Selector as Selector
import TestHelpers exposing (libraryProgram, profileShelfProgram, simulateBookshelfResponse, testBook, testPlacement)
import Types.RemoteData exposing (RemoteData(..))
import Types.Shelf exposing (Shelf)


{-| Read-only browse of `alice`'s `library` shelf as an authenticated viewer.
-}
browse : ProgramTest.ProgramTest Bookshelf.Model Bookshelf.Msg (ProgramTest.SimulatedEffect Bookshelf.Msg)
browse =
    ProgramTest.start () (profileShelfProgram (Just "viewer-token") "alice" "library")


browseAnon : ProgramTest.ProgramTest Bookshelf.Model Bookshelf.Msg (ProgramTest.SimulatedEffect Bookshelf.Msg)
browseAnon =
    ProgramTest.start () (profileShelfProgram Nothing "alice" "library")


profileEndpoint : String
profileEndpoint =
    "/api/u/alice/bookshelves/library"


{-| A shelf-list response as returned by `ProfileController.shelf`
(`%{bookshelf, count, shelves: [...]}`) — the extra fields are ignored by the
`shelves`-only decoder, matching production.
-}
simulateShelvesResponse : List { id : String, position : Int, placements : List Encode.Value } -> Http.Response String
simulateShelvesResponse shelves =
    let
        encodeShelf s =
            Encode.object
                [ ( "id", Encode.string s.id )
                , ( "position", Encode.int s.position )
                , ( "placements", Encode.list identity s.placements )
                ]

        json =
            Encode.encode 0
                (Encode.object
                    [ ( "bookshelf", Encode.string "library" )
                    , ( "count", Encode.int (List.length (List.concatMap .placements shelves)) )
                    , ( "shelves", Encode.list encodeShelf shelves )
                    ]
                )
    in
    Http.GoodStatus_
        { url = profileEndpoint
        , statusCode = 200
        , statusText = "OK"
        , headers = Dict.empty
        }
        json


simulateNotFound : Http.Response String
simulateNotFound =
    Http.BadStatus_
        { url = profileEndpoint
        , statusCode = 404
        , statusText = "Not Found"
        , headers = Dict.empty
        }
        "{\"error\":\"not_found\"}"


encodePlacement : String -> String -> Encode.Value
encodePlacement placementId title =
    Encode.object
        [ ( "id", Encode.string placementId )
        , ( "position", Encode.int 1 )
        , ( "placed_at", Encode.string "2025-01-15T10:30:00Z" )
        , ( "book"
          , Encode.object
                [ ( "id", Encode.string "book-001" )
                , ( "title", Encode.string title )
                , ( "author"
                  , Encode.object
                        [ ( "id", Encode.string "author-001" )
                        , ( "name", Encode.string "Ursula K. Le Guin" )
                        ]
                  )
                , ( "editions", Encode.list identity [] )
                , ( "edition_count", Encode.int 0 )
                , ( "subjects", Encode.list Encode.string [] )
                , ( "visibility_tier", Encode.string "public" )
                ]
          )
        ]


oneShelf : Http.Response String
oneShelf =
    simulateShelvesResponse
        [ { id = "shelf-1", position = 0, placements = [ encodePlacement "p-1" "The Dispossessed" ] } ]


suite : Test
suite =
    describe "Page.Bookshelf — read-only browse (Issue #215 / US-10.5.3)"
        [ fetchesProfileEndpoint
        , fetchesProfileEndpointAnon
        , rendersReceivedPlacements
        , noAddShelfControl
        , noShelfOrganiserPanel
        , ownerMutationIsObservable
        , noMutatingRequestOnLoad
        , ownerOrganiserDriveIsObservable
        , readOnlyOrganiserIsInert
        , readOnlySyntheticOrganiserMsg
        , lookOnlySpineClick
        , rendersOwnerAttribution
        , notFoundShowsNeutralState
        ]


{-| A spine click while browsing another reader's shelf must be look-only: it
must NOT escape into the viewer's own owner-mode BookDetail (`NavigateTo`) nor
issue any mutation. The `OutMsg` is swallowed by the ProgramTest harness, so
this asserts the update contract directly.
-}
lookOnlySpineClick : Test
lookOnlySpineClick =
    test "look_only_spine_click_SECURITY: a read-only spine click emits no navigation/mutation" <|
        \() ->
            let
                ( model, _ ) =
                    Bookshelf.init
                        (Bookshelf.profileConfig "alice" "library")
                        (Just "viewer-token")
                        "viewer-user-id"

                ( _, _, outMsg ) =
                    Bookshelf.update (Bookshelf.BookClicked testBook) model
            in
            Expect.equal outMsg Bookshelf.NoOut


{-| The read-only view orients the viewer with an attribution back-link to the
owner's profile hub (`testId "shelf-attribution"` → `/u/:handle`).
-}
rendersOwnerAttribution : Test
rendersOwnerAttribution =
    test "renders_owner_attribution: read-only view links back to the owner's profile hub" <|
        \() ->
            browse
                |> ProgramTest.expectViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "shelf-attribution")
                    , Selector.attribute (Html.Attributes.href "/u/alice")
                    ]


fetchesProfileEndpoint : Test
fetchesProfileEndpoint =
    test "read_only_init_fetches_profile_endpoint: GETs /api/u/:handle/bookshelves/:name, not the viewer's own shelf" <|
        \() ->
            browse
                |> ProgramTest.ensureHttpRequestWasMade "GET" profileEndpoint
                |> ProgramTest.expectHttpRequests "GET"
                    "/api/bookshelves/library"
                    (\requests -> Expect.equal (List.length requests) 0)


fetchesProfileEndpointAnon : Test
fetchesProfileEndpointAnon =
    test "read_only_anon_still_fetches: an unauthenticated viewer still issues the optional-auth GET" <|
        \() ->
            browseAnon
                |> ProgramTest.expectHttpRequestWasMade "GET" profileEndpoint


rendersReceivedPlacements : Test
rendersReceivedPlacements =
    test "renders_received_placements: spines render for the placements the endpoint returned" <|
        \() ->
            browse
                |> ProgramTest.simulateHttpResponse "GET" profileEndpoint oneShelf
                |> ProgramTest.expectViewHas
                    [ Selector.class "book-button" ]


noAddShelfControl : Test
noAddShelfControl =
    test "no_mutation_control_SECURITY: read-only view exposes no shelf organiser" <|
        \() ->
            browse
                |> ProgramTest.simulateHttpResponse "GET" profileEndpoint oneShelf
                |> ProgramTest.expectViewHasNot
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "shelf-add") ]


noShelfOrganiserPanel : Test
noShelfOrganiserPanel =
    test "no_mutation_control_SECURITY: the organiser panel itself is absent, not merely disabled" <|
        \() ->
            browse
                |> ProgramTest.simulateHttpResponse "GET" profileEndpoint oneShelf
                |> ProgramTest.expectViewHasNot
                    [ Selector.attribute
                        (Html.Attributes.attribute "data-testid" "shelf-organiser")
                    ]


{-| ⚠️ **POSITIVE CONTROL for `noMutatingRequestOnLoad` below.**

The negative assertion is only worth what this test proves: that the harness can
observe a shelf mutation at all. Until Issue #330 the shared effect translator
(`TestHelpers.libraryEffects`) was `case msg of _ -> Cmd.none`, so _no_
`Bookshelf.Msg` could produce a request in _any_ bookshelf harness — the
SECURITY assertion below counted POSTs in a world where the count was pinned at
zero by construction, and would have kept passing had the read-only view started
firing mutations on every render.

Same page module, same translator, owner config: clicking the organiser's real
"Add a shelf" button must issue exactly one POST. If this goes red the negative
assertion below has stopped meaning anything.

-}
ownerMutationIsObservable : Test
ownerMutationIsObservable =
    test "owner_mutation_is_observable: the SAME harness in owner mode DOES issue a shelf POST — so the assertion below can fail" <|
        \() ->
            ProgramTest.start () (libraryProgram (Just "owner-token"))
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/library"
                    (simulateBookshelfResponse [ testPlacement ])
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "shelf-add") ]
                |> ProgramTest.clickButton "Add a shelf"
                |> ProgramTest.expectHttpRequests "POST"
                    "/api/bookshelves/library/shelves"
                    (\requests -> Expect.equal (List.length requests) 1)


{-| The read-only browse must issue no mutation across the whole load cycle.

Paired with `ownerMutationIsObservable` above, which proves this harness reports
a shelf POST when one is made.

-}
noMutatingRequestOnLoad : Test
noMutatingRequestOnLoad =
    test "no_mutating_request_SECURITY: browsing another reader's shelf issues no POST/PUT/DELETE" <|
        \() ->
            browse
                |> ProgramTest.simulateHttpResponse "GET" profileEndpoint oneShelf
                |> ProgramTest.ensureHttpRequests "POST"
                    "/api/bookshelves/library/shelves"
                    (\requests -> Expect.equal (List.length requests) 0)
                |> ProgramTest.ensureHttpRequests "PUT"
                    "/api/bookshelves/library/shelves/reorder"
                    (\requests -> Expect.equal (List.length requests) 0)
                |> ProgramTest.expectHttpRequests "DELETE"
                    "/api/shelves/shelf-1"
                    (\requests -> Expect.equal (List.length requests) 0)


{-| Two empty shelves — enough for a reorder to have somewhere to go, and empty so
`RemoveShelf` is the action the organiser would really offer (it disables Remove on
a shelf that still holds books).
-}
twoShelves : List Shelf
twoShelves =
    [ { id = "shelf-1", position = 0, placements = [] }
    , { id = "shelf-2", position = 1, placements = [] }
    ]


{-| Every organiser message that is _supposed_ to mutate, paired with the drive that
reaches it. `DropOn` needs a `DragStart` first — without one it takes its own
`Nothing` branch and would look guarded when it is not.

Kept as data so the inert-under-read-only and observable-under-owner suites below
run the **identical** drives. A guard that covered four of five branches would
otherwise read as fully covered.

-}
mutatingOrganiserDrives : List ( String, List ShelfOrganiser.Msg )
mutatingOrganiserDrives =
    [ ( "AddShelf", [ ShelfOrganiser.AddShelf ] )
    , ( "RemoveShelf", [ ShelfOrganiser.RemoveShelf "shelf-1" ] )
    , ( "MoveUp", [ ShelfOrganiser.MoveUp "shelf-2" ] )
    , ( "MoveDown", [ ShelfOrganiser.MoveDown "shelf-1" ] )
    , ( "DragStart then DropOn"
      , [ ShelfOrganiser.DragStart "shelf-1", ShelfOrganiser.DropOn "shelf-2" ]
      )
    ]


{-| Load a bookshelf under `config`, then fold organiser messages through the real
`Page.Bookshelf.update`, returning the final model and the **last** command.

Deliberately no `ProgramTest`: the harness's effects come from
`TestHelpers.libraryEffects`, so a program test observes the translator's answer,
not the page's. This drives production `update` and looks at the `Cmd` it returns,
which is the only thing that decides whether a request leaves the browser.

-}
driveOrganiser : Bookshelf.Config -> List ShelfOrganiser.Msg -> ( Bookshelf.Model, Cmd Bookshelf.Msg )
driveOrganiser config drive =
    let
        ( initial, _ ) =
            Bookshelf.init config (Just "viewer-token") "viewer-user-id"

        ( loaded, _, _ ) =
            Bookshelf.update
                (Bookshelf.ShelvesLoaded (Bookshelf.requestKey config)
                    (Ok { shelves = twoShelves, visibility = "owner" })
                )
                initial

        step subMsg ( model, _ ) =
            let
                ( next, cmd, _ ) =
                    Bookshelf.update (Bookshelf.OrganiserMsg subMsg) model
            in
            ( next, cmd )
    in
    List.foldl step ( loaded, Cmd.none ) drive


{-| ⚠️ **POSITIVE CONTROL for `readOnlyOrganiserIsInert` below.**

Same page module, same drive, same token, same loaded shelves — only the config
differs. Each drive must produce a command and set `organiserBusy`, which is what
the read-only assertions claim does _not_ happen. If this goes red, that claim has
stopped distinguishing anything.

It also pins the other half of the issue's contract: the owner path is unchanged.

-}
ownerOrganiserDriveIsObservable : Test
ownerOrganiserDriveIsObservable =
    describe "owner_organiser_drive_is_observable: the same drives DO mutate under the owner config"
        (List.map
            (\( label, drive ) ->
                test label <|
                    \() ->
                        driveOrganiser Bookshelf.libraryConfig drive
                            |> Expect.all
                                [ Tuple.second >> Expect.notEqual Cmd.none
                                , Tuple.first >> .organiserBusy >> Expect.equal True
                                ]
            )
            mutatingOrganiserDrives
        )


{-| The guard, asserted where it is enforced (Issue #332).

Not "the button isn't rendered" — that is `noAddShelfControl` above, and it was the
_only_ thing standing here until #332. This dispatches the organiser messages
straight into `Page.Bookshelf.update` on a read-only model that is holding a valid
viewer token and fully loaded shelves — every precondition the mutating branches
used to need — and requires that nothing comes back out.

Three assertions per drive because each can fail independently: the command is the
request itself; `organiserBusy` is the page telling the reader a mutation is in
flight; the shelf list is the optimistic local reorder. A branch that skipped one
would still be caught by the others.

-}
readOnlyOrganiserIsInert : Test
readOnlyOrganiserIsInert =
    describe "read_only_organiser_is_inert_SECURITY: no organiser message mutates a read-only bookshelf"
        (List.map
            (\( label, drive ) ->
                test label <|
                    \() ->
                        driveOrganiser (Bookshelf.profileConfig "alice" "library") drive
                            |> Expect.all
                                [ Tuple.second >> Expect.equal Cmd.none
                                , Tuple.first >> .organiserBusy >> Expect.equal False
                                , Tuple.first >> .shelves >> Expect.equal (Success twoShelves)
                                ]
            )
            mutatingOrganiserDrives
        )


{-| The same guarantee through the whole program, since a page is more than its
update function: a synthetic `OrganiserMsg` delivered to a running read-only browse
must leave the request log untouched.

Paired with `ownerMutationIsObservable`, which proves this harness reports a shelf
POST when one is made.

-}
readOnlySyntheticOrganiserMsg : Test
readOnlySyntheticOrganiserMsg =
    test "read_only_synthetic_organiser_msg_SECURITY: an OrganiserMsg bypassing the view still issues no POST" <|
        \() ->
            browse
                |> ProgramTest.simulateHttpResponse "GET" profileEndpoint oneShelf
                |> ProgramTest.update (Bookshelf.OrganiserMsg ShelfOrganiser.AddShelf)
                |> ProgramTest.expectHttpRequests "POST"
                    "/api/bookshelves/library/shelves"
                    (\requests -> Expect.equal (List.length requests) 0)


notFoundShowsNeutralState : Test
notFoundShowsNeutralState =
    test "not_found_shows_neutral_state: a 404 renders a not-available state, not the owner error" <|
        \() ->
            browse
                |> ProgramTest.simulateHttpResponse "GET" profileEndpoint simulateNotFound
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "shelf-unavailable") ]
                |> ProgramTest.expectViewHasNot
                    [ Selector.text "Could not load your" ]
