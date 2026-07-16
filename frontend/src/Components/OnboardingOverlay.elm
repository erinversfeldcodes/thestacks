module Components.OnboardingOverlay exposing
    ( Model
    , Msg(..)
    , OnboardingStep(..)
    , OutMsg(..)
    , completeStep
    , init
    , initCmd
    , update
    , view
    )

{-| OnboardingOverlay — API-driven onboarding flow.

On init (when a token is available) it calls GET /api/onboarding/status to
resume from the correct step rather than always starting at step 1.

Completing each step calls PUT /api/onboarding/step/:step and advances to
the next step on success. The two backend steps map to the two UI steps
(the self-declared age step was removed with ADR-020 — age assurance is now
provider-sourced, shipped in a later issue):

    profile  → Welcome (set up your profile)
    privacy  → Privacy (privacy settings)

-}

import Api exposing (OnboardingStatus)
import Browser.Dom
import Html exposing (Html, button, div, h2, p, span, text)
import Html.Attributes exposing (attribute, class, disabled, tabindex)
import Html.Events exposing (onClick)
import Http
import Task
import Util.TestId exposing (testId)


type OnboardingStep
    = Welcome
    | Privacy
    | Complete


type alias Model =
    { step : OnboardingStep
    , visible : Bool
    , loading : Bool
    }


type OutMsg
    = NoOut
    | SkipCompleted
    | FinishCompleted


type Msg
    = StatusLoaded (Result Http.Error OnboardingStatus)
    | StepCompleted (Result Http.Error OnboardingStatus)
    | NextStep
    | SkipOnboarding
    | FinishOnboarding
    | FocusResult


{-| Create the initial model. Call `initCmd` with the auth token to load the
resume point from the API.
-}
init : Model
init =
    { step = Welcome
    , loading = False
    , visible = True
    }


{-| Fire the GET /api/onboarding/status request. Call this from the parent's
init whenever a token is available.
-}
initCmd : String -> Cmd Msg
initCmd token =
    Api.getOnboardingStatus token StatusLoaded


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        StatusLoaded (Ok status) ->
            let
                step =
                    stepFromNextStep status.nextStep
            in
            if status.completed then
                ( { model | visible = False, loading = False }, Cmd.none, NoOut )

            else
                ( { model | step = step, loading = False }, Cmd.none, NoOut )

        StatusLoaded (Err _) ->
            -- On error, start from Welcome rather than blocking the user
            ( { model | step = Welcome, loading = False }, Cmd.none, NoOut )

        StepCompleted (Ok status) ->
            let
                step =
                    stepFromNextStep status.nextStep
            in
            if status.completed then
                ( { model | step = Complete, loading = False }, Cmd.none, NoOut )

            else
                ( { model | step = step, loading = False }, Cmd.none, NoOut )

        StepCompleted (Err _) ->
            -- On error, advance locally so the user is not stuck
            ( { model | step = nextStep model.step, loading = False }, Cmd.none, NoOut )

        NextStep ->
            ( { model | step = nextStep model.step, loading = True }
            , Task.attempt (\_ -> FocusResult) (Browser.Dom.focus "onboarding-overlay-container")
            , NoOut
            )

        SkipOnboarding ->
            ( { model | visible = False }, Cmd.none, SkipCompleted )

        FinishOnboarding ->
            ( { model | visible = False }, Cmd.none, FinishCompleted )

        FocusResult ->
            ( model, Cmd.none, NoOut )


{-| Advance a step — used as a fallback when the API call fails.
-}
nextStep : OnboardingStep -> OnboardingStep
nextStep step =
    case step of
        Welcome ->
            Privacy

        Privacy ->
            Complete

        Complete ->
            Complete


{-| Map the backend next\_step string to the overlay step.
An empty / missing next\_step means all steps are done.
-}
stepFromNextStep : Maybe String -> OnboardingStep
stepFromNextStep maybeNext =
    case maybeNext of
        Just "profile" ->
            Welcome

        Just "privacy" ->
            Privacy

        _ ->
            Complete


{-| The backend step name for each overlay step.
-}
backendStepName : OnboardingStep -> String
backendStepName step =
    case step of
        Welcome ->
            "profile"

        Privacy ->
            "privacy"

        Complete ->
            ""


{-| Complete the current step via the API and advance.
Pass the auth token from the parent.
-}
completeStep : String -> OnboardingStep -> Cmd Msg
completeStep token step =
    let
        name =
            backendStepName step
    in
    if name == "" then
        Cmd.none

    else
        Api.completeOnboardingStep name token StepCompleted


view : Model -> Html Msg
view model =
    if not model.visible then
        text ""

    else
        div
            [ class "onboarding-overlay"
            , testId "onboarding-overlay"
            , attribute "role" "dialog"
            , attribute "aria-modal" "true"
            , attribute "aria-label" "Welcome to The Stacks"
            , attribute "id" "onboarding-overlay-container"
            , tabindex -1
            ]
            [ div [ class "onboarding-overlay__backdrop" ] []
            , div [ class "onboarding-overlay__card" ]
                [ viewStep model.loading model.step
                , viewProgressDots model.step
                ]
            ]


viewStep : Bool -> OnboardingStep -> Html Msg
viewStep loading step =
    case step of
        Welcome ->
            div [ class "onboarding-overlay__step" ]
                [ h2 [ class "onboarding-overlay__title" ]
                    [ text "Welcome to The Stacks" ]
                , p [ class "onboarding-overlay__tagline" ]
                    [ text "Your personal collection, beautifully organised." ]
                , div [ class "onboarding-overlay__actions" ]
                    [ button
                        [ class "btn btn--primary"
                        , onClick NextStep
                        , disabled loading
                        , testId "onboarding-continue-btn"
                        ]
                        [ text "Get started" ]
                    , button
                        [ class "btn btn--ghost"
                        , onClick SkipOnboarding
                        ]
                        [ text "Skip" ]
                    ]
                ]

        Privacy ->
            div [ class "onboarding-overlay__step" ]
                [ h2 [ class "onboarding-overlay__title" ]
                    [ text "Your privacy" ]
                , p [ class "onboarding-overlay__tagline" ]
                    [ text "Choose who can see your shelves and activity. You can change this any time in Settings." ]
                , div [ class "onboarding-overlay__actions" ]
                    [ button
                        [ class "btn btn--primary"
                        , onClick NextStep
                        , disabled loading
                        , testId "onboarding-continue-btn"
                        ]
                        [ text "Continue" ]
                    , button
                        [ class "btn btn--ghost"
                        , onClick SkipOnboarding
                        ]
                        [ text "Skip" ]
                    ]
                ]

        Complete ->
            div [ class "onboarding-overlay__step" ]
                [ h2 [ class "onboarding-overlay__title" ]
                    [ text "Welcome to your library" ]
                , p [ class "onboarding-overlay__tagline" ]
                    [ text "Your shelves are ready. Start exploring and organising your books." ]
                , div [ class "onboarding-overlay__actions" ]
                    [ button
                        [ class "btn btn--primary"
                        , onClick FinishOnboarding
                        , testId "onboarding-continue-btn"
                        ]
                        [ text "Start exploring" ]
                    ]
                ]


viewProgressDots : OnboardingStep -> Html Msg
viewProgressDots step =
    let
        stepIndex =
            case step of
                Welcome ->
                    0

                Privacy ->
                    1

                Complete ->
                    2

        dot idx =
            span
                [ class
                    (if idx == stepIndex then
                        "onboarding-overlay__dot onboarding-overlay__dot--active"

                     else
                        "onboarding-overlay__dot"
                    )
                ]
                []
    in
    div [ class "onboarding-overlay__dots" ]
        [ dot 0
        , dot 1
        , dot 2
        ]
