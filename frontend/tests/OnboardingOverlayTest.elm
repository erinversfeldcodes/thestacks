module OnboardingOverlayTest exposing (suite)

import Api exposing (OnboardingStatus)
import Components.OnboardingOverlay as Overlay
    exposing
        ( Msg(..)
        , OutMsg(..)
        , Step(..)
        )
import Expect
import Html.Attributes
import Http
import Page.Settings.Consent as Consent
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector


noToken : Maybe String
noToken =
    Nothing


statusAtProfile : OnboardingStatus
statusAtProfile =
    { completed = False, nextStep = Just "profile" }


statusAtPrivacy : OnboardingStatus
statusAtPrivacy =
    { completed = False, nextStep = Just "privacy" }


statusCompleted : OnboardingStatus
statusCompleted =
    { completed = True, nextStep = Nothing }


{-| Test id selector helper.
-}
byTestId : String -> Selector.Selector
byTestId id =
    Selector.attribute (Html.Attributes.attribute "data-testid" id)


{-| Index of a step in the DEFAULT sequence, for readability in assertions.
-}
welcomeIx : Int
welcomeIx =
    0


uploadIx : Int
uploadIx =
    1


consentIx : Int
consentIx =
    2


doneIx : Int
doneIx =
    3


suite : Test
suite =
    describe "OnboardingOverlay (D2 flow, US-14.1.2)"
        [ dataDrivenStepsOracle
        , d2SequenceWalk
        , finishPaths
        , resume
        , consentDelegation
        , modalA11y
        , embeddedSurfaces
        ]


{-| ⭐ THE oracle: the step sequence is DATA the view folds over, not a
hardcoded enum. Each test here mutates ONLY the `steps` list (and index) and
asserts the view follows — with no change to `update`/`view`. At least one
assertion FAILS on the old hardcoded 3-step enum (which always rendered exactly
three dots via a literal `[ dot 0, dot 1, dot 2 ]` and always rendered "Welcome"
at index 0).
-}
dataDrivenStepsOracle : Test
dataDrivenStepsOracle =
    describe "data-driven steps (AC#2)"
        [ test "progress dots derive from List.length steps — EXTENDING the list adds a dot" <|
            \_ ->
                -- Five descriptors → five dots. The old enum hardcoded three
                -- (`[ dot 0, dot 1, dot 2 ]`), so this assertion is red on it.
                let
                    model =
                        { init | steps = Overlay.defaultSteps ++ [ Welcome ] }
                in
                Overlay.view model noToken
                    |> Query.fromHtml
                    |> Query.findAll [ Selector.class "onboarding-overlay__dot" ]
                    |> Query.count (Expect.equal 5)
        , test "dropping a descriptor removes a dot (three-step sequence → three dots)" <|
            \_ ->
                let
                    model =
                        { init | steps = [ Welcome, Consent, Done ] }
                in
                Overlay.view model noToken
                    |> Query.fromHtml
                    |> Query.findAll [ Selector.class "onboarding-overlay__dot" ]
                    |> Query.count (Expect.equal 3)
        , test "REORDERING the list changes which step renders at an index (Consent first)" <|
            \_ ->
                -- Consent is placed at index 0. The view must render the consent
                -- controls there. The old enum rendered "Welcome to The Stacks"
                -- at index 0 unconditionally, so this is red on it.
                let
                    model =
                        { init
                            | steps = [ Consent, Welcome, UploadFirstBook, Done ]
                            , currentIndex = 0
                        }
                in
                Overlay.view model noToken
                    |> Query.fromHtml
                    |> Query.has [ byTestId "onboarding-consent-embed" ]
        , test "exactly one dot is active, and it tracks currentIndex over a reordered list" <|
            \_ ->
                let
                    model =
                        { init
                            | steps = [ Done, Consent, Welcome ]
                            , currentIndex = 2
                        }

                    rendered =
                        Overlay.view model noToken |> Query.fromHtml
                in
                Expect.all
                    [ \q ->
                        q
                            |> Query.findAll [ Selector.class "onboarding-overlay__dot--active" ]
                            |> Query.count (Expect.equal 1)

                    -- currentIndex 2 over a 3-item list renders the Welcome step.
                    , \q -> Query.has [ Selector.text "Welcome to The Stacks" ] q
                    ]
                    rendered
        , test "currentStep is List lookup, not a branch — reorder puts UploadFirstBook at index 0" <|
            \_ ->
                let
                    model =
                        { init | steps = [ UploadFirstBook, Welcome ], currentIndex = 0 }
                in
                Expect.equal (Just UploadFirstBook) (Overlay.currentStep model)
        ]


{-| The D2 sequence is walked in order by a pure index bump.
-}
d2SequenceWalk : Test
d2SequenceWalk =
    describe "walks Welcome → Upload → Consent → Done"
        [ test "the default sequence is exactly the D2 four" <|
            \_ ->
                Expect.equal [ Welcome, UploadFirstBook, Consent, Done ] Overlay.defaultSteps
        , test "NextStep advances the index by one (Welcome → Upload)" <|
            \_ ->
                let
                    ( model, _, out ) =
                        Overlay.update noToken NextStep init
                in
                Expect.all
                    [ \m -> Expect.equal (Just UploadFirstBook) (Overlay.currentStep m)
                    , \m -> Expect.equal True m.visible
                    , \_ -> Expect.equal NoOut out
                    ]
                    model
        , test "NextStep clamps: from Done (last) it finishes rather than overrunning" <|
            \_ ->
                let
                    ( model, _, out ) =
                        Overlay.update noToken NextStep { init | currentIndex = doneIx }
                in
                Expect.all
                    [ \m -> Expect.equal False m.visible
                    , \_ -> Expect.equal OnboardingFinished out
                    ]
                    model
        , test "ConfirmConsent (the Consent step's Continue) advances the index" <|
            \_ ->
                let
                    ( model, _, _ ) =
                        Overlay.update noToken ConfirmConsent { init | currentIndex = consentIx }
                in
                Expect.equal (Just Done) (Overlay.currentStep model)
        ]


{-| Skip, Escape, and advance-off-the-end share ONE finish path.
-}
finishPaths : Test
finishPaths =
    describe "finish path (skip == escape == advance-off-end)"
        [ test "SkipOnboarding hides the overlay and emits OnboardingFinished" <|
            \_ ->
                let
                    ( model, _, out ) =
                        Overlay.update noToken SkipOnboarding init
                in
                Expect.all
                    [ \m -> Expect.equal False m.visible
                    , \_ -> Expect.equal OnboardingFinished out
                    ]
                    model
        , test "EscapePressed uses the identical finish path as Skip" <|
            \_ ->
                let
                    ( model, _, out ) =
                        Overlay.update noToken EscapePressed init
                in
                Expect.all
                    [ \m -> Expect.equal False m.visible
                    , \_ -> Expect.equal OnboardingFinished out
                    ]
                    model
        , test "skipping from the Upload step still finishes (leaves the shelf empty)" <|
            \_ ->
                let
                    ( model, _, out ) =
                        Overlay.update noToken SkipOnboarding { init | currentIndex = uploadIx }
                in
                Expect.all
                    [ \m -> Expect.equal False m.visible
                    , \_ -> Expect.equal OnboardingFinished out
                    ]
                    model
        ]


{-| The overlay resumes from the server's next\_step.
-}
resume : Test
resume =
    describe "StatusLoaded resume"
        [ test "next_step profile resumes at the Welcome index" <|
            \_ ->
                let
                    ( model, _, _ ) =
                        Overlay.update noToken (StatusLoaded (Ok statusAtProfile)) init
                in
                Expect.equal welcomeIx model.currentIndex
        , test "next_step privacy resumes at the Consent index" <|
            \_ ->
                let
                    ( model, _, _ ) =
                        Overlay.update noToken (StatusLoaded (Ok statusAtPrivacy)) init
                in
                Expect.all
                    [ \m -> Expect.equal consentIx m.currentIndex
                    , \m -> Expect.equal (Just Consent) (Overlay.currentStep m)
                    ]
                    model
        , test "a completed status hides the overlay" <|
            \_ ->
                let
                    ( model, _, _ ) =
                        Overlay.update noToken (StatusLoaded (Ok statusCompleted)) init
                in
                Expect.equal False model.visible
        , test "an API error falls back to the first step, still visible" <|
            \_ ->
                let
                    ( model, _, _ ) =
                        Overlay.update noToken (StatusLoaded (Err Http.NetworkError)) init
                in
                Expect.all
                    [ \m -> Expect.equal 0 m.currentIndex
                    , \m -> Expect.equal True m.visible
                    ]
                    model
        ]


{-| The Consent step delegates to `Page.Settings.Consent.update` VERBATIM — the
consent write path is reused unchanged, so a toggle in the overlay is the same
state change the Settings page makes.
-}
consentDelegation : Test
consentDelegation =
    describe "consent step delegates to the unchanged consent update"
        [ test "ConsentMsg ToggleAnalytics flips the embedded consent sub-model" <|
            \_ ->
                let
                    ( model, _, out ) =
                        Overlay.update noToken
                            (ConsentMsg Consent.ToggleAnalytics)
                            { init | currentIndex = consentIx }
                in
                Expect.all
                    [ \m -> Expect.equal True m.consent.analyticsConsent
                    , \_ -> Expect.equal NoOut out
                    ]
                    model
        , test "the consent sub-model starts with both grants OFF (US-14.1.2 §1)" <|
            \_ ->
                Expect.all
                    [ \m -> Expect.equal False m.consent.analyticsConsent
                    , \m -> Expect.equal False m.consent.writingAssistantConsent
                    ]
                    init
        ]


{-| aria-modal is honoured as far as a program test can assert: the dialog
attributes are present, Escape closes it (see finishPaths), and a focus guard
sits after the card. (Actual focus movement is a browser-drive item.)
-}
modalA11y : Test
modalA11y =
    describe "modal a11y attributes"
        [ test "the overlay is role=dialog with aria-modal=true" <|
            \_ ->
                Overlay.view init noToken
                    |> Query.fromHtml
                    |> Query.has
                        [ Selector.attribute (Html.Attributes.attribute "role" "dialog")
                        , Selector.attribute (Html.Attributes.attribute "aria-modal" "true")
                        ]
        , test "aria-label reflects the current step" <|
            \_ ->
                Overlay.view { init | currentIndex = consentIx } noToken
                    |> Query.fromHtml
                    |> Query.has
                        [ Selector.attribute
                            (Html.Attributes.attribute "aria-label" "Your privacy choices")
                        ]
        , test "a tabbable focus guard is rendered (Tab off the card cannot escape silently)" <|
            \_ ->
                Overlay.view init noToken
                    |> Query.fromHtml
                    |> Query.has [ Selector.class "onboarding-overlay__focus-guard" ]
        , test "a hidden overlay renders nothing" <|
            \_ ->
                Overlay.view { init | visible = False } noToken
                    |> Query.fromHtml
                    |> Query.hasNot [ byTestId "onboarding-overlay" ]
        ]


{-| The Upload step embeds the REAL US-1.1.1 surface (not a prompt); the Consent
step embeds the real consent controls.
-}
embeddedSurfaces : Test
embeddedSurfaces =
    describe "embedded real surfaces"
        [ test "the Upload step renders the real US-1.1.1 upload surface, not a prompt" <|
            \_ ->
                Overlay.view { init | currentIndex = uploadIx } (Just "tok")
                    |> Query.fromHtml
                    |> Query.has
                        [ byTestId "onboarding-upload-embed"

                        -- The genuine upload drop zone from Page.Upload, proving
                        -- the surface is embedded rather than re-described.
                        , byTestId "upload-drop-zone"
                        ]
        , test "the Consent step renders the real consent toggles" <|
            \_ ->
                Overlay.view { init | currentIndex = consentIx } noToken
                    |> Query.fromHtml
                    |> Query.has
                        [ byTestId "onboarding-consent-embed"
                        , byTestId "analytics-consent-toggle"
                        , byTestId "writing-assistant-consent-toggle"
                        ]
        ]


init : Overlay.Model
init =
    Overlay.init
