module Page.BookDetailProgressTest exposing (suite)

{-| Program tests for the reading-progress UI on the BookDetail overlay.
The card mounts when the placement sits on a readable bookshelf;
saving drives PUT /api/placements/:id/progress and folds the returned
progress in place. Covers the mount predicate, the request lifecycle,
and the completed-read bridge into the Reading Pile flow.
-}

import Components.PlacementCard as Card
import Dict
import Expect
import Html.Attributes
import Http
import Page.BookDetail as BookDetail
import ProgramTest exposing (ProgramTest, SimulatedEffect)
import ProgressSaveContract
import Test exposing (Test, describe, test)
import Test.Html.Event as Event
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import TestHelpers
    exposing
        ( BookDetailTestModel
        , bookDetailProgram
        , bookDetailProgramWithOut
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
(which reads "Not recorded" on load — this fixture's payload carries no
`reading_status`), pick "Reading" from the select, type a page, and Save.

⚠️ It used to read "To Read", and that was the defect rather than the contract:
the card defaulted an absent status to a specific one, so a reader mid-book saw
"To Read" and pressing Save wrote `to_read` over the real value. The badge now
distinguishes "not recorded" from "to read", and Save is disabled until a status
is chosen — which is why this walkthrough must pick one from the select before
clicking Save, as a reader would.

The `<select>` is labelled implicitly (nested inside its `<label>`, no id), so
`ProgramTest.selectOption` — which requires a `for`/`id` pair — cannot reach it;
the `input` event is simulated directly on the test-id'd node instead.

-}
openAndSave : ProgramTest BookDetail.Model BookDetail.Msg (SimulatedEffect BookDetail.Msg) -> ProgramTest BookDetail.Model BookDetail.Msg (SimulatedEffect BookDetail.Msg)
openAndSave program =
    program
        |> ProgramTest.clickButton "Not recorded"
        |> ProgramTest.simulateDomEvent
            (Query.find [ Selector.attribute (Html.Attributes.attribute "data-testid" "status-select") ])
            (Event.input "reading")
        |> ProgramTest.fillIn "" "Current page" "142"
        |> ProgramTest.clickButton "Save"


suite : Test
suite =
    describe "BookDetail reading progress"
        [ cardRendersForReadableShelf
        , saveFoldsResult
        , errorResponseKeepsFormOpen
        , finishedOnPileSurfacesBridge
        , finishedOnLibraryHasNoBridge
        , saveWithNoChosenStatusIssuesNoRequest
        , progressSaveContract
        ]


{-| The shared outcome table from `ProgressSaveContract`, driven through this
host's own UI. The Reading Pile runs the same list.

⛔ Written as a `List.map` over `ProgressSaveContract.outcomes` rather than as
hand-listed cases, so a new outcome cannot be added to one host and forgotten in
the other — and `expectedOut` below stops compiling until this host says what
the new outcome should produce.

-}
progressSaveContract : Test
progressSaveContract =
    describe "progress_save_contract: every terminal outcome clears the in-flight flag"
        (List.map contractCase ProgressSaveContract.outcomes)


{-| What this host must emit for each outcome.

Exhaustive on purpose: this is the per-host half of the contract, and the
compiler is what keeps it complete.

-}
expectedOut : ProgressSaveContract.Outcome -> BookDetail.OutMsg
expectedOut outcome =
    case outcome of
        ProgressSaveContract.Saved ->
            BookDetail.NoOut

        ProgressSaveContract.ServerRefused ->
            BookDetail.NoOut

        ProgressSaveContract.SessionRejected ->
            BookDetail.SessionExpired


contractCase : ProgressSaveContract.Outcome -> Test
contractCase outcome =
    test (ProgressSaveContract.label outcome) <|
        \() ->
            ProgramTest.start () (bookDetailProgramWithOut "book-test-001" (Just "test-token") Nothing)
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-test-001"
                    (simulateBookDetailResponseWithPlacement "book-test-001" testBook libraryPlacement)
                |> openAndSaveWithOut
                |> ProgramTest.simulateHttpResponse "PUT"
                    progressEndpoint
                    (ProgressSaveContract.response progressEndpoint completedBody outcome)
                -- The in-flight flag, asserted through the button a reader sees.
                -- A host that leaves it set shows "Saving…" with Save disabled
                -- and no response ever coming.
                |> ProgramTest.ensureViewHasNot [ Selector.text "Saving…" ]
                |> ProgramTest.expectModel
                    (\model -> Expect.equal (expectedOut outcome) model.lastOut)


{-| `openAndSave`, against the out-recording harness.
-}
openAndSaveWithOut :
    ProgramTest BookDetailTestModel BookDetail.Msg (SimulatedEffect BookDetail.Msg)
    -> ProgramTest BookDetailTestModel BookDetail.Msg (SimulatedEffect BookDetail.Msg)
openAndSaveWithOut program =
    program
        |> ProgramTest.clickButton "Not recorded"
        |> ProgramTest.simulateDomEvent
            (Query.find [ Selector.attribute (Html.Attributes.attribute "data-testid" "status-select") ])
            (Event.input "reading")
        |> ProgramTest.fillIn "" "Current page" "142"
        |> ProgramTest.clickButton "Save"


{-| ⛔ Saving a card whose status was never recorded must issue NO request.

This is the destructive half of the original defect, asserted at the host rather
than at the screen. The card seeded an absent status with `ToRead`, so opening
the card and pressing Save wrote `to_read` over whatever the server held —
including over a status this build could not parse.

⚠️ Why this test exists even though Save is disabled: a `disabled` attribute is
the screen, not the write. **Measured** — defeating both host guards while
keeping `draftStatus : Maybe ReadingStatus` (so the type still looks protective)
reintroduced the destructive write with **zero** of the then-2150 tests failing.
The `disabled` assertion was the whole of the suite's protection, and it does
not cover the path a `SaveClicked` message takes.

So this drives `SaveClicked` directly instead of clicking the rendered button:
going through the button would assert the `disabled` attribute again rather than
the guard behind it, and would pass against a host with no guard at all.

-}
saveWithNoChosenStatusIssuesNoRequest : Test
saveWithNoChosenStatusIssuesNoRequest =
    test "save_guard: Save on a card with NO recorded status issues no PUT at all" <|
        \() ->
            startDetailWith libraryPlacement
                -- Open the card without choosing a status, so draftStatus is
                -- Nothing — the state the fixture's payload actually describes.
                |> ProgramTest.clickButton "Not recorded"
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "status-select") ]
                -- ⛔ Driven as the card's own SaveClicked, routed through the
                -- host's ProgressCardMsg — the exact path a click takes once
                -- the button is enabled. Clicking the rendered button instead
                -- would assert the `disabled` attribute, which is the half
                -- already covered and the half that is not the write.
                |> ProgramTest.update (BookDetail.ProgressCardMsg Card.SaveClicked)
                |> ProgramTest.ensureHttpRequests "PUT"
                    progressEndpoint
                    (List.length >> Expect.equal 0)
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "status-select") ]
                -- ⛔ Not redundant with the open form, and the sibling host
                -- proves why: `SaveClicked` sets `saving = True` before the
                -- guard refuses, so a host that forgets `Card.stopSaving`
                -- leaves the card on "Saving…" with Save disabled and no
                -- response ever arriving. That stuck state satisfies every
                -- form-is-open assertion. ReadingPile had exactly this bug
                -- while its guard test passed.
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "save-progress-btn")
                    , Selector.text "Save"
                    ]
                |> ProgramTest.expectViewHasNot [ Selector.text "Saving…" ]


cardRendersForReadableShelf : Test
cardRendersForReadableShelf =
    test "card_mounts: an absent reading status renders as NOT RECORDED, never as To Read" <|
        \() ->
            startDetailWith libraryPlacement
                |> ProgramTest.ensureViewHas [ Selector.class "book-detail__progress" ]
                |> ProgramTest.ensureViewHas [ Selector.text "Reading Progress" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "reading-status-badge")
                    , Selector.text "Not recorded"
                    ]
                -- ⛔ The assertion that would have been RED before this change:
                -- the badge must not claim a status the server never sent.
                |> ProgramTest.ensureViewHasNot
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "reading-status-badge")
                    , Selector.text "To Read"
                    ]
                |> ProgramTest.expectViewHasNot
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "reading-progress") ]


saveFoldsResult : Test
saveFoldsResult =
    test "save_folds: saving drives the API and folds the returned progress in place" <|
        \() ->
            startDetailWith libraryPlacement
                |> ProgramTest.ensureViewHasNot [ Selector.text "p. 142 / 371" ]
                |> openAndSave
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
