module Page.ReadingPileProgramTest exposing (suite)

{-| Program tests for `Page.Bookshelf.ReadingPile` (Issue #112 punch #7/#8).

`Page.ReadingPileMsgTest` drives `update` directly; this suite drives the page
through its _rendered DOM_ — the request `init` fires, the pile the response
paints, the hover/click wiring on each piled book, and every sad path's
user-visible message.

Note that the Reading Pile deliberately does **not** share `Page.Bookshelf`'s
`ShelvesLoaded`/`shelves` shape: it uses `BooksLoaded` and flattens straight to
`books : RemoteData Http.Error (List Placement)`. The two families diverged on
purpose and these tests assert the pile's own contract.

-}

import Dict
import Expect
import Http
import Navigation.Route exposing (Route(..))
import Page.Bookshelf.ReadingPile as ReadingPile
import ProgramTest
import Test exposing (Test, describe, test)
import Test.Html.Event as Event
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import TestHelpers
    exposing
        ( namedPlacement
        , readingPileProgram
        , simulateBookshelfResponse
        , simulateMultiShelfResponse
        )
import Types.Placement exposing (Placement)


pileEndpoint : String
pileEndpoint =
    "/api/bookshelves/reading_pile"


startPile : ProgramTest.ProgramTest TestHelpers.ReadingPileTestModel ReadingPile.Msg (ProgramTest.SimulatedEffect ReadingPile.Msg)
startPile =
    ProgramTest.start () (readingPileProgram (Just "test-token"))


{-| A piled book, addressable in the DOM by the title it renders.
-}
duneP : Placement
duneP =
    namedPlacement "book-dune" "Dune"


solarisP : Placement
solarisP =
    namedPlacement "book-solaris" "Solaris"


suite : Test
suite =
    describe "Page.Bookshelf.ReadingPile (ProgramTest)"
        [ describe "happy path (punch #7)"
            [ initFiresPileRequest
            , booksLoadedFlattensAcrossShelves
            , bookHoveredSelectsThatBook
            , firstClickOnlySelects
            , secondClickNavigatesToBookDetail
            , deselectClearsTheSelection
            , pileRendersExactlyFifty
            , grandfatheredPileRendersEverything
            ]
        , describe "sad paths (punch #8)"
            [ forbiddenRaisesAgeGate
            , serverErrorShowsPileErrorMessage
            , emptyPileShowsEmptyMessage
            ]
        ]



-- HAPPY PATH (punch #7)


initFiresPileRequest : Test
initFiresPileRequest =
    test "reading_pile_init_fires_request: init issues GET /api/bookshelves/reading_pile" <|
        \() ->
            startPile
                |> ProgramTest.expectHttpRequestWasMade "GET" pileEndpoint


booksLoadedFlattensAcrossShelves : Test
booksLoadedFlattensAcrossShelves =
    test "reading_pile_flattens_shelves: BooksLoaded Ok concat-maps every shelf's placements into one pile" <|
        \() ->
            startPile
                |> ProgramTest.simulateHttpResponse "GET"
                    pileEndpoint
                    (simulateMultiShelfResponse
                        [ { id = "shelf-1", position = 1, placements = [ duneP ] }
                        , { id = "shelf-2", position = 2, placements = [ solarisP ] }
                        ]
                    )
                -- Both shelves' books land in the single pile: a page that read
                -- only the first shelf would render one book, not two.
                |> ProgramTest.ensureView
                    (Query.findAll [ Selector.class "book-pile__book" ]
                        >> Query.count (Expect.equal 2)
                    )
                |> ProgramTest.ensureViewHas [ Selector.text "Dune" ]
                |> ProgramTest.expectViewHas [ Selector.text "Solaris" ]


bookHoveredSelectsThatBook : Test
bookHoveredSelectsThatBook =
    test "reading_pile_hover_selects: hovering a piled book marks that book — and only that book — selected" <|
        \() ->
            loadedPile
                |> ProgramTest.simulateDomEvent (findPiledBook "Solaris") Event.mouseEnter
                |> ProgramTest.ensureView
                    (Query.findAll [ Selector.class "book-pile__book--selected" ]
                        >> Query.count (Expect.equal 1)
                    )
                -- The selected class must land on the *hovered* book. Asserting
                -- only the count would pass if it landed on Dune instead.
                |> ProgramTest.expectView
                    (findPiledBook "Solaris"
                        >> Query.has [ Selector.class "book-pile__book--selected" ]
                    )


firstClickOnlySelects : Test
firstClickOnlySelects =
    test "reading_pile_first_click_selects: a first click on an unselected book selects it without navigating" <|
        \() ->
            loadedPile
                |> ProgramTest.simulateDomEvent (findPiledBook "Dune") Event.click
                |> ProgramTest.expectModel
                    (\model ->
                        ( model.page.selectedBookId, model.lastOut )
                            |> Expect.equal ( Just "book-dune", ReadingPile.NoOut )
                    )


secondClickNavigatesToBookDetail : Test
secondClickNavigatesToBookDetail =
    test "reading_pile_second_click_navigates: a second click on the already-selected book emits NavigateTo (BookDetail id)" <|
        \() ->
            loadedPile
                |> ProgramTest.simulateDomEvent (findPiledBook "Dune") Event.click
                |> ProgramTest.simulateDomEvent (findPiledBook "Dune") Event.click
                |> ProgramTest.expectModel
                    (\model ->
                        model.lastOut
                            |> Expect.equal (ReadingPile.NavigateTo (BookDetail "book-dune"))
                    )


deselectClearsTheSelection : Test
deselectClearsTheSelection =
    test "reading_pile_deselect_clears: clicking off the pile clears the selected book" <|
        \() ->
            loadedPile
                |> ProgramTest.simulateDomEvent (findPiledBook "Dune") Event.mouseEnter
                -- Pre-condition: a book really is selected, so the assertion
                -- below is not satisfied by an already-empty selection.
                |> ProgramTest.ensureViewHas [ Selector.class "book-pile__book--selected" ]
                -- `Deselect` is wired to the page root (`reading-pile-page`),
                -- which is the query root itself — `Query.find` only searches
                -- descendants, so target it with `identity`.
                |> ProgramTest.simulateDomEvent identity Event.click
                |> ProgramTest.expectViewHasNot [ Selector.class "book-pile__book--selected" ]


pileRendersExactlyFifty : Test
pileRendersExactlyFifty =
    test "reading_pile_renders_fifty: a pile at the 50-book cap renders all 50" <|
        \() ->
            startPile
                |> ProgramTest.simulateHttpResponse "GET"
                    pileEndpoint
                    (simulateBookshelfResponse (numberedPile 50))
                |> ProgramTest.expectView
                    (Query.findAll [ Selector.class "book-pile__book" ]
                        >> Query.count (Expect.equal 50)
                    )


grandfatheredPileRendersEverything : Test
grandfatheredPileRendersEverything =
    test "reading_pile_grandfather_renders_all: an over-limit (grandfathered) pile renders every book — none are silently hidden" <|
        \() ->
            -- #276: the 50 cap is enforced at the WRITE path. Piles that
            -- already exceed 50 are grandfathered, so the view must render
            -- all of them — silent truncation was the original defect.
            startPile
                |> ProgramTest.simulateHttpResponse "GET"
                    pileEndpoint
                    (simulateBookshelfResponse (numberedPile 60))
                |> ProgramTest.expectView
                    (Query.findAll [ Selector.class "book-pile__book" ]
                        >> Query.count (Expect.equal 60)
                    )


numberedPile : Int -> List Placement
numberedPile count =
    List.range 1 count
        |> List.map
            (\n ->
                namedPlacement ("book-" ++ String.fromInt n)
                    ("Title " ++ String.fromInt n)
            )



-- SAD PATHS (punch #8)


forbiddenRaisesAgeGate : Test
forbiddenRaisesAgeGate =
    test "reading_pile_403_age_gate: a 403 replaces the pile with the age gate" <|
        \() ->
            startPile
                |> ProgramTest.simulateHttpResponse "GET"
                    pileEndpoint
                    (pileErrorResponse 403)
                |> ProgramTest.ensureViewHas [ Selector.class "age-gate" ]
                |> ProgramTest.ensureViewHas [ Selector.text "Age Verification Required" ]
                -- The gate replaces the scene rather than sitting alongside it.
                |> ProgramTest.expectViewHasNot [ Selector.class "reading-pile__scene" ]


serverErrorShowsPileErrorMessage : Test
serverErrorShowsPileErrorMessage =
    test "reading_pile_500_error: a 500 shows the pile's own error copy" <|
        \() ->
            startPile
                |> ProgramTest.simulateHttpResponse "GET"
                    pileEndpoint
                    (pileErrorResponse 500)
                |> ProgramTest.expectViewHas
                    [ Selector.class "error"
                    , Selector.text "Could not load your reading pile. Please try again."
                    ]


emptyPileShowsEmptyMessage : Test
emptyPileShowsEmptyMessage =
    test "reading_pile_empty: an empty pile shows the empty-pile invitation and no book pile" <|
        \() ->
            startPile
                |> ProgramTest.simulateHttpResponse "GET"
                    pileEndpoint
                    (simulateBookshelfResponse [])
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Nothing on the pile right now. Move a book from your Antilibrary to start reading." ]
                |> ProgramTest.expectViewHasNot [ Selector.class "book-pile" ]



-- HELPERS


{-| A pile already loaded with two distinguishable books.
-}
loadedPile : ProgramTest.ProgramTest TestHelpers.ReadingPileTestModel ReadingPile.Msg (ProgramTest.SimulatedEffect ReadingPile.Msg)
loadedPile =
    startPile
        |> ProgramTest.simulateHttpResponse "GET"
            pileEndpoint
            (simulateBookshelfResponse [ duneP, solarisP ])


{-| Locate one piled book by the title it renders, so hover/click assertions
name a specific book rather than "whichever one comes first".
-}
findPiledBook : String -> Query.Single msg -> Query.Single msg
findPiledBook title =
    Query.find
        [ Selector.class "book-pile__book"
        , Selector.containing [ Selector.text title ]
        ]


pileErrorResponse : Int -> Http.Response String
pileErrorResponse statusCode =
    Http.BadStatus_
        { url = pileEndpoint
        , statusCode = statusCode
        , statusText = "Error"
        , headers = Dict.empty
        }
        ""
