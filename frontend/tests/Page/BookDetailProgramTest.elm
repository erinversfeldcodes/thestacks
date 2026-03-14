module Page.BookDetailProgramTest exposing (suite)

{-| Program tests for Page.BookDetail using elm-program-test.

These tests exercise the BookDetail page lifecycle through
simulated HTTP responses and user interactions.

-}

import Dict
import Http
import Page.BookDetail as BookDetail
import ProgramTest
import Test exposing (Test, describe, test)
import Test.Html.Selector as Selector
import TestHelpers exposing (bookDetailProgram, simulateBookDetailResponse, testBook)


{-| Helper to start a book detail program with an auth token.
-}
startBookDetail : ProgramTest.ProgramTest BookDetail.Model BookDetail.Msg (ProgramTest.SimulatedEffect BookDetail.Msg)
startBookDetail =
    ProgramTest.start () (bookDetailProgram "book-test-001" (Just "test-token"))


suite : Test
suite =
    describe "Page.BookDetail (ProgramTest)"
        [ loadingState
        , successRendersAllSections
        , failureRendersError
        , forbiddenTriggersAgeGate
        , formatToggleUpdatesSelected
        , shelfMoverOpenSelectConfirmFlow
        , removeModalOpenConfirmFlow
        ]


loadingState : Test
loadingState =
    test "loading_state: before HTTP response arrives, loading indicator is visible" <|
        \() ->
            startBookDetail
                |> ProgramTest.expectViewHas
                    [ Selector.text "Loading book..." ]


successRendersAllSections : Test
successRendersAllSections =
    test "success_renders_all_sections: successful response renders hero, about, reviews, prices, author, writing, shelf actions" <|
        \() ->
            startBookDetail
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-test-001"
                    (simulateBookDetailResponse "book-test-001" testBook)
                |> ProgramTest.ensureViewHas
                    [ Selector.class "book-detail__hero" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.class "book-detail__about" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.class "book-detail__reviews" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.class "book-detail__prices" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.class "book-detail__author-card" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.class "book-detail__writing" ]
                |> ProgramTest.expectViewHas
                    [ Selector.class "book-detail__shelf-actions" ]


failureRendersError : Test
failureRendersError =
    test "failure_renders_error: HTTP error response shows error message" <|
        \() ->
            startBookDetail
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-test-001"
                    (Http.BadStatus_
                        { url = "/api/books/book-test-001"
                        , statusCode = 500
                        , statusText = "Internal Server Error"
                        , headers = Dict.empty
                        }
                        ""
                    )
                |> ProgramTest.expectViewHas
                    [ Selector.text "Could not load this book. Please try again." ]


forbiddenTriggersAgeGate : Test
forbiddenTriggersAgeGate =
    test "forbidden_triggers_age_gate: 403 response triggers age gate, dismiss hides it" <|
        \() ->
            startBookDetail
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-test-001"
                    (Http.BadStatus_
                        { url = "/api/books/book-test-001"
                        , statusCode = 403
                        , statusText = "Forbidden"
                        , headers = Dict.empty
                        }
                        ""
                    )
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Age Verification Required" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.class "age-gate" ]
                |> ProgramTest.clickButton "Go Back"
                |> ProgramTest.expectViewHasNot
                    [ Selector.class "age-gate" ]


formatToggleUpdatesSelected : Test
formatToggleUpdatesSelected =
    test "format_toggle: clicking a format button adds selected class" <|
        \() ->
            startBookDetail
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-test-001"
                    (simulateBookDetailResponse "book-test-001" testBook)
                |> ProgramTest.clickButton "Physical"
                |> ProgramTest.expectViewHas
                    [ Selector.class "format-picker__btn--selected" ]


shelfMoverOpenSelectConfirmFlow : Test
shelfMoverOpenSelectConfirmFlow =
    test "shelf_mover_flow: open shelf mover, then cancel closes it" <|
        \() ->
            startBookDetail
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-test-001"
                    (simulateBookDetailResponse "book-test-001" testBook)
                |> ProgramTest.clickButton "Choose Bookshelf"
                |> ProgramTest.ensureViewHas
                    [ Selector.class "shelf-mover" ]
                |> ProgramTest.clickButton "Cancel"
                |> ProgramTest.expectViewHasNot
                    [ Selector.class "shelf-mover" ]


removeModalOpenConfirmFlow : Test
removeModalOpenConfirmFlow =
    test "remove_modal_flow: open remove modal shows confirmation, cancel closes it" <|
        \() ->
            startBookDetail
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-test-001"
                    (simulateBookDetailResponse "book-test-001" testBook)
                |> ProgramTest.clickButton "Remove from Bookshelf"
                |> ProgramTest.ensureViewHas
                    [ Selector.class "modal-overlay" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Are you sure you want to remove" ]
                |> ProgramTest.clickButton "Keep It"
                |> ProgramTest.expectViewHasNot
                    [ Selector.class "modal-overlay" ]
