module ArrivalTest exposing (suite)

{-| Issue #360 — one `Arrival` replaces six booleans, five inits and two view
predicates.


## The defect

"Why is this reader standing at the login door" was six independent booleans —
`sessionExpired`, `draftSaved`, `accountDeleted` on `Login.Model`, shadowed by
`sessionExpiredNotice`, `draftSavedNotice`, `accountDeletedNotice` on
`Main.Model` — raised by five separate inits and read by two view predicates
that could not see each other.

The reasons are mutually exclusive in life and were independently settable in
code. `{ sessionExpired = True, accountDeleted = True }` type-checked and
rendered both notices stacked; `draftSaved = True` with no expiry claimed a
listing had been saved when nothing had. And because `Main` and `Login` held
separate copies, they could disagree.


## What is now unrepresentable

Two arrival reasons at once, and a saved-draft flag detached from the expiry it
describes — `draftSaved` lives inside the `SessionExpired` constructor. Neither
is a test below, because neither compiles. See the probe transcript on the
issue.


## Why these assertions are not vacuous

Every "does not show X" assertion is paired with a positive control that shows X
under some other arrival, in the same suite. A bare negative passes just as
happily when the notice has been deleted, when the selector is wrong, or when
the view crashed to `text ""`.


## Mutation probe

Making `Login.init` ignore its argument (`init _ = init Fresh`) reddens
`expiry_shows_expiry_notice`, `draft_expiry_reassures`, `deletion_says_goodbye`,
`unreadable_tells_the_reader`, `unreadable_carries_the_reason` and
`forgot_opens_the_reset_form`.

-}

import Expect
import Html.Attributes
import Http
import Main
import Navigation.Route
import Page.Login as Login
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Types.RemoteData


suite : Test
suite =
    describe "Arrival (Issue #360)"
        [ describe "one notice per arrival"
            [ freshShowsNoNotice
            , expiryShowsExpiryNotice
            , draftExpiryReassures
            , deletionSaysGoodbye
            , unreadableTellsTheReader
            , unreadableCarriesTheReason
            , forgotOpensTheResetForm
            , confirmationExpiredOpensTheResendForm
            ]
        , describe "an arrival is spent, never accumulated"
            [ modeSwitchSpendsTheArrival
            , submittingSpendsTheArrival
            , aSubmitFailureOutranksTheNotice
            ]
        , describe "Main consumes the arrival when a card is built, not when the URL says /login"
            [ consumedByALoginCard
            , consumedByABounce
            , keptWhileTheReaderIsElsewhere
            ]
        , describe "draftWasSaved is total"
            [ draftFlagIsOnlyMeaningfulForAnExpiry ]
        , describe "the #360/#361 seam — one value answers both questions"
            [ onlyAnExpiryIsAnExpiry
            , expiryArrivalDrivesTheRedirectCapture
            , everyOtherArrivalLeavesTheCaptureAlone
            ]
        ]



-- COPY (named once, so a test cannot assert copy the page does not have)


expiryCopy : String
expiryCopy =
    "The library closed your session for safekeeping — sign in again to return."


draftExpiryCopy : String
draftExpiryCopy =
    "The library closed your session for safekeeping — your listing draft is saved. Sign in and return to Sell a Book to finish it."


farewellCopy : String
farewellCopy =
    "Your account deletion has been queued. We're sorry to see you go — thank you for the time you spent in The Stacks."


unreadableCopy : String
unreadableCopy =
    "A saved sign-in was found here but could not be read, so you have been signed out. Please sign in again."


cardFor : Login.Arrival -> Query.Single Login.Msg
cardFor arrival =
    Login.init arrival
        |> Login.view
        |> Query.fromHtml



-- ONE NOTICE PER ARRIVAL


{-| The negative control for every notice test below. Paired with the positives
that follow: each of those copies is proved renderable somewhere, so "absent
here" cannot be satisfied by "absent everywhere".
-}
freshShowsNoNotice : Test
freshShowsNoNotice =
    test "fresh_shows_no_notice: an ordinary sign-in explains nothing, because nothing happened" <|
        \() ->
            cardFor Login.Fresh
                |> Query.hasNot
                    [ Selector.text expiryCopy
                    , Selector.text draftExpiryCopy
                    , Selector.text farewellCopy
                    , Selector.text unreadableCopy
                    ]


expiryShowsExpiryNotice : Test
expiryShowsExpiryNotice =
    test "expiry_shows_expiry_notice: an expired session says so, and says nothing else" <|
        \() ->
            Expect.all
                [ Query.has [ Selector.text expiryCopy ]
                , Query.hasNot [ Selector.text farewellCopy ]
                , Query.hasNot [ Selector.text draftExpiryCopy ]
                ]
                (cardFor (Login.SessionExpired { draftSaved = False }))


draftExpiryReassures : Test
draftExpiryReassures =
    test "draft_expiry_reassures: an expiry mid-compose promises the draft survived" <|
        \() ->
            Expect.all
                [ Query.has [ Selector.text draftExpiryCopy ]
                , Query.hasNot [ Selector.text expiryCopy ]
                ]
                (cardFor (Login.SessionExpired { draftSaved = True }))


deletionSaysGoodbye : Test
deletionSaysGoodbye =
    test "deletion_says_goodbye: a closed account gets a farewell, not an expiry warning" <|
        \() ->
            Expect.all
                [ Query.has [ Selector.text farewellCopy ]
                , Query.hasNot [ Selector.text expiryCopy ]
                ]
                (cardFor Login.AccountDeleted)


{-| ⛔ The requirement of collapse 3: the reader is TOLD. Before this, an
unreadable stored credential put them back at a bare login card that looked
exactly like a deliberate sign-out.
-}
unreadableTellsTheReader : Test
unreadableTellsTheReader =
    test "unreadable_tells_the_reader: a stored credential that would not decode is explained, not swallowed" <|
        \() ->
            Expect.all
                [ Query.has [ Selector.text unreadableCopy ]
                , Query.hasNot [ Selector.text expiryCopy ]
                , Query.hasNot [ Selector.text farewellCopy ]
                ]
                (cardFor (Login.StoredSessionUnreadable "Problem with the value at json.userId"))


unreadableCarriesTheReason : Test
unreadableCarriesTheReason =
    test "unreadable_carries_the_reason: the decoder's own account of the failure reaches the page" <|
        \() ->
            cardFor (Login.StoredSessionUnreadable "Problem with the value at json.userId")
                |> Query.has
                    [ Selector.attribute
                        (Html.Attributes.title "Problem with the value at json.userId")
                    ]


forgotOpensTheResetForm : Test
forgotOpensTheResetForm =
    test "forgot_opens_the_reset_form: /forgot-password is an arrival, and opens the card on its reset mode" <|
        \() ->
            Expect.all
                [ \card -> Query.has [ Selector.attribute (Html.Attributes.attribute "data-testid" "forgot-submit") ] card
                , \card -> Query.hasNot [ Selector.text expiryCopy ] card
                ]
                (cardFor Login.ForgotPassword)


{-| The sixth arrival (#373), held to the same rule as the other five: it opens
its own mode and raises none of the other notices.
-}
confirmationExpiredOpensTheResendForm : Test
confirmationExpiredOpensTheResendForm =
    test "confirmation_expired_opens_the_resend_form: a dead confirmation link opens the card on its resend mode" <|
        \() ->
            Expect.all
                [ \card -> Query.has [ Selector.attribute (Html.Attributes.attribute "data-testid" "resend-email") ] card
                , \card -> Query.hasNot [ Selector.text expiryCopy ] card
                , \card -> Query.hasNot [ Selector.text farewellCopy ] card
                ]
                (cardFor Login.ConfirmationExpired)



-- SPENDING THE ARRIVAL


modeSwitchSpendsTheArrival : Test
modeSwitchSpendsTheArrival =
    test "mode_switch_spends_arrival: moving to Register drops the notice that brought them here" <|
        \() ->
            let
                ( switched, _, _ ) =
                    Login.update (Login.ModeSwitched Login.RegisterMode)
                        (Login.init (Login.SessionExpired { draftSaved = True }))
            in
            Expect.all
                [ \model -> Expect.equal Login.Fresh model.arrival
                , \model ->
                    Login.view model
                        |> Query.fromHtml
                        |> Query.hasNot [ Selector.text draftExpiryCopy ]
                ]
                switched


submittingSpendsTheArrival : Test
submittingSpendsTheArrival =
    test "submitting_spends_arrival: once they act on it, the explanation is done" <|
        \() ->
            let
                ( submitted, _, _ ) =
                    Login.update Login.FormSubmitted
                        (Login.init Login.AccountDeleted)
            in
            Expect.equal Login.Fresh submitted.arrival


{-| The suppression rule, written once now rather than re-derived in each notice
view: a failed sign-in is more specific than the reason they arrived.
-}
aSubmitFailureOutranksTheNotice : Test
aSubmitFailureOutranksTheNotice =
    test "submit_failure_outranks_notice: a wrong password wins over the arrival explanation" <|
        \() ->
            let
                expired =
                    Login.init (Login.SessionExpired { draftSaved = False })

                failed =
                    { expired
                        | submitState =
                            Types.RemoteData.Failure
                                (Login.SubmitHttpError (Http.BadStatus 401))
                    }
            in
            Expect.all
                [ \_ ->
                    -- positive control: the SAME arrival shows the notice while
                    -- the submit has not failed. Without it, "the notice is
                    -- absent" would be satisfied by a card that never shows one.
                    Login.view expired
                        |> Query.fromHtml
                        |> Query.has [ Selector.text expiryCopy ]
                , \model ->
                    Login.view model
                        |> Query.fromHtml
                        |> Query.hasNot [ Selector.text expiryCopy ]
                ]
                failed



-- MAIN'S SIDE OF THE SAME VALUE


consumedByALoginCard : Test
consumedByALoginCard =
    test "consumed_by_login_card: an arrival delivered to a card is spent" <|
        \() ->
            Main.consumeArrival (Main.PageLogin (Login.init Login.AccountDeleted)) Login.AccountDeleted
                |> Expect.equal Login.Fresh


{-| ⛔ The bug the three booleans had. They were each cleared by
`… && newRoute /= Login`, but the protected-route bounce shows the login card
WITHOUT changing the URL — so an expiry raised while the reader was on `/library`
was never marked delivered and resurfaced on their next navigation. Asking the
page, not the route, is what fixes it.
-}
consumedByABounce : Test
consumedByABounce =
    test "consumed_by_bounce: a card reached by the bounce spends the arrival too, though the URL never said /login" <|
        \() ->
            let
                bouncedPage =
                    Main.initPage { ageGatingEnabled = False }
                        Navigation.Route.Library
                        Nothing
                        Nothing
                        Nothing
                        (Login.SessionExpired { draftSaved = False })
                        |> Tuple.first
            in
            Main.consumeArrival bouncedPage (Login.SessionExpired { draftSaved = False })
                |> Expect.equal Login.Fresh


keptWhileTheReaderIsElsewhere : Test
keptWhileTheReaderIsElsewhere =
    test "kept_elsewhere: an arrival survives navigation until a card actually shows it" <|
        \() ->
            Main.consumeArrival Main.PageHome Login.AccountDeleted
                |> Expect.equal Login.AccountDeleted



-- draftWasSaved


draftFlagIsOnlyMeaningfulForAnExpiry : Test
draftFlagIsOnlyMeaningfulForAnExpiry =
    test "draft_flag_totality: every arrival answers, and only an expiry can answer True" <|
        \() ->
            [ Login.Fresh
            , Login.AccountDeleted
            , Login.ForgotPassword
            , Login.StoredSessionUnreadable "boom"
            , Login.ConfirmationExpired
            , Login.SessionExpired { draftSaved = False }
            , Login.SessionExpired { draftSaved = True }
            ]
                |> List.map Login.draftWasSaved
                |> Expect.equalLists [ False, False, False, False, False, False, True ]



-- THE #360/#361 SEAM
--
-- ⛔ These exist because of a gap MEASURED during the #361 reconcile, not
-- because they seemed like a good idea. #361 needs to know "is this navigation
-- an expiry bounce" and read it from `Main.Model.sessionExpiredNotice`; #360
-- collapsed that boolean into `Arrival`, so the wire now runs through
-- `Login.isSessionExpiry`. `SessionExpiryTest`'s five #361 tests call
-- `Main.redirectAfterNavigation` with `sessionExpiring` passed as a LITERAL, so
-- none of them can see whether the call site computes it correctly.
--
-- Probe (2026-08-01): stubbing `isSessionExpiry` to `always False` — which is
-- the #361 defect restored, an expiry bounce forgetting the page it left —
-- left ALL 1464 tests green. These three are what makes that probe redden.


onlyAnExpiryIsAnExpiry : Test
onlyAnExpiryIsAnExpiry =
    test "expiry_predicate_totality: every arrival answers, and only an expiry answers True" <|
        \() ->
            [ Login.Fresh
            , Login.AccountDeleted
            , Login.ForgotPassword
            , Login.StoredSessionUnreadable "boom"
            , Login.ConfirmationExpired
            , Login.SessionExpired { draftSaved = False }
            , Login.SessionExpired { draftSaved = True }
            ]
                |> List.map Login.isSessionExpiry
                |> Expect.equalLists [ False, False, False, False, False, True, True ]


{-| The seam, joined: the arrival `Main.forceSessionExpiry` raises, fed through
the predicate `Main.UrlChanged` uses, into #361's decision. This is the journey
— expiry on `/settings/password` → push `/login` → sign back in → land back on
the form — with only the `Nav.Key` left out.
-}
expiryArrivalDrivesTheRedirectCapture : Test
expiryArrivalDrivesTheRedirectCapture =
    test "expiry_arrival_drives_capture: the arrival an expiry raises is what makes #361 remember the page" <|
        \() ->
            Main.redirectAfterNavigation
                { arrivingAt = Navigation.Route.Login
                , leaving = Navigation.Route.SettingsPassword
                , sessionExpiring =
                    Login.isSessionExpiry (Login.SessionExpired { draftSaved = False })
                , auth = Nothing
                }
                |> Expect.equal (Just Navigation.Route.SettingsPassword)


{-| The paired control. Without it, the test above would pass just as well if
`isSessionExpiry` were `always True` — which would send a reader who clicked
"Sign in" of their own accord to a page they never asked for.
-}
everyOtherArrivalLeavesTheCaptureAlone : Test
everyOtherArrivalLeavesTheCaptureAlone =
    test "non_expiry_arrival_captures_nothing: a deliberate visit to /login is not treated as a bounce" <|
        \() ->
            [ Login.Fresh
            , Login.AccountDeleted
            , Login.ForgotPassword
            , Login.StoredSessionUnreadable "boom"
            , Login.ConfirmationExpired
            ]
                |> List.map
                    (\arrival ->
                        Main.redirectAfterNavigation
                            { arrivingAt = Navigation.Route.Login
                            , leaving = Navigation.Route.SettingsPassword
                            , sessionExpiring = Login.isSessionExpiry arrival
                            , auth = Nothing
                            }
                    )
                |> Expect.equalLists [ Nothing, Nothing, Nothing, Nothing, Nothing ]
