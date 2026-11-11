module Page.AuditLogExpiryTest exposing (suite)

{-| What an expired session means to a reader asking for their own audit history.

⛔ THIS TEST COULD NOT HAVE BEEN WRITTEN BEFORE THE MIGRATION, and that is the
claim it exists to make concrete. `Page.Settings.AuditLog.init` returned a
`Cmd Msg` built by `Api.getAuditLog`. `elm-program-test` cannot inspect a `Cmd`
or answer one, so there was no way to hand this page an HTTP response — the page
had exactly one branch worth testing and it was unreachable from a test.

Now `initWithEffect` returns the request as DATA. The harness can see which
endpoint is asked for and reply to it, so a 401 can be delivered and the page's
answer observed.

⚠️ And the behaviour under test is new too. The old handler decided what a 401
meant itself, with an `Api.isUnauthorized` re-test inside `AuditLogReceived`.
Now `Effect.authed` demands `onExpired` at construction, so the page cannot ask
this endpoint without saying what an ended session means to it.

-}

import Api
import Dict
import Expect
import Http
import Page.Settings.AuditLog as AuditLog
import ProgramTest
import Test exposing (Test, describe, test)
import TestHelpers


token : Api.Credentials
token =
    TestHelpers.creds "audit-log-test-token"


endpoint : String
endpoint =
    "/api/settings/audit-log?page=1"


responseWith : Int -> Http.Response String
responseWith statusCode =
    Http.BadStatus_
        { url = endpoint
        , statusCode = statusCode
        , statusText = "Error"
        , headers = Dict.empty
        }
        "{\"error\":\"session_expired\"}"


respondWith : Int -> ProgramTest.ProgramTest TestHelpers.AuditLogTestModel AuditLog.Msg (ProgramTest.SimulatedEffect AuditLog.Msg) -> ProgramTest.ProgramTest TestHelpers.AuditLogTestModel AuditLog.Msg (ProgramTest.SimulatedEffect AuditLog.Msg)
respondWith statusCode =
    ProgramTest.simulateHttpResponse "GET" endpoint (responseWith statusCode)


suite : Test
suite =
    describe "the audit-log page's answer to an ended session"
        [ test "a 401 becomes the page's session-expiry signal to Main" <|
            \_ ->
                ProgramTest.start () (TestHelpers.auditLogProgram (Just token))
                    |> respondWith 401
                    |> ProgramTest.expectModel
                        (\model ->
                            Expect.equal AuditLog.SessionExpired model.lastOut
                        )

        -- ⛔ ANTI-VACUITY, and it is the case that makes the one above mean
        -- something. If every response produced `SessionExpired`, the test above
        -- would pass while proving the page had simply stopped distinguishing
        -- failures. A 500 is a failure the reader should see AS a failure.
        , test "a 500 is not an expiry — the reader is shown an error, not signed out" <|
            \_ ->
                ProgramTest.start () (TestHelpers.auditLogProgram (Just token))
                    |> respondWith 500
                    |> ProgramTest.expectModel
                        (\model ->
                            Expect.equal AuditLog.NoOut model.lastOut
                        )

        -- ⚖️ The page asks nothing at all without a credential, so there is no
        -- request to answer. Asserted because the migration moved the `case
        -- maybeToken` into `initWithEffect`, and a plan built unconditionally
        -- would send an unauthenticated request to an authenticated endpoint.
        , test "no credential means no request, rather than an unauthenticated one" <|
            \_ ->
                ProgramTest.start () (TestHelpers.auditLogProgram Nothing)
                    |> ProgramTest.expectModel
                        (\model ->
                            Expect.equal AuditLog.NoOut model.lastOut
                        )
        ]
