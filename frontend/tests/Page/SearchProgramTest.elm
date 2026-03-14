module Page.SearchProgramTest exposing (suite)

{-| Program tests for Page.Search using elm-program-test.

These tests exercise the Search page lifecycle through
simulated user interactions and HTTP responses.

-}

import Json.Encode as Encode
import Page.Search as Search exposing (Msg(..))
import ProgramTest
import Test exposing (Test, describe, test)
import Test.Html.Selector as Selector
import TestHelpers exposing (searchProgram, testBook)
import Types.Book exposing (Book)


{-| Helper to start a search program with an auth token.
-}
startSearch : ProgramTest.ProgramTest Search.Model Search.Msg (ProgramTest.SimulatedEffect Search.Msg)
startSearch =
    ProgramTest.start () (searchProgram (Just "test-token"))


suite : Test
suite =
    describe "Page.Search (ProgramTest)"
        [ searchDebounce
        , searchClear
        , searchEmptyResults
        , searchFilterPanelToggle
        ]


searchDebounce : Test
searchDebounce =
    test "search_debounce: type query -> advance past debounce -> receive results -> results rendered" <|
        \() ->
            startSearch
                |> ProgramTest.update (QueryChanged "habit")
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Searching..." ]
                |> ProgramTest.advanceTime 300
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/books/search?q=habit"
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
                    [ Selector.text "Searching..." ]
                |> ProgramTest.update ClearQuery
                |> ProgramTest.expectViewHas
                    [ Selector.text "Enter a search term above to find books." ]


searchEmptyResults : Test
searchEmptyResults =
    test "search_empty_results: search returns empty list -> no-results message" <|
        \() ->
            startSearch
                |> ProgramTest.update (QueryChanged "zzzznonexistent")
                |> ProgramTest.advanceTime 300
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/books/search?q=zzzznonexistent"
                    (searchResponseJson [])
                |> ProgramTest.expectViewHas
                    [ Selector.text "No books found matching your search." ]


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



-- JSON ENCODING HELPERS


{-| Encode a list of books as a JSON string for simulateHttpOk.
simulateHttpOk takes a raw JSON string body (not an Http.Response).
-}
searchResponseJson : List Book -> String
searchResponseJson books =
    Encode.encode 0
        (Encode.list encodeBookForSearch books)


encodeBookForSearch : Book -> Encode.Value
encodeBookForSearch book =
    Encode.object
        ([ ( "id", Encode.string book.id )
         , ( "isbn", Encode.string book.isbn )
         , ( "title", Encode.string book.title )
         , ( "author"
           , Encode.object
                [ ( "id", Encode.string book.author.id )
                , ( "name", Encode.string book.author.name )
                ]
           )
         , ( "subjects", Encode.list Encode.string book.subjects )
         , ( "visibility_tier", Encode.string "public" )
         ]
            ++ (case book.pageCount of
                    Just pc ->
                        [ ( "page_count", Encode.int pc ) ]

                    Nothing ->
                        []
               )
            ++ (case book.publicationYear of
                    Just py ->
                        [ ( "publication_year", Encode.int py ) ]

                    Nothing ->
                        []
               )
        )
