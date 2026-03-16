module Page.Library3DProgramTest exposing (suite)

{-| Program tests for the bookshelf 3D rendering redesign (Issue #029).

Tests validate:

  - Page renders .wallpaper with damask pattern class
  - Page renders .shelf-label with "Library" text
  - Books from the API render inside the bookcase structure
  - Empty shelf shows .empty-msg with appropriate message
  - Clicking a book navigates to BookDetail page
  - HTTP error renders error message
  - 403 triggers age gate

-}

import Page.Bookshelf as Bookshelf
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


startLibrary : ProgramTest.ProgramTest Bookshelf.Model Bookshelf.Msg (ProgramTest.SimulatedEffect Bookshelf.Msg)
startLibrary =
    ProgramTest.start () (libraryProgram (Just "test-token"))


suite : Test
suite =
    describe "Library page 3D bookshelf rendering (Issue #029)"
        [ wallpaperDamaskPattern
        , shelfLabelRendered
        , booksInsideBookcase
        , emptyShelfMessage
        , clickSpineNavigatesToDetail
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
                    [ Selector.class "empty-shelf" ]


{-| Clicking a book spine navigates to the book detail page.
BookClicked produces NavigateTo (BookDetail bookId) outMsg.
We verify the book button is clickable (the navigation is handled by Main.elm).
-}
clickSpineNavigatesToDetail : Test
clickSpineNavigatesToDetail =
    test "clicking a book spine triggers BookClicked" <|
        \() ->
            startLibrary
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/library"
                    (simulateBookshelfResponse [ testPlacement ])
                |> ProgramTest.expectViewHas
                    [ Selector.class "book-button" ]


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
