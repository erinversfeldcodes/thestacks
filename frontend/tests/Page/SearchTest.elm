module Page.SearchTest exposing (suite)

{-| Pure unit tests for `Page.Search` init and the client-side update
transitions (`SortChanged`, `YearFrom/YearToChanged`, `ClearFilters`).

These assert the model-level result of each message in isolation. They
complement — they do not replace — the authoritative view-level assertions in
`SearchProgramTest.elm`, which prove that `Page.Search.view` actually applies
`model.sort` and `model.filters` to re-order and filter the rendered
`.search-results` (the sort/order/membership behaviour). Keeping the transition
checks here as well pins down the `SortOrder` mapping and year parsing directly,
without threading a full loaded-results program through each case.

-}

import Components.FilterPanel exposing (SortOrder(..), defaultFilterState)
import Expect
import Page.Search as Search exposing (Msg(..))
import Test exposing (Test, describe, test)
import Types.RemoteData exposing (RemoteData(..))


suite : Test
suite =
    describe "Page.Search (unit)"
        [ initState
        , sortChangedVariants
        , yearFromChanged
        , yearToChanged
        , clearFilters
        ]


{-| The initial model: empty query, no results requested yet, zero debounces.
`Page.Search.init` takes no arguments and issues no command, so init fires no
API call by construction (the search harness starts it with `Cmd.none`).
-}
initState : Test
initState =
    test "init_state: query empty, results NotAsked, debounceCount 0, default sort/filters" <|
        \() ->
            Expect.all
                [ \m -> Expect.equal "" m.query
                , \m -> Expect.equal NotAsked m.results
                , \m -> Expect.equal NotAsked m.readers
                , \m -> Expect.equal 0 m.debounceCount
                , \m -> Expect.equal ByRelevance m.sort
                , \m -> Expect.equal defaultFilterState m.filters
                , \m -> Expect.equal False m.filterPanelOpen
                ]
                Search.init


{-| `SortChanged` maps each selector value to its `SortOrder` and stores it
(`Page.Search.update`). Unknown / "relevance" both fall back to `ByRelevance`,
the default (a passthrough that preserves the backend's relevance ranking).
-}
sortChangedVariants : Test
sortChangedVariants =
    describe "sort_changed: each selector value updates model.sort"
        (List.map
            (\( input, expected ) ->
                test ("SortChanged \"" ++ input ++ "\" -> " ++ sortLabel expected) <|
                    \() ->
                        let
                            ( model, _, _ ) =
                                Search.update (SortChanged input) Search.init (Just "test-token")
                        in
                        Expect.equal expected model.sort
            )
            [ ( "relevance", ByRelevance )
            , ( "title", ByTitle )
            , ( "author", ByAuthor )
            , ( "year", ByYear )
            , ( "gibberish", ByRelevance )
            ]
        )


sortLabel : SortOrder -> String
sortLabel sort =
    case sort of
        ByRelevance ->
            "ByRelevance"

        ByTitle ->
            "ByTitle"

        ByAuthor ->
            "ByAuthor"

        ByYear ->
            "ByYear"


{-| `YearFromChanged` parses the input into `filters.yearFrom` (invalid -> Nothing).
-}
yearFromChanged : Test
yearFromChanged =
    describe "year_from_changed: parses into filters.yearFrom"
        [ test "valid year sets Just" <|
            \() ->
                let
                    ( model, _, _ ) =
                        Search.update (YearFromChanged "1990") Search.init (Just "test-token")
                in
                Expect.equal (Just 1990) model.filters.yearFrom
        , test "non-numeric clears to Nothing" <|
            \() ->
                let
                    ( model, _, _ ) =
                        Search.update (YearFromChanged "notayear") Search.init (Just "test-token")
                in
                Expect.equal Nothing model.filters.yearFrom
        ]


{-| `YearToChanged` parses the input into `filters.yearTo` (invalid -> Nothing).
-}
yearToChanged : Test
yearToChanged =
    describe "year_to_changed: parses into filters.yearTo"
        [ test "valid year sets Just" <|
            \() ->
                let
                    ( model, _, _ ) =
                        Search.update (YearToChanged "2020") Search.init (Just "test-token")
                in
                Expect.equal (Just 2020) model.filters.yearTo
        , test "non-numeric clears to Nothing" <|
            \() ->
                let
                    ( model, _, _ ) =
                        Search.update (YearToChanged "") Search.init (Just "test-token")
                in
                Expect.equal Nothing model.filters.yearTo
        ]


{-| `ClearFilters` resets `filters` back to `defaultFilterState`, discarding any
year range the user had set.
-}
clearFilters : Test
clearFilters =
    test "clear_filters: resets filters to defaultFilterState" <|
        \() ->
            let
                ( withYears, _, _ ) =
                    Search.update (YearFromChanged "1990") Search.init (Just "test-token")

                ( withBoth, _, _ ) =
                    Search.update (YearToChanged "2020") withYears (Just "test-token")

                ( cleared, _, _ ) =
                    Search.update ClearFilters withBoth (Just "test-token")
            in
            Expect.equal defaultFilterState cleared.filters
