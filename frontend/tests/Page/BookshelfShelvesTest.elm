module Page.BookshelfShelvesTest exposing (suite)

{-| Program tests for bookshelf spine rendering.

The bookcase auto-flows: it fetches the server's shelves but flattens their
placements and re-groups them into rows that fill the bookcase width (the
physical op.shelves boundaries from #151 are ignored on the frontend). These
tests verify books render as spines, and that an all-empty response still shows
the empty-bookshelf message.

-}

import Dict
import Expect
import Http
import Json.Encode as Encode
import Page.Bookshelf as Bookshelf
import ProgramTest
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import TestHelpers exposing (libraryProgram, namedPlacement, simulateMultiShelfResponse)


{-| Helper to start a library program with an auth token.
-}
startLibrary : ProgramTest.ProgramTest Bookshelf.Model Bookshelf.Msg (ProgramTest.SimulatedEffect Bookshelf.Msg)
startLibrary =
    ProgramTest.start () (libraryProgram (Just "test-token"))


{-| Build a shelf API response JSON with the given shelves.
Each shelf has an id, position, and list of placements. Visibility defaults to
"platform" (the historical behaviour these tests were written against).
-}
simulateShelvesResponse : List { id : String, position : Int, placements : List Encode.Value } -> Http.Response String
simulateShelvesResponse shelves =
    simulateShelvesResponseWithVisibility "platform" shelves


{-| Like `simulateShelvesResponse` but with an explicit top-level `visibility`,
matching the real `GET /api/bookshelves/:name` payload. Used to drive the RSS
gate, which shows only for a `"platform"` bookshelf.
-}
simulateShelvesResponseWithVisibility : String -> List { id : String, position : Int, placements : List Encode.Value } -> Http.Response String
simulateShelvesResponseWithVisibility visibility shelves =
    let
        encodeShelf s =
            Encode.object
                [ ( "id", Encode.string s.id )
                , ( "position", Encode.int s.position )
                , ( "placements", Encode.list identity s.placements )
                ]

        json =
            Encode.encode 0
                (Encode.object
                    [ ( "shelves", Encode.list encodeShelf shelves )
                    , ( "visibility", Encode.string visibility )
                    ]
                )
    in
    Http.GoodStatus_
        { url = "/api/bookshelves/library"
        , statusCode = 200
        , statusText = "OK"
        , headers = Dict.empty
        }
        json


{-| Encode a test placement for embedding inside a shelf response.
-}
encodePlacement : Encode.Value
encodePlacement =
    Encode.object
        [ ( "id", Encode.string "placement-test-001" )
        , ( "position", Encode.int 1 )
        , ( "placed_at", Encode.string "2025-01-15T10:30:00Z" )
        , ( "book"
          , Encode.object
                [ ( "id", Encode.string "book-test-001" )
                , ( "title", Encode.string "The Power of Habit" )
                , ( "author"
                  , Encode.object
                        [ ( "id", Encode.string "author-test-001" )
                        , ( "name", Encode.string "Charles Duhigg" )
                        ]
                  )
                , ( "editions", Encode.list identity [] )
                , ( "edition_count", Encode.int 0 )
                , ( "subjects", Encode.list Encode.string [] )
                , ( "visibility_tier", Encode.string "public" )
                ]
          )
        ]


suite : Test
suite =
    describe "Page.Bookshelf — auto-flow shelf rendering"
        [ booksRenderInRows
        , emptyShelvesShowEmptyState
        , rssIconRendersForPlatformShelf
        , rssIconHiddenForNonPlatformShelf
        , shelfOrderIsPreserved
        ]


{-| Per-shelf ordering must survive the auto-flow flattening.

`Shelving.list_shelves/1` orders shelves by `s.position` (`shelving.ex:712`),
and the frontend preserves that order only because
`List.concatMap .placements shelves` is order-preserving
(`Page/Bookshelf.elm:333,380,396`). Auto-flow re-groups placements into rows
that fill the bookcase width, which discards the _shelf boundaries_ — it must
not discard the _sequence_.

Nothing else asserts this at any layer: the two tests that covered it
(`shelves_rendered_in_order`, `each_shelf_is_distinct_row`) were deleted in
`989d86ab` along with the per-shelf DOM element they queried, and the ordering
half was never carried anywhere else. This restores that guard against the DOM
the page renders today (Issue #112).

-}
shelfOrderIsPreserved : Test
shelfOrderIsPreserved =
    test "shelf_order_is_preserved: a book on shelf position 1 renders before a book on shelf position 2" <|
        \() ->
            startLibrary
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/library"
                    (simulateMultiShelfResponse
                        [ { id = "shelf-first"
                          , position = 1
                          , placements = [ namedPlacement "book-alpha" "Alpha" ]
                          }
                        , { id = "shelf-second"
                          , position = 2
                          , placements = [ namedPlacement "book-beta" "Beta" ]
                          }
                        ]
                    )
                -- Both books are on the page at all...
                |> ProgramTest.ensureView
                    (Query.findAll [ Selector.class "book-button" ]
                        >> Query.count (Expect.equal 2)
                    )
                -- ...and shelf-first's book comes first. Pinning BOTH positions
                -- is what makes a reversal fail: asserting only index 0 would
                -- still pass if the flattening emitted [alpha, alpha].
                |> ProgramTest.ensureView
                    (Query.findAll [ Selector.class "book-button" ]
                        >> Query.index 0
                        >> Query.has [ Selector.id "spine-book-alpha" ]
                    )
                |> ProgramTest.expectView
                    (Query.findAll [ Selector.class "book-button" ]
                        >> Query.index 1
                        >> Query.has [ Selector.id "spine-book-beta" ]
                    )


booksRenderInRows : Test
booksRenderInRows =
    test "books_render_in_rows: placements from the server's shelves render as book spines, flattened into bookcase rows" <|
        \() ->
            startLibrary
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/library"
                    (simulateShelvesResponse
                        [ { id = "shelf-1", position = 0, placements = [ encodePlacement ] }
                        , { id = "shelf-2", position = 1, placements = [ encodePlacement ] }
                        ]
                    )
                |> ProgramTest.expectViewHas
                    [ Selector.class "book-button" ]


emptyShelvesShowEmptyState : Test
emptyShelvesShowEmptyState =
    test "empty_shelves_show_empty_state: all shelves empty still shows empty bookshelf message" <|
        \() ->
            startLibrary
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/library"
                    (simulateShelvesResponse
                        [ { id = "shelf-1", position = 0, placements = [] }
                        ]
                    )
                |> ProgramTest.expectViewHas
                    [ Selector.text "Your library is waiting" ]


rssIconRendersForPlatformShelf : Test
rssIconRendersForPlatformShelf =
    test "rss_icon_renders_for_platform_shelf: RSS affordance renders when the loaded shelf visibility is platform" <|
        \() ->
            startLibrary
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/library"
                    (simulateShelvesResponseWithVisibility "platform"
                        [ { id = "shelf-1", position = 0, placements = [ encodePlacement ] }
                        ]
                    )
                |> ProgramTest.expectViewHas
                    [ Selector.class "rss-link" ]


rssIconHiddenForNonPlatformShelf : Test
rssIconHiddenForNonPlatformShelf =
    test "rss_icon_hidden_for_non_platform_shelf: RSS affordance is hidden when the loaded shelf visibility is non-platform (owner)" <|
        \() ->
            startLibrary
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/library"
                    (simulateShelvesResponseWithVisibility "owner"
                        [ { id = "shelf-1", position = 0, placements = [ encodePlacement ] }
                        ]
                    )
                |> ProgramTest.expectViewHasNot
                    [ Selector.class "rss-link" ]
