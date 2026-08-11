module Page.BookDetailAvailabilityTest exposing (suite)

{-| Program tests for the "Available at" section of Page.BookDetail.

These tests exercise the availability API integration through
simulated HTTP responses.

-}

import Json.Encode as Encode
import Page.BookDetail as BookDetail
import ProgramTest
import Test exposing (Test, describe, test)
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


availabilityJson : String
availabilityJson =
    Encode.encode 0
        (Encode.object
            [ ( "availability"
              , Encode.list identity
                    [ Encode.object
                        [ ( "partner_name", Encode.string "Corner Books" )
                        , ( "price_cents", Encode.int 14900 )
                        , ( "condition", Encode.string "good" )
                        , ( "quantity", Encode.int 2 )
                        , ( "isbn", Encode.string "9780141988511" )
                        ]
                    , Encode.object
                        [ ( "partner_name", Encode.string "The Book Lounge" )
                        , ( "price_cents", Encode.int 17500 )
                        , ( "condition", Encode.string "new" )
                        , ( "quantity", Encode.int 5 )
                        , ( "isbn", Encode.string "9780141988511" )
                        ]
                    ]
              )
            ]
        )


emptyAvailabilityJson : String
emptyAvailabilityJson =
    Encode.encode 0
        (Encode.object
            [ ( "availability", Encode.list identity [] ) ]
        )


suite : Test
suite =
    describe "Page.BookDetail — Availability Section"
        [ availabilityRenderedWhenPresent
        , availabilityHiddenWhenEmpty
        , availabilityShowsPartnerAndPrice
        , availabilityNotShownDuringLoading
        ]


availabilityRenderedWhenPresent : Test
availabilityRenderedWhenPresent =
    test "available_at_present: when availability API returns items, renders 'Available at' section" <|
        \() ->
            startBookDetail
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-test-001"
                    (simulateBookDetailResponse "book-test-001" testBook)
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/books/book-test-001/availability"
                    availabilityJson
                |> ProgramTest.expectViewHas
                    [ Selector.text "Available at" ]


availabilityHiddenWhenEmpty : Test
availabilityHiddenWhenEmpty =
    test "available_at_empty: when availability API returns empty list, section is NOT rendered" <|
        \() ->
            startBookDetail
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-test-001"
                    (simulateBookDetailResponse "book-test-001" testBook)
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/books/book-test-001/availability"
                    emptyAvailabilityJson
                |> ProgramTest.expectViewHasNot
                    [ Selector.text "Available at" ]


availabilityShowsPartnerAndPrice : Test
availabilityShowsPartnerAndPrice =
    test "available_at_details: each row shows partner name, condition, and formatted price" <|
        \() ->
            startBookDetail
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-test-001"
                    (simulateBookDetailResponse "book-test-001" testBook)
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/books/book-test-001/availability"
                    availabilityJson
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Corner Books" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.text "R149.00" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.text "good" ]
                |> ProgramTest.ensureViewHas
                    [ Selector.text "The Book Lounge" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "R175.00" ]


availabilityNotShownDuringLoading : Test
availabilityNotShownDuringLoading =
    test "available_at_loading: availability section not shown while book is still loading" <|
        \() ->
            startBookDetail
                |> ProgramTest.expectViewHasNot
                    [ Selector.text "Available at" ]
