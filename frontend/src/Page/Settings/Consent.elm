module Page.Settings.Consent exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
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


{-| The verbatim copy shown under the writing-assistant toggle when it is OFF.
Kept as a named constant so tests can assert the exact wording (Issue #184).
-}
writingAssistantOffDescription : String
writingAssistantOffDescription =
    "Your shelf and writing history are used to personalise writing suggestions. Disabling this turns off the writing assistant and deletes your session history and embeddings."


{-| Seed the consent page from the current user's actual consent state so the
toggles reflect reality on open (Issue FF-1). Previously both toggles were
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
            -- ⛔ `saving = NotAsked` is the load-bearing half of this line.
            --
            -- Analytics consent is a STAGED preference: the toggle changes the
            -- model and the "Save Preferences" button sends it. Once a save
            -- succeeded, `saving` stayed `Success ()` forever — nothing on this
            -- page could return it to `NotAsked` — and the save button's
            -- `Success` branch had no `onClick`. So flipping this toggle a
            -- second time left the reader with a button that said "Saved!",
            -- looked pressable, and was inert: **their consent choice could not
            -- be changed again without reloading the page**, and the label
            -- actively claimed the unsent value was saved.
            --
            -- `Components.SaveButton` now keeps `Success` clickable, so the
            -- reader is no longer stuck. This line fixes the other half — the
            -- lie. An edit means the on-screen values are no longer the saved
            -- ones, so the button must stop saying they are. `Settings.Profile`
            -- and `Settings.Privacy` have always done this on every edit
            -- message; this page was the one that did not.
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
                    -- Persist writing-assistant consent immediately: turning it
                    -- OFF triggers a server-side purge, so the toggle is not a
                    -- staged preference — it takes effect on click.
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


view : Model -> Html Msg
view model =
    div [ class "page page--settings" ]
        [ h1 [ class "page__title" ] [ text "Privacy & Consent" ]
        , div [ class "settings-section" ]
            [ h2 [ class "settings-section__title" ] [ text "Analytics" ]
            , p [ class "settings-section__desc" ]
                [ text
                    "Allow us to collect anonymous usage data to improve The Stacks."
                ]
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
          -- `Page.Settings.Notifications.viewSaveFeedback` for why one sentence
          -- for every failure was worse than no sentence for some of them.
          case model.saving of
            Failure err ->
                p [ class "error" ]
                    [ text (FailureCopy.saveFailure "your consent preferences" err) ]

            _ ->
                text ""
        ]
