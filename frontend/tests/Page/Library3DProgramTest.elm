module Page.Library3DProgramTest exposing (suite)

{-| Program tests for the bookshelf 3D rendering redesign (Issue #029).

Tests validate:

  - Page renders .wallpaper with damask pattern class
  - Page renders .shelf-label with "Library" text
  - Books from the API render inside the bookcase structure
  - Empty shelf shows .empty-msg with appropriate message
  - Clicking a book spine shows a .book-detail overlay
  - The overlay displays the book's title and author
  - Clicking outside the overlay dismisses it

-}

import Page.Bookshelf.Library as Library
import ProgramTest
import Test exposing (Test, describe, test)
import Test.Html.Selector as Selector
import TestHelpers
    exposing
        ( libraryProgram
        , simulateBookshelfErrorResponse
        , simulateBookshelfResponse
        , testBook
        , testPlacement
        )


startLibrary : ProgramTest.ProgramTest Library.Model Library.Msg (ProgramTest.SimulatedEffect Library.Msg)
startLibrary =
    ProgramTest.start () (libraryProgram (Just "test-token"))


suite : Test
suite =
    describe "Library page 3D bookshelf rendering (Issue #029)"
        [ wallpaperDamaskPattern
        , shelfLabelRendered
        , booksInsideBookcase
        , emptyShelfMessage
        , clickSpineShowsOverlay
        , overlayShowsTitleAndAuthor
        , clickOutsideDismissesOverlay
        , failureRendersError
        , forbiddenTriggersAgeGate
        ]


{-| The page must render a .wallpaper element with .wallpaper--damask class.
-}
wallpaperDamaskPattern : Test
wallpaperDamaskPattern =
    test "page renders .wallpaper with damask pattern class" <|
        \() ->
            startLibrary
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/library"
                    (simulateBookshelfResponse [ testPlacement ])
                |> ProgramTest.expectViewHas
                    [ Selector.class "wallpaper--damask" ]


{-| The page must render a .shelf-label element containing "Library" text.
-}
shelfLabelRendered : Test
shelfLabelRendered =
    test "page renders .shelf-label with Library text" <|
        \() ->
            startLibrary
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/library"
                    (simulateBookshelfResponse [ testPlacement ])
                |> ProgramTest.ensureViewHas
                    [ Selector.class "shelf-label" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "Library" ]


{-| Books from the API must render inside a .bookcase structure.
-}
booksInsideBookcase : Test
booksInsideBookcase =
    test "books render inside .bookcase structure with side panels" <|
        \() ->
            startLibrary
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/library"
                    (simulateBookshelfResponse [ testPlacement ])
                |> ProgramTest.ensureViewHas
                    [ Selector.class "bookcase" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.class "bookcase__side--left" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.class "bookcase__side--right" ]
                |> ProgramTest.expectViewHas
                    [ Selector.class "book__spine" ]


{-| Empty shelf shows .empty-msg with descriptive message.
-}
emptyShelfMessage : Test
emptyShelfMessage =
    test "empty shelf shows .empty-msg with descriptive message" <|
        \() ->
            startLibrary
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/library"
                    (simulateBookshelfResponse [])
                |> ProgramTest.expectViewHas
                    [ Selector.class "empty-msg" ]


{-| Clicking a book spine shows a .book-detail overlay.
-}
clickSpineShowsOverlay : Test
clickSpineShowsOverlay =
    test "clicking a book spine shows a .book-detail overlay" <|
        \() ->
            startLibrary
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/library"
                    (simulateBookshelfResponse [ testPlacement ])
                |> ProgramTest.clickButton testBook.title
                |> ProgramTest.expectViewHas
                    [ Selector.class "book-detail" ]


{-| The book-detail overlay displays the book's title and author.
-}
overlayShowsTitleAndAuthor : Test
overlayShowsTitleAndAuthor =
    test "book-detail overlay displays title and author" <|
        \() ->
            startLibrary
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/library"
                    (simulateBookshelfResponse [ testPlacement ])
                |> ProgramTest.clickButton testBook.title
                |> ProgramTest.ensureViewHas
                    [ Selector.text "The Power of Habit" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "Charles Duhigg" ]


{-| Clicking outside the overlay dismisses it.
-}
clickOutsideDismissesOverlay : Test
clickOutsideDismissesOverlay =
    test "clicking outside overlay dismisses it" <|
        \() ->
            startLibrary
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/library"
                    (simulateBookshelfResponse [ testPlacement ])
                |> ProgramTest.clickButton testBook.title
                |> ProgramTest.ensureViewHas
                    [ Selector.class "book-detail" ]
                |> ProgramTest.clickButton "Close"
                |> ProgramTest.expectViewHasNot
                    [ Selector.class "book-detail" ]


{-| An HTTP error response must render the error message.
-}
failureRendersError : Test
failureRendersError =
    test "HTTP error response shows error message" <|
        \() ->
            startLibrary
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/library"
                    (simulateBookshelfErrorResponse 500)
                |> ProgramTest.expectViewHas
                    [ Selector.text "Could not load your library" ]


{-| A 403 response must trigger the age gate component.
-}
forbiddenTriggersAgeGate : Test
forbiddenTriggersAgeGate =
    test "403 response triggers age gate component" <|
        \() ->
            startLibrary
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/library"
                    (simulateBookshelfErrorResponse 403)
                |> ProgramTest.ensureViewHas
                    [ Selector.class "age-gate" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "Age Verification Required" ]
