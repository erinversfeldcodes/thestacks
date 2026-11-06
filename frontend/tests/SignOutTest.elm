module SignOutTest exposing (suite)

{-| A sign-out does not claim to have happened until the server says it did.

⛔ WHY THIS EXISTS. Sign-out was dispatched as
`Cmd.batch [ Api.logout auth.token (always FocusResult), clearListingDraft (), Nav.pushUrl … Login ]`.
`always` discards the result on success and failure alike, and the navigation is
local and immediate — so a reader whose logout never landed (offline, a 500, a
machine that had scaled to zero) was shown `/login`, an interface whose entire
claim is "you are signed out", while the `stacks_session` cookie stayed valid for
the rest of its lifetime. The next request from that browser was authenticated
again, and nothing anywhere said so.

⚖️ WHAT IS ASSERTED HERE, AND WHAT IS ASSERTED BY THE COMPILER. The obligation
itself is a type: `Api.logout` now takes an `Api.Authed`, whose record demands
both an expiry msg and a result handler, so `always FocusResult` does not
compile. That is the mutation probe for requirement 2 and it needs no test.

What a type cannot say is which msg each HTTP status produces, or what the reader
is then told. So this module drives REAL `Http.Response` values through
`Main.signOutHandlers` — the record production hands to `Api.authed` — and
asserts the `Main.Msg` that comes back, then the session verdict, then the copy.

⚠️ NOT a `ProgramTest`, and the reason is structural rather than a shortcut:
`Main` is a `Browser.application` with ports, so no test can build a `Main.Model`
or a `Nav.Key` (`NavigationProgramTest` records the same constraint). The one
link below that no test reaches is therefore the two-branch `update` dispatch
itself; everything it dispatches on is here.

-}

import Api
import Dict
import Expect
import Html.Attributes as Attr
import Http
import Main
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import TestHelpers


suite : Test
suite =
    describe "signing out does not report a success it has not confirmed"
        [ describe "what the server's answer means for the session"
            [ aConfirmedLogoutEndsTheSession
            , aRefusedLogoutLeavesTheSessionOpen
            , aLogoutThatNeverArrivedLeavesTheSessionOpen
            , aTimedOutLogoutLeavesTheSessionOpen
            , anUnsendableLogoutLeavesTheSessionOpen
            , anUnreadableLogoutLeavesTheSessionOpen
            ]
        , describe "the response reaches the handler production gave it"
            [ aSuccessReachesTheResultHandler
            , aServerFaultReachesTheResultHandler
            , aTransportFailureReachesTheResultHandler
            , aLogout401IsAConfirmedSignOut
            ]
        , describe "what the reader is told"
            [ nothingIsSaidWhenNoSignOutIsHappening
            , theWaitIsAnnouncedWithoutClaimingAnything
            , aStalledSignOutNamesTheLiveSession
            , aStalledSignOutCorrectsTheClosingTheBrowserAssumption
            , aStalledSignOutOffersTheActionThatWorks
            , aStalledSignOutDistinguishesRefusedFromUnreachable
            ]
        ]



-- WHAT THE ANSWER MEANS


{-| ⛔ The only answer that licenses a signed-out interface.
-}
aConfirmedLogoutEndsTheSession : Test
aConfirmedLogoutEndsTheSession =
    test "sign_out_204_ends_the_session: a confirmed logout is the one case that does" <|
        \() ->
            Main.signOutAnswer (Ok ())
                |> Expect.equal Main.SessionEnded


{-| ⛔ THE DEFECT, as an assertion. The server answered and refused; the cookie
it did not clear is still in the browser, so the session is still open.
-}
aRefusedLogoutLeavesTheSessionOpen : Test
aRefusedLogoutLeavesTheSessionOpen =
    test "sign_out_500_leaves_the_session_open: a refused logout is not a sign-out" <|
        \() ->
            Main.signOutAnswer (Err (Http.BadStatus 500))
                |> Expect.equal (Main.SessionStillOpen Main.ServerRefused)


aLogoutThatNeverArrivedLeavesTheSessionOpen : Test
aLogoutThatNeverArrivedLeavesTheSessionOpen =
    test "sign_out_network_error_leaves_the_session_open: an unasked question has no answer" <|
        \() ->
            Main.signOutAnswer (Err Http.NetworkError)
                |> Expect.equal (Main.SessionStillOpen Main.DidNotArrive)


aTimedOutLogoutLeavesTheSessionOpen : Test
aTimedOutLogoutLeavesTheSessionOpen =
    test "sign_out_timeout_leaves_the_session_open: silence is not confirmation" <|
        \() ->
            Main.signOutAnswer (Err Http.Timeout)
                |> Expect.equal (Main.SessionStillOpen Main.DidNotArrive)


anUnsendableLogoutLeavesTheSessionOpen : Test
anUnsendableLogoutLeavesTheSessionOpen =
    test "sign_out_bad_url_leaves_the_session_open: a request never sent changes nothing" <|
        \() ->
            Main.signOutAnswer (Err (Http.BadUrl "/api/auth/logout"))
                |> Expect.equal (Main.SessionStillOpen Main.DidNotArrive)


anUnreadableLogoutLeavesTheSessionOpen : Test
anUnreadableLogoutLeavesTheSessionOpen =
    test "sign_out_bad_body_leaves_the_session_open: an answer we cannot read is not a yes" <|
        \() ->
            Main.signOutAnswer (Err (Http.BadBody "not json"))
                |> Expect.equal (Main.SessionStillOpen Main.ServerRefused)



-- THE RESPONSE, DRIVEN THROUGH PRODUCTION'S OWN HANDLERS


{-| One sign-out response, read exactly as `Api.logout` reads it: the resolver is
`Api.resolveWhatever` and the handlers are the record `Main` hands `Api.authed`.
-}
answered : Http.Response String -> Main.Msg
answered =
    Api.interpretAuthed Api.resolveWhatever
        (Api.authed (TestHelpers.creds "tok") Main.signOutHandlers)


metadata : Int -> Http.Metadata
metadata statusCode =
    { url = "https://example.test/api/auth/logout"
    , statusCode = statusCode
    , statusText = String.fromInt statusCode
    , headers = Dict.empty
    }


aSuccessReachesTheResultHandler : Test
aSuccessReachesTheResultHandler =
    test "sign_out_204_reaches_the_result_handler" <|
        \() ->
            answered (Http.GoodStatus_ (metadata 204) "")
                |> Expect.equal (Main.SignOutAnswered (Ok ()))


aServerFaultReachesTheResultHandler : Test
aServerFaultReachesTheResultHandler =
    test "sign_out_500_reaches_the_result_handler: the status survives to the handler" <|
        \() ->
            answered (Http.BadStatus_ (metadata 500) "{\"error\":\"boom\"}")
                |> Expect.equal (Main.SignOutAnswered (Err (Http.BadStatus 500)))


aTransportFailureReachesTheResultHandler : Test
aTransportFailureReachesTheResultHandler =
    test "sign_out_network_error_reaches_the_result_handler" <|
        \() ->
            answered Http.NetworkError_
                |> Expect.equal (Main.SignOutAnswered (Err Http.NetworkError))


{-| ⚖️ A 401 is the ONE failure that still ends the session: the credential the
request carried has already been refused, so there is nothing left to revoke and
nothing to ask the reader to retry. It reaches the expiry msg rather than the
result handler, which is why `signOutAnswer` never has to consider it.
-}
aLogout401IsAConfirmedSignOut : Test
aLogout401IsAConfirmedSignOut =
    test "sign_out_401_is_a_confirmed_sign_out: nothing left to revoke" <|
        \() ->
            answered (Http.BadStatus_ (metadata 401) "{\"error\":\"session_expired\"}")
                |> Expect.equal Main.SessionAlreadyGone



-- WHAT THE READER IS TOLD


stalled : Main.SignOutFailure -> Query.Single Main.Msg
stalled failure =
    Main.viewSignOut (Main.SignOutStalled failure) |> Query.fromHtml


marked : String -> Selector.Selector
marked value =
    Selector.attribute (Attr.attribute "data-testid" value)


nothingIsSaidWhenNoSignOutIsHappening : Test
nothingIsSaidWhenNoSignOutIsHappening =
    test "sign_out_idle_says_nothing" <|
        \() ->
            Main.viewSignOut Main.NotSigningOut
                |> Query.fromHtml
                |> Query.hasNot [ marked "sign-out-stalled" ]


{-| ⚠️ Immediate feedback that the request is in flight, which is allowed — what
is not allowed is a claim about the session. So this state says what the app is
doing and nothing about whether the reader is signed in.
-}
theWaitIsAnnouncedWithoutClaimingAnything : Test
theWaitIsAnnouncedWithoutClaimingAnything =
    test "sign_out_waiting_announces_the_wait" <|
        \() ->
            Main.viewSignOut Main.SigningOut
                |> Query.fromHtml
                |> Query.has [ Selector.text "Signing you out…" ]


{-| ⛔ The copy requirement. "Something went wrong" is true and useless; the
reader needs the state of their session, which is the opposite of what they asked
for.
-}
aStalledSignOutNamesTheLiveSession : Test
aStalledSignOutNamesTheLiveSession =
    test "sign_out_stalled_says_the_session_is_still_open" <|
        \() ->
            stalled Main.DidNotArrive
                |> Query.has [ Selector.text "You are still signed in on this device: the request to sign you out never reached the library. Check your connection." ]


{-| ⛔ The assumption a reader makes next, corrected. The session cookie carries
a `max-age` derived from the token's own lifetime — it is deliberately
persistent, so a session survives a browser restart. Quitting the browser leaves
the session exactly as live as it was, and an interface that let the reader
believe otherwise would be the same false claim one step along.
-}
aStalledSignOutCorrectsTheClosingTheBrowserAssumption : Test
aStalledSignOutCorrectsTheClosingTheBrowserAssumption =
    test "sign_out_stalled_says_closing_the_browser_will_not_help" <|
        \() ->
            stalled Main.DidNotArrive
                |> Query.has [ Selector.text "Closing this tab or quitting your browser will not end it — the session lasts until a sign-out reaches us, or until it expires on its own." ]


{-| A reader told their sign-out failed and given nothing to do is worse off than
one who was not told, so the one action that actually ends the session is on
screen.
-}
aStalledSignOutOffersTheActionThatWorks : Test
aStalledSignOutOffersTheActionThatWorks =
    test "sign_out_stalled_offers_a_retry" <|
        \() ->
            stalled Main.ServerRefused
                |> Query.find [ marked "sign-out-retry" ]
                |> Query.has [ Selector.text "Try signing out again" ]


{-| The two failures differ in what the reader should try, so they must not read
the same: "check your connection" is advice for one of them and noise for the
other.

⚠️ Stated as a SECOND POSITIVE assertion rather than as the absence of the
other's wording. An absence assertion over prose is satisfied by a view that
rendered nothing at all, and this repository's own gate flags it — three other
surfaces already say "Check your connection, then try again", so the absence
would have been reading someone else's copy. Two literals, each pinned by its
own test, is the same guarantee without the vacuity: collapsing them to one
sentence reds one of these two.

-}
aStalledSignOutDistinguishesRefusedFromUnreachable : Test
aStalledSignOutDistinguishesRefusedFromUnreachable =
    test "sign_out_stalled_tells_the_two_failures_apart" <|
        \() ->
            stalled Main.ServerRefused
                |> Query.has [ Selector.text "You are still signed in on this device: the library answered, but would not end your session." ]
