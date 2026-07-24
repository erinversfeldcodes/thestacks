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
        ]


{-| The book-search request must target `GET /api/search` — the route the
backend actually serves (`router.ex`, alongside `/api/search/users`). Before
the #115 fix the client built `/api/books/search`, which 404s live; this asserts
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



-- SORT / FILTER (view-level) --------------------------------------------------
--
-- These assert the RENDERED order and membership of `.search-results`, not just
-- model state: sort and year-filter are applied by `Page.Search.view` to the
-- Success books list before rendering. Fixtures are chosen so every SortOrder
-- and the year filter produce a distinct visible order from the server order.


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



-- JSON ENCODING HELPERS


{-| Encode a search response as a JSON string for simulateHttpOk.

This mirrors the REAL `SearchController.index` wire shape — an object
`{"query": ..., "count": N, "results": [...]}` (search\_controller.ex:18-22) —
NOT a bare top-level array. Every simulated book-search response goes through
here so the mirror can't drift back to a bare-list fiction.

-}
searchResponseJson : List Book -> String
searchResponseJson books =
    Encode.encode 0
        (Encode.object
            [ ( "query", Encode.string "test" )
            , ( "count", Encode.int (List.length books) )
            , ( "results", Encode.list encodeBookForSearch books )
            ]
        )


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
