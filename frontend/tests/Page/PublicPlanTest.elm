module Page.PublicPlanTest exposing (suite)

{-| What a `public` plan does with a 401, on the two pages that have one.

⛔ THE DISTINCTION THESE CASES EXIST FOR. `Effect.authed` claims a 401 at the
seam and routes it to the page's expiry msg. `Effect.public` does NOT, by
design: an endpoint that answers an anonymous reader can return 401 for a reason
that is not an expiry — a wrong password on `POST /api/auth/login` being the
standing example — so the page decides what one means.

⚠️ That makes "the page still re-tests the status itself" **correct** on a public
plan and **residue** on an authed one. A sweep that deleted every
`Api.isUnauthorized` would get `Page.Profile` wrong, and these cases are what
would notice.

⚖️ The two pages differ, deliberately:

  - `Page.Metrics` serves nobody in particular and carries no credential, so it
    has no `OutMsg` and nothing to say about a session.
  - `Page.Profile` carries the viewer's credential WHEN THEY HAVE ONE. An
    anonymous request there is answered 200 or 404, never 401 — so a 401 can
    only mean a credential was sent and refused, and reading it as an expiry is
    right.

-}

import Api
import Dict
import Expect
import Http
import Page.Profile as Profile
import ProgramTest
import Test exposing (Test, describe, test)
import TestHelpers


token : Api.Credentials
token =
    TestHelpers.creds "public-plan-test-token"


failure : String -> Int -> Http.Response String
failure url statusCode =
    Http.BadStatus_
        { url = url
        , statusCode = statusCode
        , statusText = "Error"
        , headers = Dict.empty
        }
        "{\"error\":\"session_expired\"}"


suite : Test
suite =
    describe "a public plan leaves the 401 to the page"
        [ describe "Page.Profile — optional credential, so a 401 IS an expiry"
            [ test "a 401 reaches the page and becomes SessionExpired" <|
                \_ ->
                    ProgramTest.start () (TestHelpers.profileProgram (Just token) "ada")
                        |> ProgramTest.simulateHttpResponse "GET"
                            "/api/u/ada"
                            (failure "/api/u/ada" 401)
                        |> ProgramTest.expectModel
                            (\model -> Expect.equal Profile.SessionExpired model.lastOut)

            -- ⛔ ANTI-VACUITY. Without this, a page that signalled SessionExpired
            -- for every failure would pass the case above while telling a reader
            -- their session had ended whenever the server had a bad day.
            , test "a 500 is shown as a failure, not as an ended session" <|
                \_ ->
                    ProgramTest.start () (TestHelpers.profileProgram (Just token) "ada")
                        |> ProgramTest.simulateHttpResponse "GET"
                            "/api/u/ada"
                            (failure "/api/u/ada" 500)
                        |> ProgramTest.expectModel
                            (\model -> Expect.equal Profile.NoOut model.lastOut)

            -- ⚖️ The handle reaches the URL percent-encoded now, where the old
            -- builder concatenated it. Asserted by asking for a handle the old
            -- `baseUrl ++ "/api/u/" ++ handle` would have passed through raw.
            , test "the handle is encoded into the path rather than concatenated" <|
                \_ ->
                    ProgramTest.start () (TestHelpers.profileProgram Nothing "a da")
                        |> ProgramTest.simulateHttpResponse "GET"
                            "/api/u/a%20da"
                            (failure "/api/u/a%20da" 404)
                        |> ProgramTest.expectModel
                            (\model -> Expect.equal Profile.NoOut model.lastOut)
            ]
        , describe "Page.Metrics — no credential, so nothing to say about a session"
            [ test "the public transparency request is reachable and answerable" <|
                \_ ->
                    ProgramTest.start () TestHelpers.metricsProgram
                        |> ProgramTest.simulateHttpResponse "GET"
                            "/api/transparency/metrics"
                            (failure "/api/transparency/metrics" 503)
                        |> ProgramTest.expectModel (\_ -> Expect.pass)
            ]
        ]
