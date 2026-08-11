module ApiAuthedTest exposing (suite)

{-| Issue #361 — the authed-request wrapper: a 401 on a request that definitely
carried a credential is claimed before the endpoint's own resolver sees it.


## What is under test, and why it is reachable

`Api.interpretAuthed` is the whole decision, extracted as a pure function of the
`Http.Response`. The alternative — asserting through a `SimulatedEffect` — is the
shape that has twice passed vacuously here (#302, #328): the harness hand-writes
its own copy of the request and then agrees with itself. There is no copy below.
`Api.interpretAuthed`, `Api.resolveWhatever` and `Api.resolveProfile` are the
production functions, wired the same way `Api.updatePassword` wires them.

The `msg` type is a local `Outcome`, so "did the 401 reach the result handler?"
is a value comparison rather than a claim about a `Cmd` nobody can open.


## Mutation probes (run 2026-08-01, both RED)

  - `metadata.statusCode == 401` → `== 403` in `Api.interpretAuthed`:
    reddens `expired_401_never_reaches_the_result_handler` and
    `expired_401_on_a_json_endpoint`.
  - deleting the `Http.BadStatus_` branch (fall through to `_ ->`):
    reddens the same two.

-}

import Api
import Dict
import Expect
import Http
import Test exposing (Test, describe, test)


{-| Stands in for a page's `Msg`. `Expired` is what `onExpired` produces;
everything else arrives through `onResult`.
-}
type Outcome err ok
    = Expired
    | Completed (Result err ok)


{-| An `Authed` built exactly as a page builds one — `onExpired` is not optional,
which is the guarantee this whole module exists to protect.
-}
authedOutcome : Api.Authed err ok (Outcome err ok)
authedOutcome =
    Api.authed "tok" { onExpired = Expired, onResult = Completed }


metadata : Int -> Http.Metadata
metadata statusCode =
    { url = "https://example.test/api/settings/password"
    , statusCode = statusCode
    , statusText = String.fromInt statusCode
    , headers = Dict.empty
    }


badStatus : Int -> String -> Http.Response String
badStatus statusCode bodyText =
    Http.BadStatus_ (metadata statusCode) bodyText


goodStatus : String -> Http.Response String
goodStatus bodyText =
    Http.GoodStatus_ (metadata 200) bodyText


whatever : Http.Response String -> Outcome Http.Error ()
whatever =
    Api.interpretAuthed Api.resolveWhatever authedOutcome


profile : Http.Response String -> Outcome Api.ProfileError String
profile =
    Api.interpretAuthed Api.resolveProfile authedOutcome


{-| What the endpoint's own resolver made of the response — `Nothing` when the
401 branch claimed it first and the resolver never ran.
-}
resultOf : Outcome err ok -> Maybe (Result err ok)
resultOf outcome =
    case outcome of
        Expired ->
            Nothing

        Completed result ->
            Just result


suite : Test
suite =
    describe "Api.authed — 401 handling is forced, not remembered (#361)"
        [ describe "the 401 is claimed before the endpoint resolver runs"
            [ test "expired_401_never_reaches_the_result_handler" <|
                \() ->
                    whatever (badStatus 401 "")
                        |> Expect.equal Expired
            , test "expired_401_on_a_json_endpoint" <|
                \() ->
                    Api.interpretAuthed Api.resolveProfile authedOutcome (badStatus 401 "{}")
                        |> Expect.equal Expired
            , test "expired_401_is_claimed_even_when_the_body_would_decode" <|
                \() ->
                    profile (badStatus 401 "{\"errors\":{\"email\":[\"is invalid\"]}}")
                        |> Expect.equal Expired
            ]
        , describe "everything else still reaches the endpoint's own resolver"
            [ test "a_422_keeps_its_field_errors" <|
                \() ->
                    profile (badStatus 422 "{\"errors\":{\"handle\":[\"has already been taken\"]}}")
                        |> resultOf
                        |> Expect.equal
                            (Just
                                (Err
                                    (Api.ProfileValidationFailed
                                        [ ( "handle", [ "has already been taken" ] ) ]
                                    )
                                )
                            )
            , test "a_403_stays_local" <|
                \() ->
                    whatever (badStatus 403 "")
                        |> resultOf
                        |> Expect.equal (Just (Err (Http.BadStatus 403)))
            , test "a_500_stays_local" <|
                \() ->
                    whatever (badStatus 500 "")
                        |> resultOf
                        |> Expect.equal (Just (Err (Http.BadStatus 500)))
            , test "a_network_error_stays_local" <|
                \() ->
                    whatever Http.NetworkError_
                        |> resultOf
                        |> Expect.equal (Just (Err Http.NetworkError))
            , test "a_timeout_stays_local" <|
                \() ->
                    whatever Http.Timeout_
                        |> resultOf
                        |> Expect.equal (Just (Err Http.Timeout))
            , test "a_success_reaches_the_result_handler" <|
                \() ->
                    whatever (goodStatus "")
                        |> resultOf
                        |> Expect.equal (Just (Ok ()))
            , test "a_success_body_is_still_decoded" <|
                \() ->
                    profile (goodStatus "{\"handle\":\"ada\"}")
                        |> resultOf
                        |> Expect.equal (Just (Ok "ada"))
            ]
        ]
