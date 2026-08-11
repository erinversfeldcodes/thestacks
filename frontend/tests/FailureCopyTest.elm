module FailureCopyTest exposing (suite)

{-| The shared failure vocabulary (Issue #374).

Two rules are under test here, and neither is about wording:

1.  **A wait is named only when the server named one.** `retryAfterSeconds`
    returns `Nothing` for a 429 that carried no `retry-after`, and the copy for
    that case must contain no interval at all. A hard-coded fallback would read
    "60 seconds" forever, including after `StacksWeb.Plugs.RateLimiter` was
    retuned, and nothing would fail.
2.  **A rounded wait rounds up.** Being sent back early produces a second 429 and
    teaches the reader that the number is not to be trusted.

-}

import Api
import Dict
import Expect
import Http
import Test exposing (Test, describe, test)
import Util.FailureCopy as FailureCopy


{-| Metadata as `elm/http` hands it over: header names already lower-cased.
-}
metadataWith : List ( String, String ) -> Http.Metadata
metadataWith headers =
    { url = "/api/auth/login"
    , statusCode = 429
    , statusText = "Too Many Requests"
    , headers = Dict.fromList headers
    }


suite : Test
suite =
    describe "Util.FailureCopy / Api.retryAfterSeconds (#374)"
        [ describe "reading retry-after off a 429"
            [ test "a delay in seconds is read" <|
                \_ ->
                    Api.retryAfterSeconds (metadataWith [ ( "retry-after", "60" ) ])
                        |> Expect.equal (Just 60)
            , test "surrounding whitespace does not defeat it" <|
                \_ ->
                    Api.retryAfterSeconds (metadataWith [ ( "retry-after", " 30 " ) ])
                        |> Expect.equal (Just 30)
            , test "a missing header is Nothing, not a default" <|
                \_ ->
                    Api.retryAfterSeconds (metadataWith [])
                        |> Expect.equal Nothing
            , test "an HTTP-date is Nothing rather than a guess" <|
                \_ ->
                    Api.retryAfterSeconds
                        (metadataWith [ ( "retry-after", "Wed, 21 Oct 2026 07:28:00 GMT" ) ])
                        |> Expect.equal Nothing
            , test "a zero or negative delay is Nothing" <|
                \_ ->
                    Expect.all
                        [ \_ ->
                            Api.retryAfterSeconds (metadataWith [ ( "retry-after", "0" ) ])
                                |> Expect.equal Nothing
                        , \_ ->
                            Api.retryAfterSeconds (metadataWith [ ( "retry-after", "-5" ) ])
                                |> Expect.equal Nothing
                        ]
                        ()
            ]
        , describe "rate-limit copy"
            [ test "with no wait known, it names no interval" <|
                \_ ->
                    FailureCopy.rateLimited Nothing
                        |> String.contains "a little while"
                        |> Expect.equal True
            , test "⛔ with no wait known, it invents no number" <|
                \_ ->
                    FailureCopy.rateLimited Nothing
                        |> String.any Char.isDigit
                        |> Expect.equal False
            , test "with a wait known, it names it" <|
                \_ ->
                    FailureCopy.rateLimited (Just 45)
                        |> String.contains "45 seconds"
                        |> Expect.equal True
            ]
        , describe "waitPhrase"
            [ test "one second is not '1 seconds'" <|
                \_ -> FailureCopy.waitPhrase 1 |> Expect.equal "a second"
            , test "sub-minute waits are named in seconds" <|
                \_ -> FailureCopy.waitPhrase 45 |> Expect.equal "45 seconds"
            , test "exactly a minute reads as a minute" <|
                \_ -> FailureCopy.waitPhrase 60 |> Expect.equal "a minute"
            , test "⛔ a part-minute wait rounds UP, never down" <|
                \_ ->
                    FailureCopy.waitPhrase 61 |> Expect.equal "2 minutes"
            , test "a longer wait rounds up too" <|
                \_ -> FailureCopy.waitPhrase 130 |> Expect.equal "3 minutes"
            ]
        , describe "settings save failures"
            [ test "a 422 sends the reader to a reload, not a repeat" <|
                \_ ->
                    FailureCopy.saveFailure "your preferences" (Http.BadStatus 422)
                        |> String.contains "Reload the page"
                        |> Expect.equal True
            , test "a dropped connection says the change was not saved" <|
                \_ ->
                    FailureCopy.saveFailure "your preferences" Http.NetworkError
                        |> String.contains "were not saved"
                        |> Expect.equal True
            , test "⛔ a timeout does NOT claim the change was lost" <|
                \_ ->
                    FailureCopy.saveFailure "your preferences" Http.Timeout
                        |> String.contains "we cannot say whether"
                        |> Expect.equal True
            , test "an unrecognised status admits it is unrecognised" <|
                \_ ->
                    FailureCopy.saveFailure "your preferences" (Http.BadStatus 502)
                        |> String.contains "we cannot say why"
                        |> Expect.equal True
            , test "⛔ the four causes do not share a sentence" <|
                \_ ->
                    [ FailureCopy.saveFailure "your preferences" (Http.BadStatus 422)
                    , FailureCopy.saveFailure "your preferences" (Http.BadStatus 429)
                    , FailureCopy.saveFailure "your preferences" Http.NetworkError
                    , FailureCopy.saveFailure "your preferences" Http.Timeout
                    , FailureCopy.saveFailure "your preferences" (Http.BadStatus 502)
                    ]
                        |> distinctCount
                        |> Expect.equal 5
            ]
        ]


distinctCount : List String -> Int
distinctCount =
    List.foldl
        (\item seen ->
            if List.member item seen then
                seen

            else
                item :: seen
        )
        []
        >> List.length
