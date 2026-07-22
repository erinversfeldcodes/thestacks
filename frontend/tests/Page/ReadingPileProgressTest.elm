module Page.ReadingPileProgressTest exposing (suite)

{-| Program tests for the reading-progress UI mounted on the Reading Pile
(US-1.6.6, Issue #116 Phase 2).

Covers: the PlacementCard renders progress for a book on the pile; opening the
card and saving drives PUT /api/placements/:id/progress and folds the returned
progress back into the card in place; a returned Finished status surfaces the
"record this read?" bridge prompt; and a 422 current\_page error surfaces an
inline message.

The fold is driven by the API RESPONSE, not the draft the user typed, so these
host-integration tests open the card and Save, then vary the simulated response.
The draft-to-request mapping itself is covered by PlacementCardTest.

-}

import Dict
import Html.Attributes
import Http
import Page.Bookshelf.ReadingPile as ReadingPile
import ProgramTest exposing (ProgramTest, SimulatedEffect)
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


startPile : ProgramTest ReadingPileTestModel ReadingPile.Msg (SimulatedEffect ReadingPile.Msg)
startPile =
    ProgramTest.start () (readingPileProgram (Just "test-token"))
        |> ProgramTest.simulateHttpResponse "GET"
            pileUrl
            (simulateBookshelfResponse [ readingPlacement ])


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
    describe "Reading Pile reading progress (US-1.6.6)"
        [ progressRendersOnCard
        , editAndSaveFoldsResult
        , finishedTransitionSurfacesBridge
        , errorResponseSurfacesMessage
        ]


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
                -- The form stays open so the reader can correct it...
                |> ProgramTest.ensureViewHas [ Selector.class "placement-card__edit-form" ]
                -- ...with the draft page (seeded from the current page, 40) preserved.
                |> ProgramTest.expectViewHas [ Selector.attribute (Html.Attributes.value "40") ]
