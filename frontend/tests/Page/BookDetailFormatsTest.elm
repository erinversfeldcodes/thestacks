module Page.BookDetailFormatsTest exposing (suite)

{-| Program tests for the "Formats on My Shelf" picker on the book-detail
overlay.

The picker's own interactivity was never the risk: a button that paints itself
selected on click satisfies every widget-level assertion while the click reaches
no server at all, which is exactly what this control did. So these tests assert
the request — its method, url and body, derived from the production
`Api.RequestSpec` rather than copied beside it — and the two ways the model may
end up after it: the server's stored list on success, the reader's prior set on
failure.

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
        ( bookDetailProgram
        , simulateBookDetailResponseWithFormats
        , simulatePlacementFormatsResponse
        , testBook
        )


type alias BookDetailTest =
    ProgramTest.ProgramTest BookDetail.Model BookDetail.Msg (ProgramTest.SimulatedEffect BookDetail.Msg)


start : BookDetailTest
start =
    ProgramTest.start () (bookDetailProgram "book-test-001" (Just "test-token"))


formatsEndpoint : String
formatsEndpoint =
    "/api/placements/placement-fmt-001/formats"


{-| Load a placement owning exactly the given formats.
-}
loadPlacementOwning : List String -> BookDetailTest -> BookDetailTest
loadPlacementOwning formats program =
    program
        |> ProgramTest.simulateHttpResponse "GET"
            "/api/books/book-test-001"
            (simulateBookDetailResponseWithFormats "book-test-001" testBook formats)


{-| The picker renders one button per format, each carrying the format's label
as its `title`; `aria-pressed` is the owned/not-owned state a reader (and a
screen reader) actually sees.
-}
expectPressed : String -> Bool -> BookDetailTest -> Expect.Expectation
expectPressed label pressed program =
    program
        |> ProgramTest.expectView
            (\view ->
                view
                    |> Query.find
                        [ Selector.tag "button"
                        , Selector.attribute (Html.Attributes.title label)
                        ]
                    |> Query.has
                        [ Selector.attribute
                            (Html.Attributes.attribute "aria-pressed"
                                (if pressed then
                                    "true"

                                 else
                                    "false"
                                )
                            )
                        ]
            )


serverError : Http.Response String
serverError =
    Http.BadStatus_
        { url = formatsEndpoint
        , statusCode = 500
        , statusText = "Internal Server Error"
        , headers = Dict.empty
        }
        "{\"error\":\"boom\"}"


suite : Test
suite =
    describe "Page.BookDetail format picker (ProgramTest)"
        [ toggleOnPutsTheWholeSet
        , toggleOffPutsTheRemainder
        , successAdoptsTheStoredList
        , errorRevertsTheToggle
        , errorSaysItRolledBack
        , noPlacementSendsNothing
        ]


toggleOnPutsTheWholeSet : Test
toggleOnPutsTheWholeSet =
    test "toggle_on_puts: selecting a format PUTs the resulting set, not a delta" <|
        \() ->
            start
                |> loadPlacementOwning []
                |> ProgramTest.clickButton "Physical"
                |> ProgramTest.expectHttpRequest "PUT"
                    formatsEndpoint
                    (.body >> Expect.equal "{\"formats\":[\"physical\"]}")


toggleOffPutsTheRemainder : Test
toggleOffPutsTheRemainder =
    test "toggle_off_puts: deselecting a format PUTs what is left, not the removal" <|
        \() ->
            start
                |> loadPlacementOwning [ "physical", "ebook" ]
                |> ProgramTest.clickButton "Physical"
                |> ProgramTest.expectHttpRequest "PUT"
                    formatsEndpoint
                    (.body >> Expect.equal "{\"formats\":[\"ebook\"]}")


successAdoptsTheStoredList : Test
successAdoptsTheStoredList =
    test "success_adopts: the picker settles on the list the server says it stored" <|
        \() ->
            start
                |> loadPlacementOwning []
                |> ProgramTest.clickButton "Physical"
                |> ProgramTest.simulateHttpResponse "PUT"
                    formatsEndpoint
                    (simulatePlacementFormatsResponse "placement-fmt-001" [ "physical", "audiobook" ])
                |> expectPressed "Audiobook" True


errorRevertsTheToggle : Test
errorRevertsTheToggle =
    test "error_reverts: a failed save puts the button back the way it was" <|
        \() ->
            start
                |> loadPlacementOwning [ "physical" ]
                |> ProgramTest.clickButton "Physical"
                |> ProgramTest.simulateHttpResponse "PUT" formatsEndpoint serverError
                |> expectPressed "Physical" True


errorSaysItRolledBack : Test
errorSaysItRolledBack =
    test "error_says: the rollback is named, not left for the reader to infer" <|
        \() ->
            start
                |> loadPlacementOwning []
                |> ProgramTest.clickButton "Physical"
                |> ProgramTest.simulateHttpResponse "PUT" formatsEndpoint serverError
                |> ProgramTest.expectViewHas
                    [ Selector.text "We couldn't save your formats, so we've put them back as they were." ]


noPlacementSendsNothing : Test
noPlacementSendsNothing =
    test "no_placement: a reader without a placement has no picker and sends nothing" <|
        \() ->
            ProgramTest.start () (bookDetailProgram "book-test-001" (Just "test-token"))
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-test-001"
                    (TestHelpers.simulateBookDetailResponse "book-test-001" testBook)
                |> ProgramTest.expectViewHasNot
                    [ Selector.attribute (Html.Attributes.title "Physical") ]
