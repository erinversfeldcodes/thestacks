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
        ]
