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
import Page.Search as Search exposing (Msg(..), SnippetSegment(..))
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
        , deepSearchToggledSetsFlag
        , snippetParser
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


{-| `DeepSearchToggled` stores the new flag on the model. `init` starts it off,
so toggling on sets it True and toggling off sets it back False.
-}
deepSearchToggledSetsFlag : Test
deepSearchToggledSetsFlag =
    describe "deep_search_toggled: stores the flag on the model"
        [ test "init starts deep search OFF" <|
            \() ->
                Expect.equal False Search.init.deepSearch
        , test "toggling on sets deepSearch True" <|
            \() ->
                let
                    ( model, _, _ ) =
                        Search.update (DeepSearchToggled True) Search.init (Just "test-token")
                in
                Expect.equal True model.deepSearch
        , test "toggling off sets deepSearch False" <|
            \() ->
                let
                    ( on, _, _ ) =
                        Search.update (DeepSearchToggled True) Search.init (Just "test-token")

                    ( off, _, _ ) =
                        Search.update (DeepSearchToggled False) on (Just "test-token")
                in
                Expect.equal False off.deepSearch
        ]


{-| `Page.Search.parseSnippet` turns a `ts_headline` snippet string into a list
of plain / `<mark>`-highlighted segments. Elm cannot innerHTML without a port, so
the `<mark>` markup must be parsed into styled elements rather than injected — and
malformed / unbalanced input must pass through verbatim as plain text (never a
false highlight, never dropped).
-}
snippetParser : Test
snippetParser =
    describe "snippet_parser: parseSnippet splits on balanced <mark> pairs"
        [ test "happy: one highlight between plain runs" <|
            \() ->
                Expect.equal
                    [ Plain "the ", Highlight "habit", Plain " loop" ]
                    (Search.parseSnippet "the <mark>habit</mark> loop")
        , test "multiple: two highlights are each parsed" <|
            \() ->
                Expect.equal
                    [ Highlight "sand", Plain " and ", Highlight "sea" ]
                    (Search.parseSnippet "<mark>sand</mark> and <mark>sea</mark>")
        , test "no marks: whole string is one plain segment" <|
            \() ->
                Expect.equal
                    [ Plain "just plain text" ]
                    (Search.parseSnippet "just plain text")
        , test "malformed: an open with no close passes through verbatim as plain" <|
            \() ->
                Expect.equal
                    [ Plain "the <mark>habit loop" ]
                    (Search.parseSnippet "the <mark>habit loop")
        , test "empty: an empty snippet parses to no segments" <|
            \() ->
                Expect.equal
                    []
                    (Search.parseSnippet "")
        ]
