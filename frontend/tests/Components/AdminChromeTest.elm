module Components.AdminChromeTest exposing (suite)

{-| The admin chrome's sign-out affordance, driven the way an operator drives
it: click the button, then read the request that leaves.

⛔ The endpoint being _routed_ was never the problem — `DELETE
/api/admin/auth/logout` revoked correctly all along, and nothing called it. So
the assertion that matters here is not "the model changed" but "a request went
out, to that path, carrying the ADMIN token", and the request under assertion
is derived from `Api.adminLogoutRequest` through `Effect`, never restated. A
test that hardcoded the URL could agree with itself while production drifted —
which is how the sibling defect (pages sending the ordinary token to
`/api/admin/*`) stayed invisible behind a green suite.

-}

import Components.AdminChrome as AdminChrome
import Dict
import Expect
import Http
import ProgramTest exposing (SimulatedEffect)
import Test exposing (Test, describe, test)
import Test.Html.Selector as Selector
import TestHelpers


adminToken : String
adminToken =
    "admin-session-token"


logoutEndpoint : String
logoutEndpoint =
    "/api/admin/auth/logout"


start : ProgramTest.ProgramTest TestHelpers.AdminChromeTestModel AdminChrome.Msg (SimulatedEffect AdminChrome.Msg)
start =
    ProgramTest.start () (TestHelpers.adminChromeProgram (Just adminToken))


{-| The chrome as it appears to someone who arrived without an admin token —
which `Main` never renders, but the harness can, and it pins the no-token
branch.
-}
startWithoutToken : ProgramTest.ProgramTest TestHelpers.AdminChromeTestModel AdminChrome.Msg (SimulatedEffect AdminChrome.Msg)
startWithoutToken =
    ProgramTest.start () (TestHelpers.adminChromeProgram Nothing)


okResponse : Http.Response String
okResponse =
    Http.GoodStatus_
        { url = logoutEndpoint
        , statusCode = 200
        , statusText = "OK"
        , headers = Dict.empty
        }
        "{\"ok\":true}"


errorResponse : Int -> Http.Response String
errorResponse statusCode =
    Http.BadStatus_
        { url = logoutEndpoint
        , statusCode = statusCode
        , statusText = "Error"
        , headers = Dict.empty
        }
        "{\"error\":\"nope\"}"


suite : Test
suite =
    describe "Components.AdminChrome — ending an admin session"
        [ offersTheAffordance
        , clickRevokesServerSide
        , clickCarriesTheAdminToken
        , successEndsTheSession
        , unauthorisedEndsTheSession
        , serverErrorKeepsTheSession
        , networkErrorKeepsTheSession
        , inFlightSendsOnlyOnce
        , noTokenSendsNothing
        ]


offersTheAffordance : Test
offersTheAffordance =
    test "offers_affordance: every admin surface carries a way out of the session" <|
        \() ->
            start
                |> ProgramTest.expectViewHas [ Selector.text "End admin session" ]


{-| The whole point of the issue: the click must produce a REQUEST. Asserting
the rendered state alone would pass just as happily against a button that only
cleared local state — the defect being fixed.
-}
clickRevokesServerSide : Test
clickRevokesServerSide =
    test "click_revokes: ending the session sends DELETE to the revoke endpoint" <|
        \() ->
            start
                |> ProgramTest.clickButton "End admin session"
                |> ProgramTest.expectHttpRequestWasMade "DELETE" logoutEndpoint


{-| `/api/admin/*` 401s the ordinary Guardian token. A sign-out that sent it
would look like it worked (the operator is re-gated either way) while the
session stayed open for the rest of its window.
-}
clickCarriesTheAdminToken : Test
clickCarriesTheAdminToken =
    test "click_admin_token: the revoke carries the admin token, not the ordinary one" <|
        \() ->
            start
                |> ProgramTest.clickButton "End admin session"
                |> ProgramTest.expectHttpRequest "DELETE"
                    logoutEndpoint
                    (.headers
                        >> Expect.equal [ ( "Authorization", "Bearer " ++ adminToken ) ]
                    )


successEndsTheSession : Test
successEndsTheSession =
    test "success_ends: a revoked session asks Main to drop the token" <|
        \() ->
            start
                |> ProgramTest.clickButton "End admin session"
                |> ProgramTest.simulateHttpResponse "DELETE" logoutEndpoint okResponse
                |> ProgramTest.expectModel
                    (.lastOut >> Expect.equal AdminChrome.SessionEnded)


{-| A 401 means the token is already gone server-side, so the session IS over.
Reporting a failure would leave the operator staring at an admin surface they
no longer have a session for.
-}
unauthorisedEndsTheSession : Test
unauthorisedEndsTheSession =
    test "unauthorised_ends: a 401 counts as ended, because the token is already dead" <|
        \() ->
            start
                |> ProgramTest.clickButton "End admin session"
                |> ProgramTest.simulateHttpResponse "DELETE" logoutEndpoint (errorResponse 401)
                |> ProgramTest.expectModel
                    (.lastOut >> Expect.equal AdminChrome.SessionEnded)


{-| ⚠️ The honesty case. If the revoke did not happen, saying "ended" would be
the original defect with a button on it: local state cleared, session still
live. The chrome keeps the session and says so.
-}
serverErrorKeepsTheSession : Test
serverErrorKeepsTheSession =
    test "server_error_keeps: a refused revoke leaves the session open and says so" <|
        \() ->
            start
                |> ProgramTest.clickButton "End admin session"
                |> ProgramTest.simulateHttpResponse "DELETE" logoutEndpoint (errorResponse 500)
                |> ProgramTest.ensureViewHas
                    [ Selector.text "It is still open — try again." ]
                |> ProgramTest.expectModel
                    (.lastOut >> Expect.equal AdminChrome.NoOut)


networkErrorKeepsTheSession : Test
networkErrorKeepsTheSession =
    test "network_error_keeps: a revoke that never arrived leaves the session open" <|
        \() ->
            start
                |> ProgramTest.clickButton "End admin session"
                |> ProgramTest.simulateHttpResponse "DELETE" logoutEndpoint Http.NetworkError_
                |> ProgramTest.ensureViewHas
                    [ Selector.text "this admin session is still open" ]
                |> ProgramTest.expectModel
                    (.lastOut >> Expect.equal AdminChrome.NoOut)


{-| The button disables while the revoke is in flight, so a second click cannot
fire a second DELETE against a token the first one is already revoking.
-}
inFlightSendsOnlyOnce : Test
inFlightSendsOnlyOnce =
    test "in_flight_once: a second EndSession while one is in flight sends nothing more" <|
        \() ->
            start
                |> ProgramTest.clickButton "End admin session"
                |> ProgramTest.update AdminChrome.EndSession
                |> ProgramTest.expectHttpRequests "DELETE"
                    logoutEndpoint
                    (List.length >> Expect.equal 1)


noTokenSendsNothing : Test
noTokenSendsNothing =
    test "no_token_none: with no admin token there is nothing to revoke, so nothing is sent" <|
        \() ->
            startWithoutToken
                |> ProgramTest.clickButton "End admin session"
                |> ProgramTest.ensureHttpRequests "DELETE"
                    logoutEndpoint
                    (List.length >> Expect.equal 0)
                |> ProgramTest.expectModel
                    (.lastOut >> Expect.equal AdminChrome.SessionEnded)
