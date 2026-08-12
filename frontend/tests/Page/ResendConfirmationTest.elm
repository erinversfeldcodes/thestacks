module Page.ResendConfirmationTest exposing (suite)

{-| Resending the confirmation email. The defect: registration ended at
"Check your inbox!" with only "Back to Sign In" — useless while
unconfirmed — and the failure page advised re-registering, which the
taken address makes impossible. These tests pin the resend affordance
on both the pending card and the dead-link page: it sends to the right
address, acknowledges, guards the double-send, and never leaks whether
the address exists.
-}

import Expect
import Html.Attributes
import Http
import Main
import Navigation.Route
import Page.Login as Login
import ProgramTest
import Test exposing (Test, describe, test)
import Test.Html.Selector as Selector
import TestHelpers exposing (loginProgram, loginProgramFrom, simulateRegisterResponse)
import Types.RemoteData


suite : Test
suite =
    describe "Resend confirmation"
        [ describe "from the check-your-inbox card"
            [ pendingCardOffersAResend
            , resendSendsToTheAddressOnScreen
            , resendIgnoresAStaleEmailField
            , resendIsAcknowledged
            , acknowledgementIsNotClaimedBeforeItAnswers
            , doubleSendIsImpossible
            , resendFailureReopensTheButton
            , leavingTheCardSpendsTheResend
            ]
        , describe "from a dead confirmation link"
            [ theRouteIsWiredToTheArrival
            , deadLinkArrivalOpensTheResendForm
            , deadLinkResendUsesTheTypedAddress
            , deadLinkResendIsAcknowledged
            , deadLinkFormAsksNothingBeforeAnAddressIsGiven
            ]
        ]


successCopy : String
successCopy =
    "If that address is waiting to be confirmed, a fresh link is on its way. It replaces any earlier one."


{-| The copy for a DROPPED CONNECTION specifically.

It used to be one sentence for every failure — including a 429, where "please try
again in a moment" is the instruction guaranteed to fail. The constant is named
for the case the tests below actually drive (`Http.NetworkError_`) so that a
future test simulating a different failure cannot silently reuse it.

-}
failureCopy : String
failureCopy =
    "The library is unreachable. Check your connection, then try again."


resendEndpoint : String
resendEndpoint =
    "/api/auth/resend-confirmation"


type alias LoginTest =
    ProgramTest.ProgramTest Login.Model Login.Msg (ProgramTest.SimulatedEffect Login.Msg)


justRegistered : LoginTest
justRegistered =
    ProgramTest.start () loginProgram
        |> ProgramTest.clickButton "Register"
        |> ProgramTest.fillIn "display-name" "Display Name" "New Reader"
        |> ProgramTest.fillIn "email" "Email" "lost-the-email@stacks.dev"
        |> ProgramTest.fillIn "password" "Password" "secret123"
        |> ProgramTest.fillIn "password-confirm" "Confirm Password" "secret123"
        |> ProgramTest.clickButton "Request Entry"
        |> ProgramTest.simulateHttpResponse "POST" "/api/auth/register" simulateRegisterResponse


pendingCardOffersAResend : Test
pendingCardOffersAResend =
    test "pending_card_offers_a_resend: the card is no longer a dead end" <|
        \() ->
            justRegistered
                |> ProgramTest.expectViewHas
                    [ Selector.attribute
                        (Html.Attributes.attribute "data-testid" "resend-confirmation")
                    , Selector.text "Send it again"
                    ]


{-| ⛔ The card names an address in its own sentence. A "send it again" button
underneath that sentence must send to THAT address, or the card is lying about
what the reader just asked for.
-}
resendSendsToTheAddressOnScreen : Test
resendSendsToTheAddressOnScreen =
    test "resend_sends_to_the_address_on_screen: the request carries the address the card names" <|
        \() ->
            justRegistered
                |> ProgramTest.clickButton "Send it again"
                |> ProgramTest.expectHttpRequest "POST"
                    resendEndpoint
                    (\request ->
                        Expect.equal
                            "{\"email\":\"lost-the-email@stacks.dev\"}"
                            request.body
                    )


{-| The same requirement, pinned where it can be SEEN to hold. Honest
scope: the pending card has no email input, so this forces a divergence
the UI cannot currently produce — because the assertion above cannot
distinguish the two candidate sources when they agree. If a future edit
adds an input, this is the test that already covers it.
-}
resendIgnoresAStaleEmailField : Test
resendIgnoresAStaleEmailField =
    test "resend_follows_the_card_not_the_field: the pending card's address wins over the model's" <|
        \() ->
            justRegistered
                |> ProgramTest.update (Login.EmailChanged "somebody-else@stacks.dev")
                |> ProgramTest.clickButton "Send it again"
                |> ProgramTest.expectHttpRequest "POST"
                    resendEndpoint
                    (\request ->
                        Expect.equal
                            "{\"email\":\"lost-the-email@stacks.dev\"}"
                            request.body
                    )


resendIsAcknowledged : Test
resendIsAcknowledged =
    test "resend_is_acknowledged: the reader is told, in a live region" <|
        \() ->
            justRegistered
                |> ProgramTest.clickButton "Send it again"
                |> ProgramTest.simulateHttpOk "POST" resendEndpoint "{}"
                |> ProgramTest.expectViewHas
                    [ Selector.attribute (Html.Attributes.attribute "role" "status")
                    , Selector.text successCopy
                    ]


{-| The paired control for the acknowledgement: it must not be on screen before
the request answers, and this proves the assertion above is not satisfied by copy
that is simply always there.
-}
acknowledgementIsNotClaimedBeforeItAnswers : Test
acknowledgementIsNotClaimedBeforeItAnswers =
    test "acknowledgement_waits: nothing is claimed until the request answers" <|
        \() ->
            justRegistered
                |> ProgramTest.expectViewHasNot [ Selector.text successCopy ]


{-| ⛔ The double-send guard.

`expectHttpRequests` counts requests still AWAITING a response, so the zero below
is "the second press started nothing", not "nothing ever happened". The
difference matters, and is supplied by `simulateHttpOk` on the line above: it
fails the test outright if no matching request was in flight to answer. So the
first press is proved by the step that consumes it, and this assertion is left
free to mean only what it says.

-}
doubleSendIsImpossible : Test
doubleSendIsImpossible =
    test "double_send_is_impossible: pressing again after it worked sends nothing more" <|
        \() ->
            justRegistered
                |> ProgramTest.clickButton "Send it again"
                |> ProgramTest.simulateHttpOk "POST" resendEndpoint "{}"
                |> ProgramTest.update Login.ResendRequested
                |> ProgramTest.expectHttpRequests "POST"
                    resendEndpoint
                    (\requests -> Expect.equal 0 (List.length requests))


{-| The control for the test above, and a requirement in its own right: a
request that FAILED must be retryable. Without this, `isResendDisabled` could be
`always True` after the first press and the double-send test would still pass.

Note it drives `ResendRequested` directly rather than clicking, for the same
reason `update` carries the guard at all: a disabled attribute is a hint, and the
message can arrive regardless. This asserts the model's rule, not the DOM's.

-}
resendFailureReopensTheButton : Test
resendFailureReopensTheButton =
    test "resend_failure_reopens: a failed attempt can be retried" <|
        \() ->
            justRegistered
                |> ProgramTest.clickButton "Send it again"
                |> ProgramTest.simulateHttpResponse "POST" resendEndpoint Http.NetworkError_
                |> ProgramTest.ensureViewHas [ Selector.text failureCopy ]
                |> ProgramTest.update Login.ResendRequested
                |> ProgramTest.expectHttpRequests "POST"
                    resendEndpoint
                    (\requests -> Expect.equal 1 (List.length requests))


{-| The resend outcome is spent when the reader moves on, exactly as `forgotState`
and the arrival are (rule, applied to the new field).

Without this, a reader who resent and then went back to sign in would carry a
stale "a fresh link is on its way" notice — and a disabled button — into a later
visit to the resend form, refusing them a second request they may by then
genuinely want.

-}
leavingTheCardSpendsTheResend : Test
leavingTheCardSpendsTheResend =
    test "leaving_spends_the_resend: moving on clears the acknowledgement and re-arms the button" <|
        \() ->
            justRegistered
                |> ProgramTest.clickButton "Send it again"
                |> ProgramTest.simulateHttpOk "POST" resendEndpoint "{}"
                |> ProgramTest.ensureViewHas [ Selector.text successCopy ]
                |> ProgramTest.clickButton "Back to Sign In"
                |> ProgramTest.expectModel
                    (\model ->
                        Expect.all
                            [ \m -> Expect.equal Types.RemoteData.NotAsked m.resendState
                            , \m -> Expect.equal False (Login.isResendDisabled { m | email = "someone@stacks.dev" })
                            ]
                            model
                    )


{-| ⛔ The wire, not the parts.

Every other test here starts the card from `ConfirmationExpired` directly, and so
would pass with the route left pointing anywhere at all — a working form nobody
can reach, which is this codebase's most-repeated defect. `Route.fromPath` in
`RouteTest` proves the URL parses; this proves `Main` turns that route into THIS
arrival. Between them there is no gap for a dead link to fall into.

-}
theRouteIsWiredToTheArrival : Test
theRouteIsWiredToTheArrival =
    test "route_is_wired: /resend-confirmation builds the card on the confirmation-expired arrival" <|
        \() ->
            Main.initPage { ageGatingEnabled = False, inviteOnly = False }
                Navigation.Route.ResendConfirmation
                "https://thestacks.test"
                Nothing
                Nothing
                Nothing
                Login.Fresh
                |> Tuple.first
                |> Expect.equal (Main.PageLogin (Login.init Login.ConfirmationExpired))


deadLinkArrivalOpensTheResendForm : Test
deadLinkArrivalOpensTheResendForm =
    test "dead_link_opens_the_resend_form: /resend-confirmation is an arrival, and opens the card on its resend mode" <|
        \() ->
            ProgramTest.start () (loginProgramFrom Login.ConfirmationExpired)
                |> ProgramTest.expectViewHas
                    [ Selector.attribute
                        (Html.Attributes.attribute "data-testid" "resend-email")
                    , Selector.text "Send a new link"
                    ]


deadLinkResendUsesTheTypedAddress : Test
deadLinkResendUsesTheTypedAddress =
    test "dead_link_resend_uses_typed_address: with no card to name one, the field supplies it" <|
        \() ->
            ProgramTest.start () (loginProgramFrom Login.ConfirmationExpired)
                |> ProgramTest.fillIn "email" "Email" "came-back-later@stacks.dev"
                |> ProgramTest.clickButton "Send a new link"
                |> ProgramTest.expectHttpRequest "POST"
                    resendEndpoint
                    (\request ->
                        Expect.equal
                            "{\"email\":\"came-back-later@stacks.dev\"}"
                            request.body
                    )


{-| Closes the acknowledge gap: the dead-link path proved it SENDS but
nothing proved it acknowledges. A live drive made the acknowledgement
look missing and it nearly got filed as a defect — it was the
fixed-height card swallowing the notice below the fold. The program
test pins the render itself.
-}
deadLinkResendIsAcknowledged : Test
deadLinkResendIsAcknowledged =
    test "dead_link_resend_is_acknowledged: a reader who came from a dead link is told it worked" <|
        \() ->
            ProgramTest.start () (loginProgramFrom Login.ConfirmationExpired)
                |> ProgramTest.fillIn "email" "Email" "came-back-later@stacks.dev"
                |> ProgramTest.clickButton "Send a new link"
                |> ProgramTest.simulateHttpOk "POST" resendEndpoint "{}"
                |> ProgramTest.expectViewHas
                    [ Selector.attribute (Html.Attributes.attribute "role" "status")
                    , Selector.text successCopy
                    ]


{-| An empty field asks nothing — otherwise the first thing this page would do is
post a blank address. Counted, not asserted absent, for the usual reason.
-}
deadLinkFormAsksNothingBeforeAnAddressIsGiven : Test
deadLinkFormAsksNothingBeforeAnAddressIsGiven =
    test "dead_link_form_waits_for_an_address: an empty field sends nothing" <|
        \() ->
            ProgramTest.start () (loginProgramFrom Login.ConfirmationExpired)
                |> ProgramTest.update Login.ResendRequested
                |> ProgramTest.expectHttpRequests "POST"
                    resendEndpoint
                    (\requests -> Expect.equal 0 (List.length requests))
