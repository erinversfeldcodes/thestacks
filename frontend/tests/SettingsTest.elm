module SettingsTest exposing (suite)

import Expect
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
        , describe "Consent — a saved choice can be changed again (#363)"
            [ test "toggling analytics after a save clears the 'Saved!' state" <|
                \_ ->
                    -- ⛔ THE REGRESSION. `ToggleAnalytics` did not touch
                    -- `saving`, and nothing else on this page could return it to
                    -- `NotAsked`. So after one successful save the button read
                    -- "Saved!" for the rest of the page's life — and, in the
                    -- shipped version, the "Saved!" branch had no `onClick`.
                    -- A reader who granted analytics consent and then changed
                    -- their mind could not revoke it without reloading, and the
                    -- button claimed their unsent choice was already saved.
                    consentAfterSave
                        |> toggleAnalytics
                        |> .saving
                        |> Expect.equal NotAsked
            , test "positive control — the save really did reach Success first" <|
                \_ ->
                    -- Without this, the test above would also pass against a
                    -- page whose save never succeeds.
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
