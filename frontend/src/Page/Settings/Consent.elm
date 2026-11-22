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
import Effect exposing (Effect)
import Html exposing (Html, button, div, h1, h2, label, p, text)
import Html.Attributes exposing (attribute, class, disabled)
import Html.Events exposing (onClick)
import Http
import Types.RemoteData exposing (RemoteData(..))
import Util.FailureCopy as FailureCopy


{-| All three controls on this page are GDPR consent records, and all three
WRITE ON CLICK: flipping a toggle persists the decision immediately, and each
carries its OWN save state so its outcome is reported beside the control that
caused it (a shared field would make one control's status speak for another's).
There is no "Save Preferences" button — a draft consent is a hazard, because a
reader who flips a toggle and navigates away believes the decision is recorded
when it is not.
-}
type alias Model =
    { analyticsConsent : Bool
    , analyticsSaving : RemoteData Http.Error ()
    , writingAssistantConsent : Bool
    , writingAssistantSaving : RemoteData Http.Error ()
    , searchIndexingConsent : Bool
    , searchIndexingSaving : RemoteData Http.Error ()
    }


type Msg
    = ToggleAnalytics
      -- ⚠️ Carries the value that was ATTEMPTED, so a failure can restore the
      -- opposite exactly rather than toggling the current value back — which
      -- assumes exactly one flip is in flight.
    | SaveAnalyticsCompleted Bool (Result Http.Error ())
    | SessionExpiryDetected
    | ToggleWritingAssistant
    | SaveWritingAssistantCompleted Bool (Result Http.Error ())
    | ToggleSearchIndexing
    | SaveSearchIndexingCompleted Bool (Result Http.Error ())


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


{-| The verbatim copy shown under the search-indexing toggle. A named constant so
the wording lives in one place; the settings e2e spec asserts a reader sees it.
-}
searchIndexingDescription : String
searchIndexingDescription =
    "Off by default: your public profile and shelves are not offered to search engines. Turn this on to let search engines index content you have ALREADY made public — it does not change who can see it, only whether it can be found through a search engine."


{-| Seed the consent page from the current user's actual consent state so the
toggles reflect reality on open. Previously both toggles were
hard-coded OFF, so a user who had already granted consent saw them as OFF and
their first click re-granted instead of revoking.

⚠️ The host (`Page.Settings.Privacy`) now opens the controls LOCKED and does not
seed them from any login payload: the stored consent is read from
`GET /api/settings/privacy`, the single source of truth, and until that answers
the view renders each toggle as "not yet known" (see `toggleLabel`) rather than a
definite Off. So in the host's hands these initial values are never SHOWN as a
recorded decision; the record is whatever the fetch brings back.

-}
init : { analytics : Bool, writingAssistant : Bool, searchIndexing : Bool } -> Model
init consent =
    { analyticsConsent = consent.analytics
    , analyticsSaving = NotAsked
    , writingAssistantConsent = consent.writingAssistant
    , writingAssistantSaving = NotAsked
    , searchIndexingConsent = consent.searchIndexing
    , searchIndexingSaving = NotAsked
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
            let
                newValue =
                    not model.analyticsConsent
            in
            case maybeToken of
                Just token ->
                    ( { model
                        | analyticsConsent = newValue
                        , analyticsSaving = Loading
                      }
                    , Effect.authed (Api.saveConsentRequest newValue)
                        token
                        { onExpired = SessionExpiryDetected
                        , onResponse =
                            Api.resolveWhatever >> SaveAnalyticsCompleted newValue
                        }
                    , NoOut
                    )

                Nothing ->
                    ( { model | analyticsConsent = newValue }, Effect.None, NoOut )

        SaveAnalyticsCompleted attempted result ->
            case result of
                Ok _ ->
                    ( { model | analyticsSaving = Success () }, Effect.None, NoOut )

                Err err ->
                    let
                        -- ⛔ Restored from the ATTEMPTED value and settled BEFORE
                        -- the 401 is classified — the same contract the
                        -- writing-assistant handler documents below. The
                        -- optimistic flip is REVERTED on failure: without it a
                        -- failed save leaves the control reading the value the
                        -- reader chose while the server still holds the old one,
                        -- and for a consent record that is the worst available
                        -- outcome — the reader believes their decision took and
                        -- it did not.
                        restored =
                            { model
                                | analyticsConsent = not attempted
                                , analyticsSaving = Failure err
                            }
                    in
                    if Api.isUnauthorized err then
                        ( restored, Effect.None, SessionExpired )

                    else
                        ( restored, Effect.None, NoOut )

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

        ToggleSearchIndexing ->
            let
                newValue =
                    not model.searchIndexingConsent
            in
            case maybeToken of
                Just token ->
                    ( { model
                        | searchIndexingConsent = newValue
                        , searchIndexingSaving = Loading
                      }
                    , Effect.authed (Api.saveSearchIndexingConsentRequest newValue)
                        token
                        { onExpired = SessionExpiryDetected
                        , onResponse =
                            Api.resolveWhatever >> SaveSearchIndexingCompleted newValue
                        }
                    , NoOut
                    )

                Nothing ->
                    ( { model | searchIndexingConsent = newValue }, Effect.None, NoOut )

        SaveSearchIndexingCompleted attempted result ->
            case result of
                Ok _ ->
                    ( { model | searchIndexingSaving = Success () }, Effect.None, NoOut )

                Err err ->
                    let
                        -- Restored from the ATTEMPTED value, and settled BEFORE
                        -- the 401 is classified — the same contract the
                        -- writing-assistant handler documents above, so a failed
                        -- opt-in save never leaves the toggle lying about what
                        -- the server stores.
                        restored =
                            { model
                                | searchIndexingConsent = not attempted
                                , searchIndexingSaving = Failure err
                            }
                    in
                    if Api.isUnauthorized err then
                        ( restored, Effect.None, SessionExpired )

                    else
                        ( restored, Effect.None, NoOut )


{-| The standalone-page wrapper. Since TR-4 the consent controls live as a
section INSIDE the Privacy page (`Page.Settings.Privacy` embeds this module and
renders `viewSection`); this whole-page view is retained for direct unit tests
of the consent surface. The update path — and therefore what
`Stacks.GDPR.Consent` records via `Api.saveConsentRequest` /
`Api.saveWritingAssistantConsentRequest` — is unchanged either way.
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
re-seeded wholesale from the server. The host decides when the answer is in, and
while it is still learning, each control renders as "not yet known" (`toggleLabel`
/ `toggleClass`) rather than a definite On/Off, so a value nobody has read is
never shown as a recorded consent.

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
                    [ class (toggleClass locked model.analyticsConsent)
                    , attribute "data-testid" "analytics-consent-toggle"

                    -- ⛔ Writes on click, so it is disabled while its own save is
                    -- in flight as well as while the host is still learning the
                    -- stored state. Without the in-flight term a second click
                    -- lands while the first write is in flight — two requests
                    -- racing, and a failure handler restoring a value that is no
                    -- longer the one the server is deciding about.
                    , disabled (locked || model.analyticsSaving == Loading)
                    , onClick ToggleAnalytics
                    ]
                    [ text (toggleLabel locked model.analyticsConsent) ]
                ]
            , viewSaveError "analytics-consent-error" "your analytics preference" model.analyticsSaving
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
                    [ class (toggleClass locked model.writingAssistantConsent)
                    , attribute "data-testid" "writing-assistant-consent-toggle"
                    , disabled (locked || model.writingAssistantSaving == Loading)
                    , onClick ToggleWritingAssistant
                    ]
                    [ text (toggleLabel locked model.writingAssistantConsent) ]
                ]
            , viewSaveError "writing-assistant-consent-error" "your book-linking preference" model.writingAssistantSaving
            ]
        , div [ class "settings-section" ]
            [ h2 [ class "settings-section__title" ] [ text "Search-engine indexing" ]
            , p [ class "settings-section__desc" ]
                [ text searchIndexingDescription ]
            , div [ class "toggle-row" ]
                [ label [ class "toggle-row__label" ]
                    [ text "Let search engines index my public content" ]
                , button
                    [ class (toggleClass locked model.searchIndexingConsent)
                    , attribute "data-testid" "search-indexing-consent-toggle"
                    , disabled (locked || model.searchIndexingSaving == Loading)
                    , onClick ToggleSearchIndexing
                    ]
                    [ text (toggleLabel locked model.searchIndexingConsent) ]
                ]
            , viewSaveError "search-indexing-consent-error" "your search-indexing preference" model.searchIndexingSaving
            ]
        ]


{-| A toggle's CSS class. While the host is still learning the stored state
(`locked`), the control shows an UNKNOWN visual rather than a definite on/off: a
definite state shown before the fetch has answered is a manufactured value, and
on a consent record — where the displayed state IS the record, now that there is
no confirming Save press — that is exactly what must not happen.
-}
toggleClass : Bool -> Bool -> String
toggleClass locked on =
    if locked then
        "toggle toggle--unknown"

    else if on then
        "toggle toggle--on"

    else
        "toggle toggle--off"


{-| A toggle's label: "—" (not yet known) until the stored state has loaded,
then the real On/Off. Pairs with `toggleClass`.
-}
toggleLabel : Bool -> Bool -> String
toggleLabel locked on =
    if locked then
        "—"

    else if on then
        "On"

    else
        "Off"


{-| The inline save-status for one control: its failure, announced
(`role="alert"`, as this project gives its other refusal messages) and rendered
as a SIBLING of `.toggle-row`, not a child of it — that is a measured layout fix.
`.toggle-row` is `display: flex; justify-content: space-between`, so a third
child moves the toggle button from the right edge to the centre on failure, and
`.error`'s padding stretches the row. Success and in-flight render nothing: the
toggle itself, and its disabled state, already say what is happening.
-}
viewSaveError : String -> String -> RemoteData Http.Error () -> Html Msg
viewSaveError testid subject saving =
    case saving of
        Failure err ->
            p
                [ class "error"
                , attribute "role" "alert"
                , attribute "data-testid" testid
                ]
                [ text (FailureCopy.saveFailure subject err) ]

        _ ->
            text ""
