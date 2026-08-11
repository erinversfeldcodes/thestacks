module ApiTimeoutTest exposing (suite)

{-| — every request the SPA makes is bounded in time, and a request
that hits the bound tells the reader something they can act on.


## The defect

All 91 requests under `frontend/src/` carried `timeout = Nothing`. That is not
"no timeout configured"; it is "wait forever". A connection that opens and then
stalls — a sleeping machine, a proxy holding the socket, a captive portal — never
resolves, so the page's `RemoteData` never leaves `Loading`. Every `Failure`
branch in the app was, for that entire class of failure, unreachable code.


## ⚠️ What this suite can and cannot prove

`elm-program-test` resolves simulated effects itself and **never consults the
`timeout` field of an `Http.request` record**. So no Elm test can prove "the
runtime will give up after 15 seconds". Pretending otherwise is how a gate ends
up standing in for the thing it was supposed to guard.

The claim is therefore split three ways, and each part is proved where it can be:

1.  **The bound exists at every call site** — `scripts/check-http-timeouts.sh`,
    which reads the source. No test; a script, because the field is a fact about
    the text and the suite structurally cannot see it.
2.  **The bound is the right size** — the two tests below, which pin the values
    and their relationship. A future edit that quietly drops `standardTimeout`
    to 500 ms, or lets it overtake `uploadTimeout`, fails here.
3.  **The bound actually fires, in elapsed seconds** — a live drive against a
    server that accepts the connection and never answers.

What the program tests below add is the fourth thing, and the one that matters
to a person: **what the reader sees when the bound is reached.** They hand the
page a real `Http.Timeout` and check it leaves the loading state for words that
distinguish "the answer never came" from "your shelf is empty" and from "the
server said no".

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
