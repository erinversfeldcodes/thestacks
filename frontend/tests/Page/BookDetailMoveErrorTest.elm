module Page.BookDetailMoveErrorTest exposing (suite)

{-| Program tests for the reading-pile-full rejection on the BookDetail move
path (Issue #276).

The backend rejects a placement that would take the reading pile past 50 with
a 422 whose body carries the `reading_pile_full` error code. These tests
assert that the shelf-mover flow surfaces that rejection with the specific
full-pile message, distinct from the generic move failure.

-}

import Dict
import Http
import Page.BookDetail as BookDetail
import ProgramTest
import Test exposing (Test, describe, test)
import Test.Html.Selector as Selector
import TestHelpers
    exposing
        ( bookDetailProgram
        , simulateBookDetailResponseWithPlacement
        , testBook
        , testPlacement
        )


moveEndpoint : String
moveEndpoint =
    "/api/placements/placement-test-001/move"


{-| Start the page, load the book with a placement, open the shelf mover and
confirm a move — leaving the PUT /move request in flight.
-}
startMoveFlow : ProgramTest.ProgramTest BookDetail.Model BookDetail.Msg (ProgramTest.SimulatedEffect BookDetail.Msg)
startMoveFlow =
    ProgramTest.start () (bookDetailProgram "book-test-001" (Just "test-token"))
        |> ProgramTest.simulateHttpResponse "GET"
            "/api/books/book-test-001"
            (simulateBookDetailResponseWithPlacement "book-test-001" testBook testPlacement)
        |> ProgramTest.clickButton "Choose Bookshelf"
        |> ProgramTest.clickButton "Move"


moveErrorResponse : Int -> String -> Http.Response String
moveErrorResponse status body =
    Http.BadStatus_
        { url = moveEndpoint
        , statusCode = status
        , statusText = "Unprocessable Entity"
        , headers = Dict.empty
        }
        body


suite : Test
suite =
    describe "Page.BookDetail move rejection (#276)"
        [ fullPileShowsSpecificMessage
        , genericFailureKeepsGenericMessage
        , fullPile422WithoutCodeStaysGeneric
        ]


fullPileShowsSpecificMessage : Test
fullPileShowsSpecificMessage =
    test "move_full_pile_message: a 422 reading_pile_full response renders the specific full-pile message" <|
        \() ->
            startMoveFlow
                |> ProgramTest.simulateHttpResponse "PUT"
                    moveEndpoint
                    (moveErrorResponse 422 "{\"error\":\"reading_pile_full\"}")
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Your reading pile is full — finish or remove a book before adding another." ]
                |> ProgramTest.expectViewHasNot
                    [ Selector.text "Failed to move book. Please try again." ]


genericFailureKeepsGenericMessage : Test
genericFailureKeepsGenericMessage =
    test "move_generic_failure: a 500 response renders the generic move failure, not the full-pile message" <|
        \() ->
            startMoveFlow
                |> ProgramTest.simulateHttpResponse "PUT"
                    moveEndpoint
                    (moveErrorResponse 500 "")
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Failed to move book. Please try again." ]
                |> ProgramTest.expectViewHasNot
                    [ Selector.text "Your reading pile is full — finish or remove a book before adding another." ]


fullPile422WithoutCodeStaysGeneric : Test
fullPile422WithoutCodeStaysGeneric =
    test "move_422_other_code: a 422 without the reading_pile_full code renders the generic failure" <|
        \() ->
            startMoveFlow
                |> ProgramTest.simulateHttpResponse "PUT"
                    moveEndpoint
                    (moveErrorResponse 422 "{\"error\":\"something_else\"}")
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Failed to move book. Please try again." ]
                |> ProgramTest.expectViewHasNot
                    [ Selector.text "Your reading pile is full — finish or remove a book before adding another." ]
