module Page.BookDetailShelfRowTest exposing (suite)

{-| Program tests for the shelf-row picker on the book-detail overlay.

`PUT /api/placements/:id/shelf` was routed, tested at the controller, and had no
client at all: nothing in the app could ask a book to stand on a different
physical row. So the assertions here are about the request reaching the wire —
its method, url and body derived from the production `Api.RequestSpec` rather
than copied beside it — and about what the page does with the four answers the
server can give: the row it stored, and the three refusals (a shelf that is
gone, a shelf that is someone else's, a shelf in another bookcase).

Shelf rows, not bookshelves. The bookshelf mover sits in the section above this
one and is a different control with a different endpoint; a test that drove the
wrong one would pass while this leg stayed unbuilt.

-}

import Dict
import Expect
import Html.Attributes
import Http
import Page.BookDetail as BookDetail
import ProgramTest
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import TestHelpers
    exposing
        ( bookDetailProgramWithOut
        , simulateBookDetailResponse
        , simulateBookDetailResponseWithPlacement
        , simulateMultiShelfResponse
        , simulatePlacementShelfResponse
        , testBook
        , testPlacement
        )


type alias ShelfRowTest =
    ProgramTest.ProgramTest TestHelpers.BookDetailTestModel BookDetail.Msg (ProgramTest.SimulatedEffect BookDetail.Msg)


shelfEndpoint : String
shelfEndpoint =
    "/api/placements/placement-test-001/shelf"


bookshelfEndpoint : String
bookshelfEndpoint =
    "/api/bookshelves/library"


start : ShelfRowTest
start =
    ProgramTest.start ()
        (bookDetailProgramWithOut "book-test-001" (Just "test-token") Nothing)


{-| A book open on the detail page, sitting on a placement in the Library.
-}
withPlacement : ShelfRowTest
withPlacement =
    start
        |> ProgramTest.simulateHttpResponse "GET"
            "/api/books/book-test-001"
            (simulateBookDetailResponseWithPlacement "book-test-001" testBook testPlacement)


{-| The bookcase behind the book: three rows, with the book on the first.
-}
onFirstOfThreeRows : ShelfRowTest -> ShelfRowTest
onFirstOfThreeRows program =
    program
        |> ProgramTest.simulateHttpResponse "GET"
            bookshelfEndpoint
            (simulateMultiShelfResponse
                [ { id = "shelf-a", position = 0, placements = [ testPlacement ] }
                , { id = "shelf-b", position = 1, placements = [] }
                , { id = "shelf-c", position = 2, placements = [] }
                ]
            )


loaded : ShelfRowTest
loaded =
    onFirstOfThreeRows withPlacement


{-| The picker with a move in flight, waiting on the server's answer.
-}
midMove : ShelfRowTest
midMove =
    loaded |> ProgramTest.clickButton "Move"


refusal : Int -> Http.Response String
refusal statusCode =
    Http.BadStatus_
        { url = shelfEndpoint
        , statusCode = statusCode
        , statusText = "Refused"
        , headers = Dict.empty
        }
        "{\"error\":\"nope\"}"


answered : Http.Response String -> ShelfRowTest
answered response =
    midMove |> ProgramTest.simulateHttpResponse "PUT" shelfEndpoint response


suite : Test
suite =
    describe "Page.BookDetail shelf-row picker (ProgramTest)"
        [ readsTheRowsOfTheBookcase
        , offersEveryRowButTheOneItIsOn
        , namesTheRowItIsOn
        , movePutsTheChosenRow
        , successAdoptsTheServersRow
        , successReportsAMutation
        , refusalReportsNothing
        , wrongBookshelfSaysSo
        , goneShelfSaysSo
        , someoneElsesShelfSaysSo
        , oneRowHidesThePicker
        , noPlacementAsksForNothing
        ]


readsTheRowsOfTheBookcase : Test
readsTheRowsOfTheBookcase =
    test "reads_the_rows: opening a shelved book reads the bookcase it stands in" <|
        \() ->
            withPlacement
                |> ProgramTest.expectHttpRequestWasMade "GET" bookshelfEndpoint


{-| The current row is not an option, for the same reason the bookshelf mover
omits the bookshelf the book is already on: choosing it is a move to nowhere.

Asserted on the options' VALUES — the shelf ids the request would carry — not
on their labels. A label is assembled at render time (`"Shelf " ++ index`), so
"the view does not contain the text Shelf 1" is satisfied by a view that
contains no options at all, or renders them under some other wording.

-}
offersEveryRowButTheOneItIsOn : Test
offersEveryRowButTheOneItIsOn =
    test "offers_the_others: the row the book already stands on is not on offer" <|
        \() ->
            loaded
                |> ProgramTest.expectView
                    (\view ->
                        view
                            |> Query.find [ Selector.attribute (Html.Attributes.attribute "aria-label" "Target shelf row") ]
                            |> Query.findAll [ Selector.tag "option" ]
                            |> Expect.all
                                [ Query.count (Expect.equal 2)
                                , Query.each
                                    (Query.hasNot
                                        [ Selector.attribute (Html.Attributes.value "shelf-a") ]
                                    )
                                , Query.index 0
                                    >> Query.has
                                        [ Selector.attribute (Html.Attributes.value "shelf-b")
                                        , Selector.text "Shelf 2"
                                        ]
                                , Query.index 1
                                    >> Query.has
                                        [ Selector.attribute (Html.Attributes.value "shelf-c")
                                        , Selector.text "Shelf 3"
                                        ]
                                ]
                    )


namesTheRowItIsOn : Test
namesTheRowItIsOn =
    test "names_the_row: the reader is told which row the book stands on now" <|
        \() ->
            loaded
                |> ProgramTest.expectViewHas [ Selector.text "On Shelf 1 right now." ]


movePutsTheChosenRow : Test
movePutsTheChosenRow =
    test "move_puts_the_row: confirming a move PUTs the chosen shelf id" <|
        \() ->
            loaded
                |> ProgramTest.clickButton "Move"
                |> ProgramTest.expectHttpRequest "PUT"
                    shelfEndpoint
                    (.body >> Expect.equal "{\"shelf_id\":\"shelf-b\"}")


{-| The server is the authority on where the book ended up. Answering with a row
the reader did not choose is not a realistic server, but it is the only way to
tell "the page adopted the answer" apart from "the page kept its own guess",
which look identical whenever the two agree.
-}
successAdoptsTheServersRow : Test
successAdoptsTheServersRow =
    test "success_adopts: the page settles on the row the server says it stored" <|
        \() ->
            answered (simulatePlacementShelfResponse "placement-test-001" "shelf-c")
                |> ProgramTest.expectViewHas [ Selector.text "On Shelf 3 right now." ]


successReportsAMutation : Test
successReportsAMutation =
    test "success_reports_a_mutation: a completed shelf move tells the host the placement changed" <|
        \() ->
            answered (simulatePlacementShelfResponse "placement-test-001" "shelf-b")
                |> ProgramTest.expectModel
                    (\model -> Expect.equal BookDetail.PlacementMutated model.lastOut)


{-| The mutation signal has to mean "the server changed". A refetch on a
rejected move would re-read a bookcase that never changed.
-}
refusalReportsNothing : Test
refusalReportsNothing =
    test "refusal_reports_nothing: a rejected shelf move raises no mutation signal" <|
        \() ->
            answered (refusal 422)
                |> ProgramTest.expectModel
                    (\model -> Expect.equal BookDetail.NoOut model.lastOut)


{-| The three refusals are three different things the reader can do about it,
so each gets its own sentence rather than one "try again" for all of them.
-}
wrongBookshelfSaysSo : Test
wrongBookshelfSaysSo =
    test "wrong_bookshelf_says_so: a row in another bookcase is named as that" <|
        \() ->
            answered (refusal 422)
                |> ProgramTest.expectViewHas
                    [ Selector.text "That shelf belongs to a different bookshelf — move the book to that bookshelf first." ]


goneShelfSaysSo : Test
goneShelfSaysSo =
    test "gone_shelf_says_so: a row that no longer exists asks for a reload" <|
        \() ->
            answered (refusal 404)
                |> ProgramTest.expectViewHas
                    [ Selector.text "That shelf is no longer there. Reload the page and try again." ]


someoneElsesShelfSaysSo : Test
someoneElsesShelfSaysSo =
    test "someone_elses_shelf_says_so: a row belonging to another reader is named as that" <|
        \() ->
            answered (refusal 403)
                |> ProgramTest.expectViewHas
                    [ Selector.text "That shelf isn't yours to rearrange." ]


{-| A bookcase with one row has nowhere to move the book to.
-}
oneRowHidesThePicker : Test
oneRowHidesThePicker =
    test "one_row_hides_it: a bookcase with a single row shows no picker" <|
        \() ->
            withPlacement
                |> ProgramTest.simulateHttpResponse "GET"
                    bookshelfEndpoint
                    (simulateMultiShelfResponse
                        [ { id = "shelf-a", position = 0, placements = [ testPlacement ] } ]
                    )
                |> ProgramTest.expectViewHasNot
                    [ Selector.attribute (Html.Attributes.attribute "aria-label" "Target shelf row") ]


{-| A book the reader has not shelved is on no row of theirs, so there is
nothing to read and nothing to move.
-}
noPlacementAsksForNothing : Test
noPlacementAsksForNothing =
    test "no_placement_asks_for_nothing: an unshelved book reads no bookcase and shows no picker" <|
        \() ->
            start
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-test-001"
                    (simulateBookDetailResponse "book-test-001" testBook)
                |> Expect.all
                    [ ProgramTest.expectHttpRequests "GET" bookshelfEndpoint (List.length >> Expect.equal 0)
                    , ProgramTest.expectViewHasNot
                        [ Selector.attribute (Html.Attributes.attribute "aria-label" "Target shelf row") ]
                    ]
