module Page.BookshelfProgramTest exposing (suite)

{-| Program tests for Page.Bookshelf using elm-program-test.

These tests exercise the Bookshelf page lifecycle through
simulated HTTP responses and user interactions.

`Page.Bookshelf` is config-driven: Library, Antilibrary and Wish List are the
same module under three `Config` values, so the per-shelf suites below assert
exactly what the config is responsible for — the endpoint it fetches, the theme
and wallpaper it paints, the label it announces, and the error copy it writes
from that label.

-}

import Components.BookList as BookList
import Dict
import Expect
import Html.Attributes
import Http
import Json.Encode as Encode
import Page.Bookshelf as Bookshelf
import ProgramTest
import Test exposing (Test, describe, test)
import Test.Html.Event as Event
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import TestHelpers
    exposing
        ( bookshelfProgram
        , libraryProgram
        , namedPlacement
        , simulateBookshelfResponse
        , testPlacement
        )


{-| Helper to start a library program with an auth token.
-}
startLibrary : ProgramTest.ProgramTest Bookshelf.Model Bookshelf.Msg (ProgramTest.SimulatedEffect Bookshelf.Msg)
startLibrary =
    ProgramTest.start () (libraryProgram (Just "test-token"))


{-| Start any owner-mode bookshelf under the given config.
-}
startShelf : Bookshelf.Config -> ProgramTest.ProgramTest Bookshelf.Model Bookshelf.Msg (ProgramTest.SimulatedEffect Bookshelf.Msg)
startShelf config =
    ProgramTest.start () (bookshelfProgram config (Just "test-token"))


suite : Test
suite =
    describe "Page.Bookshelf.Library (ProgramTest)"
        [ bookshelfLoadingState
        , bookshelfRendersPlacements
        , bookshelfEmptyState
        , bookshelfErrorState
        , bookshelfErrorIsNotEmpty
        , bookshelfAgeGate
        , antiLibrarySuite
        , wishListSuite
        , noTokenSuite
        , viewModeSuite
        , rovingTabindexSuite
        ]


{-| Roving tabindex: the bookcase is ONE tab stop, and the arrow keys
move it. Each negative (tabindex -1) is paired with the positive control that
proves the selector is real — a suite asserting only "some spine has
tabindex 0" would have passed before the widget existed, when EVERY spine did.
-}
rovingTabindexSuite : Test
rovingTabindexSuite =
    let
        loaded =
            startLibrary
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/library"
                    (simulateBookshelfResponse
                        [ namedPlacement "book-1" "First Book"
                        , namedPlacement "book-2" "Second Book"
                        ]
                    )

        spinesWithTabindex value =
            Query.findAll
                [ Selector.class "book-button"
                , Selector.attribute (Html.Attributes.tabindex value)
                ]

        arrowRightOn spineId =
            ProgramTest.simulateDomEvent
                (Query.find [ Selector.id ("spine-" ++ spineId) ])
                ( "keydown", Encode.object [ ( "key", Encode.string "ArrowRight" ) ] )
    in
    describe "roving tabindex"
        [ test "roving_single_tab_stop: exactly the first spine is tabbable on load" <|
            \() ->
                loaded
                    |> ProgramTest.expectView
                        (Expect.all
                            [ Query.findAll [ Selector.class "book-button" ]
                                >> Query.count (Expect.equal 2)
                            , spinesWithTabindex 0 >> Query.count (Expect.equal 1)
                            , spinesWithTabindex 0
                                >> Query.first
                                >> Query.has [ Selector.id "spine-book-1" ]
                            , spinesWithTabindex -1 >> Query.count (Expect.equal 1)
                            ]
                        )
        , test "roving_arrow_moves_the_tab_stop: ArrowRight hands the tab stop to the next spine" <|
            \() ->
                loaded
                    |> arrowRightOn "book-1"
                    |> ProgramTest.expectView
                        (Expect.all
                            [ spinesWithTabindex 0 >> Query.count (Expect.equal 1)
                            , spinesWithTabindex 0
                                >> Query.first
                                >> Query.has [ Selector.id "spine-book-2" ]
                            ]
                        )
        , test "roving_grid_edge_keeps_focus: ArrowRight on the last spine moves nothing" <|
            \() ->
                loaded
                    |> arrowRightOn "book-1"
                    |> arrowRightOn "book-2"
                    |> ProgramTest.expectView
                        (spinesWithTabindex 0
                            >> Query.first
                            >> Query.has [ Selector.id "spine-book-2" ]
                        )
        ]


{-| ⛔ `Loading` and `Success []` must not render the same page. The test
this suite replaced asserted the loading view has a `.bookcase` — true
in every state, so it passed with the defect and would pass after any
repair. These assertions distinguish the placeholder skeleton from a
genuinely empty shelf from a populated one.
-}
bookshelfLoadingState : Test
bookshelfLoadingState =
    describe "Loading is not the empty shelf"
        [ test "bookshelf_loading_shows_a_loading_state: before the response arrives the page says so, in markup a screen reader can use" <|
            \() ->
                startLibrary
                    |> ProgramTest.ensureViewHas [ Selector.attribute (Html.Attributes.attribute "data-testid" "bookshelf-loading") ]
                    |> ProgramTest.ensureViewHas [ Selector.class "bookshelf--loading" ]
                    |> ProgramTest.ensureViewHas [ Selector.attribute (Html.Attributes.attribute "aria-busy" "true") ]
                    |> ProgramTest.ensureViewHas [ Selector.attribute (Html.Attributes.attribute "role" "status") ]
                    |> ProgramTest.ensureViewHas [ Selector.text "Fetching your Library…" ]
                    |> ProgramTest.expectView
                        (Query.findAll [ Selector.class "book-skeleton" ]
                            >> Query.count (Expect.greaterThan 1)
                        )
        , test "bookshelf_loading_is_not_the_empty_state: nothing on the loading page claims the shelf is empty" <|
            \() ->
                startLibrary
                    |> ProgramTest.ensureViewHas [ Selector.class "bookshelf--loading" ]
                    |> ProgramTest.ensureViewHasNot [ Selector.attribute (Html.Attributes.attribute "data-testid" "bookshelf-empty") ]
                    |> ProgramTest.ensureViewHasNot [ Selector.class "shelf-row--empty" ]
                    |> ProgramTest.expectViewHasNot [ Selector.text "Your library is waiting. Move a book here when you've finished reading it." ]
        , test "bookshelf_empty_is_not_the_loading_state: once an empty shelf arrives the waiting marks are gone" <|
            \() ->
                startLibrary
                    |> ProgramTest.ensureViewHas [ Selector.class "bookshelf--loading" ]
                    |> ProgramTest.simulateHttpResponse "GET"
                        "/api/bookshelves/library"
                        (simulateBookshelfResponse [])
                    |> ProgramTest.ensureViewHas [ Selector.attribute (Html.Attributes.attribute "data-testid" "bookshelf-empty") ]
                    |> ProgramTest.ensureViewHasNot [ Selector.class "bookshelf--loading" ]
                    |> ProgramTest.ensureViewHasNot [ Selector.class "book-skeleton" ]
                    |> ProgramTest.expectViewHasNot
                        [ Selector.attribute (Html.Attributes.attribute "aria-busy" "true") ]
        , test "profile_shelf_loading_names_whose_shelf: read-only browse does not call it 'your' library" <|
            \() ->
                ProgramTest.start () (bookshelfProgram (Bookshelf.profileConfig "ada" "library") Nothing)
                    |> ProgramTest.ensureViewHas [ Selector.text "Fetching @ada’s Library…" ]
                    |> ProgramTest.expectViewHasNot [ Selector.text "Fetching your Library…" ]
        ]


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
                    [ Selector.class "book" ]
                |> ProgramTest.expectViewHas
                    [ Selector.class "book__spine" ]


bookshelfEmptyState : Test
bookshelfEmptyState =
    test "bookshelf_empty_state: successful response with empty list shows empty bookshelf message" <|
        \() ->
            startLibrary
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/library"
                    (simulateBookshelfResponse [])
                |> ProgramTest.ensureViewHas
                    [ Selector.class "shelf-row--empty" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "Your library is waiting" ]


bookshelfErrorState : Test
bookshelfErrorState =
    test "bookshelf_error_state: HTTP error response shows error message" <|
        \() ->
            startLibrary
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/library"
                    (shelfErrorResponse "/api/bookshelves/library" 500)
                |> ProgramTest.expectViewHas
                    [ Selector.text "Could not load your library. Please try again." ]


{-| higher-severity property, pinned: a failed load must NEVER read as
an empty library. `bookshelf_empty_state` above is the positive control — it
proves both marks (`shelf-row--empty`, the "waiting" copy) are what a real
empty library shows, so the two `ensureViewHasNot`s here cannot pass vacuously.
-}
bookshelfErrorIsNotEmpty : Test
bookshelfErrorIsNotEmpty =
    test "bookshelf_error_is_not_the_empty_state: a failed load never paints an empty library" <|
        \() ->
            startLibrary
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/library"
                    (TestHelpers.simulateBookshelfErrorResponse 500)
                |> ProgramTest.ensureViewHasNot [ Selector.text "Your library is waiting" ]
                |> ProgramTest.ensureViewHasNot [ Selector.class "shelf-row--empty" ]
                |> ProgramTest.expectViewHas
                    [ Selector.attribute (Html.Attributes.attribute "data-testid" "shelf-error") ]


bookshelfAgeGate : Test
bookshelfAgeGate =
    test "bookshelf_age_gate: 403 response triggers age gate, dismiss hides it" <|
        \() ->
            startLibrary
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/library"
                    (shelfErrorResponse "/api/bookshelves/library" 403)
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Age Verification Required" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.class "age-gate" ]
                |> ProgramTest.clickButton "Go Back"
                |> ProgramTest.expectViewHasNot
                    [ Selector.class "age-gate" ]


antiLibrarySuite : Test
antiLibrarySuite =
    describe "antiLibraryConfig"
        [ test "antilibrary_fetches_own_endpoint: init GETs /api/bookshelves/antilibrary, not the library's" <|
            \() ->
                startShelf Bookshelf.antiLibraryConfig
                    |> ProgramTest.expectHttpRequestWasMade "GET" "/api/bookshelves/antilibrary"
        , test "antilibrary_theme_and_label: the antilibrary paints its own theme, wallpaper and label" <|
            \() ->
                startShelf Bookshelf.antiLibraryConfig
                    |> ProgramTest.simulateHttpResponse "GET"
                        "/api/bookshelves/antilibrary"
                        (simulateBookshelfResponse [ testPlacement ])
                    |> ProgramTest.ensureViewHas [ Selector.class "shelf-antilibrary" ]
                    |> ProgramTest.ensureViewHas [ Selector.class "wallpaper--botanical" ]
                    |> ProgramTest.ensureView
                        (Query.find [ Selector.class "shelf-label" ]
                            >> Query.has [ Selector.attribute (Html.Attributes.attribute "aria-label" "Antilibrary") ]
                        )
                    |> ProgramTest.ensureViewHasNot [ Selector.class "shelf-library" ]
                    |> ProgramTest.expectViewHasNot [ Selector.class "wallpaper--damask" ]
        , test "antilibrary_empty_state: an empty antilibrary shows its own invitation copy" <|
            \() ->
                startShelf Bookshelf.antiLibraryConfig
                    |> ProgramTest.simulateHttpResponse "GET"
                        "/api/bookshelves/antilibrary"
                        (simulateBookshelfResponse [])
                    |> ProgramTest.expectViewHas
                        [ Selector.text "Books you own but haven't read yet. Upload a photo to start building your collection." ]
        , test "antilibrary_error_state: a 500 names the antilibrary in the error copy" <|
            \() ->
                startShelf Bookshelf.antiLibraryConfig
                    |> ProgramTest.simulateHttpResponse "GET"
                        "/api/bookshelves/antilibrary"
                        (shelfErrorResponse "/api/bookshelves/antilibrary" 500)
                    |> ProgramTest.ensureViewHas
                        [ Selector.text "Could not load your antilibrary. Please try again." ]
                    |> ProgramTest.expectViewHasNot [ Selector.class "age-gate" ]
        , test "antilibrary_age_gate: a 403 raises the age gate over the antilibrary" <|
            \() ->
                startShelf Bookshelf.antiLibraryConfig
                    |> ProgramTest.simulateHttpResponse "GET"
                        "/api/bookshelves/antilibrary"
                        (shelfErrorResponse "/api/bookshelves/antilibrary" 403)
                    |> ProgramTest.ensureViewHas [ Selector.class "age-gate" ]
                    |> ProgramTest.clickButton "Go Back"
                    |> ProgramTest.expectViewHasNot [ Selector.class "age-gate" ]
        ]


wishListSuite : Test
wishListSuite =
    describe "wishListConfig"
        [ test "wishlist_fetches_own_endpoint: init GETs /api/bookshelves/wishlist" <|
            \() ->
                startShelf Bookshelf.wishListConfig
                    |> ProgramTest.expectHttpRequestWasMade "GET" "/api/bookshelves/wishlist"
        , test "wishlist_theme_and_label: the wish list paints its own theme, wallpaper and label" <|
            \() ->
                startShelf Bookshelf.wishListConfig
                    |> ProgramTest.simulateHttpResponse "GET"
                        "/api/bookshelves/wishlist"
                        (simulateBookshelfResponse [ testPlacement ])
                    |> ProgramTest.ensureViewHas [ Selector.class "shelf-wishlist" ]
                    |> ProgramTest.ensureViewHas [ Selector.class "wallpaper--floral" ]
                    |> ProgramTest.ensureView
                        (Query.find [ Selector.class "shelf-label" ]
                            >> Query.has [ Selector.attribute (Html.Attributes.attribute "aria-label" "Wish List") ]
                        )
                    |> ProgramTest.ensureViewHasNot [ Selector.class "shelf-library" ]
                    |> ProgramTest.expectViewHasNot [ Selector.class "wallpaper--damask" ]
        , test "wishlist_empty_state: an empty wish list shows its own invitation copy" <|
            \() ->
                startShelf Bookshelf.wishListConfig
                    |> ProgramTest.simulateHttpResponse "GET"
                        "/api/bookshelves/wishlist"
                        (simulateBookshelfResponse [])
                    |> ProgramTest.expectViewHas
                        [ Selector.text "Books you're dreaming about. Add one from a photo, a screenshot, or an ISBN." ]
        , test "wishlist_error_state: a 500 names the wish list in the error copy" <|
            \() ->
                startShelf Bookshelf.wishListConfig
                    |> ProgramTest.simulateHttpResponse "GET"
                        "/api/bookshelves/wishlist"
                        (shelfErrorResponse "/api/bookshelves/wishlist" 500)
                    |> ProgramTest.ensureViewHas
                        [ Selector.text "Could not load your wish list. Please try again." ]
                    |> ProgramTest.expectViewHasNot [ Selector.class "age-gate" ]
        , test "wishlist_age_gate: a 403 raises the age gate over the wish list" <|
            \() ->
                startShelf Bookshelf.wishListConfig
                    |> ProgramTest.simulateHttpResponse "GET"
                        "/api/bookshelves/wishlist"
                        (shelfErrorResponse "/api/bookshelves/wishlist" 403)
                    |> ProgramTest.ensureViewHas [ Selector.class "age-gate" ]
                    |> ProgramTest.clickButton "Go Back"
                    |> ProgramTest.expectViewHasNot [ Selector.class "age-gate" ]
        ]


noTokenSuite : Test
noTokenSuite =
    describe "init with no token"
        [ test "no_token_fires_no_request: init without a token issues no bookshelf request" <|
            \() ->
                ProgramTest.start () (libraryProgram Nothing)
                    |> ProgramTest.expectHttpRequests "GET"
                        "/api/bookshelves/library"
                        (List.length >> Expect.equal 0)
        , test "token_fires_one_request: the same harness WITH a token issues exactly one — so the assertion above can fail" <|
            \() ->
                startLibrary
                    |> ProgramTest.expectHttpRequests "GET"
                        "/api/bookshelves/library"
                        (List.length >> Expect.equal 1)
        , test "no_token_renders_empty_bookcase: the anonymous page still renders the four-row bookcase frame" <|
            \() ->
                ProgramTest.start () (libraryProgram Nothing)
                    |> ProgramTest.ensureViewHas [ Selector.class "bookcase" ]
                    |> ProgramTest.ensureViewHas [ Selector.class "bookcase__inner" ]
                    |> ProgramTest.ensureView
                        (Query.findAll [ Selector.class "shelf-row" ]
                            >> Query.count (Expect.equal 4)
                        )
                    |> ProgramTest.ensureViewHasNot [ Selector.class "book-button" ]
                    |> ProgramTest.expectViewHasNot [ Selector.class "error" ]
        , test "no_token_is_not_asked_not_loading: with no request issued the page does not claim one is in flight" <|
            \() ->
                ProgramTest.start () (libraryProgram Nothing)
                    |> ProgramTest.ensureViewHasNot [ Selector.class "bookshelf--loading" ]
                    |> ProgramTest.expectViewHasNot
                        [ Selector.attribute (Html.Attributes.attribute "aria-busy" "true") ]
        , test "token_is_loading: the same harness WITH a token does claim a request is in flight" <|
            \() ->
                startLibrary
                    |> ProgramTest.ensureViewHas [ Selector.class "bookshelf--loading" ]
                    |> ProgramTest.expectViewHas
                        [ Selector.attribute (Html.Attributes.attribute "aria-busy" "true") ]
        ]


viewModeSuite : Test
viewModeSuite =
    describe "view mode and list sorting"
        [ test "list_view_swaps_to_book_list: toggling to list view replaces the bookcase with BookList's sortable table" <|
            \() ->
                loadedLibrary
                    |> ProgramTest.ensureViewHas [ Selector.class "bookcase" ]
                    |> ProgramTest.simulateDomEvent (findViewModeButton "List view") Event.click
                    |> ProgramTest.ensureViewHas [ Selector.class "bookshelf--list-view" ]
                    |> ProgramTest.ensureViewHas [ Selector.class "book-list" ]
                    |> ProgramTest.ensureViewHas [ Selector.text "Title" ]
                    |> ProgramTest.ensureViewHas [ Selector.text "Author" ]
                    |> ProgramTest.ensureViewHas [ Selector.text "Pages" ]
                    |> ProgramTest.ensureViewHas [ Selector.text "Date Added" ]
                    |> ProgramTest.ensureViewHas [ Selector.text "Formats" ]
                    |> ProgramTest.expectViewHasNot [ Selector.class "bookcase" ]
        , test "spine_view_returns: toggling back to spine view restores the bookcase" <|
            \() ->
                loadedLibrary
                    |> ProgramTest.simulateDomEvent (findViewModeButton "List view") Event.click
                    |> ProgramTest.ensureViewHasNot [ Selector.class "bookcase" ]
                    |> ProgramTest.simulateDomEvent (findViewModeButton "Spine view") Event.click
                    |> ProgramTest.ensureViewHas [ Selector.class "bookcase" ]
                    |> ProgramTest.expectViewHasNot [ Selector.class "book-list" ]
        , test "sort_default_is_title_ascending: the list opens sorted by Title ascending" <|
            \() ->
                inListView
                    |> ProgramTest.expectModel
                        (\model ->
                            model.sortState
                                |> Expect.equal { column = BookList.Title, direction = BookList.Asc }
                        )
        , test "sort_same_column_toggles_direction: clicking the active column flips Asc to Desc and back" <|
            \() ->
                inListView
                    |> ProgramTest.simulateDomEvent (findColumnHeader "Title") Event.click
                    |> ProgramTest.ensureView
                        (findColumnHeader "Title" >> Query.has [ ariaSort "descending" ])
                    |> ProgramTest.simulateDomEvent (findColumnHeader "Title") Event.click
                    |> ProgramTest.expectView
                        (findColumnHeader "Title" >> Query.has [ ariaSort "ascending" ])
        , test "sort_new_column_resets_to_ascending: switching column starts it ascending and clears the old column's indicator" <|
            \() ->
                inListView
                    |> ProgramTest.simulateDomEvent (findColumnHeader "Title") Event.click
                    |> ProgramTest.ensureView
                        (findColumnHeader "Title" >> Query.has [ ariaSort "descending" ])
                    |> ProgramTest.simulateDomEvent (findColumnHeader "Author") Event.click
                    |> ProgramTest.ensureView
                        (findColumnHeader "Author" >> Query.has [ ariaSort "ascending" ])
                    |> ProgramTest.ensureView
                        (findColumnHeader "Title" >> Query.has [ ariaSort "none" ])
                    |> ProgramTest.expectModel
                        (\model ->
                            model.sortState
                                |> Expect.equal { column = BookList.Author, direction = BookList.Asc }
                        )
        ]


{-| A library holding two distinguishable books.
-}
loadedLibrary : ProgramTest.ProgramTest Bookshelf.Model Bookshelf.Msg (ProgramTest.SimulatedEffect Bookshelf.Msg)
loadedLibrary =
    startLibrary
        |> ProgramTest.simulateHttpResponse "GET"
            "/api/bookshelves/library"
            (simulateBookshelfResponse
                [ namedPlacement "book-dune" "Dune"
                , namedPlacement "book-solaris" "Solaris"
                ]
            )


{-| The same library, already switched into list view.
-}
inListView : ProgramTest.ProgramTest Bookshelf.Model Bookshelf.Msg (ProgramTest.SimulatedEffect Bookshelf.Msg)
inListView =
    loadedLibrary
        |> ProgramTest.simulateDomEvent (findViewModeButton "List view") Event.click


{-| The view-mode toggle buttons carry only a glyph, so address them by their
accessible name.
-}
findViewModeButton : String -> Query.Single msg -> Query.Single msg
findViewModeButton label =
    Query.find
        [ Selector.class "view-mode-toggle__btn"
        , Selector.attribute (Html.Attributes.attribute "aria-label" label)
        ]


findColumnHeader : String -> Query.Single msg -> Query.Single msg
findColumnHeader label =
    Query.find
        [ Selector.tag "th"
        , Selector.containing [ Selector.text label ]
        ]


ariaSort : String -> Selector.Selector
ariaSort value =
    Selector.attribute (Html.Attributes.attribute "aria-sort" value)


shelfErrorResponse : String -> Int -> Http.Response String
shelfErrorResponse url statusCode =
    Http.BadStatus_
        { url = url
        , statusCode = statusCode
        , statusText = "Error"
        , headers = Dict.empty
        }
        ""
