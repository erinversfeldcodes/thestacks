module Page.Settings.Consent exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , analyticsDescription
    , init
    , update
    , view
    , viewSection
    )

import Api
import Components.SaveButton as SaveButton
import Effect exposing (Effect)
import Html exposing (Html, button, div, h1, h2, label, p, text)
import Html.Attributes exposing (attribute, class, disabled)
import Html.Events exposing (onClick)
import Http
import Types.RemoteData exposing (RemoteData(..))
import Util.FailureCopy as FailureCopy


type alias Model =
    { analyticsConsent : Bool
    , writingAssistantConsent : Bool
    , saving : RemoteData Http.Error ()

    {- ⛔ The writing toggle's OWN save state, separate from `saving`.

       The two controls on this page have different durability: analytics is a
       draft until "Save Preferences" is pressed, while the writing toggle
       writes immediately on click. That is a design asymmetry and is recorded
       as one — but they also used to SHARE `saving`, which turned it into a
       lie: flipping the writing toggle made "Save Preferences" show its
       saving-then-saved state for a save the reader never asked for, and a
       writing-toggle FAILURE rendered an error message underneath a button that
       had not been pressed.

       Splitting them means each control reports its own outcome, so the Save
       button speaks only for what it actually governs.
    -}
    , writingAssistantSaving : RemoteData Http.Error ()
    }


type Msg
    = ToggleAnalytics
    | SessionExpiryDetected
    | ToggleWritingAssistant
    | SaveConsent
    | SaveCompleted (Result Http.Error ())
      -- ⚠️ Carries the value that was ATTEMPTED, so a failure can restore the
      -- opposite exactly rather than toggling the current value back — which
      -- assumes exactly one flip is in flight.
    | SaveWritingAssistantCompleted Bool (Result Http.Error ())


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


{-| The verbatim copy shown under the AI book-linking toggle when it is OFF.
A named constant so the off-state wording lives in one place; the assertion that
a reader actually sees it is in the settings e2e spec, against the rendered page.

This used to describe a writing assistant that draws on your shelf and writing
history. No such feature exists — it was designed, never built, and the claim has
been retired. What the switch actually controls is narrower and worth saying
plainly: whether a published post may be sent to an AI model to work out which
books it mentions.

-}
writingAssistantOffDescription : String
writingAssistantOffDescription =
    "Your published posts are not sent to an AI model, so books you mention won't be linked automatically."


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
    , writingAssistantSaving = NotAsked
    }


update : Msg -> Model -> Maybe Api.Credentials -> ( Model, Cmd Msg, OutMsg )
update msg model maybeToken =
    let
        ( newModel, effect, out ) =
            updateWithEffect msg model maybeToken
    in
    ( newModel, Effect.perform effect, out )


updateWithEffect : Msg -> Model -> Maybe Api.Credentials -> ( Model, Effect Msg, OutMsg )
updateWithEffect msg model maybeToken =
    case msg of
        -- ⛔ NEW WITH THE PLAN, and it is an obligation the old call could not
        -- state. `Api.saveConsent` took a bare `toMsg`, so a 401 arrived as an
        -- ordinary failure and the page showed "could not save" beside a toggle
        -- that would never save again. `Effect.authed` requires `onExpired`, so
        -- asking this endpoint now means saying what an ended session does.
        SessionExpiryDetected ->
            ( model, Effect.None, SessionExpired )

        ToggleAnalytics ->
            ( { model | analyticsConsent = not model.analyticsConsent, saving = NotAsked }
            , Effect.None
            , NoOut
            )

        ToggleWritingAssistant ->
            let
                newValue =
                    not model.writingAssistantConsent
            in
            case maybeToken of
                Just token ->
                    ( { model
                        | writingAssistantConsent = newValue
                        , writingAssistantSaving = Loading
                      }
                    , Effect.authed (Api.saveWritingAssistantConsentRequest newValue)
                        token
                        { onExpired = SessionExpiryDetected
                        , onResponse =
                            Api.resolveWhatever >> SaveWritingAssistantCompleted newValue
                        }
                    , NoOut
                    )

                Nothing ->
                    ( { model | writingAssistantConsent = newValue }, Effect.None, NoOut )

        SaveConsent ->
            case maybeToken of
                Just token ->
                    ( { model | saving = Loading }
                    , Effect.authed (Api.saveConsentRequest model.analyticsConsent)
                        token
                        { onExpired = SessionExpiryDetected
                        , onResponse = Api.resolveWhatever >> SaveCompleted
                        }
                    , NoOut
                    )

                Nothing ->
                    ( model, Effect.None, NoOut )

        SaveWritingAssistantCompleted attempted result ->
            case result of
                Ok _ ->
                    ( { model | writingAssistantSaving = Success () }, Effect.None, NoOut )

                Err err ->
                    let
                        -- ⚠️ Restored from the ATTEMPTED value, not by toggling
                        -- the current one back. A blind `not model.…Consent`
                        -- assumes exactly one flip is in flight, so a second
                        -- click during an in-flight save could make this handler
                        -- flip away from what the server stored. The view also
                        -- disables the control while saving, which closes that
                        -- window — this makes the restore exact rather than
                        -- merely unlikely to be wrong.
                        restored =
                            { model
                                | writingAssistantConsent = not attempted
                                , writingAssistantSaving = Failure err
                            }
                    in
                    if Api.isUnauthorized err then
                        -- ⛔ The 401 path gets the SAME treatment, and its
                        -- absence was the sharpest gap here: `isUnauthorized` is
                        -- 401-only and this branch returned the model UNTOUCHED,
                        -- so on the single most likely failure for a consent save
                        -- the optimistic flip was never reverted, no error
                        -- rendered, and `writingAssistantSaving` stayed `Loading`
                        -- forever. A session-expiry hand-off is not a reason to
                        -- leave a consent control lying about what is stored.
                        ( restored, Effect.None, SessionExpired )

                    else
                        -- ⛔ The optimistic flip is REVERTED. The toggle moved
                        -- the moment it was clicked, on the assumption the write
                        -- would succeed; without undoing it a failed save leaves
                        -- the control reading "Off" while the server still holds
                        -- "On". For a consent record that is the worst available
                        -- outcome: the reader believes they have withdrawn
                        -- consent and processing continues.
                        --
                        -- The error beside the toggle says the save failed; the
                        -- toggle itself goes back to what is actually stored.
                        ( restored, Effect.None, NoOut )

        SaveCompleted result ->
            case result of
                Ok _ ->
                    ( { model | saving = Success () }, Effect.None, NoOut )

                Err err ->
                    let
                        -- ⛔ SETTLED BEFORE the error is classified, exactly as
                        -- `SaveWritingAssistantCompleted` above does.
                        --
                        -- ⚠️ This handler was MISSED when that one was fixed,
                        -- in this same module, twelve lines away. The 401 arm
                        -- returned `model` untouched, so an expired session left
                        -- `saving` on `Loading` and the Save button disabled
                        -- forever, while the `else` branch recorded a `Failure`.
                        -- It was found by sweeping the shape across the whole
                        -- frontend, not by re-reading this file — which is the
                        -- argument for sweeping rather than for reading harder.
                        settled =
                            { model | saving = Failure err }
                    in
                    if Api.isUnauthorized err then
                        ( settled, Effect.None, SessionExpired )

                    else
                        ( settled, Effect.None, NoOut )


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
        , viewSection False model
        ]


{-| The consent controls with no page chrome, so the Privacy page can fold them
in as a section (TR-4). Identical markup to the standalone page minus its
`page`/`h1` wrapper.

`locked` holds the toggles inert while the host page is still learning the
stored state. A flip made before that answer landed used to be overwritten by
it — the reader saw their click, then saw it undone — because this model is
re-seeded wholesale from the server. The host decides when the answer is in.

-}
viewSection : Bool -> Model -> Html Msg
viewSection locked model =
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
                    , disabled locked
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
            [ h2 [ class "settings-section__title" ] [ text "Linking books in your writing" ]
            , p [ class "settings-section__desc" ]
                [ text
                    (if model.writingAssistantConsent then
                        "When you publish a post, its text is sent to an AI model to work out which books you mentioned, so they can be linked to the catalogue."

                     else
                        writingAssistantOffDescription
                    )
                ]
            , div [ class "toggle-row" ]
                [ label [ class "toggle-row__label" ] [ text "Link books automatically" ]
                , button
                    [ class
                        (if model.writingAssistantConsent then
                            "toggle toggle--on"

                         else
                            "toggle toggle--off"
                        )
                    , attribute "data-testid" "writing-assistant-consent-toggle"

                    -- ⛔ Disabled while SAVING as well as while locked. This
                    -- control writes on click, so without the second term a
                    -- second click lands while the first write is in flight —
                    -- two requests racing, and a failure handler restoring a
                    -- value that is no longer the one the server is deciding
                    -- about. `locked` covers the host still learning the stored
                    -- state; this covers the window the control itself opens.
                    --
                    -- ⚠️ The analytics toggle above needs no in-flight term
                    -- ONLY while it stays a draft — it writes nothing on click,
                    -- so there is no request to race. If it is ever made
                    -- save-on-click, it needs this same second term, and the
                    -- absence of one there is not evidence that it is unnecessary.
                    , disabled (locked || model.writingAssistantSaving == Loading)
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
            , case model.writingAssistantSaving of
                Failure err ->
                    p
                        [ class "error"
                        , attribute "role" "alert"
                        , attribute "data-testid" "writing-assistant-consent-error"
                        ]
                        [ text (FailureCopy.saveFailure "your book-linking preference" err) ]

                _ ->
                    text ""

            -- ⛔ A SIBLING of `.toggle-row`, not a child of it, and that is a
            -- measured layout fix rather than tidiness. `.toggle-row` is
            -- `display: flex; justify-content: space-between`, so a third child
            -- moved the toggle button from the right edge to the CENTRE on
            -- failure, `.error`'s padding and border stretched the row, and with
            -- no `flex-wrap` it compressed to roughly one word per line at
            -- 400px. This is where the rest of the page already puts a
            -- control's error.
            --
            -- ⚠️ `role="alert"` because a failure here has to be announced, not
            -- merely rendered — the same treatment this project gives
            -- `syndication-url-error` and `invite-refusal`.
            ]
        , div [ class "settings-actions" ]
            [ SaveButton.primary model.saving SaveConsent "Save Preferences" ]
        , -- Distinguished by cause — see
          case model.saving of
            Failure err ->
                p [ class "error" ]
                    [ text (FailureCopy.saveFailure "your consent preferences" err) ]

            _ ->
                text ""
        ]
