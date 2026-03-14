module Page.BookshelfProgramTest exposing (suite)

{-| Program tests for Page.Bookshelf.Library using elm-program-test.

These tests exercise the Library bookshelf page lifecycle through
simulated HTTP responses and user interactions.

-}

import Dict
import Http
import Page.Bookshelf.Library as Library
import ProgramTest
import Test exposing (Test, describe, test)
import Test.Html.Selector as Selector
import TestHelpers exposing (libraryProgram, simulateBookshelfResponse, testPlacement)


{-| Helper to start a library program with an auth token.
-}
startLibrary : ProgramTest.ProgramTest Library.Model Library.Msg (ProgramTest.SimulatedEffect Library.Msg)
startLibrary =
    ProgramTest.start () (libraryProgram (Just "test-token"))


suite : Test
suite =
    describe "Page.Bookshelf.Library (ProgramTest)"
        [ bookshelfLoadingState
        , bookshelfRendersPlacements
        , bookshelfEmptyState
        , bookshelfErrorState
        , bookshelfAgeGate
        ]


bookshelfLoadingState : Test
bookshelfLoadingState =
    test "bookshelf_loading_state: before HTTP response arrives, loading indicator is visible" <|
        \() ->
            startLibrary
                |> ProgramTest.expectViewHas
                    [ Selector.text "Loading your library..." ]


bookshelfRendersPlacements : Test
bookshelfRendersPlacements =
    test "bookshelf_renders_placements: successful response with placements renders spine elements" <|
        \() ->
            startLibrary
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/library"
                    (simulateBookshelfResponse [ testPlacement ])
                |> ProgramTest.ensureViewHas
                    [ Selector.class "bookshelf" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.class "bookshelf__book" ]
                |> ProgramTest.expectViewHas
                    [ Selector.class "spine" ]


bookshelfEmptyState : Test
bookshelfEmptyState =
    test "bookshelf_empty_state: successful response with empty list shows empty bookshelf message" <|
        \() ->
            startLibrary
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/library"
                    (simulateBookshelfResponse [])
                |> ProgramTest.ensureViewHas
                    [ Selector.class "empty-shelf" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "Your library is waiting" ]


bookshelfErrorState : Test
bookshelfErrorState =
    test "bookshelf_error_state: HTTP error response shows error message" <|
        \() ->
            startLibrary
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/library"
                    (Http.BadStatus_
                        { url = "/api/bookshelves/library"
                        , statusCode = 500
                        , statusText = "Internal Server Error"
                        , headers = Dict.empty
                        }
                        ""
                    )
                |> ProgramTest.expectViewHas
                    [ Selector.text "Could not load your library. Please try again." ]


bookshelfAgeGate : Test
bookshelfAgeGate =
    test "bookshelf_age_gate: 403 response triggers age gate, dismiss hides it" <|
        \() ->
            startLibrary
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/library"
                    (Http.BadStatus_
                        { url = "/api/bookshelves/library"
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
