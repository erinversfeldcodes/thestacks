module Page.BookDetailProgressTest exposing (suite)

{-| Program tests for the reading-progress UI mounted on the BookDetail overlay
(US-1.6.6, Issue #116 Phase 2).

The progress card is mounted whenever the placement sits on a readable bookshelf
(reading\_pile, library). Opening it and saving drives
PUT /api/placements/:id/progress and folds the returned progress in place. The
"record this read?" bridge is a Reading Pile affordance only — a Finished
transition surfaces it on a reading\_pile placement but NOT on a library one (no
library→library move offer). A failed save keeps the form open with the draft.


## Where progress can and cannot come from

`GET /api/books/:id` cannot carry reading progress. Its placement object is
`StacksWeb.ProtoJSON.book_placement/1`
(`apps/core/lib/stacks_web/proto_json.ex:311-322`), whose allow-list is
`id`, `book_id`, `personal_rating`, `notes`, `bookshelf_name`, `formats`,
`visibility`, `bookshelf_visibility` — no `reading_status`, no `current_page`,
no `started_at`, no `finished_at`.

So on page load the card ALWAYS opens at its `Maybe.withDefault ToRead` default
with no page count, and progress can only reach the view one way: the user
saves, and `PUT /api/placements/:id/progress` answers with
`ProtoJSON.reading_progress/1` (`proto_json.ex:688-696`), which does carry the
quartet. Every test below therefore starts from "To Read, no pages" and drives
progress in through the form — the only path a real reader has.

Until Issue #328 the fixture injected the quartet into the book-detail
response, so two of these tests asserted a rendering the server can never
produce (a live "p. 40 / 371" badge on load, and a page field pre-seeded to
"40"). Whether the contract SHOULD carry progress here is Issue #314's
question; faking it in a fixture is not an answer to it.

-}

import Dict
import Html.Attributes
import Http
import Page.BookDetail as BookDetail
import ProgramTest exposing (ProgramTest, SimulatedEffect)
import Test exposing (Test, describe, test)
import Test.Html.Event as Event
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import TestHelpers
    exposing
        ( bookDetailProgram
        , simulateBookDetailResponseWithPlacement
        , testBook
        , testPlacement
        )
import Types.Placement exposing (Placement)


progressEndpoint : String
progressEndpoint =
    "/api/placements/placement-test-001/progress"


{-| A library placement as `book_placement/1` can actually deliver it: on a
readable bookshelf, and with no reading progress attached (see the module doc).
-}
libraryPlacement : Placement
libraryPlacement =
    { testPlacement | bookshelfName = Just "library" }


{-| The same, but on the Reading Pile — the context that offers the bridge.
-}
pilePlacement : Placement
pilePlacement =
    { libraryPlacement | bookshelfName = Just "reading_pile" }


startDetailWith : Placement -> ProgramTest BookDetail.Model BookDetail.Msg (SimulatedEffect BookDetail.Msg)
startDetailWith placement =
    ProgramTest.start () (bookDetailProgram "book-test-001" (Just "test-token"))
        |> ProgramTest.simulateHttpResponse "GET"
            "/api/books/book-test-001"
            (simulateBookDetailResponseWithPlacement "book-test-001" testBook placement)


completedBody : String
completedBody =
    "{\"placement\":{\"id\":\"placement-test-001\",\"reading_status\":\"completed\",\"current_page\":142,\"started_at\":\"2026-07-22T10:00:00Z\",\"finished_at\":\"2026-07-23T10:00:00Z\"}}"


goodProgress : String -> Http.Response String
goodProgress body =
    Http.GoodStatus_
        { url = progressEndpoint
        , statusCode = 200
        , statusText = "OK"
        , headers = Dict.empty
        }
        body


badProgress : Int -> String -> Http.Response String
badProgress status body =
    Http.BadStatus_
        { url = progressEndpoint
        , statusCode = status
        , statusText = "Unprocessable Entity"
        , headers = Dict.empty
        }
        body


{-| Walk the whole affordance the way a reader does: click the status badge
(which reads "To Read" on load — the server sends no status here), pick
"Reading" from the select, type a page, and Save.

The `<select>` is labelled implicitly (nested inside its `<label>`, no id), so
`ProgramTest.selectOption` — which requires a `for`/`id` pair — cannot reach it;
the `input` event is simulated directly on the test-id'd node instead.

-}
openAndSave : ProgramTest BookDetail.Model BookDetail.Msg (SimulatedEffect BookDetail.Msg) -> ProgramTest BookDetail.Model BookDetail.Msg (SimulatedEffect BookDetail.Msg)
openAndSave program =
    program
        |> ProgramTest.clickButton "To Read"
        |> ProgramTest.simulateDomEvent
            (Query.find [ Selector.attribute (Html.Attributes.attribute "data-testid" "status-select") ])
            (Event.input "reading")
        |> ProgramTest.fillIn "" "Current page" "142"
        |> ProgramTest.clickButton "Save"


suite : Test
suite =
    describe "BookDetail reading progress (US-1.6.6)"
        [ cardRendersForReadableShelf
        , saveFoldsResult
        , errorResponseKeepsFormOpen
        , finishedOnPileSurfacesBridge
        , finishedOnLibraryHasNoBridge
        ]


cardRendersForReadableShelf : Test
cardRendersForReadableShelf =
    test "card_mounts: the progress card renders at its To Read default, because the book-detail contract carries no progress" <|
        \() ->
            startDetailWith libraryPlacement
                |> ProgramTest.ensureViewHas [ Selector.class "book-detail__progress" ]
                |> ProgramTest.ensureViewHas [ Selector.text "Reading Progress" ]
                -- `book_placement/1` (proto_json.ex:311-322) emits no
                -- `reading_status`, so the badge falls to its ToRead default...
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "reading-status-badge")
                    , Selector.text "To Read"
                    ]
                -- ...and with no `current_page` either there is no progress
                -- line to render. Asserting its ABSENCE is what pins the
                -- contract: the moment #314 adds progress to this endpoint,
                -- this test fails and asks to be updated deliberately.
                |> ProgramTest.expectViewHasNot
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "reading-progress") ]


saveFoldsResult : Test
saveFoldsResult =
    test "save_folds: saving drives the API and folds the returned progress in place" <|
        \() ->
            startDetailWith libraryPlacement
                -- Nothing renders a page count before the save: the card loaded
                -- with no progress, so a later "p. 142" can only have come from
                -- the response body.
                |> ProgramTest.ensureViewHasNot [ Selector.text "p. 142 / 371" ]
                |> openAndSave
                -- Exactly `ProtoJSON.reading_progress/1`
                -- (proto_json.ex:688-696): the five keys it emits, no more.
                |> ProgramTest.simulateHttpResponse "PUT"
                    progressEndpoint
                    (goodProgress
                        "{\"placement\":{\"id\":\"placement-test-001\",\"reading_status\":\"reading\",\"current_page\":142,\"started_at\":\"2026-07-22T10:00:00Z\",\"finished_at\":null}}"
                    )
                |> ProgramTest.expectViewHas [ Selector.text "p. 142 / 371" ]


errorResponseKeepsFormOpen : Test
errorResponseKeepsFormOpen =
    test "error_surfaces: a 422 keeps the form open with the typed draft, and announces the error" <|
        \() ->
            startDetailWith libraryPlacement
                |> openAndSave
                |> ProgramTest.simulateHttpResponse "PUT"
                    progressEndpoint
                    (badProgress 422
                        "{\"errors\":{\"current_page\":[\"must be less than or equal to 112\"]}}"
                    )
                |> ProgramTest.ensureViewHas
                    [ Selector.text "That page is past the end of the book." ]
                |> ProgramTest.ensureViewHas [ Selector.class "placement-card__edit-form" ]
                -- The draft the reader typed survives the rejection. It has to
                -- be typed rather than seeded from the placement: the
                -- book-detail contract carries no `current_page` to seed it
                -- with, so a fixture that pre-filled the field was testing a
                -- state production never reaches.
                |> ProgramTest.expectViewHas [ Selector.attribute (Html.Attributes.value "142") ]


finishedOnPileSurfacesBridge : Test
finishedOnPileSurfacesBridge =
    test "finished_bridge_pile: a Finished response on the Reading Pile surfaces the record-a-read prompt" <|
        \() ->
            startDetailWith pilePlacement
                |> openAndSave
                |> ProgramTest.simulateHttpResponse "PUT" progressEndpoint (goodProgress completedBody)
                |> ProgramTest.expectViewHas
                    [ Selector.text "Move to your Library and record this read?" ]


finishedOnLibraryHasNoBridge : Test
finishedOnLibraryHasNoBridge =
    test "finished_bridge_gated: a Finished response on the Library offers NO move-to-library bridge" <|
        \() ->
            startDetailWith libraryPlacement
                |> openAndSave
                |> ProgramTest.simulateHttpResponse "PUT" progressEndpoint (goodProgress completedBody)
                |> ProgramTest.expectViewHasNot
                    [ Selector.text "Move to your Library and record this read?" ]
