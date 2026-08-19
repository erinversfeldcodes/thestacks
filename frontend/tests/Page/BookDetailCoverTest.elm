module Page.BookDetailCoverTest exposing (suite)

{-| A cover URL that fails to load must fall back to the styled placeholder the
catalogue already uses, rather than leaving the browser's broken-image glyph in
a frame every neighbouring surface fills.
-}

import Html.Attributes
import Json.Encode as Encode
import Page.BookDetail as BookDetail
import ProgramTest
import Test exposing (Test, describe, test)
import Test.Html.Event as Event
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import TestHelpers
    exposing
        ( bookDetailProgram
        , simulateBookDetailResponse
        , testBook
        )


startBookDetail : ProgramTest.ProgramTest BookDetail.Model BookDetail.Msg (ProgramTest.SimulatedEffect BookDetail.Msg)
startBookDetail =
    ProgramTest.start () (bookDetailProgram "book-test-001" (Just "test-token"))


loadBook : ProgramTest.ProgramTest m msg effect -> ProgramTest.ProgramTest m msg effect
loadBook program =
    ProgramTest.simulateHttpResponse "GET"
        "/api/books/book-test-001"
        (simulateBookDetailResponse "book-test-001" testBook)
        program


coverSelector : Selector.Selector
coverSelector =
    Selector.attribute (Html.Attributes.attribute "data-testid" "book-cover")


suite : Test
suite =
    describe "Page.BookDetail cover fallback"
        [ test "shows the cover image when the URL loads" <|
            \_ ->
                startBookDetail
                    |> loadBook
                    |> ProgramTest.expectViewHas [ coverSelector ]
        , test "swaps a broken cover for the styled placeholder the catalogue uses" <|
            \_ ->
                startBookDetail
                    |> loadBook
                    |> ProgramTest.simulateDomEvent
                        (Query.find [ coverSelector ])
                        ( "error", Encode.object [] )
                    |> ProgramTest.expectViewHas
                        [ Selector.class "book-detail__cover-placeholder" ]
        , test "the broken image element is gone, not merely covered up" <|
            \_ ->
                startBookDetail
                    |> loadBook
                    |> ProgramTest.simulateDomEvent
                        (Query.find [ coverSelector ])
                        ( "error", Encode.object [] )
                    -- Leaving the <img> in place would keep the browser's broken
                    -- glyph rendering underneath the placeholder.
                    |> ProgramTest.expectViewHasNot [ coverSelector ]
        ]
