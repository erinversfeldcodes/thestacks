module SettingsTest exposing (suite)

import Expect
import Http
import Page.Settings.AgeVerification as AgeVerification exposing (Msg(..))
import Page.Settings.Consent as Consent
import Test exposing (Test, describe, test)
import Types.RemoteData exposing (RemoteData(..))


suite : Test
suite =
    describe "Settings pages"
        [ describe "Consent"
            [ test "SaveConsent with token sets saving to Loading" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update Consent.SaveConsent Consent.init (Just "tok")
                    in
                    model.saving |> Expect.equal Loading
            , test "SaveConsent without token leaves saving as NotAsked" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update Consent.SaveConsent Consent.init Nothing
                    in
                    model.saving |> Expect.equal NotAsked
            , test "ToggleAnalytics flips analyticsConsent" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update Consent.ToggleAnalytics Consent.init Nothing
                    in
                    model.analyticsConsent |> Expect.equal True
            , test "SaveCompleted Ok sets saving to Success" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update (Consent.SaveCompleted (Ok ())) Consent.init (Just "tok")
                    in
                    model.saving |> Expect.equal (Success ())
            , test "SaveCompleted Err sets saving to Failure" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update (Consent.SaveCompleted (Err Http.NetworkError)) Consent.init (Just "tok")
                    in
                    model.saving |> Expect.equal (Failure Http.NetworkError)
            ]
        , describe "AgeVerification"
            [ test "ToggleRequested opens the confirmation modal" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            AgeVerification.update ToggleRequested AgeVerification.init (Just "tok")
                    in
                    model.confirmModalOpen |> Expect.equal True
            , test "CancelToggle closes the modal" <|
                \_ ->
                    let
                        base =
                            AgeVerification.init

                        modelWithModal =
                            { base | confirmModalOpen = True }

                        ( model, _, _ ) =
                            AgeVerification.update CancelToggle modelWithModal Nothing
                    in
                    model.confirmModalOpen |> Expect.equal False
            , test "ConfirmToggle with token sets saving to Loading without flipping ageVerified" <|
                \_ ->
                    let
                        base =
                            AgeVerification.init

                        modelWithModal =
                            { base | confirmModalOpen = True }

                        ( model, _, _ ) =
                            AgeVerification.update ConfirmToggle modelWithModal (Just "tok")
                    in
                    Expect.all
                        [ \m -> m.saving |> Expect.equal Loading
                        , \m -> m.ageVerified |> Expect.equal False
                        , \m -> m.confirmModalOpen |> Expect.equal False
                        ]
                        model
            , test "ConfirmToggle without token closes modal without setting Loading" <|
                \_ ->
                    let
                        base =
                            AgeVerification.init

                        modelWithModal =
                            { base | confirmModalOpen = True }

                        ( model, _, _ ) =
                            AgeVerification.update ConfirmToggle modelWithModal Nothing
                    in
                    Expect.all
                        [ \m -> m.saving |> Expect.equal NotAsked
                        , \m -> m.confirmModalOpen |> Expect.equal False
                        ]
                        model
            , test "SaveCompleted Ok flips ageVerified and sets Success" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            AgeVerification.update (SaveCompleted (Ok ())) AgeVerification.init (Just "tok")
                    in
                    Expect.all
                        [ \m -> m.ageVerified |> Expect.equal True
                        , \m -> m.saving |> Expect.equal (Success ())
                        ]
                        model
            , test "SaveCompleted Err leaves ageVerified unchanged and sets Failure" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            AgeVerification.update (SaveCompleted (Err Http.NetworkError)) AgeVerification.init (Just "tok")
                    in
                    Expect.all
                        [ \m -> m.ageVerified |> Expect.equal False
                        , \m -> m.saving |> Expect.equal (Failure Http.NetworkError)
                        ]
                        model
            ]
        ]
