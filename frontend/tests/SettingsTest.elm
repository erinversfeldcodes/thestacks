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
                    (Consent.init { analytics = True, writingAssistant = False, searchIndexing = False }).analyticsConsent
                        |> Expect.equal True
            , test "init seeds writingAssistantConsent from the current user" <|
                \_ ->
                    (Consent.init { analytics = False, writingAssistant = True, searchIndexing = False }).writingAssistantConsent
                        |> Expect.equal True
            , test "init keeps analyticsSaving as NotAsked" <|
                \_ ->
                    (Consent.init { analytics = True, writingAssistant = True, searchIndexing = False }).analyticsSaving
                        |> Expect.equal NotAsked
            , test "search-indexing consent seeds true from the init value" <|
                \_ ->
                    (Consent.init { analytics = False, writingAssistant = False, searchIndexing = True }).searchIndexingConsent
                        |> Expect.equal True
            , test "search-indexing consent defaults off when not granted" <|
                \_ ->
                    (Consent.init { analytics = False, writingAssistant = False, searchIndexing = False }).searchIndexingConsent
                        |> Expect.equal False
            , test "a fully-consenting user sees all toggles ON (no OFF toggles rendered)" <|
                \_ ->
                    Consent.init { analytics = True, writingAssistant = True, searchIndexing = True }
                        |> Consent.view
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.findAll [ Selector.class "toggle--on" ] >> Query.count (Expect.equal 3)
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
                    Consent.init { analytics = False, writingAssistant = False, searchIndexing = False }
                        |> Consent.view
                        |> Query.fromHtml
                        |> Query.has [ Selector.exactText Consent.analyticsDescription ]
            , test "it says the same with the toggle on — consent does not start a collection" <|
                \_ ->
                    Consent.init { analytics = True, writingAssistant = False, searchIndexing = False }
                        |> Consent.view
                        |> Query.fromHtml
                        |> Query.has [ Selector.exactText Consent.analyticsDescription ]
            ]
        , describe "Consent — analytics toggle (save-on-click, revert, 401)"
            [ test "ToggleAnalytics with a token flips the value and enters its OWN Loading" <|
                -- ⛔ Analytics writes on click now, exactly like the other two
                -- controls. It carries its OWN save state: a flip must not leave
                -- another control's status field reporting a save the reader
                -- never asked for.
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update Consent.ToggleAnalytics
                                (Consent.init { analytics = False, writingAssistant = False, searchIndexing = False })
                                (Just (TestHelpers.creds "tok"))
                    in
                    Expect.all
                        [ \m -> m.analyticsConsent |> Expect.equal True
                        , \m -> m.analyticsSaving |> Expect.equal Loading
                        , \m -> m.writingAssistantSaving |> Expect.equal NotAsked
                        , \m -> m.searchIndexingSaving |> Expect.equal NotAsked
                        ]
                        model
            , test "ToggleAnalytics without a token flips but attempts no save" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update Consent.ToggleAnalytics
                                (Consent.init { analytics = False, writingAssistant = False, searchIndexing = False })
                                Nothing
                    in
                    Expect.all
                        [ \m -> m.analyticsConsent |> Expect.equal True
                        , \m -> m.analyticsSaving |> Expect.equal NotAsked
                        ]
                        model
            , test "⛔ a failed save (500) REVERTS the optimistic flip and records Failure" <|
                -- the un-reverted state is "the worst available outcome: the
                -- reader believes their decision took and it did not" — so the
                -- revert is the load-bearing arm.
                \_ ->
                    let
                        ( model, _, out ) =
                            Consent.update
                                (Consent.SaveAnalyticsCompleted True (Err (Http.BadStatus 500)))
                                (Consent.init { analytics = False, writingAssistant = False, searchIndexing = False }
                                    |> (\m -> { m | analyticsConsent = True })
                                )
                                (Just (TestHelpers.creds "tok"))
                    in
                    Expect.all
                        [ \_ -> model.analyticsConsent |> Expect.equal False
                        , \_ -> model.analyticsSaving |> Expect.equal (Failure (Http.BadStatus 500))
                        , \_ -> out |> Expect.equal Consent.NoOut
                        ]
                        ()
            , test "⛔ a failed REVOKE (attempted False) reverts the flip back to ON" <|
                -- the OTHER direction of the revert arm. Without this case a
                -- mutation of `not attempted` to the constant `False` survives the
                -- whole suite, because every other failure test attempts True.
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update
                                (Consent.SaveAnalyticsCompleted False (Err (Http.BadStatus 500)))
                                (Consent.init { analytics = True, writingAssistant = False, searchIndexing = False }
                                    |> (\m -> { m | analyticsConsent = False })
                                )
                                (Just (TestHelpers.creds "tok"))
                    in
                    model.analyticsConsent |> Expect.equal True
            , test "⛔ a 401 reverts the flip AND hands off SessionExpired" <|
                \_ ->
                    let
                        ( model, _, out ) =
                            Consent.update
                                (Consent.SaveAnalyticsCompleted True (Err (Http.BadStatus 401)))
                                (Consent.init { analytics = False, writingAssistant = False, searchIndexing = False }
                                    |> (\m -> { m | analyticsConsent = True })
                                )
                                (Just (TestHelpers.creds "tok"))
                    in
                    Expect.all
                        [ \_ -> model.analyticsConsent |> Expect.equal False
                        , \_ -> model.analyticsSaving |> Expect.equal (Failure (Http.BadStatus 401))
                        , \_ -> out |> Expect.equal Consent.SessionExpired
                        ]
                        ()
            , test "a successful save records Success" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update
                                (Consent.SaveAnalyticsCompleted True (Ok ()))
                                (Consent.init { analytics = True, writingAssistant = False, searchIndexing = False })
                                (Just (TestHelpers.creds "tok"))
                    in
                    model.analyticsSaving |> Expect.equal (Success ())
            , test "⛔ a failed save is RENDERED inline, announced (role=alert), and the flip reverts" <|
                -- ⛔ The per-control outcome, planted red: with only the model
                -- assertions above, deleting the analytics `viewSaveError` call
                -- would be silent — a failed analytics save would render nowhere,
                -- and under save-on-click (no Save button) nothing else reports
                -- it either. A reader must be able to tell the click did NOT
                -- take, so the inline status is load-bearing.
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update
                                (Consent.SaveAnalyticsCompleted True (Err (Http.BadStatus 500)))
                                (Consent.init { analytics = False, writingAssistant = False, searchIndexing = False }
                                    |> (\m -> { m | analyticsConsent = True })
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
                                            "analytics-consent-error"
                                        )
                                    ]
                                |> Query.has
                                    [ Selector.attribute (Html.Attributes.attribute "role" "alert") ]
                        , \_ ->
                            model.analyticsConsent |> Expect.equal False
                        ]
                        ()
            , test "and with no failure, no analytics error element is rendered at all" <|
                -- The negative half: an assertion that only ever looks at the
                -- failure state cannot tell a correct render from one that always
                -- renders.
                \_ ->
                    Consent.init { analytics = False, writingAssistant = False, searchIndexing = False }
                        |> Consent.viewSection False
                        |> Query.fromHtml
                        |> Query.findAll
                            [ Selector.attribute
                                (Html.Attributes.attribute "data-testid"
                                    "analytics-consent-error"
                                )
                            ]
                        |> Query.count (Expect.equal 0)
            ]
        , describe "Consent — each control reports only its own outcome"
            [ test "ToggleAnalytics flips analyticsConsent even with no token" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update Consent.ToggleAnalytics (Consent.init { analytics = False, writingAssistant = False, searchIndexing = False }) Nothing
                    in
                    model.analyticsConsent |> Expect.equal True
            , test "⛔ the writing toggle touches ONLY its own save state" <|
                -- ⛔ The three controls each report their own outcome. They must
                -- not share a status field — flipping one would then put
                -- another's reported state into saving-then-saved for a save
                -- nobody asked for.
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update Consent.ToggleWritingAssistant
                                (Consent.init { analytics = False, writingAssistant = False, searchIndexing = False })
                                (Just (TestHelpers.creds "tok"))
                    in
                    Expect.all
                        [ \m -> m.writingAssistantSaving |> Expect.equal Loading
                        , \m -> m.analyticsSaving |> Expect.equal NotAsked
                        , \m -> m.searchIndexingSaving |> Expect.equal NotAsked
                        ]
                        model
            , test "⛔ a FAILED writing toggle does not touch the analytics state" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update
                                (Consent.SaveWritingAssistantCompleted True (Err (Http.BadStatus 500)))
                                (Consent.init { analytics = False, writingAssistant = True, searchIndexing = False })
                                (Just (TestHelpers.creds "tok"))
                    in
                    Expect.all
                        [ \m -> m.writingAssistantSaving |> Expect.equal (Failure (Http.BadStatus 500))
                        , \m -> m.analyticsSaving |> Expect.equal NotAsked
                        ]
                        model
            , test "⛔ a failed book-linking save is RENDERED, announced, and reverts the toggle" <|
                -- ⛔ Predicted and confirmed: with only the model assertions
                -- above, deleting the view's `Failure err -> p [...]` branch
                -- produced ZERO red — so a failed consent withdrawal would have
                -- been silent everywhere.
                --
                -- Three things in one assertion because they are one event: the
                -- message appears, it is announced (`role="alert"`), and the
                -- optimistic flip is undone so the control stops disagreeing with
                -- the server about a consent record.
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update
                                (Consent.SaveWritingAssistantCompleted True (Err (Http.BadStatus 500)))
                                (Consent.init { analytics = False, writingAssistant = False, searchIndexing = False }
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
                -- ⛔ `.toggle-row` is `display: flex; justify-content: space-between`,
                -- so a third child moved the toggle button from the right edge to
                -- the CENTRE on failure, `.error`'s padding stretched the row, and
                -- with no `flex-wrap` it compressed to roughly one word per line at
                -- 400px. CSS has no test that can see that, so the structural fact —
                -- the error is a SIBLING of the row, not a child — is what gets
                -- pinned.
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update
                                (Consent.SaveWritingAssistantCompleted True
                                    (Err (Http.BadStatus 500))
                                )
                                (Consent.init { analytics = False, writingAssistant = False, searchIndexing = False })
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
            , test "⛔ a 401 reverts, reports AND clears Loading — not just a 500" <|
                -- ⛔ The gap the 500-based cases above could not see, and it was
                -- on the MOST LIKELY failure for a consent save. `isUnauthorized`
                -- is 401-only, and that branch used to return the model
                -- untouched: the optimistic flip was never reverted, no error
                -- rendered, and `writingAssistantSaving` stayed `Loading` forever.
                \_ ->
                    let
                        ( model, _, out ) =
                            Consent.update
                                (Consent.SaveWritingAssistantCompleted True
                                    (Err (Http.BadStatus 401))
                                )
                                (Consent.init { analytics = False, writingAssistant = False, searchIndexing = False }
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
                -- restore exact.
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update
                                (Consent.SaveWritingAssistantCompleted False
                                    (Err (Http.BadStatus 500))
                                )
                                (Consent.init { analytics = False, writingAssistant = True, searchIndexing = False })
                                (Just (TestHelpers.creds "tok"))
                    in
                    model.writingAssistantConsent
                        |> Expect.equal True
            ]
        , describe "Consent — search-indexing toggle (optimistic save, revert, 401)"
            [ test "toggling sets only its own saving state, not the others" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update Consent.ToggleSearchIndexing
                                (Consent.init { analytics = False, writingAssistant = False, searchIndexing = False })
                                (Just (TestHelpers.creds "tok"))
                    in
                    Expect.all
                        [ \m -> m.searchIndexingSaving |> Expect.equal Loading
                        , \m -> m.searchIndexingConsent |> Expect.equal True
                        , \m -> m.analyticsSaving |> Expect.equal NotAsked
                        ]
                        model
            , test "⛔ a failed save (500) REVERTS the optimistic flip and records Failure" <|
                -- the un-reverted state is, by the module's own comment, "the worst
                -- available outcome: the reader believes they have withdrawn consent
                -- and processing continues" — so the revert is the load-bearing arm.
                \_ ->
                    let
                        ( model, _, out ) =
                            Consent.update
                                (Consent.SaveSearchIndexingCompleted True (Err (Http.BadStatus 500)))
                                (Consent.init { analytics = False, writingAssistant = False, searchIndexing = False }
                                    |> (\m -> { m | searchIndexingConsent = True })
                                )
                                (Just (TestHelpers.creds "tok"))
                    in
                    Expect.all
                        [ \_ -> model.searchIndexingConsent |> Expect.equal False
                        , \_ -> model.searchIndexingSaving |> Expect.equal (Failure (Http.BadStatus 500))
                        , \_ -> out |> Expect.equal Consent.NoOut
                        ]
                        ()
            , test "⛔ a failed REVOKE (attempted False) reverts the flip back to ON" <|
                -- the OTHER direction of the revert arm. Without this case a
                -- mutation of `not attempted` to the constant `False` survives the
                -- whole suite, because every other failure test attempts True.
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update
                                (Consent.SaveSearchIndexingCompleted False (Err (Http.BadStatus 500)))
                                (Consent.init { analytics = False, writingAssistant = False, searchIndexing = True }
                                    |> (\m -> { m | searchIndexingConsent = False })
                                )
                                (Just (TestHelpers.creds "tok"))
                    in
                    model.searchIndexingConsent |> Expect.equal True
            , test "⛔ a 401 reverts the flip AND hands off SessionExpired" <|
                \_ ->
                    let
                        ( model, _, out ) =
                            Consent.update
                                (Consent.SaveSearchIndexingCompleted True (Err (Http.BadStatus 401)))
                                (Consent.init { analytics = False, writingAssistant = False, searchIndexing = False }
                                    |> (\m -> { m | searchIndexingConsent = True })
                                )
                                (Just (TestHelpers.creds "tok"))
                    in
                    Expect.all
                        [ \_ -> model.searchIndexingConsent |> Expect.equal False
                        , \_ -> out |> Expect.equal Consent.SessionExpired
                        ]
                        ()
            , test "a successful save records Success" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update
                                (Consent.SaveSearchIndexingCompleted True (Ok ()))
                                (Consent.init { analytics = False, writingAssistant = False, searchIndexing = True })
                                (Just (TestHelpers.creds "tok"))
                    in
                    model.searchIndexingSaving |> Expect.equal (Success ())
            , test "a failed save is RENDERED and announced (role=alert)" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update
                                (Consent.SaveSearchIndexingCompleted True (Err (Http.BadStatus 500)))
                                (Consent.init { analytics = False, writingAssistant = False, searchIndexing = False }
                                    |> (\m -> { m | searchIndexingConsent = True })
                                )
                                (Just (TestHelpers.creds "tok"))
                    in
                    Consent.viewSection False model
                        |> Query.fromHtml
                        |> Query.find
                            [ Selector.attribute
                                (Html.Attributes.attribute "data-testid" "search-indexing-consent-error")
                            ]
                        |> Query.has [ Selector.attribute (Html.Attributes.attribute "role" "alert") ]
            ]
        , describe "Consent — a saved choice can be changed again"
            [ test "toggling analytics after a successful save re-enters its own Loading (it re-saves)" <|
                \_ ->
                    consentAfterSave
                        |> toggleAnalytics
                        |> .analyticsSaving
                        |> Expect.equal Loading
            , test "positive control — the save really did reach Success first" <|
                \_ ->
                    consentAfterSave.analyticsSaving |> Expect.equal (Success ())
            , test "the toggle still flips the value it is there to flip" <|
                \_ ->
                    consentAfterSave
                        |> toggleAnalytics
                        |> .analyticsConsent
                        |> Expect.equal False
            ]
        ]


{-| A consent page whose analytics preference has been turned on, saved on click
(no Save button), and confirmed by the server.
-}
consentAfterSave : Consent.Model
consentAfterSave =
    Consent.init { analytics = False, writingAssistant = False, searchIndexing = False }
        |> toggleAnalytics
        |> consentUpdate (Consent.SaveAnalyticsCompleted True (Ok ()))


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
