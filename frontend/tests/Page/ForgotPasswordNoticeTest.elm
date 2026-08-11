module Page.ForgotPasswordNoticeTest exposing (suite)

{-| The forgot-password acknowledgement (#363).

Asking for a reset link is a request whose whole outcome is a sentence: the
reader's inbox is somewhere else, and the endpoint deliberately answers the same
way whether or not the address is registered, so this line is the only evidence
anything happened.

It was rendered as `p [ class "login-card__subtitle" ]` — the same class as the
"Enter your email and we'll send you a link" helper text two elements above it,
in no live region at all. A screen-reader user pressed the button and was told
nothing; a sighted one got a line of helper text where a confirmation belonged.

Driven through the real card: switch to reset mode, type an address, press the
button, answer the request.

-}

import Api exposing (RequestError)
import Dict
import Expect
import Html.Attributes
import Http
import Page.Login as Login
import ProgramTest
import Test exposing (Test, describe, test)
import Test.Html.Selector as Selector
import TestHelpers exposing (loginProgram)
import Types.RemoteData exposing (RemoteData(..))


{-| The card in reset mode with an address typed in, one press away from asking.
-}
askingForALink : ProgramTest.ProgramTest Login.Model Login.Msg (ProgramTest.SimulatedEffect Login.Msg)
askingForALink =
    ProgramTest.start () loginProgram
        |> ProgramTest.clickButton "Forgot your password?"
        |> ProgramTest.fillIn "email" "Email" "reader@stacks.dev"
        |> ProgramTest.clickButton "Send reset link"


suite : Test
suite =
    describe "Forgot-password acknowledgement"
        [ test "a successful request is announced, not merely drawn" <|
            \() ->
                askingForALink
                    |> ProgramTest.simulateHttpOk "POST" "/api/auth/forgot-password" "{}"
                    |> ProgramTest.expectViewHas
                        [ Selector.attribute (Html.Attributes.attribute "role" "status")
                        , Selector.text "If that email is registered, a reset link is on its way. Check your inbox."
                        ]
        , test "the acknowledgement is a notice, not helper text" <|
            \() ->
                askingForALink
                    |> ProgramTest.simulateHttpOk "POST" "/api/auth/forgot-password" "{}"
                    |> ProgramTest.ensureViewHas
                        [ Selector.class "login-card__notice"
                        , Selector.text "If that email is registered, a reset link is on its way. Check your inbox."
                        ]
                    |> ProgramTest.expectViewHasNot
                        [ Selector.text "If that email is registered, a reset link is on its way. Check your inbox."
                        , Selector.class "login-card__subtitle"
                        ]
        , test "positive control — nothing is acknowledged before the request answers" <|
            \() ->
                ProgramTest.start () loginProgram
                    |> ProgramTest.clickButton "Forgot your password?"
                    |> ProgramTest.expectViewHasNot
                        [ Selector.text "If that email is registered, a reset link is on its way. Check your inbox." ]
        , test "a failed request is announced too" <|
            \() ->
                askingForALink
                    |> ProgramTest.simulateHttpResponse "POST"
                        "/api/auth/forgot-password"
                        (Http.BadStatus_
                            { url = "/api/auth/forgot-password"
                            , statusCode = 500
                            , statusText = "Internal Server Error"
                            , headers = Dict.empty
                            }
                            ""
                        )
                    |> ProgramTest.expectViewHas
                        [ Selector.attribute (Html.Attributes.attribute "role" "status")
                        , Selector.class "login-card__error"
                        , Selector.text "Something went wrong at our end, and we cannot say what."
                        ]
        , test "a throttled request says to wait, and how long, when the server said" <|
            \() ->
                askingForALink
                    |> ProgramTest.simulateHttpResponse "POST"
                        "/api/auth/forgot-password"
                        (throttled (Dict.fromList [ ( "retry-after", "60" ) ]))
                    |> ProgramTest.expectViewHas
                        [ Selector.text "Please wait a minute before trying again." ]
        , test "a throttled request with no retry-after names no interval at all" <|
            \() ->
                askingForALink
                    |> ProgramTest.simulateHttpResponse "POST"
                        "/api/auth/forgot-password"
                        (throttled Dict.empty)
                    |> ProgramTest.ensureViewHas
                        [ Selector.text "Please wait a little while before trying again." ]
                    |> ProgramTest.expectViewHasNot
                        [ Selector.text "60 seconds" ]
        , doubleSendIsImpossible
        , forgotFailureReopensTheButton
        , disabledStateIsAddressIndependent
        ]


{-| A 429 carrying whatever `retry-after` the caller wants to have been sent.
-}
throttled : Dict.Dict String String -> Http.Response String
throttled headers =
    Http.BadStatus_
        { url = "/api/auth/forgot-password"
        , statusCode = 429
        , statusText = "Too Many Requests"
        , headers = headers
        }
        ""


{-| ⛔ The double-send (Issue #374).

Modelled on #373's resend guard and true for the same reason:
`expectHttpRequests` counts requests still AWAITING a response, so the zero below
means "the second press started nothing", not "nothing ever happened". The first
press is proved by the `simulateHttpOk` above it, which fails outright if there
was no matching request in flight to answer.

The second press arrives as a message rather than a click because that is the
case the guard has to survive: `disabled` is a hint, and a keyboard, a screen
reader or two clicks landing in one frame all deliver `ForgotSubmitted` anyway.

Before this, the button re-armed the instant the 200 arrived and still read "Send
reset link", so a reader who pressed twice queued a second reset mail — which
invalidates the link in the first.

-}
doubleSendIsImpossible : Test
doubleSendIsImpossible =
    test "double_send_is_impossible: pressing again after it worked sends nothing more" <|
        \() ->
            askingForALink
                |> ProgramTest.simulateHttpOk "POST" "/api/auth/forgot-password" "{}"
                |> ProgramTest.ensureViewHas [ Selector.text "Reset link sent" ]
                |> ProgramTest.update Login.ForgotSubmitted
                |> ProgramTest.expectHttpRequests "POST"
                    "/api/auth/forgot-password"
                    (\requests -> Expect.equal 0 (List.length requests))


{-| The control for the test above, and a requirement of its own: a FAILED
request must stay retryable.

Without this, `isForgotDisabled` could be `always True` after the first press —
locking a reader out of password reset entirely — and the double-send test above
would still pass.

-}
forgotFailureReopensTheButton : Test
forgotFailureReopensTheButton =
    test "forgot_failure_reopens: a failed attempt can be retried" <|
        \() ->
            askingForALink
                |> ProgramTest.simulateHttpResponse "POST" "/api/auth/forgot-password" Http.NetworkError_
                |> ProgramTest.ensureViewHas
                    [ Selector.text "The library is unreachable. Check your connection, then try again." ]
                |> ProgramTest.update Login.ForgotSubmitted
                |> ProgramTest.expectHttpRequests "POST"
                    "/api/auth/forgot-password"
                    (\requests -> Expect.equal 1 (List.length requests))


{-| ⛔ The disabled state may not depend on whether the address exists (#374).

`AuthController.forgot_password/2` answers 200 with ONE literal body for every
address — that uniformity is the whole of its no-enumeration property, and the
SPA is the half of it the server cannot enforce. A card that behaved differently
for a registered address (a different label, a control that stayed live, a notice
that said "sent" rather than "if that email is registered") would rebuild the
account-existence oracle in the browser, out of an API that refuses to be one.

Written the way #373's `no_enumeration` test is written: drive both addresses
through the IDENTICAL response the server always sends, then assert the two
control states are equal **to each other**. The second case is the anti-vacuity
guard — `( False, NotAsked )` compares equal to itself too, so the value being
compared is pinned to what a completed send actually produces.

-}
disabledStateIsAddressIndependent : Test
disabledStateIsAddressIndependent =
    describe "no_enumeration: the send control cannot reveal whether an address exists"
        [ test "two different addresses leave the control in the same state" <|
            \() ->
                Expect.equal
                    (controlStateAfterSend "registered@stacks.dev")
                    (controlStateAfterSend "nobody@stacks.dev")
        , test "and that state is a completed send, not an untouched form" <|
            \() ->
                controlStateAfterSend "registered@stacks.dev"
                    |> Expect.equal ( True, Success () )
        ]


{-| Everything the forgot-password control's rendering is a function of after one
send: whether it is inert, and the state its label and its notice case over.

Deliberately does NOT include the address. If a later change made the control
depend on anything address-derived, this tuple would have to grow to keep
covering it — which is the point at which someone has to justify the dependency.

-}
controlStateAfterSend : String -> ( Bool, RemoteData RequestError () )
controlStateAfterSend email =
    let
        ( withMode, _, _ ) =
            Login.update (Login.ModeSwitched Login.ForgotPasswordMode) (Login.init Login.Fresh)

        ( withEmail, _, _ ) =
            Login.update (Login.EmailChanged email) withMode

        ( sending, _, _ ) =
            Login.update Login.ForgotSubmitted withEmail

        ( sent, _, _ ) =
            Login.update (Login.GotForgotResponse (Ok ())) sending
    in
    ( Login.isForgotDisabled sent, sent.forgotState )
