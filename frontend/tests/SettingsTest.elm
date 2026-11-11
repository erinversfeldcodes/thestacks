module SettingsTest exposing (suite)

import Expect
import Html.Attributes
import Http
import Page.Settings.Consent as Consent
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import TestHelpers
import Types.RemoteData exposing (RemoteData(..))


suite : Test
suite =
    describe "Settings pages"
        [ describe "Consent init seeding (FF-1)"
            [ test "init seeds analyticsConsent from the current user" <|
                \_ ->
                    (Consent.init { analytics = True, writingAssistant = False }).analyticsConsent
                        |> Expect.equal True
            , test "init seeds writingAssistantConsent from the current user" <|
                \_ ->
                    (Consent.init { analytics = False, writingAssistant = True }).writingAssistantConsent
                        |> Expect.equal True
            , test "init keeps saving as NotAsked" <|
                \_ ->
                    (Consent.init { analytics = True, writingAssistant = True }).saving
                        |> Expect.equal NotAsked
            , test "a consenting user sees both toggles ON (no OFF toggles rendered)" <|
                \_ ->
                    Consent.init { analytics = True, writingAssistant = True }
                        |> Consent.view
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.findAll [ Selector.class "toggle--on" ] >> Query.count (Expect.equal 2)
                            , Query.hasNot [ Selector.class "toggle--off" ]
                            ]
            ]
        , describe "the analytics toggle says what it actually does"
            [ test "the description names the switch as reserved rather than collecting" <|
                \_ ->
                    Consent.analyticsDescription
                        |> Expect.equal "Reserved — nothing reads this yet. No usage data is collected about you, by us or by anyone else. Your answer is recorded now so that if that ever changes, it changes with your say-so already on file rather than assumed."
            , test "the page renders that description rather than a claim of its own" <|
                \_ ->
                    Consent.init { analytics = False, writingAssistant = False }
                        |> Consent.view
                        |> Query.fromHtml
                        |> Query.has [ Selector.text Consent.analyticsDescription ]
            , test "it says the same with the toggle on — consent does not start a collection" <|
                \_ ->
                    Consent.init { analytics = True, writingAssistant = False }
                        |> Consent.view
                        |> Query.fromHtml
                        |> Query.has [ Selector.text Consent.analyticsDescription ]
            ]
        , describe "Consent"
            [ test "SaveConsent with token sets saving to Loading" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update Consent.SaveConsent (Consent.init { analytics = False, writingAssistant = False }) (Just (TestHelpers.creds "tok"))
                    in
                    model.saving |> Expect.equal Loading
            , test "SaveConsent without token leaves saving as NotAsked" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update Consent.SaveConsent (Consent.init { analytics = False, writingAssistant = False }) Nothing
                    in
                    model.saving |> Expect.equal NotAsked
            , test "⛔ a 401 on Save Preferences settles `saving` and hands off the session" <|
                -- ⛔ The SECOND handler in this module with this defect. The
                -- writing-assistant toggle's 401 path was fixed first, and this
                -- one — the Save Preferences button — was left returning the
                -- model untouched, so an expired session left `saving` on
                -- `Loading` and the button disabled forever while the sibling
                -- `else` branch recorded a `Failure`.
                --
                -- ⚠️ Found by sweeping the shape rather than by reading this
                -- file, which is the point: the earlier fix was made IN this
                -- module and did not notice the handler twelve lines below it.
                --
                -- ⚠️ The precondition is asserted first. `saving` starts as
                -- `NotAsked`, so "no longer Loading" would otherwise be
                -- satisfied by a fresh model and pass against the defect.
                \_ ->
                    let
                        ( inFlight, _, _ ) =
                            Consent.update Consent.SaveConsent
                                (Consent.init { analytics = False, writingAssistant = False })
                                (Just (TestHelpers.creds "tok"))

                        ( settled, _, out ) =
                            Consent.update
                                (Consent.SaveCompleted (Err (Http.BadStatus 401)))
                                inFlight
                                (Just (TestHelpers.creds "tok"))
                    in
                    Expect.all
                        [ \_ -> inFlight.saving |> Expect.equal Loading
                        , \_ -> settled.saving |> Expect.notEqual Loading
                        , \_ -> out |> Expect.equal Consent.SessionExpired
                        ]
                        ()
            , test "⛔ the writing toggle does NOT touch the Save button's state" <|
                -- ⛔ The two controls on this page have different durability:
                -- analytics is a draft until Save is pressed, the writing
                -- toggle writes immediately. They used to share `saving`, which
                -- made the shared button LIE — flipping the writing toggle put
                -- "Save Preferences" into its saving-then-saved state for a
                -- save the reader never asked for.
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update Consent.ToggleWritingAssistant
                                (Consent.init { analytics = False, writingAssistant = False })
                                (Just (TestHelpers.creds "tok"))
                    in
                    Expect.all
                        [ \m -> m.writingAssistantSaving |> Expect.equal Loading
                        , \m -> m.saving |> Expect.equal NotAsked
                        ]
                        model
            , test "⛔ a FAILED writing toggle does not surface under the Save button" <|
                -- ⛔ The worse half: a writing-toggle failure used to render an
                -- error message underneath a button that had not been pressed.
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update
                                (Consent.SaveWritingAssistantCompleted True (Err (Http.BadStatus 500)))
                                (Consent.init { analytics = False, writingAssistant = True })
                                (Just (TestHelpers.creds "tok"))
                    in
                    Expect.all
                        [ \m -> m.writingAssistantSaving |> Expect.equal (Failure (Http.BadStatus 500))
                        , \m -> m.saving |> Expect.equal NotAsked
                        ]
                        model
            , test "⛔ a failed book-linking save is RENDERED, announced, and reverts the toggle" <|
                -- ⛔ Predicted and confirmed: with only the model assertions
                -- above, deleting the view's `Failure err -> p [...]` branch
                -- produced ZERO red of 2156 — so a failed consent withdrawal
                -- would have been silent everywhere, which is strictly worse
                -- than the wrongly-placed error it replaced, because the Save
                -- button no longer reports it either.
                --
                -- Three things in one assertion because they are one event: the
                -- message appears, it is announced (`role="alert"`, as this
                -- project gives its other refusal messages), and the optimistic
                -- flip is undone so the control stops disagreeing with the
                -- server about a consent record.
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update
                                (Consent.SaveWritingAssistantCompleted True (Err (Http.BadStatus 500)))
                                (Consent.init { analytics = False, writingAssistant = False }
                                    |> (\m -> { m | writingAssistantConsent = True })
                                )
                                (Just (TestHelpers.creds "tok"))

                        rendered =
                            Consent.viewSection False model |> Query.fromHtml
                    in
                    Expect.all
                        [ \_ ->
                            rendered
                                |> Query.find
                                    [ Selector.attribute
                                        (Html.Attributes.attribute "data-testid"
                                            "writing-assistant-consent-error"
                                        )
                                    ]
                                |> Query.has
                                    [ Selector.attribute (Html.Attributes.attribute "role" "alert") ]
                        , \_ ->
                            model.writingAssistantConsent
                                |> Expect.equal False
                        ]
                        ()
            , test "⛔ the error is NOT inside .toggle-row, which space-between would wreck" <|
                -- ⛔ The one fix in this round with no gate behind it. `.toggle-row`
                -- is `display: flex; justify-content: space-between`, so a third
                -- child moved the toggle button from the right edge to the CENTRE
                -- on failure, `.error`'s padding stretched the row, and with no
                -- `flex-wrap` it compressed to roughly one word per line at 400px.
                -- CSS has no test that can see that, so the structural fact —
                -- the error is a SIBLING of the row, not a child — is what gets
                -- pinned.
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update
                                (Consent.SaveWritingAssistantCompleted True
                                    (Err (Http.BadStatus 500))
                                )
                                (Consent.init { analytics = False, writingAssistant = False })
                                (Just (TestHelpers.creds "tok"))

                        rendered =
                            Consent.viewSection False model |> Query.fromHtml
                    in
                    Expect.all
                        [ -- the error exists at all, so the next assertion is not vacuous
                          \_ ->
                            rendered
                                |> Query.findAll
                                    [ Selector.attribute
                                        (Html.Attributes.attribute "data-testid"
                                            "writing-assistant-consent-error"
                                        )
                                    ]
                                |> Query.count (Expect.equal 1)
                        , -- and it is not inside the flex row
                          \_ ->
                            rendered
                                |> Query.findAll [ Selector.class "toggle-row" ]
                                |> Query.keep
                                    (Selector.attribute
                                        (Html.Attributes.attribute "data-testid"
                                            "writing-assistant-consent-error"
                                        )
                                    )
                                |> Query.count (Expect.equal 0)
                        ]
                        ()
            , test "and with no failure, no error element is rendered at all" <|
                -- The negative half the view test lacked: an assertion that only
                -- ever looks at the failure state cannot tell a correct render
                -- from one that always renders.
                \_ ->
                    Consent.init { analytics = False, writingAssistant = False }
                        |> Consent.viewSection False
                        |> Query.fromHtml
                        |> Query.findAll
                            [ Selector.attribute
                                (Html.Attributes.attribute "data-testid"
                                    "writing-assistant-consent-error"
                                )
                            ]
                        |> Query.count (Expect.equal 0)
            , test "⛔ a 401 reverts, reports AND clears Loading — not just a 500" <|
                -- ⛔ The gap the 500-based cases above could not see, and it was
                -- on the MOST LIKELY failure for a consent save. `isUnauthorized`
                -- is 401-only, and that branch used to return the model
                -- untouched: the optimistic flip was never reverted, no error
                -- rendered, and `writingAssistantSaving` stayed `Loading`
                -- forever — a control stuck mid-save, lying about what the server
                -- holds, on a GDPR consent field.
                --
                -- A session-expiry hand-off is not a reason to leave the model in
                -- that state, so the 401 path now does everything the 500 path
                -- does and reports `SessionExpired` as well.
                \_ ->
                    let
                        ( model, _, out ) =
                            Consent.update
                                (Consent.SaveWritingAssistantCompleted True
                                    (Err (Http.BadStatus 401))
                                )
                                (Consent.init { analytics = False, writingAssistant = False }
                                    |> (\m -> { m | writingAssistantConsent = True })
                                )
                                (Just (TestHelpers.creds "tok"))
                    in
                    Expect.all
                        [ \_ -> model.writingAssistantConsent |> Expect.equal False
                        , \_ ->
                            model.writingAssistantSaving
                                |> Expect.equal (Failure (Http.BadStatus 401))
                        , \_ -> out |> Expect.equal Consent.SessionExpired
                        ]
                        ()
            , test "⛔ the restore uses the ATTEMPTED value, not a blind toggle-back" <|
                -- ⚠️ `not model.writingAssistantConsent` assumes exactly one flip
                -- is in flight. Carrying the attempted value in the Msg makes the
                -- restore exact: a failure for an attempted `False` restores
                -- `True`, whatever the model happens to read at the time.
                --
                -- Driven with the model DISAGREEING with the attempt, which is
                -- the state a blind toggle-back gets wrong and an exact restore
                -- gets right.
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update
                                (Consent.SaveWritingAssistantCompleted False
                                    (Err (Http.BadStatus 500))
                                )
                                (Consent.init { analytics = False, writingAssistant = True })
                                (Just (TestHelpers.creds "tok"))
                    in
                    model.writingAssistantConsent
                        |> Expect.equal True
            , test "and a SaveConsent failure still surfaces under the Save button" <|
                -- The positive control: splitting the state must not make the
                -- button stop reporting the save it does govern.
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update
                                (Consent.SaveCompleted (Err (Http.BadStatus 500)))
                                (Consent.init { analytics = True, writingAssistant = False })
                                (Just (TestHelpers.creds "tok"))
                    in
                    Expect.all
                        [ \m -> m.saving |> Expect.equal (Failure (Http.BadStatus 500))
                        , \m -> m.writingAssistantSaving |> Expect.equal NotAsked
                        ]
                        model
            , test "ToggleAnalytics flips analyticsConsent" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update Consent.ToggleAnalytics (Consent.init { analytics = False, writingAssistant = False }) Nothing
                    in
                    model.analyticsConsent |> Expect.equal True
            , test "SaveCompleted Ok sets saving to Success" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update (Consent.SaveCompleted (Ok ())) (Consent.init { analytics = False, writingAssistant = False }) (Just (TestHelpers.creds "tok"))
                    in
                    model.saving |> Expect.equal (Success ())
            , test "SaveCompleted Err sets saving to Failure" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update (Consent.SaveCompleted (Err Http.NetworkError)) (Consent.init { analytics = False, writingAssistant = False }) (Just (TestHelpers.creds "tok"))
                    in
                    model.saving |> Expect.equal (Failure Http.NetworkError)
            ]
        , describe "Consent — a saved choice can be changed again"
            [ test "toggling analytics after a save clears the 'Saved!' state" <|
                \_ ->
                    consentAfterSave
                        |> toggleAnalytics
                        |> .saving
                        |> Expect.equal NotAsked
            , test "positive control — the save really did reach Success first" <|
                \_ ->
                    consentAfterSave.saving |> Expect.equal (Success ())
            , test "the toggle still flips the value it is there to flip" <|
                \_ ->
                    consentAfterSave
                        |> toggleAnalytics
                        |> .analyticsConsent
                        |> Expect.equal False
            , test "the save button is offering to save again, not reporting 'Saved!'" <|
                \_ ->
                    consentAfterSave
                        |> toggleAnalytics
                        |> Consent.view
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.has [ Selector.text "Save Preferences" ]
                            , Query.hasNot [ Selector.text "Saved!" ]
                            ]
            , test "positive control — it DOES say 'Saved!' immediately after the save" <|
                \_ ->
                    consentAfterSave
                        |> Consent.view
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "Saved!" ]
            ]
        ]


{-| A consent page whose analytics preference has been turned on and saved.
-}
consentAfterSave : Consent.Model
consentAfterSave =
    Consent.init { analytics = False, writingAssistant = False }
        |> toggleAnalytics
        |> consentUpdate Consent.SaveConsent
        |> consentUpdate (Consent.SaveCompleted (Ok ()))


toggleAnalytics : Consent.Model -> Consent.Model
toggleAnalytics =
    consentUpdate Consent.ToggleAnalytics


consentUpdate : Consent.Msg -> Consent.Model -> Consent.Model
consentUpdate msg model =
    let
        ( newModel, _, _ ) =
            Consent.update msg model (Just (TestHelpers.creds "tok"))
    in
    newModel
