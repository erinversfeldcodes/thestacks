module Components.OnboardingOverlay exposing
    ( Model
    , Msg
    , OutMsg(..)
    , init
    , update
    , view
    )

import Html exposing (Html, button, div, h2, p, span, text)
import Html.Attributes exposing (attribute, class, tabindex)
import Html.Events exposing (onClick)


type OnboardingStep
    = Welcome
    | UploadPrompt
    | Complete


type alias Model =
    { step : OnboardingStep
    , visible : Bool
    }


type OutMsg
    = NoOut
    | SkipCompleted
    | FinishCompleted


type Msg
    = NextStep
    | SkipOnboarding
    | FinishOnboarding


init : Model
init =
    { step = Welcome
    , visible = True
    }


update : Msg -> Model -> ( Model, OutMsg )
update msg model =
    case msg of
        NextStep ->
            case model.step of
                Welcome ->
                    ( { model | step = UploadPrompt }, NoOut )

                UploadPrompt ->
                    ( { model | step = Complete }, NoOut )

                Complete ->
                    ( { model | visible = False }, FinishCompleted )

        SkipOnboarding ->
            ( { model | visible = False }, SkipCompleted )

        FinishOnboarding ->
            ( { model | visible = False }, FinishCompleted )


view : Model -> Html Msg
view model =
    if not model.visible then
        text ""

    else
        div
            [ class "onboarding-overlay"
            , attribute "role" "dialog"
            , attribute "aria-modal" "true"
            , attribute "aria-label" "Welcome to The Stacks"
            , tabindex -1
            ]
            [ div [ class "onboarding-overlay__backdrop" ] []
            , div [ class "onboarding-overlay__card" ]
                [ viewStep model.step
                , viewProgressDots model.step
                ]
            ]


viewStep : OnboardingStep -> Html Msg
viewStep step =
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
                        ]
                        [ text "Get started" ]
                    , button
                        [ class "btn btn--ghost"
                        , onClick SkipOnboarding
                        ]
                        [ text "Skip" ]
                    ]
                ]

        UploadPrompt ->
            div [ class "onboarding-overlay__step" ]
                [ h2 [ class "onboarding-overlay__title" ]
                    [ text "Upload your first book" ]
                , p [ class "onboarding-overlay__tagline" ]
                    [ text "Take a photo of a book cover or enter an ISBN to start building your collection." ]
                , div [ class "onboarding-overlay__actions" ]
                    [ button
                        [ class "btn btn--primary"
                        , onClick NextStep
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

                UploadPrompt ->
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
