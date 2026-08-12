module Page.SearchProgramTest exposing (suite)

{-| Program tests for Page.Search using elm-program-test.

These tests exercise the Search page lifecycle through
simulated user interactions and HTTP responses.

-}

import Dict
import Expect
import Html.Attributes
import Http
import Json.Encode as Encode
import Page.Search as Search exposing (Msg(..))
import ProgramTest
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import TestHelpers exposing (searchProgram, testBook)
import Types.Book exposing (Book)


{-| Helper to start a search program with an auth token.
-}
startSearch : ProgramTest.ProgramTest Search.Model Search.Msg (ProgramTest.SimulatedEffect Search.Msg)
startSearch =
    ProgramTest.start () (searchProgram (Just "test-token"))


{-| Helper to start a search program for an anonymous visitor (no token). Book
search is authenticated-only, so it must fire no request; people search is
optional-auth and still runs.
-}
startSearchNoToken : ProgramTest.ProgramTest Search.Model Search.Msg (ProgramTest.SimulatedEffect Search.Msg)
startSearchNoToken =
    ProgramTest.start () (searchProgram Nothing)


suite : Test
suite =
    describe "Page.Search (ProgramTest)"
        [ searchUrlIsApiSearch
        , searchDebounce
        , searchClear
        , searchEmptyResults
        , searchFilterPanelToggle
        , searchFailure
        , searchStaleDebounce
        , searchNoTokenFiresNoBookRequest
        , sortDefaultRelevance
        , sortByTitleSelected
        , sortByAuthor
        , sortByYear
        , sortByRelevanceSelected
        , filterAwareEmptyState
        , undatedVisibleUnderFilter
        , yearFilterAndClear
        , readersResults
        , readersEmptyResults
        , readersFailure
        , readers401RaisesSessionExpired
        , resultClickEmitsOpenOverlay
        , resultRendersAsButtonWithStableId
        , collectionAndPlatformSectionsRender
        , collectionAbovePlatform
        , collectionShelfLabel
        , collectionShelfLabelNamesEveryShelf
        , collectionShelfLabelJoinsThreeAsProse
        , platformLookingForHomeLabel
        , platformListedLabel
        , platformPlainHitHasNoLabel
        , emptyCollectionHidesSection
        , emptyPlatformHidesSection
        , sortWithinEachSection
        , collectionResultRendersAsButton
        , deepToggleRefiresWithScopeDeep
        , defaultScopeEmitsNoScopeParam
        , deepToggleOffRefiresWithoutScope
        , snippetAndLabelRenderWhenSnippetPresent
        , highlightRendersAsMarkElement
        , noSnippetNoLabelWhenSnippetEmpty
        , searchInputHasAccessibleName
        ]


{-| The search field's only visible cue is its placeholder, which is not an
accessible name — it disappears the moment the reader types and several screen
readers ignore it entirely. So the input carries an explicit `aria-label`, and
this asserts it is present and matches the placeholder copy (TR-6).
-}
searchInputHasAccessibleName : Test
searchInputHasAccessibleName =
    test "search_input_has_accessible_name: the search field carries an aria-label" <|
        \() ->
            startSearch
                |> ProgramTest.expectViewHas
                    [ Selector.attribute
                        (Html.Attributes.attribute "aria-label" "Search by title, author, or ISBN...")
                    ]


{-| The book-search request must target `GET /api/search` — the route the
backend actually serves (`router.ex`, alongside `/api/search/users`). Before
the fix the client built `/api/books/search`, which 404s live; this asserts
the requested URL so the mismatch can never silently return.
-}
searchUrlIsApiSearch : Test
searchUrlIsApiSearch =
    test "search_url: book-search request targets /api/search (not /api/books/search)" <|
        \() ->
            startSearch
                |> ProgramTest.update (QueryChanged "habit")
                |> ProgramTest.advanceTime 300
                |> ProgramTest.expectHttpRequestWasMade "GET" "/api/search?q=habit"


readersFailure : Test
readersFailure =
    test "readers_failure: a failed people-search renders the reader error banner" <|
        \() ->
            startSearch
                |> ProgramTest.update (QueryChanged "ada")
                |> ProgramTest.advanceTime 300
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/search/users?q=ada"
                    (Http.BadStatus_
                        { url = "/api/search/users?q=ada"
                        , statusCode = 500
                        , statusText = "Internal Server Error"
                        , headers = Dict.empty
                        }
                        "{\"error\":\"boom\"}"
                    )
                |> ProgramTest.expectViewHas
                    [ Selector.text "We couldn't reach the shelves just now. Give it a moment and try again." ]


{-| A 401 from people-search must raise `SessionExpired` (so Main routes to the
session-expiry flow). The `OutMsg` is swallowed by the ProgramTest harness, so
this asserts the update contract directly.
-}
readers401RaisesSessionExpired : Test
readers401RaisesSessionExpired =
    test "readers_401_session_expired: a 401 from people-search raises SessionExpired" <|
        \() ->
            let
                ( _, _, outMsg ) =
                    Search.update
                        (ReadersCompleted (Err (Http.BadStatus 401)))
                        Search.init
                        (Just "test-token")
            in
            Expect.equal outMsg Search.SessionExpired


readersResults : Test
readersResults =
    test "readers_results: query -> receive readers -> profile cards link to /u/:handle" <|
        \() ->
            startSearch
                |> ProgramTest.update (QueryChanged "ada")
                |> ProgramTest.advanceTime 300
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/search/users?q=ada"
                    (readersResponseJson [ ( "adal", "Ada Lovelace" ) ])
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Readers" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Ada Lovelace" ]
                |> ProgramTest.expectViewHas
                    [ Selector.attribute (Html.Attributes.href "/u/adal") ]


readersEmptyResults : Test
readersEmptyResults =
    test "readers_empty: query -> empty readers list -> empty state" <|
        \() ->
            startSearch
                |> ProgramTest.update (QueryChanged "zzz")
                |> ProgramTest.advanceTime 300
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/search/users?q=zzz"
                    (readersResponseJson [])
                |> ProgramTest.expectViewHas
                    [ Selector.text "No readers found matching your search." ]


searchDebounce : Test
searchDebounce =
    test "search_debounce: type query -> advance past debounce -> receive results -> results rendered" <|
        \() ->
            startSearch
                |> ProgramTest.update (QueryChanged "habit")
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Searching the stacks…" ]
                |> ProgramTest.advanceTime 300
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/search?q=habit"
                    (searchResponseJson [ testBook ])
                |> ProgramTest.ensureViewHas
                    [ Selector.class "search-results" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.text "The Power of Habit" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "Charles Duhigg" ]


searchClear : Test
searchClear =
    test "search_clear: type query -> clear -> no results shown, hint visible" <|
        \() ->
            startSearch
                |> ProgramTest.update (QueryChanged "something")
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Searching the stacks…" ]
                |> ProgramTest.update ClearQuery
                |> ProgramTest.expectViewHas
                    [ Selector.text "Type a title, author, or ISBN to search the stacks." ]


searchEmptyResults : Test
searchEmptyResults =
    test "search_empty_results: search returns empty list -> no-results message" <|
        \() ->
            startSearch
                |> ProgramTest.update (QueryChanged "zzzznonexistent")
                |> ProgramTest.advanceTime 300
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/search?q=zzzznonexistent"
                    (searchResponseJson [])
                |> ProgramTest.expectViewHas
                    [ Selector.text "Nothing on the shelves matches that — yet." ]


searchFilterPanelToggle : Test
searchFilterPanelToggle =
    test "search_filter_panel_toggle: toggle open -> visible, toggle again -> hidden" <|
        \() ->
            startSearch
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Show Filters" ]
                |> ProgramTest.clickButton "Show Filters"
                |> ProgramTest.ensureViewHas
                    [ Selector.class "filter-panel__body" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Hide Filters" ]
                |> ProgramTest.clickButton "Hide Filters"
                |> ProgramTest.expectViewHasNot
                    [ Selector.class "filter-panel__body" ]


searchFailure : Test
searchFailure =
    test "search_failure: a failed book-search renders the error banner" <|
        \() ->
            startSearch
                |> ProgramTest.update (QueryChanged "habit")
                |> ProgramTest.advanceTime 300
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/search?q=habit"
                    (Http.BadStatus_
                        { url = "/api/search?q=habit"
                        , statusCode = 500
                        , statusText = "Internal Server Error"
                        , headers = Dict.empty
                        }
                        "{\"error\":\"boom\"}"
                    )
                |> ProgramTest.expectViewHas
                    [ Selector.text "We couldn't reach the shelves just now. Give it a moment and try again." ]


{-| A stale debounce must not fire a request. Typing twice schedules two
`DebounceExpired` timers; advancing past the debounce delivers both, but only
the timer whose count matches `model.debounceCount` (the latest query) may fire
the book-search request. Asserting exactly one request to the final query proves
the earlier (stale) timer was a no-op (`Page.Search.update`, `DebounceExpired`).
-}
searchStaleDebounce : Test
searchStaleDebounce =
    test "search_stale_debounce: only the latest debounce fires a book-search request" <|
        \() ->
            startSearch
                |> ProgramTest.update (QueryChanged "a")
                |> ProgramTest.update (QueryChanged "ab")
                |> ProgramTest.advanceTime 300
                |> ProgramTest.ensureHttpRequests "GET"
                    "/api/search?q=a"
                    (\requests -> Expect.equal 0 (List.length requests))
                |> ProgramTest.expectHttpRequests "GET"
                    "/api/search?q=ab"
                    (\requests -> Expect.equal 1 (List.length requests))


{-| With no auth token the authenticated-only book search must fire no request
(results stay `NotAsked` → the entry hint remains), while the optional-auth
people search still runs (`Page.Search.update`, `DebounceExpired`).
-}
searchNoTokenFiresNoBookRequest : Test
searchNoTokenFiresNoBookRequest =
    test "search_no_token: anonymous visitor fires no book-search request; readers search unaffected" <|
        \() ->
            startSearchNoToken
                |> ProgramTest.update (QueryChanged "habit")
                |> ProgramTest.advanceTime 300
                |> ProgramTest.ensureHttpRequests "GET"
                    "/api/search?q=habit"
                    (\requests -> Expect.equal 0 (List.length requests))
                |> ProgramTest.ensureHttpRequestWasMade "GET" "/api/search/users?q=habit"
                |> ProgramTest.expectViewHas
                    [ Selector.text "Type a title, author, or ISBN to search the stacks." ]


{-| Three books whose server (insertion) order is Zebra, Middle, Alpha, chosen
so each sort produces a different visible order:

  - server / DateAdded: Zebra Tales, Middle Ground, Alpha Dawn
  - Title asc: Alpha Dawn, Middle Ground, Zebra Tales
  - Author asc (Anna, Mike, Zoe): Alpha Dawn, Zebra Tales, Middle Ground
  - Year asc (1999, 2001, 2010): Middle Ground, Zebra Tales, Alpha Dawn

-}
sortFixtures : List Book
sortFixtures =
    [ fixtureBook "Zebra Tales" "Mike Rivers" 2001
    , fixtureBook "Middle Ground" "Zoe Quill" 1999
    , fixtureBook "Alpha Dawn" "Anna Blake" 2010
    ]


fixtureBook : String -> String -> Int -> Book
fixtureBook title authorNm year =
    { testBook
        | id = "book-" ++ title
        , title = title
        , author = Just { id = "author-" ++ authorNm, name = authorNm, bio = Nothing, website = Nothing }
        , primaryEdition =
            testBook.primaryEdition
                |> Maybe.map (\ed -> { ed | id = "edition-" ++ title, publicationYear = Just year })
    }


{-| Start a search, load `sortFixtures` as the results, ready for a sort/filter
message to be dispatched and the rendered order asserted.
-}
loadedThreeBooks : ProgramTest.ProgramTest Search.Model Search.Msg (ProgramTest.SimulatedEffect Search.Msg)
loadedThreeBooks =
    startSearch
        |> ProgramTest.update (QueryChanged "book")
        |> ProgramTest.advanceTime 300
        |> ProgramTest.simulateHttpOk "GET"
            "/api/search?q=book"
            (searchResponseJson sortFixtures)


{-| Assert the rendered `.search-result__title` elements are exactly `titles`,
in order.
-}
expectResultTitleOrder : List String -> ProgramTest.ProgramTest Search.Model Search.Msg (ProgramTest.SimulatedEffect Search.Msg) -> Expect.Expectation
expectResultTitleOrder titles =
    ProgramTest.expectView
        (\view ->
            Query.findAll [ Selector.class "search-result__title" ] view
                |> Expect.all
                    (Query.count (Expect.equal (List.length titles))
                        :: List.indexedMap
                            (\i title ->
                                Query.index i >> Query.has [ Selector.text title ]
                            )
                            titles
                    )
        )


sortByTitleSelected : Test
sortByTitleSelected =
    test "sort_by_title: SortChanged title re-orders rendered results title-ascending" <|
        \() ->
            loadedThreeBooks
                |> ProgramTest.update (SortChanged "title")
                |> expectResultTitleOrder
                    [ "Alpha Dawn", "Middle Ground", "Zebra Tales" ]


sortByAuthor : Test
sortByAuthor =
    test "sort_by_author: SortChanged author re-orders rendered results by author" <|
        \() ->
            loadedThreeBooks
                |> ProgramTest.update (SortChanged "author")
                |> expectResultTitleOrder
                    [ "Alpha Dawn", "Zebra Tales", "Middle Ground" ]


sortByYear : Test
sortByYear =
    test "sort_by_year: SortChanged year re-orders rendered results by publication year" <|
        \() ->
            loadedThreeBooks
                |> ProgramTest.update (SortChanged "year")
                |> expectResultTitleOrder
                    [ "Middle Ground", "Zebra Tales", "Alpha Dawn" ]


{-| Selecting "Relevance" after another sort restores the server order — proving
the passthrough is reachable from the selector, not just the default.
-}
sortByRelevanceSelected : Test
sortByRelevanceSelected =
    test "sort_by_relevance: SortChanged relevance restores server (relevance) order" <|
        \() ->
            loadedThreeBooks
                |> ProgramTest.update (SortChanged "author")
                |> ProgramTest.update (SortChanged "relevance")
                |> expectResultTitleOrder
                    [ "Zebra Tales", "Middle Ground", "Alpha Dawn" ]


sortDefaultRelevance : Test
sortDefaultRelevance =
    test "sort_default_relevance: results render in server (relevance) order by default" <|
        \() ->
            loadedThreeBooks
                |> expectResultTitleOrder
                    [ "Zebra Tales", "Middle Ground", "Alpha Dawn" ]


filterAwareEmptyState : Test
filterAwareEmptyState =
    test "filter_aware_empty: a year range that empties matched results shows filter-aware copy" <|
        \() ->
            loadedThreeBooks
                |> ProgramTest.update (YearFromChanged "3000")
                |> ProgramTest.expectViewHas
                    [ Selector.text "No books in that year range — widen it or clear filters" ]


undatedVisibleUnderFilter : Test
undatedVisibleUnderFilter =
    test "undated_visible: an undated book stays visible under a year bound, labelled Unknown year" <|
        \() ->
            startSearch
                |> ProgramTest.update (QueryChanged "book")
                |> ProgramTest.advanceTime 300
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/search?q=book"
                    (searchResponseJson [ fixtureBook "Dated Book" "Anna Blake" 2001, undatedBook ])
                |> ProgramTest.update (YearFromChanged "2000")
                |> ProgramTest.ensureViewHas
                    [ Selector.text "No Year Book" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "Unknown year" ]


{-| A fixture book with no publication year, for the undated-treatment tests.
-}
undatedBook : Book
undatedBook =
    { testBook
        | id = "book-undated"
        , title = "No Year Book"
        , author = Just { id = "author-noyear", name = "Nemo Undated", bio = Nothing, website = Nothing }
        , primaryEdition =
            testBook.primaryEdition
                |> Maybe.map (\ed -> { ed | id = "edition-undated", publicationYear = Nothing })
    }


yearFilterAndClear : Test
yearFilterAndClear =
    test "year_filter: a year range filters rendered results; ClearFilters restores them" <|
        \() ->
            loadedThreeBooks
                |> ProgramTest.update (YearFromChanged "2000")
                |> ProgramTest.update (YearToChanged "2005")
                |> ProgramTest.ensureView
                    (\view ->
                        Query.findAll [ Selector.class "search-result__title" ] view
                            |> Expect.all
                                [ Query.count (Expect.equal 1)
                                , Query.index 0 >> Query.has [ Selector.text "Zebra Tales" ]
                                ]
                    )
                |> ProgramTest.update ClearFilters
                |> expectResultTitleOrder
                    [ "Zebra Tales", "Middle Ground", "Alpha Dawn" ]


{-| Activating a result must emit `OpenOverlay <bookId>` — the OutMsg Main turns
into an overlay-open with a `search-result-<bookId>` focus-return trigger. The
harness swallows the OutMsg, so assert the update contract directly.
-}
resultClickEmitsOpenOverlay : Test
resultClickEmitsOpenOverlay =
    test "result_click_open_overlay: BookClicked emits OpenOverlay for that book id" <|
        \() ->
            let
                ( _, _, outMsg ) =
                    Search.update
                        (BookClicked "book-Zebra Tales")
                        Search.init
                        (Just "test-token")
            in
            Expect.equal outMsg (Search.OpenOverlay "book-Zebra Tales")


{-| Each result renders as a real `<button>` (natively keyboard-focusable and
Enter/Space-activatable) carrying `id="search-result-<bookId>"` — the stable
element id Main hands the overlay as the focus-return trigger. A
plain div with an onClick would fail both the tag and the id assertion.
-}
resultRendersAsButtonWithStableId : Test
resultRendersAsButtonWithStableId =
    test "result_button_stable_id: a result renders as a <button> with id search-result-<bookId>" <|
        \() ->
            loadedThreeBooks
                |> ProgramTest.expectView
                    (\view ->
                        Query.findAll
                            [ Selector.tag "button"
                            , Selector.id "search-result-book-Zebra Tales"
                            ]
                            view
                            |> Expect.all
                                [ Query.count (Expect.equal 1)
                                , Query.index 0 >> Query.has [ Selector.text "Zebra Tales" ]
                                ]
                    )


{-| A collection hit and a platform hit both present: both section headings
render, each with its book.
-}
collectionAndPlatformSectionsRender : Test
collectionAndPlatformSectionsRender =
    test "sections_render: a collection hit and a platform hit render both section headings" <|
        \() ->
            loadedSections
                [ collectionHit "library" (fixtureBook "Mine Own" "Anna Blake" 2001) ]
                [ plainPlatformHit (fixtureBook "Out There" "Zoe Quill" 1999) ]
                |> ProgramTest.ensureViewHas [ Selector.text "Your Collection" ]
                |> ProgramTest.ensureViewHas [ Selector.text "On the Platform" ]
                |> ProgramTest.ensureViewHas [ Selector.text "Mine Own" ]
                |> ProgramTest.expectViewHas [ Selector.text "Out There" ]


{-| "Your Collection" renders ABOVE "On the Platform" — the section titles appear
in that DOM order.
-}
collectionAbovePlatform : Test
collectionAbovePlatform =
    test "section_order: Your Collection renders above On the Platform" <|
        \() ->
            loadedSections
                [ collectionHit "library" (fixtureBook "Mine Own" "Anna Blake" 2001) ]
                [ plainPlatformHit (fixtureBook "Out There" "Zoe Quill" 1999) ]
                |> ProgramTest.expectView
                    (\view ->
                        Query.findAll [ Selector.class "search-section__title" ] view
                            |> Expect.all
                                [ Query.count (Expect.equal 2)
                                , Query.index 0 >> Query.has [ Selector.text "Your Collection" ]
                                , Query.index 1 >> Query.has [ Selector.text "On the Platform" ]
                                ]
                    )


{-| A collection hit shows which shelf it sits on, with the raw bookshelf name
humanised (`reading_pile` -> "Reading Pile").
-}
collectionShelfLabel : Test
collectionShelfLabel =
    test "collection_shelf_label: a collection hit shows 'On your <Shelf> shelf'" <|
        \() ->
            loadedSections
                [ collectionHit "reading_pile" (fixtureBook "Mine Own" "Anna Blake" 2001) ]
                []
                |> ProgramTest.expectViewHas [ Selector.text "On your Reading Pile shelf" ]


{-| — the annotation must name EVERY bookshelf a book sits on. It used to
name one and silently drop the rest, which looked exactly like the whole truth:
a book on the Wish List and the Reading Pile was reported as "On your Wish List
shelf" and the reader had no way to know otherwise.
-}
collectionShelfLabelNamesEveryShelf : Test
collectionShelfLabelNamesEveryShelf =
    test "collection_shelf_label_multi: a two-shelf hit names both, not just the first" <|
        \() ->
            loadedSections
                [ multiShelfCollectionHit [ "library", "wishlist" ]
                    (fixtureBook "Mine Own" "Anna Blake" 2001)
                ]
                []
                |> ProgramTest.expectViewHas
                    [ Selector.text "On your Library and Wish List shelves" ]


{-| Three shelves join as prose ("A, B and C") rather than as a comma soup, and
the noun stays plural.
-}
collectionShelfLabelJoinsThreeAsProse : Test
collectionShelfLabelJoinsThreeAsProse =
    test "collection_shelf_label_three: three shelves read as 'A, B and C shelves'" <|
        \() ->
            loadedSections
                [ multiShelfCollectionHit [ "antilibrary", "library", "reading_pile" ]
                    (fixtureBook "Mine Own" "Anna Blake" 2001)
                ]
                []
                |> ProgramTest.expectViewHas
                    [ Selector.text "On your Antilibrary, Library and Reading Pile shelves" ]


{-| An always-visible looking-for-home platform hit is labelled with the owner's
handle.
-}
platformLookingForHomeLabel : Test
platformLookingForHomeLabel =
    test "platform_lfh_label: a looking_for_home hit shows 'Looking for a home on <handle>'s shelf'" <|
        \() ->
            loadedSections
                []
                [ lookingForHomeHit "adal" (fixtureBook "Out There" "Zoe Quill" 1999) ]
                |> ProgramTest.expectViewHas [ Selector.text "Looking for a home on adal's shelf" ]


{-| An active marketplace listing platform hit is labelled with the seller's
handle and the (server-formatted) price.
-}
platformListedLabel : Test
platformListedLabel =
    test "platform_listed_label: a listed hit shows 'Listed by <handle> for <price>'" <|
        \() ->
            loadedSections
                []
                [ listedHit "adal" "R120.00" (fixtureBook "Out There" "Zoe Quill" 1999) ]
                |> ProgramTest.expectViewHas [ Selector.text "Listed by adal for R120.00" ]


{-| A plain platform hit (empty source) carries no label line at all — only
label-bearing hits (LFH / listed / a collection shelf) render `search-result__label`.
-}
platformPlainHitHasNoLabel : Test
platformPlainHitHasNoLabel =
    test "platform_plain_no_label: a plain platform hit renders no label line" <|
        \() ->
            loadedSections
                []
                [ plainPlatformHit (fixtureBook "Out There" "Zoe Quill" 1999) ]
                |> ProgramTest.ensureViewHas [ Selector.text "Out There" ]
                |> ProgramTest.expectViewHasNot [ Selector.class "search-result__label" ]


{-| With no collection hits, the "Your Collection" section is hidden entirely —
an empty-collection viewer sees the platform-only view.
-}
emptyCollectionHidesSection : Test
emptyCollectionHidesSection =
    test "empty_collection_hides: no collection hits -> Your Collection section absent" <|
        \() ->
            loadedSections
                []
                [ plainPlatformHit (fixtureBook "Out There" "Zoe Quill" 1999) ]
                |> ProgramTest.ensureViewHas [ Selector.text "On the Platform" ]
                |> ProgramTest.expectViewHasNot [ Selector.text "Your Collection" ]


{-| With no platform hits, the "On the Platform" section is hidden entirely.
-}
emptyPlatformHidesSection : Test
emptyPlatformHidesSection =
    test "empty_platform_hides: no platform hits -> On the Platform section absent" <|
        \() ->
            loadedSections
                [ collectionHit "library" (fixtureBook "Mine Own" "Anna Blake" 2001) ]
                []
                |> ProgramTest.ensureViewHas [ Selector.text "Your Collection" ]
                |> ProgramTest.expectViewHasNot [ Selector.text "On the Platform" ]


{-| Sort applies WITHIN each section independently: a title sort orders the
collection rows and the platform rows each ascending, not across the two.
-}
sortWithinEachSection : Test
sortWithinEachSection =
    test "sort_within_section: title sort orders each section independently" <|
        \() ->
            loadedSections
                [ collectionHit "library" (fixtureBook "Collection Zed" "Anna Blake" 2000)
                , collectionHit "library" (fixtureBook "Collection Alpha" "Anna Blake" 2001)
                ]
                [ plainPlatformHit (fixtureBook "Platform Zed" "Zoe Quill" 2002)
                , plainPlatformHit (fixtureBook "Platform Alpha" "Zoe Quill" 2003)
                ]
                |> ProgramTest.update (SortChanged "title")
                |> ProgramTest.expectView
                    (\view ->
                        Expect.all
                            [ \v ->
                                Query.find [ Selector.class "search-section--collection" ] v
                                    |> Query.findAll [ Selector.class "search-result__title" ]
                                    |> Expect.all
                                        [ Query.index 0 >> Query.has [ Selector.text "Collection Alpha" ]
                                        , Query.index 1 >> Query.has [ Selector.text "Collection Zed" ]
                                        ]
                            , \v ->
                                Query.find [ Selector.class "search-section--platform" ] v
                                    |> Query.findAll [ Selector.class "search-result__title" ]
                                    |> Expect.all
                                        [ Query.index 0 >> Query.has [ Selector.text "Platform Alpha" ]
                                        , Query.index 1 >> Query.has [ Selector.text "Platform Zed" ]
                                        ]
                            ]
                            view
                    )


{-| A collection result is the same keyboard-operable `<button>` carrying the
stable `search-result-<bookId>` focus-return id as a platform result —
proving the click surface is shared across both sections.
-}
collectionResultRendersAsButton : Test
collectionResultRendersAsButton =
    test "collection_button_stable_id: a collection hit renders as a <button> with its stable id" <|
        \() ->
            loadedSections
                [ collectionHit "library" (fixtureBook "Mine Own" "Anna Blake" 2001) ]
                []
                |> ProgramTest.expectView
                    (\view ->
                        Query.findAll
                            [ Selector.tag "button"
                            , Selector.id "search-result-book-Mine Own"
                            ]
                            view
                            |> Expect.all
                                [ Query.count (Expect.equal 1)
                                , Query.index 0 >> Query.has [ Selector.text "Mine Own" ]
                                ]
                    )


{-| Toggling deep search ON with a non-empty query re-fires the book search with
`scope=deep` appended — the signal the backend reads to match descriptions.
-}
deepToggleRefiresWithScopeDeep : Test
deepToggleRefiresWithScopeDeep =
    test "deep_toggle_refires: toggling deep ON re-queries with scope=deep" <|
        \() ->
            startSearch
                |> ProgramTest.update (QueryChanged "book")
                |> ProgramTest.advanceTime 300
                |> ProgramTest.update (DeepSearchToggled True)
                |> ProgramTest.expectHttpRequestWasMade "GET" "/api/search?q=book&scope=deep"


{-| The default (deep OFF) search emits NO scope param — the request URL stays
`/api/search?q=…` exactly, so the backend's default title-only behaviour is
unchanged. Asserting zero `scope=deep` requests proves the param is opt-in only.
-}
defaultScopeEmitsNoScopeParam : Test
defaultScopeEmitsNoScopeParam =
    test "default_scope_no_param: the default search emits no scope=deep param" <|
        \() ->
            startSearch
                |> ProgramTest.update (QueryChanged "book")
                |> ProgramTest.advanceTime 300
                |> ProgramTest.ensureHttpRequests "GET"
                    "/api/search?q=book&scope=deep"
                    (\requests -> Expect.equal 0 (List.length requests))
                |> ProgramTest.expectHttpRequestWasMade "GET" "/api/search?q=book"


{-| Toggling deep OFF (after ON) re-fires the query WITHOUT the scope param. The
initial debounce already fired `/api/search?q=book` once; the OFF toggle fires it
again, so exactly two such requests exist — proving the OFF path re-queries too
(not that it merely left the earlier request standing).
-}
deepToggleOffRefiresWithoutScope : Test
deepToggleOffRefiresWithoutScope =
    test "deep_toggle_off_refires: toggling deep OFF re-queries without scope" <|
        \() ->
            startSearch
                |> ProgramTest.update (QueryChanged "book")
                |> ProgramTest.advanceTime 300
                |> ProgramTest.update (DeepSearchToggled True)
                |> ProgramTest.ensureHttpRequestWasMade "GET" "/api/search?q=book&scope=deep"
                |> ProgramTest.update (DeepSearchToggled False)
                |> ProgramTest.expectHttpRequests "GET"
                    "/api/search?q=book"
                    (\requests -> Expect.equal 2 (List.length requests))


{-| A deep-matched result (non-empty snippet) renders the highlighted excerpt in
`search-result__snippet` and a "via deep search" provenance line.
-}
snippetAndLabelRenderWhenSnippetPresent : Test
snippetAndLabelRenderWhenSnippetPresent =
    test "snippet_renders: a deep-matched hit renders its snippet + 'via deep search'" <|
        \() ->
            loadedSections
                []
                [ plainPlatformHit (fixtureBook "Deep Match" "Anna Blake" 2001)
                    |> withSnippet "the <mark>habit</mark> loop"
                ]
                |> ProgramTest.ensureViewHas [ Selector.class "search-result__snippet" ]
                |> ProgramTest.ensureViewHas [ Selector.text "habit" ]
                |> ProgramTest.expectViewHas [ Selector.text "via deep search" ]


{-| The `<mark>` run in a snippet renders as a real `<mark>` element carrying the
highlighted text — proving the markup was parsed into a styled element, not
injected as raw HTML (which Elm cannot do without a port anyway).
-}
highlightRendersAsMarkElement : Test
highlightRendersAsMarkElement =
    test "snippet_highlight_mark: a <mark> run renders as a <mark> element" <|
        \() ->
            loadedSections
                []
                [ plainPlatformHit (fixtureBook "Deep Match" "Anna Blake" 2001)
                    |> withSnippet "a <mark>habit</mark> b"
                ]
                |> ProgramTest.expectView
                    (\view ->
                        Query.findAll [ Selector.tag "mark", Selector.text "habit" ] view
                            |> Query.count (Expect.equal 1)
                    )


{-| A title match (empty snippet) renders NEITHER the snippet block NOR the "via
deep search" label — the excerpt is shown only when the match was on description
/review text.
-}
noSnippetNoLabelWhenSnippetEmpty : Test
noSnippetNoLabelWhenSnippetEmpty =
    test "no_snippet_no_label: a title match (empty snippet) renders no snippet/label" <|
        \() ->
            loadedSections
                []
                [ plainPlatformHit (fixtureBook "Title Match" "Anna Blake" 2001) ]
                |> ProgramTest.ensureViewHas [ Selector.text "Title Match" ]
                |> ProgramTest.ensureViewHasNot [ Selector.text "via deep search" ]
                |> ProgramTest.expectViewHasNot [ Selector.class "search-result__snippet" ]


{-| A test-side search hit mirroring the proto `SearchHit` wire shape
(`book`, `source`, `owner_handle`, `price`, `bookshelf_name`, `snippet`). The
constructors below build the shapes the backend emits; `snippet` defaults to ""
(a title match) and `withSnippet` sets a deep-search description/review excerpt.
-}
type alias TestHit =
    { book : Book
    , source : String
    , ownerHandle : String
    , price : String
    , bookshelfName : String
    , bookshelfNames : List String
    , snippet : String
    }


{-| A collection hit: the viewer's own book, tagged with its (raw) bookshelf name,
no label fields.
-}
collectionHit : String -> Book -> TestHit
collectionHit bookshelfName book =
    { book = book, source = "", ownerHandle = "", price = "", bookshelfName = bookshelfName, bookshelfNames = [ bookshelfName ], snippet = "" }


{-| A collection hit sitting on SEVERAL of the viewer's bookshelves — a
legal state. `bookshelf_name` carries the first, exactly as the backend emits it
for wire compatibility; `bookshelf_names` carries them all.
-}
multiShelfCollectionHit : List String -> Book -> TestHit
multiShelfCollectionHit names book =
    { book = book
    , source = ""
    , ownerHandle = ""
    , price = ""
    , bookshelfName = Maybe.withDefault "" (List.head names)
    , bookshelfNames = names
    , snippet = ""
    }


{-| A plain platform hit: a platform-visible book with no discoverable label.
-}
plainPlatformHit : Book -> TestHit
plainPlatformHit book =
    { book = book, source = "", ownerHandle = "", price = "", bookshelfName = "", bookshelfNames = [], snippet = "" }


{-| An always-visible looking-for-home platform hit, carrying the owner handle.
-}
lookingForHomeHit : String -> Book -> TestHit
lookingForHomeHit ownerHandle book =
    { book = book, source = "looking_for_home", ownerHandle = ownerHandle, price = "", bookshelfName = "", bookshelfNames = [], snippet = "" }


{-| An active-listing platform hit, carrying the seller handle and formatted price.
-}
listedHit : String -> String -> Book -> TestHit
listedHit ownerHandle price book =
    { book = book, source = "listed", ownerHandle = ownerHandle, price = price, bookshelfName = "", bookshelfNames = [], snippet = "" }


{-| Attach a deep-search snippet (a `ts_headline` `<mark>` excerpt) to any hit —
the wire signal that the match was on the description/review, not the title.
-}
withSnippet : String -> TestHit -> TestHit
withSnippet snippet hit =
    { hit | snippet = snippet }


{-| Start a search and load the given collection + platform hits through the real
sectioned wire shape, ready for further messages / assertions.
-}
loadedSections : List TestHit -> List TestHit -> ProgramTest.ProgramTest Search.Model Search.Msg (ProgramTest.SimulatedEffect Search.Msg)
loadedSections collection platform =
    startSearch
        |> ProgramTest.update (QueryChanged "book")
        |> ProgramTest.advanceTime 300
        |> ProgramTest.simulateHttpOk "GET"
            "/api/search?q=book"
            (sectionedResponseJson collection platform)


{-| Encode a single `SearchHit` in the proto wire shape.
-}
encodeSearchHit : TestHit -> Encode.Value
encodeSearchHit hit =
    Encode.object
        [ ( "book", encodeBookForSearch hit.book )
        , ( "source", Encode.string hit.source )
        , ( "owner_handle", Encode.string hit.ownerHandle )
        , ( "price", Encode.string hit.price )
        , ( "bookshelf_name", Encode.string hit.bookshelfName )
        , ( "bookshelf_names", Encode.list Encode.string hit.bookshelfNames )
        , ( "snippet", Encode.string hit.snippet )
        ]


{-| Encode the full sectioned `SearchResponse` wire shape — `collection` and
`platform_hits` are what the page reads; `results` is kept for wire fidelity
(the legacy flat list the backend still emits) though the page no longer reads it.
-}
sectionedResponseJson : List TestHit -> List TestHit -> String
sectionedResponseJson collection platform =
    let
        allBooks =
            List.map .book collection ++ List.map .book platform
    in
    Encode.encode 0
        (Encode.object
            [ ( "query", Encode.string "test" )
            , ( "count", Encode.int (List.length allBooks) )
            , ( "results", Encode.list encodeBookForSearch allBooks )
            , ( "collection", Encode.list encodeSearchHit collection )
            , ( "platform_hits", Encode.list encodeSearchHit platform )
            ]
        )


{-| Encode a search response as a JSON string for simulateHttpOk.

The generic fixtures aren't tied to the viewer, so they land in the PLATFORM
section as plain (source "") hits — rendered as bare rows, the pre-sectioning
behaviour these existing tests assert. Every simulated book-search response goes
through the sectioned builder so the mirror can't drift from the real wire shape.

-}
searchResponseJson : List Book -> String
searchResponseJson books =
    sectionedResponseJson [] (List.map plainPlatformHit books)


{-| Encode a `{ users: [...] }` people-search response. Each tuple is
`(handle, display_name)`.
-}
readersResponseJson : List ( String, String ) -> String
readersResponseJson people =
    Encode.encode 0
        (Encode.object
            [ ( "users"
              , Encode.list
                    (\( handle, displayName ) ->
                        Encode.object
                            [ ( "handle", Encode.string handle )
                            , ( "display_name", Encode.string displayName )
                            , ( "city", Encode.string "" )
                            , ( "country_code", Encode.string "" )
                            ]
                    )
                    people
              )
            ]
        )


encodeBookForSearch : Book -> Encode.Value
encodeBookForSearch book =
    Encode.object
        ([ ( "id", Encode.string book.id )
         , ( "title", Encode.string book.title )
         , ( "author"
           , case book.author of
                Just author ->
                    Encode.object
                        [ ( "id", Encode.string author.id )
                        , ( "name", Encode.string author.name )
                        ]

                Nothing ->
                    Encode.null
           )
         , ( "editions", Encode.list identity [] )
         , ( "edition_count", Encode.int 0 )
         , ( "subjects", Encode.list Encode.string book.subjects )
         , ( "visibility_tier", Encode.string "public" )
         ]
            ++ (case book.primaryEdition of
                    Just ed ->
                        [ ( "primary_edition"
                          , Encode.object
                                ([ ( "id", Encode.string ed.id )
                                 , ( "isbn", Encode.string ed.isbn )
                                 , ( "is_primary", Encode.bool True )
                                 ]
                                    ++ (case ed.publicationYear of
                                            Just year ->
                                                [ ( "publication_year", Encode.int year ) ]

                                            Nothing ->
                                                []
                                       )
                                )
                          )
                        ]

                    Nothing ->
                        []
               )
        )
