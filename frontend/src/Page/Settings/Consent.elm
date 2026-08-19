module Page.Settings.Consent exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , analyticsDescription
    , init
    , update
    , view
    , viewSection
    , writingAssistantOffDescription
    )

import Api
import Components.SaveButton as SaveButton
import Html exposing (Html, button, div, h1, h2, label, p, text)
import Html.Attributes exposing (attribute, class)
import Html.Events exposing (onClick)
import Http
import Types.RemoteData exposing (RemoteData(..))
import Util.FailureCopy as FailureCopy


type alias Model =
    { analyticsConsent : Bool
    , writingAssistantConsent : Bool
    , saving : RemoteData Http.Error ()
    }


type Msg
    = ToggleAnalytics
    | ToggleWritingAssistant
    | SaveConsent
    | SaveCompleted (Result Http.Error ())
    | SaveWritingAssistantCompleted (Result Http.Error ())


type OutMsg
    = NoOut
    | SessionExpired


{-| The verbatim copy shown under the analytics toggle, in either position.

The switch is real — the answer is stored, exported and erased with the rest of
your record — but nothing on the platform reads it, so the old "allow us to
collect anonymous usage data" was describing a collection that does not happen.
Kept as a named constant so a test pins the wording: if analytics ever start
being read, this sentence becomes false and the test is where that is noticed.

-}
analyticsDescription : String
analyticsDescription =
    "Reserved — nothing reads this yet. No usage data is collected about you, by us or by anyone else. Your answer is recorded now so that if that ever changes, it changes with your say-so already on file rather than assumed."


{-| The verbatim copy shown under the writing-assistant toggle when it is OFF.
Kept as a named constant so tests can assert the exact wording.
-}
writingAssistantOffDescription : String
writingAssistantOffDescription =
    "Your shelf and writing history are used to personalise writing suggestions. Disabling this turns off the writing assistant and deletes your session history and embeddings."


{-| Seed the consent page from the current user's actual consent state so the
toggles reflect reality on open. Previously both toggles were
hard-coded OFF, so a user who had already granted consent saw them as OFF and
their first click re-granted instead of revoking.
-}
init : { analytics : Bool, writingAssistant : Bool } -> Model
init consent =
    { analyticsConsent = consent.analytics
    , writingAssistantConsent = consent.writingAssistant
    , saving = NotAsked
    }


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg, OutMsg )
update msg model maybeToken =
    case msg of
        ToggleAnalytics ->
            ( { model | analyticsConsent = not model.analyticsConsent, saving = NotAsked }
            , Cmd.none
            , NoOut
            )

        ToggleWritingAssistant ->
            let
                newValue =
                    not model.writingAssistantConsent
            in
            case maybeToken of
                Just token ->
                    ( { model | writingAssistantConsent = newValue, saving = Loading }
                    , Api.saveWritingAssistantConsent newValue token SaveWritingAssistantCompleted
                    , NoOut
                    )

                Nothing ->
                    ( { model | writingAssistantConsent = newValue }, Cmd.none, NoOut )

        SaveConsent ->
            case maybeToken of
                Just token ->
                    ( { model | saving = Loading }
                    , Api.saveConsent model.analyticsConsent token SaveCompleted
                    , NoOut
                    )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        SaveWritingAssistantCompleted result ->
            case result of
                Ok _ ->
                    ( { model | saving = Success () }, Cmd.none, NoOut )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | saving = Failure err }, Cmd.none, NoOut )

        SaveCompleted result ->
            case result of
                Ok _ ->
                    ( { model | saving = Success () }, Cmd.none, NoOut )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | saving = Failure err }, Cmd.none, NoOut )


{-| The standalone-page wrapper. Since TR-4 the consent controls live as a
section INSIDE the Privacy page (`Page.Settings.Privacy` embeds this module and
renders `viewSection`); this whole-page view is retained for direct unit tests
of the consent surface. The update path — and therefore what
`Stacks.GDPR.Consent` records via `Api.saveConsent` /
`Api.saveWritingAssistantConsent` — is unchanged either way.
-}
view : Model -> Html Msg
view model =
    div [ class "page page--settings" ]
        [ h1 [ class "page__title" ] [ text "Privacy & Consent" ]
        , viewSection model
        ]


{-| The consent controls with no page chrome, so the Privacy page can fold them
in as a section (TR-4). Identical markup to the standalone page minus its
`page`/`h1` wrapper.
-}
viewSection : Model -> Html Msg
viewSection model =
    div [ class "settings-consent" ]
        [ div [ class "settings-section" ]
            [ h2 [ class "settings-section__title" ] [ text "Analytics" ]
            , p [ class "settings-section__desc" ]
                [ text analyticsDescription ]
            , div [ class "toggle-row" ]
                [ label [ class "toggle-row__label" ] [ text "Analytics" ]
                , button
                    [ class
                        (if model.analyticsConsent then
                            "toggle toggle--on"

                         else
                            "toggle toggle--off"
                        )
                    , attribute "data-testid" "analytics-consent-toggle"
                    , onClick ToggleAnalytics
                    ]
                    [ text
                        (if model.analyticsConsent then
                            "On"

                         else
                            "Off"
                        )
                    ]
                ]
            ]
        , div [ class "settings-section" ]
            [ h2 [ class "settings-section__title" ] [ text "Writing assistant" ]
            , p [ class "settings-section__desc" ]
                [ text
                    (if model.writingAssistantConsent then
                        "Your shelf and writing history are used to personalise writing suggestions."

                     else
                        writingAssistantOffDescription
                    )
                ]
            , div [ class "toggle-row" ]
                [ label [ class "toggle-row__label" ] [ text "Writing assistant" ]
                , button
                    [ class
                        (if model.writingAssistantConsent then
                            "toggle toggle--on"

                         else
                            "toggle toggle--off"
                        )
                    , attribute "data-testid" "writing-assistant-consent-toggle"
                    , onClick ToggleWritingAssistant
                    ]
                    [ text
                        (if model.writingAssistantConsent then
                            "On"

                         else
                            "Off"
                        )
                    ]
                ]
            ]
        , div [ class "settings-actions" ]
            [ SaveButton.primary model.saving SaveConsent "Save Preferences" ]
        , -- Distinguished by cause since #374 — see
          case model.saving of
            Failure err ->
                p [ class "error" ]
                    [ text (FailureCopy.saveFailure "your consent preferences" err) ]

            _ ->
                text ""
        ]
