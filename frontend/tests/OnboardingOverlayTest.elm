module OnboardingOverlayTest exposing (suite)

import Api exposing (OnboardingStatus)
import Components.OnboardingOverlay as Overlay
import Expect
import Html.Attributes
import Http
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector


{-| A successful onboarding status response indicating the user should start from "profile".
-}
statusAtProfile : OnboardingStatus
statusAtProfile =
    { completed = False
    , nextStep = Just "profile"
    }


statusAtPrivacy : OnboardingStatus
statusAtPrivacy =
    { completed = False
    , nextStep = Just "privacy"
    }


statusCompleted : OnboardingStatus
statusCompleted =
    { completed = True
    , nextStep = Nothing
    }


initialModel : Overlay.Model
initialModel =
    Overlay.init


suite : Test
suite =
    describe "OnboardingOverlay"
        [ describe "StatusLoaded"
            [ test "resumes from Welcome when next_step is profile" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Overlay.update (Overlay.StatusLoaded (Ok statusAtProfile)) initialModel
                    in
                    Expect.equal True model.visible
            , test "resumes from privacy step when next_step is privacy" <|
                \_ ->
                    let
                        ( model, _, outMsg ) =
                            Overlay.update (Overlay.StatusLoaded (Ok statusAtPrivacy)) initialModel
                    in
                    Expect.all
                        [ \m -> Expect.equal True m.visible
                        , \m -> Expect.equal Overlay.Privacy m.step
                        , \_ -> Expect.equal Overlay.NoOut outMsg
                        ]
                        model
            , test "hides the overlay when completed is true" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Overlay.update (Overlay.StatusLoaded (Ok statusCompleted)) initialModel
                    in
                    Expect.equal False model.visible
            , test "starts from Welcome on API error (graceful fallback)" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Overlay.update (Overlay.StatusLoaded (Err Http.NetworkError)) initialModel
                    in
                    Expect.equal True model.visible
            ]
        , describe "StepCompleted"
            [ test "advances to next step when more steps remain" <|
                \_ ->
                    let
                        ( model, _, outMsg ) =
                            Overlay.update (Overlay.StepCompleted (Ok statusAtPrivacy)) initialModel
                    in
                    Expect.all
                        [ \m -> Expect.equal True m.visible
                        , \m -> Expect.equal Overlay.Privacy m.step
                        , \_ -> Expect.equal Overlay.NoOut outMsg
                        ]
                        model
            , test "advances to complete when all steps done" <|
                \_ ->
                    let
                        ( model, _, outMsg ) =
                            Overlay.update (Overlay.StepCompleted (Ok statusCompleted)) initialModel
                    in
                    Expect.all
                        [ \m -> Expect.equal True m.visible
                        , \m -> Expect.equal Overlay.Complete m.step
                        , \_ -> Expect.equal Overlay.NoOut outMsg
                        ]
                        model
            , test "advances locally on API error (user not stuck)" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Overlay.update (Overlay.StepCompleted (Err Http.NetworkError)) initialModel
                    in
                    Expect.all
                        [ \m -> Expect.equal True m.visible
                        , \m -> Expect.equal Overlay.Privacy m.step
                        ]
                        model
            ]
        , describe "SkipOnboarding"
            [ test "hides the overlay and emits SkipCompleted" <|
                \_ ->
                    let
                        ( model, _, outMsg ) =
                            Overlay.update Overlay.SkipOnboarding initialModel
                    in
                    Expect.all
                        [ \m -> Expect.equal False m.visible
                        , \_ -> Expect.equal Overlay.SkipCompleted outMsg
                        ]
                        model
            ]
        , describe "FinishOnboarding"
            [ test "hides the overlay and emits FinishCompleted" <|
                \_ ->
                    let
                        ( model, _, outMsg ) =
                            Overlay.update Overlay.FinishOnboarding initialModel
                    in
                    Expect.all
                        [ \m -> Expect.equal False m.visible
                        , \_ -> Expect.equal Overlay.FinishCompleted outMsg
                        ]
                        model
            ]
        , describe "NextStep loading guard"
            [ test "NextStep sets loading = True to prevent duplicate API calls" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Overlay.update Overlay.NextStep initialModel
                    in
                    Expect.equal True model.loading
            , test "Continue button is disabled while loading = True" <|
                \_ ->
                    let
                        loadingModel =
                            { initialModel | loading = True }
                    in
                    Overlay.view loadingModel
                        |> Query.fromHtml
                        |> Query.find
                            [ Selector.attribute
                                (Html.Attributes.attribute "data-testid" "onboarding-continue-btn")
                            ]
                        |> Query.has [ Selector.disabled True ]
            , test "Continue button is enabled while loading = False" <|
                \_ ->
                    Overlay.view initialModel
                        |> Query.fromHtml
                        |> Query.find
                            [ Selector.attribute
                                (Html.Attributes.attribute "data-testid" "onboarding-continue-btn")
                            ]
                        |> Query.has [ Selector.disabled False ]
            ]
        ]
