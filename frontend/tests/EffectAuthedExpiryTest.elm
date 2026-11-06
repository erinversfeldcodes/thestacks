module EffectAuthedExpiryTest exposing (suite)

{-| A 401 on an authenticated request PLAN reaches the expiry msg, and a 401 on
a public one does not.

⛔ WHY THIS EXISTS. `Api.Authed` makes session-expiry handling a compile-time
obligation — its constructor demands an `onExpired` msg, so a call site that
ignores expiry does not build. `Effect.authed` took a credential and a single
response mapping, and nothing asked the caller to distinguish a 401 from any
other failure. So the two request paths offered different guarantees, and the
one that is drivable in tests was the weaker one: every endpoint moved onto the
plan lost the obligation silently, and four of `Page.Upload`'s nine
authenticated requests had already stopped routing their 401.

⚖️ WHAT IS BEING ASSERTED, AND WHY IT IS A PROGRAM TEST. The obligation itself
is checked by the compiler — `Api.interceptExpiry` is also unit-tested through
`Api.interpretAuthed` in `ApiAuthedTest`. What neither of those can show is that
the plan a page builds is actually interpreted that way: `Effect.perform` and
`TestHelpers.simulateEffect` are two interpreters of the same `RequestPlan`, and
this module exists downstream of a defect where two such decisions drifted while
the whole suite stayed green. So these drive a request through a real
interpreter and a real HTTP status.

⚠️ The program's `Msg` is local, deliberately. Every page that takes a 401
already routed one somewhere before this change, which makes a page a BAD
subject for the discriminating case: collapse the two handlers and
`Page.Bookshelf`'s 401 still becomes `SessionExpired`, by its own result
handler, so the test could not fail. A local Msg records WHICH handler ran, so
the probe has somewhere to show. `EffectAuthedExpiryPageTest` then drives the
same claim through a real page, at a site that routed nothing before.

-}

import Api
import Dict
import Effect
import Expect
import Html
import Http
import ProgramTest exposing (ProgramTest, SimulatedEffect)
import SimulatedEffect.Cmd
import Test exposing (Test, describe, test)
import TestHelpers


suite : Test
suite =
    describe "an authenticated plan's 401 is the session ending"
        [ describe "the authenticated constructor"
            [ aPlan401ReachesTheExpiryMsg
            , aPlan403ReachesTheResponseHandler
            , aPlan500ReachesTheResponseHandler
            , aPlanSuccessReachesTheResponseHandler
            , aPlanTransportFailureReachesTheResponseHandler
            ]
        , describe "the public constructor carries no such obligation"
            [ aPublicPlan401ReachesTheResponseHandler
            ]
        ]


{-| Stands in for a page's `Msg`: `Expired` is what `onExpired` produces, and
`Answered` records the status the response handler was given — so "the expiry
msg fired" and "the response handler fired and happened to agree" are
distinguishable outcomes rather than the same one.
-}
type Outcome
    = Waiting
    | Expired
    | Answered String


{-| What `onResponse` makes of a response: the status it saw, named.
-}
answer : Http.Response String -> Outcome
answer response =
    case response of
        Http.BadStatus_ metadata _ ->
            Answered ("status " ++ String.fromInt metadata.statusCode)

        Http.GoodStatus_ _ _ ->
            Answered "success"

        Http.Timeout_ ->
            Answered "timeout"

        Http.NetworkError_ ->
            Answered "network error"

        Http.BadUrl_ url ->
            Answered ("bad url " ++ url)


{-| `GET /api/auth/me`, an endpoint that requires a credential — the shape of
request this obligation is about.
-}
spec : Api.RequestSpec
spec =
    Api.getAccountRequest


{-| A program whose one effect is an AUTHENTICATED plan for that endpoint,
driven through `TestHelpers.simulateEffect` — production's twin interpreter,
pinned to the same header builder by `EffectHeaderParityTest`.
-}
authedProgram : ProgramTest.ProgramDefinition () Outcome Outcome (SimulatedEffect Outcome)
authedProgram =
    programFiring
        (Effect.authed spec
            (TestHelpers.creds "tok")
            { onExpired = Expired, onResponse = answer }
        )


{-| The same program over the PUBLIC constructor, with the credential the viewer
happens to hold. The endpoint is the same one, so the only difference between
this program and the one above is which constructor built the plan.
-}
publicProgram : ProgramTest.ProgramDefinition () Outcome Outcome (SimulatedEffect Outcome)
publicProgram =
    programFiring
        (Effect.public spec
            (Just (TestHelpers.creds "tok"))
            Nothing
            answer
        )


{-| A program that fires one effect at init and whose model is the Msg that came
back, rendered so a failure reports the outcome rather than a mismatch between
two opaque values.
-}
programFiring : Effect.Effect Outcome -> ProgramTest.ProgramDefinition () Outcome Outcome (SimulatedEffect Outcome)
programFiring effect =
    ProgramTest.createElement
        { init = \() -> ( Waiting, TestHelpers.simulateEffect effect )
        , update = \msg _ -> ( msg, SimulatedEffect.Cmd.none )
        , view = \model -> Html.text (render model)
        }
        |> ProgramTest.withSimulatedEffects identity


render : Outcome -> String
render outcome =
    case outcome of
        Waiting ->
            "waiting"

        Expired ->
            "the expiry msg"

        Answered what ->
            "the response handler, with " ++ what


{-| A response with a status, on the endpoint the plan addresses.
-}
responseWith : Int -> Http.Response String
responseWith statusCode =
    Http.BadStatus_
        { url = "/api/auth/me"
        , statusCode = statusCode
        , statusText = "Error"
        , headers = Dict.empty
        }
        "{\"error\":\"nope\"}"


start : ProgramTest.ProgramDefinition () Outcome Outcome (SimulatedEffect Outcome) -> Http.Response String -> ProgramTest Outcome Outcome (SimulatedEffect Outcome)
start program response =
    ProgramTest.start () program
        |> ProgramTest.simulateHttpResponse "GET" "/api/auth/me" response


expectOutcome : Outcome -> ProgramTest Outcome Outcome (SimulatedEffect Outcome) -> Expect.Expectation
expectOutcome expected =
    ProgramTest.expectModel (\model -> Expect.equal (render expected) (render model))


{-| ⛔ The claim. A 401 on an authenticated plan goes to `onExpired`, and the
endpoint's own handler never sees it — the same guarantee `Api.Authed` gives,
now on the path pages are being migrated onto.
-}
aPlan401ReachesTheExpiryMsg : Test
aPlan401ReachesTheExpiryMsg =
    test "authed_plan_401_routes_to_the_expiry_msg: a 401 never reaches the response handler" <|
        \() ->
            start authedProgram (responseWith 401)
                |> expectOutcome Expired


{-| A 403 is the age-gate path on several pages, not an expired session. It must
stay with the handler that asked.
-}
aPlan403ReachesTheResponseHandler : Test
aPlan403ReachesTheResponseHandler =
    test "authed_plan_403_stays_with_the_handler: only the 401 is claimed" <|
        \() ->
            start authedProgram (responseWith 403)
                |> expectOutcome (Answered "status 403")


aPlan500ReachesTheResponseHandler : Test
aPlan500ReachesTheResponseHandler =
    test "authed_plan_500_stays_with_the_handler: a server fault is not an expiry" <|
        \() ->
            start authedProgram (responseWith 500)
                |> expectOutcome (Answered "status 500")


aPlanSuccessReachesTheResponseHandler : Test
aPlanSuccessReachesTheResponseHandler =
    test "authed_plan_200_stays_with_the_handler: the ordinary path is untouched" <|
        \() ->
            start authedProgram
                (Http.GoodStatus_
                    { url = "/api/auth/me"
                    , statusCode = 200
                    , statusText = "OK"
                    , headers = Dict.empty
                    }
                    "{}"
                )
                |> expectOutcome (Answered "success")


{-| ⚠️ A transport failure carries no status at all, and the branch that reads
one must not treat "I could not ask" as "your session ended" — the reader would
be signed out by a flaky network.
-}
aPlanTransportFailureReachesTheResponseHandler : Test
aPlanTransportFailureReachesTheResponseHandler =
    test "authed_plan_network_error_stays_with_the_handler: no status is not a 401" <|
        \() ->
            start authedProgram Http.NetworkError_
                |> expectOutcome (Answered "network error")


{-| ⛔ The distinction requirement, as a test. `Effect.public` answers an
anonymous reader, where a 401 is the server's answer rather than the end of a
session — `POST /api/auth/login` with the wrong password is the standing case.
So the SAME endpoint, the SAME 401 and the SAME credential go to the response
handler when the plan was built by `public`.

⚖️ This is what stops the obligation being implemented as "the plan intercepts
401s": it is the AUTHENTICATED constructor that carries it.
`SessionExpiryTest`'s `login_401_stays_local` asserts the consequence on the
real login form; this asserts the mechanism that produces it.

-}
aPublicPlan401ReachesTheResponseHandler : Test
aPublicPlan401ReachesTheResponseHandler =
    test "public_plan_401_stays_with_the_handler: a public 401 is not an expiry" <|
        \() ->
            start publicProgram (responseWith 401)
                |> expectOutcome (Answered "status 401")
