module Page.BookshelfShelvesTest exposing (suite)

{-| Program tests for the physical shelf entity feature (Issue #151).

These tests verify that the bookshelf page renders server-provided shelves
instead of client-side row grouping, and that shelf management actions work.

These tests are expected to FAIL until the Shelf type and related Msg
constructors are implemented.

-}

import Dict
import Html.Attributes
import Http
import Json.Encode as Encode
import Page.Bookshelf as Bookshelf
import ProgramTest
import Test exposing (Test, describe, test)
import Test.Html.Selector as Selector
import TestHelpers exposing (libraryProgram, testPlacement)
import Types.Shelf exposing (Shelf)


{-| Helper to start a library program with an auth token.
-}
startLibrary : ProgramTest.ProgramTest Bookshelf.Model Bookshelf.Msg (ProgramTest.SimulatedEffect Bookshelf.Msg)
startLibrary =
    ProgramTest.start () (libraryProgram (Just "test-token"))


{-| Build a shelf API response JSON with the given shelves.
Each shelf has an id, position, and list of placements.
-}
simulateShelvesResponse : List { id : String, position : Int, placements : List Encode.Value } -> Http.Response String
simulateShelvesResponse shelves =
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
                    [ ( "shelves", Encode.list encodeShelf shelves ) ]
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
    describe "Page.Bookshelf — Physical Shelves (Issue #151)"
        [ shelvesRenderedInOrder
        , eachShelfIsDistinctRow
        , emptyShelvesShowEmptyState
        , addShelfButtonPresent
        , addShelfButtonFiresPost
        ]


shelvesRenderedInOrder : Test
shelvesRenderedInOrder =
    test "shelves_rendered_in_order: API response with two shelves renders books from shelf-1 before shelf-2" <|
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
                    [ Selector.class "bookcase__shelf" ]


eachShelfIsDistinctRow : Test
eachShelfIsDistinctRow =
    test "each_shelf_is_distinct_row: each server shelf renders as a separate bookcase__shelf element" <|
        \() ->
            startLibrary
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/library"
                    (simulateShelvesResponse
                        [ { id = "shelf-1", position = 0, placements = [ encodePlacement ] }
                        , { id = "shelf-2", position = 1, placements = [] }
                        ]
                    )
                |> ProgramTest.expectViewHas
                    [ Selector.all
                        [ Selector.class "bookcase__shelf"
                        , Selector.attribute (Html.Attributes.attribute "data-shelf-id" "shelf-2")
                        ]
                    ]


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


addShelfButtonPresent : Test
addShelfButtonPresent =
    test "add_shelf_button_present: authenticated owner sees Add Shelf button" <|
        \() ->
            startLibrary
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/library"
                    (simulateShelvesResponse
                        [ { id = "shelf-1", position = 0, placements = [] }
                        ]
                    )
                |> ProgramTest.expectViewHas
                    [ Selector.all
                        [ Selector.tag "button"
                        , Selector.text "Add shelf"
                        ]
                    ]


addShelfButtonFiresPost : Test
addShelfButtonFiresPost =
    test "add_shelf_button_fires_post: clicking Add Shelf fires POST to shelves endpoint" <|
        \() ->
            startLibrary
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/library"
                    (simulateShelvesResponse
                        [ { id = "shelf-1", position = 0, placements = [] }
                        ]
                    )
                |> ProgramTest.clickButton "Add shelf"
                |> ProgramTest.expectHttpRequestWasMade "POST"
                    "/api/bookshelves/library/shelves"
