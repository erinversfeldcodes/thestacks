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
        , simulateBookDetailResponse
        , simulateBookDetailResponseWithPlacement
        , testBook
        , testPlacement
        )


moveEndpoint : String
moveEndpoint =
    "/api/placements/placement-test-001/move"


{-| A book loaded WITHOUT a placement defaults `selectedBookshelf` to "library"
(the first bookshelf that is not the empty current one), so the direct-place
POST lands here.
-}
placeEndpoint : String
placeEndpoint =
    "/api/bookshelves/library/placements"


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


{-| Start the page, load the book with NO placement (so the "Add to Collection"
place path shows), open the shelf mover and confirm — leaving the POST
/placements request in flight.
-}
startPlaceFlow : ProgramTest.ProgramTest BookDetail.Model BookDetail.Msg (ProgramTest.SimulatedEffect BookDetail.Msg)
startPlaceFlow =
    ProgramTest.start () (bookDetailProgram "book-test-001" (Just "test-token"))
        |> ProgramTest.simulateHttpResponse "GET"
            "/api/books/book-test-001"
            (simulateBookDetailResponse "book-test-001" testBook)
        |> ProgramTest.clickButton "Choose Bookshelf"
        |> ProgramTest.clickButton "Move"


placeErrorResponse : Int -> String -> Http.Response String
placeErrorResponse status body =
    Http.BadStatus_
        { url = placeEndpoint
        , statusCode = status
        , statusText = "Unprocessable Entity"
        , headers = Dict.empty
        }
        body


suite : Test
suite =
    describe "Page.BookDetail placement rejection (#276/#281)"
        [ fullPileShowsSpecificMessage
        , genericFailureKeepsGenericMessage
        , fullPile422WithoutCodeStaysGeneric
        , placeFullPileShowsSpecificMessage
        , placeGenericFailureKeepsGenericMessage
        , placeFullPile422WithoutCodeStaysGeneric
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


placeFullPileShowsSpecificMessage : Test
placeFullPileShowsSpecificMessage =
    test "place_full_pile_message: a 422 reading_pile_full on the direct-place path renders the specific full-pile message" <|
        \() ->
            startPlaceFlow
                |> ProgramTest.simulateHttpResponse "POST"
                    placeEndpoint
                    (placeErrorResponse 422 "{\"error\":\"reading_pile_full\"}")
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Your reading pile is full — finish or remove a book before adding another." ]
                |> ProgramTest.expectViewHasNot
                    [ Selector.text "Failed to move book. Please try again." ]


placeGenericFailureKeepsGenericMessage : Test
placeGenericFailureKeepsGenericMessage =
    test "place_generic_failure: a 500 on the direct-place path renders the generic failure, not the full-pile message" <|
        \() ->
            startPlaceFlow
                |> ProgramTest.simulateHttpResponse "POST"
                    placeEndpoint
                    (placeErrorResponse 500 "")
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Failed to move book. Please try again." ]
                |> ProgramTest.expectViewHasNot
                    [ Selector.text "Your reading pile is full — finish or remove a book before adding another." ]


placeFullPile422WithoutCodeStaysGeneric : Test
placeFullPile422WithoutCodeStaysGeneric =
    test "place_422_other_code: a 422 without the reading_pile_full code on the place path renders the generic failure" <|
        \() ->
            startPlaceFlow
                |> ProgramTest.simulateHttpResponse "POST"
                    placeEndpoint
                    (placeErrorResponse 422 "{\"error\":\"something_else\"}")
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Failed to move book. Please try again." ]
                |> ProgramTest.expectViewHasNot
                    [ Selector.text "Your reading pile is full — finish or remove a book before adding another." ]
