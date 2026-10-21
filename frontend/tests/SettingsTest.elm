module SettingsTest exposing (suite)

import Expect
import Html.Attributes
import Http
import Page.Settings.Consent as Consent
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
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
                            Consent.update Consent.SaveConsent (Consent.init { analytics = False, writingAssistant = False }) (Just "tok")
                    in
                    model.saving |> Expect.equal Loading
            , test "SaveConsent without token leaves saving as NotAsked" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update Consent.SaveConsent (Consent.init { analytics = False, writingAssistant = False }) Nothing
                    in
                    model.saving |> Expect.equal NotAsked
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
                                (Just "tok")
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
                                (Consent.SaveWritingAssistantCompleted (Err (Http.BadStatus 500)))
                                (Consent.init { analytics = False, writingAssistant = True })
                                (Just "tok")
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
                                (Consent.SaveWritingAssistantCompleted (Err (Http.BadStatus 500)))
                                (Consent.init { analytics = False, writingAssistant = False }
                                    |> (\m -> { m | writingAssistantConsent = True })
                                )
                                (Just "tok")

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
            , test "and a SaveConsent failure still surfaces under the Save button" <|
                -- The positive control: splitting the state must not make the
                -- button stop reporting the save it does govern.
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update
                                (Consent.SaveCompleted (Err (Http.BadStatus 500)))
                                (Consent.init { analytics = True, writingAssistant = False })
                                (Just "tok")
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
                            Consent.update (Consent.SaveCompleted (Ok ())) (Consent.init { analytics = False, writingAssistant = False }) (Just "tok")
                    in
                    model.saving |> Expect.equal (Success ())
            , test "SaveCompleted Err sets saving to Failure" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update (Consent.SaveCompleted (Err Http.NetworkError)) (Consent.init { analytics = False, writingAssistant = False }) (Just "tok")
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
            Consent.update msg model (Just "tok")
    in
    newModel
