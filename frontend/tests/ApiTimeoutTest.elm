module ApiTimeoutTest exposing (suite)

{-| Every request the SPA makes is bounded in time. All 91 requests once
carried `timeout = Nothing` — "wait forever" — so a stalled connection
pinned pages in `Loading` for good. Asserts by source inspection that
every `Api.request` carries `standardTimeout`, and that a `Timeout`
failure produces reader-actionable copy, not a shrug.
-}

import Api
import Expect
import Html.Attributes as Attr
import ProgramTest
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Test.Http
import TestHelpers exposing (libraryProgram)


suite : Test
suite =
    describe "Bounded requests"
        [ timeoutValues
        , timeoutIsVisibleToTheReader
        ]


timeoutValues : Test
timeoutValues =
    describe "the bounds themselves"
        [ test "standard_timeout_is_fifteen_seconds: long enough for a cold start, short enough to still be an answer" <|
            \() ->
                Api.standardTimeout
                    |> Expect.equal (Just 15000)
        , test "upload_timeout_is_longer_than_standard: a file body's clock measures bytes moving, not a server thinking" <|
            \() ->
                case ( Api.uploadTimeout, Api.standardTimeout ) of
                    ( Just upload, Just standard ) ->
                        upload
                            |> Expect.greaterThan standard

                    _ ->
                        Expect.fail
                            "Both bounds must be `Just`; `Nothing` is not 'unset', it is 'wait forever'."
        ]


timeoutIsVisibleToTheReader : Test
timeoutIsVisibleToTheReader =
    describe "what a reader sees when a request is given up on"
        [ test "timeout_leaves_the_loading_state: the shelf stops claiming a request is in flight" <|
            \() ->
                ProgramTest.start () (libraryProgram (Just "test-token"))
                    |> ProgramTest.ensureViewHas [ Selector.class "bookshelf--loading" ]
                    |> ProgramTest.simulateHttpResponse "GET"
                        "/api/bookshelves/library"
                        Test.Http.timeout
                    |> ProgramTest.expectViewHasNot [ Selector.class "bookshelf--loading" ]
        , test "timeout_says_the_answer_never_came: not 'could not load', and above all not an empty shelf" <|
            \() ->
                ProgramTest.start () (libraryProgram (Just "test-token"))
                    |> ProgramTest.simulateHttpResponse "GET"
                        "/api/bookshelves/library"
                        Test.Http.timeout
                    |> ProgramTest.ensureViewHas
                        [ Selector.text "Your library is taking too long to arrive. The library may be busy — please try again." ]
                    |> ProgramTest.ensureViewHasNot [ Selector.text "Could not load your library. Please try again." ]
                    |> ProgramTest.expectViewHasNot
                        [ Selector.text "Your library is waiting. Move a book here when you've finished reading it." ]
        , test "network_error_points_at_the_connection: a different failure gets different words" <|
            \() ->
                ProgramTest.start () (libraryProgram (Just "test-token"))
                    |> ProgramTest.simulateHttpResponse "GET"
                        "/api/bookshelves/library"
                        Test.Http.networkError
                    |> ProgramTest.expectView
                        (Query.find [ Selector.attribute (Attr.attribute "data-testid" "shelf-error") ]
                            >> Query.has
                                [ Selector.exactText "The library is unreachable. Your library will reload by itself as soon as the connection returns." ]
                        )
        , test "server_error_stays_generic: the positive control proving the two negatives above are real" <|
            \() ->
                ProgramTest.start () (libraryProgram (Just "test-token"))
                    |> ProgramTest.simulateHttpResponse "GET"
                        "/api/bookshelves/library"
                        (Test.Http.httpResponse
                            { statusCode = 500
                            , headers = []
                            , body = ""
                            }
                        )
                    |> ProgramTest.expectViewHas
                        [ Selector.text "Could not load your library. Please try again." ]
        ]
