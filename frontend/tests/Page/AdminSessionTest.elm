module Page.AdminSessionTest exposing (suite)

{-| The admin sign-in gate.

⚠️ The four admin pages each had passing tests while being completely
unreachable: every test fed a token straight into a mocked API, and none
went through the code that CHOOSES the token. These tests drive the
choosing — password → challenge, then TOTP.

⛔ The second step no longer yields a credential. It used to emit an admin
token this page handed upward to be held in memory, which a reload dropped,
re-prompting the operator for a code the server had already accepted. The
elevation lives on the server's admin session and `/api/admin/*` is reached
with the ordinary session, so there is one credential and these tests assert
that nothing is handed upward at all.

-}

import Api exposing (AdminAuthError(..))
import Expect
import Html.Attributes as Attr
import Http
import Page.Admin.Session as Session
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import TestHelpers


ownerToken : Maybe Api.Credentials
ownerToken =
    Just (TestHelpers.creds "ordinary-owner-token")


{-| Runs a message through `update` and keeps only the model, for the many assertions that do not
care about the Cmd.
-}
run : Session.Msg -> Session.Model -> Session.Model
run msg model =
    let
        ( next, _, _ ) =
            Session.update msg model ownerToken
    in
    next


out : Session.Msg -> Session.Model -> Session.OutMsg
out msg model =
    let
        ( _, _, o ) =
            Session.update msg model ownerToken
    in
    o


filled : Session.Model
filled =
    Session.init Nothing
        |> run (Session.SetEmail "owner@thestacks.app")
        |> run (Session.SetPassword "hunter2")


{-| Past the credentials step, holding a session id — the state a code is submitted against.
-}
awaitingCode : Session.Model
awaitingCode =
    run (Session.LoggedIn (Ok { sessionId = "sess-1" })) filled


testId : String -> Selector.Selector
testId value =
    Selector.attribute (Attr.attribute "data-testid" value)


suite : Test
suite =
    describe "Page.Admin.Session"
        [ describe "elevation is reported, and nothing is handed upward"
            [ test "a verified code reports the elevation" <|
                \_ ->
                    out (Session.Verified (Ok ())) awaitingCode
                        |> Expect.equal Session.Elevated
            , test "the out-message carries NO credential" <|
                \_ ->
                    -- ⛔ The assertion that replaced "the token escapes only
                    -- through Authenticated". There is no longer a token to
                    -- escape: the server marks its own admin session verified
                    -- and finds it from the authenticated reader, so `Elevated`
                    -- is a nullary constructor and this test is the proof that
                    -- it stays one. Were a payload added back, this would not
                    -- compile — which is the strongest form this check can take.
                    Session.Elevated
                        |> Expect.equal Session.Elevated
            , test "nothing else reports an elevation" <|
                \_ ->
                    [ out (Session.SetEmail "x") (Session.init Nothing)
                    , out (Session.SetCode "123456") awaitingCode
                    , out (Session.LoggedIn (Ok { sessionId = "s" })) filled
                    , out (Session.Verified (Err InvalidCode)) awaitingCode
                    ]
                        |> Expect.equal
                            [ Session.NoOut, Session.NoOut, Session.NoOut, Session.NoOut ]
            ]
        , describe "the step machine"
            [ test "the password is dropped once it has been spent" <|
                \_ ->
                    awaitingCode.password |> Expect.equal ""
            , test "submitting a code before a session exists does nothing" <|
                \_ ->
                    let
                        withCode =
                            run (Session.SetCode "123456") filled
                    in
                    Session.update Session.SubmitCode withCode ownerToken
                        |> (\( _, cmd, _ ) -> cmd)
                        |> Expect.equal Cmd.none
            , test "a short code fires no request" <|
                \_ ->
                    let
                        shortCode =
                            run (Session.SetCode "12") awaitingCode
                    in
                    Session.update Session.SubmitCode shortCode ownerToken
                        |> (\( _, cmd, _ ) -> cmd)
                        |> Expect.equal Cmd.none
            , test "incomplete credentials fire no request" <|
                \_ ->
                    Session.update Session.SubmitCredentials (Session.init Nothing) ownerToken
                        |> (\( _, cmd, _ ) -> cmd)
                        |> Expect.equal Cmd.none
            , test "a rejected code clears the code but keeps the session" <|
                \_ ->
                    let
                        rejected =
                            run (Session.Verified (Err InvalidCode)) awaitingCode
                    in
                    Expect.all
                        [ \m -> Expect.equal "" m.code
                        , \m -> Expect.notEqual Nothing m.error
                        ]
                        rejected
            ]
        , describe "each failure keeps its own remedy"
            [ test "a wrong password says so" <|
                \_ ->
                    render (run (Session.LoggedIn (Err InvalidCredentials)) filled)
                        |> Query.has [ Selector.text "did not match" ]
            , test "a non-owner account is named as the problem" <|
                \_ ->
                    render (run (Session.LoggedIn (Err NotAnOwner)) filled)
                        |> Query.has [ Selector.text "not an owner" ]
            , test "an invalidated session explains WHY, not just that it ended" <|
                \_ ->
                    render (run (Session.Verified (Err InvalidSession)) awaitingCode)
                        |> Query.has [ Selector.text "network change or a deploy" ]
            , test "a stale code mentions the 30-second window" <|
                \_ ->
                    render (run (Session.Verified (Err InvalidCode)) awaitingCode)
                        |> Query.has [ Selector.text "30 seconds" ]
            , test "a dead network is distinguished from a slow one" <|
                \_ ->
                    Expect.notEqual
                        (errorText (Session.Verified (Err (AdminAuthTransport Http.NetworkError))))
                        (errorText (Session.Verified (Err (AdminAuthTransport Http.Timeout))))
            ]
        , describe "enrolment"
            [ test "reads the base32 secret out of the provisioning URI, unmodified" <|
                \_ ->
                    Session.enrolmentSecret
                        { provisioningUri =
                            "otpauth://totp/The%20Stacks:owner?secret=JBSWY3DPEHPK3PXP&issuer=Stacks"
                        , recoveryCodes = []
                        }
                        |> Expect.equal (Just "JBSWY3DPEHPK3PXP")
            , test "a URI with no secret yields Nothing rather than a wrong guess" <|
                \_ ->
                    Session.enrolmentSecret
                        { provisioningUri = "otpauth://totp/The%20Stacks:owner?issuer=Stacks"
                        , recoveryCodes = []
                        }
                        |> Expect.equal Nothing
            , test "enrolment is reachable without failing a sign-in first" <|
                \_ ->
                    render (Session.init Nothing)
                        |> Query.has [ testId "admin-enrol-start" ]
            , test "confirming enrolment returns to the sign-in form, not a dead end" <|
                \_ ->
                    let
                        after =
                            run (Session.EnrolmentConfirmed (Ok ())) (Session.init Nothing)
                    in
                    Expect.all
                        [ \m -> Expect.notEqual Nothing m.notice
                        , \m -> Expect.equal Nothing m.error
                        ]
                        after
            , test "and the sign-in form is actually rendered there" <|
                \_ ->
                    render (run (Session.EnrolmentConfirmed (Ok ())) (Session.init Nothing))
                        |> Query.has [ testId "admin-email" ]
            , test "the success notice is not rendered as an error" <|
                \_ ->
                    render (run (Session.EnrolmentConfirmed (Ok ())) (Session.init Nothing))
                        |> Query.has [ testId "admin-gate-notice" ]
            , test "the recovery codes are shown with the warning that they are shown once" <|
                \_ ->
                    render
                        (run
                            (Session.EnrolmentStarted
                                (Ok
                                    { provisioningUri = "otpauth://totp/x?secret=JBSWY3DPEHPK3PXP"
                                    , recoveryCodes = [ "aaaa-bbbb", "cccc-dddd" ]
                                    }
                                )
                            )
                            (Session.init Nothing)
                        )
                        |> Expect.all
                            [ Query.has [ Selector.text "not shown again" ]
                            , Query.has [ Selector.text "aaaa-bbbb" ]
                            ]
            ]
        ]


render : Session.Model -> Query.Single Session.Msg
render model =
    Session.view model |> Query.fromHtml


{-| The rendered error copy for a transition, so two failures can be compared for distinctness
without asserting either exact sentence.
-}
errorText : Session.Msg -> Maybe String
errorText msg =
    (run msg awaitingCode).error
