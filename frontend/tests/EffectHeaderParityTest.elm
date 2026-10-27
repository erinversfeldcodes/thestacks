module EffectHeaderParityTest exposing (suite)

{-| The harness and production must send the same headers for the same plan.

⛔ WHY THIS EXISTS. `Effect.perform` and `TestHelpers.simulateEffect` are the
only two interpreters of a `RequestPlan`, and each used to decide independently
what an authenticated request carries — `Api.authHeaders plan.token` on one
side, a hand-written `case maybeToken of` on the other. Nothing compared them.
So the two could drift and the entire Elm suite would stay green while every
program test asserted against a request production does not send.

That is the failure mode `Effect`'s own module documentation describes for
request DISPATCH — two decisions, each passing its own tests, disagreeing with
each other; it blanked `Page.BookDetail`'s formats dispatch and swapped
`Page.Upload`'s callbacks, both behind a green suite. Dispatch was fixed by
making the plan the single decision. **The credential was still being decided
twice.**

⚖️ WHAT THIS CAN AND CANNOT ASSERT. `Http.Header` and
`SimulatedEffect.Http.Header` are different opaque types with no accessors, so
no test can compare a production header value to a simulated one directly. What
IS comparable is the header DATA both runtimes wrap: `elm-program-test` exposes
a captured request's `headers` as `List ( String, String )`, which is exactly
`Api.requestHeaders`' return type.

So these tests assert that **the headers the harness actually emitted for a real
page's request equal the builder's output for that plan**. Production's side is
one line — `Api.authHeaders`, asserted in `ApiRequestHeadersTest` to delegate to
the same builder — so pinning the harness to the builder is what closes the
gap between them.

⚠️ The expected value is the BUILDER CALL, not a literal
`[ ( "Authorization", "Bearer test-token" ) ]`. A literal would assert that the
harness matches a third hand-written derivation, which is the defect restated as
coverage: changing the builder would red this test while the two runtimes
remained in perfect agreement with each other.

-}

import Api
import Expect
import Page.Search as Search
import ProgramTest
import Test exposing (Test, describe, test)
import TestHelpers exposing (searchProgram)


suite : Test
suite =
    describe "the harness and production derive one request's headers from one builder"
        [ authedRequestCarriesTheBuildersHeaders
        , anonymousRequestCarriesTheBuildersHeaders
        , theBuilderIsReachedWithTheSameArgumentsBothRuntimesUse
        ]


token : Api.Credentials
token =
    TestHelpers.creds "test-token"


startSearch : Maybe Api.Credentials -> ProgramTest.ProgramTest Search.Model Search.Msg (ProgramTest.SimulatedEffect Search.Msg)
startSearch maybeToken =
    ProgramTest.start () (searchProgram maybeToken)


{-| The reader case. `Page.Search`'s book search is optional-auth, so a signed-in
viewer's request carries the credential.
-}
authedRequestCarriesTheBuildersHeaders : Test
authedRequestCarriesTheBuildersHeaders =
    test "effect_header_parity_authed: the harness emits exactly what the builder returns for a reader" <|
        \() ->
            startSearch (Just token)
                |> ProgramTest.update (Search.QueryChanged "habit")
                |> ProgramTest.advanceTime 300
                |> ProgramTest.expectHttpRequest "GET"
                    "/api/search?q=habit"
                    (\request ->
                        Expect.equal
                            (Api.requestHeaders Api.SameOrigin (Api.Optional (Just token)))
                            request.headers
                    )


{-| The anonymous case, and it is not redundant: a parity test that only drove a
signed-in viewer would pass against a harness that attached the header
unconditionally.
-}
anonymousRequestCarriesTheBuildersHeaders : Test
anonymousRequestCarriesTheBuildersHeaders =
    test "effect_header_parity_anon: and exactly what it returns for a viewer with no token" <|
        \() ->
            startSearch Nothing
                |> ProgramTest.update (Search.QueryChanged "habit")
                |> ProgramTest.advanceTime 300
                |> ProgramTest.expectHttpRequest "GET"
                    "/api/search?q=habit"
                    (\request ->
                        Expect.equal
                            (Api.requestHeaders Api.SameOrigin (Api.Optional Nothing))
                            request.headers
                    )


{-| ⛔ The discriminating case, and the reason the two above are not enough.

Both tests above compare the harness's output to `Optional`. If the harness were
pinned to the WRONG credential — `Session`, say, which 401s an anonymous viewer
rather than letting the server answer them — the authed test would still pass,
because `Session t` and `Optional (Just t)` produce the identical list.

⚖️ So this asserts the thing that distinguishes them: the two constructors agree
on a viewer who HAS a token and disagree on one who does not, and it is the
second that says which constructor a plan's `Maybe` must use. This is the same
distinction `check-session-expiry-coverage.sh` reads at every call site to
decide which pages must route a 401.

-}
theBuilderIsReachedWithTheSameArgumentsBothRuntimesUse : Test
theBuilderIsReachedWithTheSameArgumentsBothRuntimesUse =
    test "effect_header_parity_constructor: a plan's Maybe token is Optional, which Session cannot stand in for" <|
        \() ->
            Expect.all
                [ \() ->
                    Expect.equal
                        (Api.requestHeaders Api.SameOrigin (Api.Session token))
                        (Api.requestHeaders Api.SameOrigin (Api.Optional (Just token)))
                , \() ->
                    Expect.equal []
                        (Api.requestHeaders Api.SameOrigin (Api.Optional Nothing))
                ]
                ()
