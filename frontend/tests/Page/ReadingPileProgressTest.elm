module Page.ReadingPileProgressTest exposing (suite)

{-| Program tests for the reading-progress UI mounted on the Reading Pile
(, Phase 2).

Covers: the PlacementCard renders progress for a book on the pile; opening the
card and saving drives PUT /api/placements/:id/progress and folds the returned
progress back into the card in place; a returned Finished status surfaces the
"record this read?" bridge prompt; and a 422 current\_page error surfaces an
inline message.

The fold is driven by the API RESPONSE, not the draft the user typed, so these
host-integration tests open the card and Save, then vary the simulated response.
The draft-to-request mapping itself is covered by PlacementCardTest.

-}

import Components.PlacementCard as Card
import Dict
import Expect
import Html.Attributes
import Http
import Page.Bookshelf.ReadingPile as ReadingPile
import ProgramTest exposing (ProgramTest, SimulatedEffect)
import ProgressSaveContract
import Test exposing (Test, describe, test)
import Test.Html.Selector as Selector
import TestHelpers exposing (ReadingPileTestModel, namedPlacement, readingPileProgram, simulateBookshelfResponse)
import Types.Placement exposing (Placement, ReadingStatus(..))


pileUrl : String
pileUrl =
    "/api/bookshelves/reading_pile"


progressEndpoint : String
progressEndpoint =
    "/api/placements/placement-book-1/progress"


{-| A reading-pile placement (book-1) already marked Reading at page 40. The
book carries the default test edition (371 pages), so the progress line reads
"p. 40 / 371".
-}
readingPlacement : Placement
readingPlacement =
    let
        base =
            namedPlacement "book-1" "Middlemarch"
    in
    { base
        | id = "placement-book-1"
        , bookshelfName = Just "reading_pile"
        , readingStatus = Just Reading
        , currentPage = Just 40
    }


{-| ⛔ The same pile placement with NO recorded reading status — the fixture
this module did not have.

Every other fixture here carries `readingStatus = Just Reading`, so until this
existed the Reading Pile host had never been driven on the unrecorded path at
all. That is why the badge-label change needed no update in this file, and why
defeating this host's save guard produced no failing test.

-}
unrecordedPlacement : Placement
unrecordedPlacement =
    { readingPlacement | readingStatus = Nothing, currentPage = Nothing }


startPile : ProgramTest ReadingPileTestModel ReadingPile.Msg (SimulatedEffect ReadingPile.Msg)
startPile =
    ProgramTest.start () (readingPileProgram (Just (TestHelpers.creds "test-token")))
        |> ProgramTest.simulateHttpResponse "GET"
            pileUrl
            (simulateBookshelfResponse [ readingPlacement ])


startPileUnrecorded : ProgramTest ReadingPileTestModel ReadingPile.Msg (SimulatedEffect ReadingPile.Msg)
startPileUnrecorded =
    ProgramTest.start () (readingPileProgram (Just (TestHelpers.creds "test-token")))
        |> ProgramTest.simulateHttpResponse "GET"
            pileUrl
            (simulateBookshelfResponse [ unrecordedPlacement ])


{-| Open the card (click the status badge) and click Save, leaving the PUT
/progress request in flight.
-}
openAndSave : ProgramTest ReadingPileTestModel ReadingPile.Msg (SimulatedEffect ReadingPile.Msg) -> ProgramTest ReadingPileTestModel ReadingPile.Msg (SimulatedEffect ReadingPile.Msg)
openAndSave program =
    program
        |> ProgramTest.clickButton "Reading"
        |> ProgramTest.clickButton "Save"


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


suite : Test
suite =
    describe "Reading Pile reading progress"
        [ progressRendersOnCard
        , editAndSaveFoldsResult
        , finishedTransitionSurfacesBridge
        , errorResponseSurfacesMessage
        , saveWithNoChosenStatusIssuesNoRequest
        , progressSaveContract
        ]


{-| The shared CLASSIFICATION table from `ProgressSaveContract`, driven through this
host's own UI. `Page.BookDetail` runs the same list.

⛔ These two hosts share a card component and have diverged four times in four
review rounds. They were then found to be wrong IDENTICALLY on the 401 branch,
which the fix-one-check-the-other reflex cannot catch, because checking the
other host shows you the same code. The list lives in one module so a case is
added to both hosts at once; `expectedOut` below is exhaustive so the compiler
makes this host say what a new classification means.

-}
progressSaveContract : Test
progressSaveContract =
    describe "progress_save_contract: every classification clears the in-flight flag"
        (ProgressSaveContract.fixtureDecodes progressEndpoint savedProgressBody
            :: describesItsTarget
            :: List.map contractCase ProgressSaveContract.classifications
        )


{-| The card's `aria-describedby` and the element it names, asserted TOGETHER.

⛔ THIS IS THE ASSERTION A CARD-LEVEL TEST STRUCTURALLY CANNOT MAKE. The card
renders the reference; this host renders the target. Only here do both halves
exist, so only here can a dangling reference be distinguished from a live one —
and `PlacementCardTest`'s comment used to claim this pairing while asserting
only the attribute.

⚠️ What is reachable now is PREDICATE drift rather than spelling drift: the
single authority closed the spelling half. The attribute is gated on this host's
failure predicate and the element on its own `case state of Failure`, two
expressions over one state. They agree by construction today and nothing would
fail if someone widened either — which is what this case is for.

-}
describesItsTarget : Test
describesItsTarget =
    test "a failed save renders the error AND the input that references it" <|
        \() ->
            startPile
                |> openAndSave
                |> ProgramTest.simulateHttpResponse "PUT"
                    progressEndpoint
                    (ProgressSaveContract.refusedResponse progressEndpoint savedProgressBody)
                |> ProgramTest.expectViewHas
                    [ Selector.id Card.progressErrorId
                    , Selector.attribute
                        (Html.Attributes.attribute "aria-describedby" Card.progressErrorId)
                    ]


{-| This host's spelling of the shared out-message decision.

⛔ The DECISION lives in `ProgressSaveContract.expectedOut`; what remains here is
only the translation into this host's own `OutMsg` type, which is genuinely
per-host. This used to be a three-case fixture owned by the host, so the shared
table fixed which CASES exist while each host decided what it owed in them — and
a host that stopped emitting its session-expiry message could be made green by
editing its own fixture, with the compiler's blessing.

⚠️ NARROWED, NOT CLOSED — stated so nobody believes it is airtight. A host can
still map BOTH constructors to `ReadingPile.NoOut` and the compiler will accept
it. What changed is the shape of the lie: it used to be a plausible per-page
decision spread over three cases, and is now one visibly nonsensical line saying
the session-expiry out-message is no out-message. That is the minimum
achievable, because `ReadingPile.OutMsg`'s constructors are not derivable from
anything the shared table knows.

-}
toOutMsg : ProgressSaveContract.ExpectedOut -> ReadingPile.OutMsg
toOutMsg expected =
    case expected of
        ProgressSaveContract.NoOutMsg ->
            ReadingPile.NoOut

        ProgressSaveContract.SessionExpiryOut ->
            ReadingPile.SessionExpired


contractCase : ProgressSaveContract.Classification -> Test
contractCase classification =
    test (ProgressSaveContract.label classification) <|
        \() ->
            startPile
                |> openAndSave
                |> ProgramTest.simulateHttpResponse "PUT"
                    progressEndpoint
                    (ProgressSaveContract.response progressEndpoint savedProgressBody classification)
                -- The in-flight flag, asserted through the button a reader
                -- sees. A host that leaves it set shows "Saving…" with Save
                -- disabled and no response ever coming.
                |> ProgramTest.ensureViewHasNot [ Selector.text "Saving…" ]
                -- ⛔ "Not stuck" is not "says why". Asserting only the absence of
                -- "Saving…" let the minimal wrong fix through — settle the flag,
                -- surface nothing — which leaves a re-enabled button and a save
                -- that silently vanished.
                -- ⛔ The branch is on the ASSERTION, not on the selector list.
                -- `ensureViewHas []` is a no-op, so putting the branch on the
                -- list made the `Saved` case claim nothing about the error's
                -- ABSENCE — a host that rendered `progress-error` on success
                -- would have passed.
                |> (if ProgressSaveContract.reportsAnError progressEndpoint savedProgressBody classification then
                        ProgramTest.ensureViewHas [ ProgressSaveContract.errorSelector ]

                    else
                        ProgramTest.ensureViewHasNot [ ProgressSaveContract.errorSelector ]
                   )
                |> ProgramTest.expectModel
                    (\model ->
                        Expect.equal
                            (toOutMsg (ProgressSaveContract.expectedOut classification))
                            model.lastOut
                    )


savedProgressBody : String
savedProgressBody =
    "{\"placement\":{\"id\":\"placement-book-1\",\"reading_status\":\"reading\",\"current_page\":142,\"started_at\":\"2026-07-22T10:00:00Z\",\"finished_at\":null}}"


{-| ⛔ Saving a pile card whose status was never recorded must issue NO request.

The destructive half of the original defect, asserted at this host. The card
seeded an absent status with `ToRead`, so opening the card and pressing Save
wrote `to_read` over whatever the server held.

⚠️ **Measured before this test existed**: keeping `draftStatus` a `Maybe` but
making `cardProgressWrite` return `Just (… Maybe.withDefault ToRead …)`
reintroduced the destructive write with **zero** of the then-2150 tests failing.
This host was the less-covered of the two — its every other fixture carries a
real status, so the no-status path had never been exercised here.

Driven as `CardMsg` carrying the card's own `SaveClicked`, which is the path a
click takes once the button is enabled. Clicking the rendered button instead
would assert the `disabled` attribute — the screen rather than the write — and
would pass against a host with no guard at all.

-}
saveWithNoChosenStatusIssuesNoRequest : Test
saveWithNoChosenStatusIssuesNoRequest =
    test "save_guard: Save on a pile card with NO recorded status issues no PUT at all" <|
        \() ->
            startPileUnrecorded
                |> ProgramTest.ensureViewHas [ Selector.text "Not recorded" ]
                |> ProgramTest.clickButton "Not recorded"
                |> ProgramTest.ensureViewHas [ Selector.class "placement-card__edit-form" ]
                |> ProgramTest.update
                    (ReadingPile.CardMsg "placement-book-1" Card.SaveClicked)
                |> ProgramTest.ensureHttpRequests "PUT"
                    progressEndpoint
                    (List.length >> Expect.equal 0)
                -- The form stays open, so the reader can still choose a status
                -- rather than being told the save succeeded.
                |> ProgramTest.ensureViewHas [ Selector.class "placement-card__edit-form" ]
                -- ⛔ The assertion that "the reader can still choose a status"
                -- actually needs, and which the form-open check does NOT give.
                -- `SaveClicked` sets `saving = True` before the guard refuses,
                -- so a host that forgets to clear it leaves the card showing
                -- "Saving…" with Save disabled and no response ever coming —
                -- and that stuck state satisfies "the edit form is open"
                -- perfectly. The open form was the half this test did not prove.
                |> ProgramTest.ensureViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "save-progress-btn")
                    , Selector.text "Save"
                    ]
                |> ProgramTest.expectViewHasNot [ Selector.text "Saving…" ]


progressRendersOnCard : Test
progressRendersOnCard =
    test "progress_renders: the pile card shows the reading progress line" <|
        \() ->
            startPile
                |> ProgramTest.ensureViewHas [ Selector.class "reading-pile__progress" ]
                |> ProgramTest.expectViewHas [ Selector.text "p. 40 / 371" ]


editAndSaveFoldsResult : Test
editAndSaveFoldsResult =
    test "edit_save_folds: saving drives the API and folds the returned progress in place" <|
        \() ->
            startPile
                |> openAndSave
                |> ProgramTest.simulateHttpResponse "PUT"
                    progressEndpoint
                    (goodProgress
                        "{\"placement\":{\"id\":\"placement-book-1\",\"reading_status\":\"reading\",\"current_page\":142,\"started_at\":\"2026-07-22T10:00:00Z\",\"finished_at\":null}}"
                    )
                |> ProgramTest.expectViewHas [ Selector.text "p. 142 / 371" ]


finishedTransitionSurfacesBridge : Test
finishedTransitionSurfacesBridge =
    test "finished_bridge: a Finished response surfaces the record-a-read prompt" <|
        \() ->
            startPile
                |> openAndSave
                |> ProgramTest.simulateHttpResponse "PUT"
                    progressEndpoint
                    (goodProgress
                        "{\"placement\":{\"id\":\"placement-book-1\",\"reading_status\":\"completed\",\"current_page\":142,\"started_at\":\"2026-07-22T10:00:00Z\",\"finished_at\":\"2026-07-23T10:00:00Z\"}}"
                    )
                |> ProgramTest.ensureViewHas [ Selector.class "reading-pile__finished-prompt" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "Move to your Library and record this read?" ]


errorResponseSurfacesMessage : Test
errorResponseSurfacesMessage =
    test "error_surfaces: a 422 keeps the form open with the draft, and announces the error" <|
        \() ->
            startPile
                |> openAndSave
                |> ProgramTest.simulateHttpResponse "PUT"
                    progressEndpoint
                    (badProgress 422
                        "{\"errors\":{\"current_page\":[\"must be less than or equal to 112\"]}}"
                    )
                |> ProgramTest.ensureViewHas
                    [ Selector.text "That page is past the end of the book." ]
                |> ProgramTest.ensureViewHas [ Selector.class "placement-card__edit-form" ]
                |> ProgramTest.expectViewHas [ Selector.attribute (Html.Attributes.value "40") ]
