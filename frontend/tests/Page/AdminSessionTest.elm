module Page.AdminSessionTest exposing (suite)

{-| The admin sign-in gate (#303).

⚠️ **The four admin pages each had passing tests while being completely unreachable**, because every
one of them fed a token straight into a mocked API. None went through the code that _chooses_ the
token, so a page handed the ordinary Guardian token — which the `:admin` pipeline rejects with 401 —
looked perfectly healthy. This module tests the choosing.

What is worth guarding here:

1.  **The step machine cannot reach an impossible state.** A code can only be submitted against a
    session id that exists, and the password is dropped as soon as it is spent.
2.  **`Authenticated` is the only way a token escapes.** Main holds it in memory; if this module
    ever stored or leaked it the in-memory decision (#303 Design) would be quietly undone.
3.  **Every failure keeps its own remedy.** A wrong password, a non-owner account, a missing factor
    and a stale code are four different next actions. Collapsing them into "something went wrong"
    is the failure mode that makes operator tooling unusable.
4.  **`enrolmentSecret` reads the URI the way the endpoint expects** — base32, unmodified. The
    endpoint used to demand base64 and no client could satisfy it; this pins the direction.

-}

import Api exposing (AdminAuthError(..))
import Expect
import Html.Attributes as Attr
import Http
import Page.Admin.Session as Session
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector


ownerToken : Maybe String
ownerToken =
    Just "ordinary-owner-token"


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
    Session.init
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
        [ describe "the token escapes only through Authenticated"
            [ test "a verified code emits the admin token" <|
                \_ ->
                    out (Session.Verified (Ok "admin-token-abc")) awaitingCode
                        |> Expect.equal (Session.Authenticated "admin-token-abc")
            , test "nothing else emits a token" <|
                \_ ->
                    -- If any other transition could emit one, Main would hold a token obtained
                    -- without a second factor.
                    [ out (Session.SetEmail "x") Session.init
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
                    -- It is not needed after step 1, and keeping it in the model past that point is
                    -- gratuitous exposure.
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
                    -- Guards against the button being bypassed by a keyboard submit: `update` has
                    -- to refuse too, not rely on `disabled`.
                    let
                        shortCode =
                            run (Session.SetCode "12") awaitingCode
                    in
                    Session.update Session.SubmitCode shortCode ownerToken
                        |> (\( _, cmd, _ ) -> cmd)
                        |> Expect.equal Cmd.none
            , test "incomplete credentials fire no request" <|
                \_ ->
                    Session.update Session.SubmitCredentials Session.init ownerToken
                        |> (\( _, cmd, _ ) -> cmd)
                        |> Expect.equal Cmd.none
            , test "a rejected code clears the code but keeps the session" <|
                \_ ->
                    -- The operator retries with a fresh code; making them re-enter the password
                    -- would be punishing them for a 30-second window.
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
                    -- ⚠️ The admin session is bound to the client IP and the node's boot_id, so a
                    -- network change or a deploy ends it. An operator told only "signed out" goes
                    -- looking for the wrong problem.
                    render (run (Session.Verified (Err InvalidSession)) awaitingCode)
                        |> Query.has [ Selector.text "network change or a deploy" ]
            , test "a stale code mentions the 30-second window" <|
                \_ ->
                    render (run (Session.Verified (Err InvalidCode)) awaitingCode)
                        |> Query.has [ Selector.text "30 seconds" ]
            , test "a dead network is distinguished from a slow one" <|
                \_ ->
                    -- The `Http.Error` payload is carried for this: "no connection" and "too slow"
                    -- lead to different actions.
                    Expect.notEqual
                        (errorText (Session.Verified (Err (AdminAuthTransport Http.NetworkError))))
                        (errorText (Session.Verified (Err (AdminAuthTransport Http.Timeout))))
            ]
        , describe "enrolment"
            [ test "reads the base32 secret out of the provisioning URI, unmodified" <|
                \_ ->
                    -- ⚠️ Pins the encoding direction. `mfa_confirm` used to demand base64 of the raw
                    -- bytes while `mfa_setup` published base32 — an impossible contract for any
                    -- client. The endpoint now takes what it publishes; this asserts we pass it
                    -- through rather than "helpfully" converting.
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
                    -- Signing in only to be told "you have no second factor" is a detour when the
                    -- operator already knows.
                    render Session.init
                        |> Query.has [ testId "admin-enrol-start" ]
            , test "confirming enrolment returns to the sign-in form, not a dead end" <|
                \_ ->
                    -- ⛔ It used to render a terminal panel saying "Sign in above to open an admin
                    -- session" while BEING the only thing on the page — the form it referred to had
                    -- been replaced. The operator finished enrolling and had nowhere to go but a
                    -- manual reload, actively misdirected by the copy. Found by driving it.
                    let
                        after =
                            run (Session.EnrolmentConfirmed (Ok ())) Session.init
                    in
                    Expect.all
                        [ \m -> Expect.notEqual Nothing m.notice
                        , \m -> Expect.equal Nothing m.error
                        ]
                        after
            , test "and the sign-in form is actually rendered there" <|
                \_ ->
                    render (run (Session.EnrolmentConfirmed (Ok ())) Session.init)
                        |> Query.has [ testId "admin-email" ]
            , test "the success notice is not rendered as an error" <|
                \_ ->
                    -- Separate fields, separate elements: a success shown in the error slot trains
                    -- the operator to ignore the error slot.
                    render (run (Session.EnrolmentConfirmed (Ok ())) Session.init)
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
                            Session.init
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
