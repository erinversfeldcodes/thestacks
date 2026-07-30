module Page.BookshelfReadOnlyTest exposing (suite)

{-| Program tests for read-only shelf browsing (Issue #215 / US-10.5.3).

A viewer browsing `/u/:handle/:bookshelf_name` sees the target reader's shelf
rendered read-only:

  - the fetch targets the profile endpoint (`/api/u/:handle/bookshelves/:name`),
    NOT the viewer's own `/api/bookshelves/:name`;
  - the received placements render as spines;
  - NO mutating affordance is exposed (no "Add shelf" button), so no mutating
    request can be issued through the UI — a SECURITY guarantee;
  - a failed load (hidden shelf / ghost / bad name → 404) shows a neutral
    "not available" state, not the owner's "could not load your library" error.

⚠️ **Scope of the SECURITY guarantee, measured (Issue #330).** It holds at the
VIEW layer only. `Page.Bookshelf.handleOrganiser` matches on
`( ShelfOrganiser.AddShelf, Just token, _ )` with **no `config.readOnly` check**,
so a synthetic `OrganiserMsg` dispatched into a read-only model still issues
`POST /api/bookshelves/:apiName/shelves` — confirmed by probe. This is not a
cross-reader leak (the request carries the _viewer's_ token, so the server
scopes it to the viewer's own bookshelf, not the owner's), but the page is not
defence-in-depth the way this module's docs previously claimed: strip the view
and the update function will happily mutate. Making `handleOrganiser` refuse
under `readOnly` is a production change and therefore out of scope here; filed
as a follow-up.

-}

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
            -- ⚠️ **This assertion was vacuous and had to be repointed.** It searched for a
            -- button whose text was `"Add shelf"`; the button says **"Add a shelf"**. So it
            -- passed by matching nothing anywhere on the page, not by the affordance being
            -- absent — it would have kept passing had the organiser leaked into the
            -- read-only view, which is the one thing it exists to prevent.
            --
            -- Now anchored on the testIds, which are stable against copy edits. The
            -- organiser's controls all 403 for a non-owner, so rendering any of them would
            -- be both a lie and a security smell.
            browse
                |> ProgramTest.simulateHttpResponse "GET" profileEndpoint oneShelf
                |> ProgramTest.expectViewHasNot
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "shelf-add") ]


noShelfOrganiserPanel : Test
noShelfOrganiserPanel =
    test "no_mutation_control_SECURITY: the organiser panel itself is absent, not merely disabled" <|
        \() ->
            -- Disabled controls would still advertise an action the viewer cannot take.
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
                -- Pre-condition: the affordance the read-only view must not
                -- expose really is on screen here.
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
