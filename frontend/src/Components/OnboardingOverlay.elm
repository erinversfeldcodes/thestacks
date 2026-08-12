module Components.OnboardingOverlay exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , Step(..)
    , currentStep
    , defaultSteps
    , init
    , initCmd
    , isOnUploadStep
    , isVisible
    , leadingGuardId
    , trailingGuardId
    , update
    , view
    )

{-| OnboardingOverlay — the first-run flow: Welcome → Upload →
Consent → Done.

⚠️ The step sequence is DATA, not branches: an ordered
`steps: List Step` + `currentIndex`; advancing is `+ 1`. Reordering or
inserting a step is a list edit, not a transition-chain rewrite.
Completion persists server-side, so a reload does not re-run the flow.

-}

import Api exposing (OnboardingStatus)
import Browser.Dom
import Html exposing (Html, button, div, h2, p, span, text)
import Html.Attributes exposing (attribute, class, id, tabindex)
import Html.Events exposing (onClick, preventDefaultOn)
import Http
import Json.Decode as Decode
import Navigation.Route as Route
import Page.Settings.Consent as Consent
import Page.Upload as Upload
import Task
import Types.RemoteData exposing (RemoteData(..))
import Util.TestId exposing (testId)


{-| The step descriptors. The TYPE is a closed set of what a step can be; the
SEQUENCE (which follow which, and how many) is the `steps` list, not this type.
-}
type Step
    = Welcome
    | UploadFirstBook
    | Consent
    | Done


{-| The D2 sequence. ⭐ The whole flow lives here — reorder, add, or drop a
descriptor and the walked order, the progress dots, and `aria-label` all follow
with no other edit.
-}
defaultSteps : List Step
defaultSteps =
    [ Welcome, UploadFirstBook, Consent, Done ]


type alias Model =
    { steps : List Step
    , currentIndex : Int
    , visible : Bool
    , upload : Upload.Model
    , consent : Consent.Model
    }


{-| Effects that must leave the overlay and be handled by `Main`.

`OnboardingFinished` is the ONE finish signal shared by Skip, Escape, and
advancing off the last step. The `Upload*`/`SessionExpired` constructors relay
the embedded upload flow's own `OutMsg`s up to the shell, which owns the SSE
port, the inbox, and navigation — the same wiring the standalone upload page
uses.

-}
type OutMsg
    = NoOut
    | OnboardingFinished
    | UploadOpenStream String
    | UploadRefreshInbox
    | UploadNavigate Route.Route
    | SessionExpired


type Msg
    = StatusLoaded (Result Http.Error OnboardingStatus)
    | StepCompleted
    | NextStep
    | SkipOnboarding
    | EscapePressed
    | ConfirmConsent
    | UploadMsg Upload.Msg
    | ConsentMsg Consent.Msg
    | FocusWrapToFirst
    | FocusWrapToLast
    | FocusResult


containerId : String
containerId =
    "onboarding-overlay-container"


{-| The leading (backward) focus sentinel's DOM id — the first tab stop inside
the dialog. Shift+Tab off it wraps to the trailing sentinel, so focus can never
escape the dialog backwards (`aria-modal` containment).
-}
leadingGuardId : String
leadingGuardId =
    "onboarding-overlay-focus-guard-leading"


{-| The trailing (forward) focus sentinel's DOM id — the last tab stop inside
the dialog. Forward Tab off it wraps back to the leading sentinel.
-}
trailingGuardId : String
trailingGuardId =
    "onboarding-overlay-focus-guard-trailing"


{-| The initial model: the full D2 sequence, index 0, visible, with fresh
embedded upload and consent sub-models (consent defaults OFF, per §1).
-}
init : Model
init =
    { steps = defaultSteps
    , currentIndex = 0
    , visible = True
    , upload =
        (\u -> { u | embedded = True }) Upload.init
    , consent = Consent.init { analytics = False, writingAssistant = False }
    }


{-| Fire `GET /api/onboarding/status` so a partially-onboarded reader resumes at
the right step rather than always from Welcome. Call from the parent's init when
a token is available.
-}
initCmd : String -> Cmd Msg
initCmd token =
    Api.getOnboardingStatus token StatusLoaded


{-| Whether the overlay wants to render. `Main` combines this with its own
`shouldShowOnboarding` gate (auth + no placements + not completed).
-}
isVisible : Model -> Bool
isVisible model =
    model.visible


{-| Whether the current descriptor is the embedded upload step. `Main` uses this
to route the SSE stream and the wait-clock subscription to the overlay's upload
sub-model while onboarding is active.
-}
isOnUploadStep : Model -> Bool
isOnUploadStep model =
    currentStep model == Just UploadFirstBook


{-| The descriptor the flow is currently on — `getAt` over `steps`, never a
hardcoded lookup. `Nothing` only for an out-of-range index.
-}
currentStep : Model -> Maybe Step
currentStep model =
    getAt model.currentIndex model.steps


{-| The element at `idx`, or `Nothing` if out of range. (Local rather than
`List.Extra` — that package is a test-only dependency here.)
-}
getAt : Int -> List a -> Maybe a
getAt idx list =
    if idx < 0 then
        Nothing

    else
        List.head (List.drop idx list)


{-| The index of the first element equal to `target`, if any.
-}
elemIndex : a -> List a -> Maybe Int
elemIndex target list =
    List.indexedMap Tuple.pair list
        |> List.filter (\( _, x ) -> x == target)
        |> List.head
        |> Maybe.map Tuple.first


isLastIndex : Model -> Bool
isLastIndex model =
    model.currentIndex >= List.length model.steps - 1


update : Maybe String -> Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update token msg model =
    case msg of
        StatusLoaded (Ok status) ->
            if status.completed then
                ( { model | visible = False }, Cmd.none, NoOut )

            else
                ( { model | currentIndex = indexForNextStep model status.nextStep }
                , focusContainerCmd
                , NoOut
                )

        StatusLoaded (Err _) ->
            ( { model | currentIndex = 0 }, focusContainerCmd, NoOut )

        StepCompleted ->
            ( model, Cmd.none, NoOut )

        NextStep ->
            advance token model

        ConfirmConsent ->
            let
                ( newConsent, consentCmd, _ ) =
                    Consent.update Consent.SaveConsent model.consent token

                ( advanced, advanceCmd, out ) =
                    advance token { model | consent = newConsent }
            in
            ( advanced
            , Cmd.batch [ Cmd.map ConsentMsg consentCmd, advanceCmd ]
            , out
            )

        SkipOnboarding ->
            finishNow token model

        EscapePressed ->
            finishNow token model

        UploadMsg subMsg ->
            let
                ( newUpload, subCmd, upOut ) =
                    Upload.update subMsg model.upload token

                mappedCmd =
                    Cmd.map UploadMsg subCmd

                mappedOut =
                    mapUploadOut upOut

                base =
                    { model | upload = newUpload }

                justPlaced =
                    isUploadComplete newUpload.step && not (isUploadComplete model.upload.step)
            in
            if justPlaced then
                let
                    ( advanced, advanceCmd, _ ) =
                        advance token base
                in
                ( advanced, Cmd.batch [ mappedCmd, advanceCmd ], mappedOut )

            else
                ( base, mappedCmd, mappedOut )

        ConsentMsg subMsg ->
            let
                ( newConsent, subCmd, consentOut ) =
                    Consent.update subMsg model.consent token

                out =
                    case consentOut of
                        Consent.SessionExpired ->
                            SessionExpired

                        Consent.NoOut ->
                            NoOut
            in
            ( { model | consent = newConsent }, Cmd.map ConsentMsg subCmd, out )

        FocusWrapToFirst ->
            ( model, focusElementCmd leadingGuardId, NoOut )

        FocusWrapToLast ->
            ( model, focusElementCmd trailingGuardId, NoOut )

        FocusResult ->
            ( model, Cmd.none, NoOut )


{-| Advance by one index. If already on the last descriptor, finish instead —
the identical finish path Skip/Escape use. Records the step being LEFT if it has
a server counterpart.
-}
advance : Maybe String -> Model -> ( Model, Cmd Msg, OutMsg )
advance token model =
    let
        recordCmd =
            recordCurrentStep token model
    in
    if isLastIndex model then
        ( { model | visible = False }, recordCmd, OnboardingFinished )

    else
        ( { model | currentIndex = model.currentIndex + 1 }
        , Cmd.batch [ recordCmd, focusContainerCmd ]
        , NoOut
        )


finishNow : Maybe String -> Model -> ( Model, Cmd Msg, OutMsg )
finishNow token model =
    ( { model | visible = False }, recordCurrentStep token model, OnboardingFinished )


focusContainerCmd : Cmd Msg
focusContainerCmd =
    focusElementCmd containerId


{-| Move DOM focus to the given element id, discarding the (ignorable) result —
a no-op if the element is not in the DOM (e.g. the shell has not rendered the
overlay yet).
-}
focusElementCmd : String -> Cmd Msg
focusElementCmd elementId =
    Task.attempt (\_ -> FocusResult) (Browser.Dom.focus elementId)


recordCurrentStep : Maybe String -> Model -> Cmd Msg
recordCurrentStep maybeToken model =
    case ( maybeToken, Maybe.andThen backendStepName (currentStep model) ) of
        ( Just token, Just name ) ->
            Api.completeOnboardingStep name token (\_ -> StepCompleted)

        _ ->
            Cmd.none


{-| The server step a client descriptor records on completion, or
`Nothing` for a client-only step (Upload is tracked by the placement existing;
Done is the terminus).
-}
backendStepName : Step -> Maybe String
backendStepName step =
    case step of
        Welcome ->
            Just "profile"

        UploadFirstBook ->
            Nothing

        Consent ->
            Just "privacy"

        Done ->
            Nothing


{-| Resume index from the server's `next_step`. Maps the server step onto the
client descriptor and finds its position in `steps` — so a reordered `steps`
resumes correctly too.
-}
indexForNextStep : Model -> Maybe String -> Int
indexForNextStep model maybeNext =
    let
        target =
            case maybeNext of
                Just "profile" ->
                    Welcome

                Just "privacy" ->
                    Consent

                _ ->
                    Welcome
    in
    elemIndex target model.steps
        |> Maybe.withDefault 0


isUploadComplete : Upload.UploadStep -> Bool
isUploadComplete step =
    case step of
        Upload.Complete _ _ ->
            True

        _ ->
            False


mapUploadOut : Upload.OutMsg -> OutMsg
mapUploadOut upOut =
    case upOut of
        Upload.NoOut ->
            NoOut

        Upload.OpenStream url ->
            UploadOpenStream url

        Upload.RefreshInbox ->
            UploadRefreshInbox

        Upload.NavigateTo route ->
            UploadNavigate route

        Upload.SessionExpired ->
            SessionExpired


view : Model -> Maybe String -> Html Msg
view model maybeToken =
    if not model.visible then
        text ""

    else
        div
            [ class "onboarding-overlay"
            , testId "onboarding-overlay"
            , attribute "role" "dialog"
            , attribute "aria-modal" "true"
            , attribute "aria-label" (ariaLabelFor (currentStep model))
            , id containerId
            , tabindex -1
            , preventDefaultOn "keydown" trapKeydownDecoder
            ]
            [ div [ class "onboarding-overlay__backdrop" ] []
            , focusGuard leadingGuardId
            , div [ class "onboarding-overlay__card" ]
                [ viewStep model maybeToken
                , viewProgressDots model
                ]
            , focusGuard trailingGuardId
            ]


{-| An off-screen, tabbable focus sentinel. It is a real tab stop the reader
lands on momentarily at a dialog boundary; the keydown trap wraps focus to the
opposite sentinel on the next Tab/Shift+Tab.
-}
focusGuard : String -> Html Msg
focusGuard guardId =
    div
        [ class "onboarding-overlay__focus-guard"
        , id guardId
        , tabindex 0
        , attribute "aria-hidden" "true"
        ]
        []


{-| Keydown decoder implementing the Tab focus trap. It reads `key`, `shiftKey`,
and the focused element's `target.id`, and only `preventDefault`s (emitting a
wrap message) at the two dialog boundaries — forward Tab on the trailing
sentinel wraps to the leading one; Shift+Tab on the leading sentinel wraps to
the trailing one. Every other keydown fails the decoder, so native tab order is
preserved for the controls in between.
-}
trapKeydownDecoder : Decode.Decoder ( Msg, Bool )
trapKeydownDecoder =
    Decode.map3 trapDecision
        (Decode.field "key" Decode.string)
        (Decode.field "shiftKey" Decode.bool)
        (Decode.at [ "target", "id" ] Decode.string)
        |> Decode.andThen identity


trapDecision : String -> Bool -> String -> Decode.Decoder ( Msg, Bool )
trapDecision key shiftKey targetId =
    if key /= "Tab" then
        Decode.fail "focus-trap: not a Tab keydown"

    else if not shiftKey && targetId == trailingGuardId then
        Decode.succeed ( FocusWrapToFirst, True )

    else if shiftKey && targetId == leadingGuardId then
        Decode.succeed ( FocusWrapToLast, True )

    else
        Decode.fail "focus-trap: natural tab order"


ariaLabelFor : Maybe Step -> String
ariaLabelFor maybeStep =
    case maybeStep of
        Just Welcome ->
            "Welcome to The Stacks"

        Just UploadFirstBook ->
            "Add your first book"

        Just Consent ->
            "Your privacy choices"

        Just Done ->
            "Welcome to your library"

        Nothing ->
            "Onboarding"


{-| The card body: `viewStep (currentStep model)` folded from the descriptor
list. NO per-step transition logic — this is a pure render of whichever
descriptor the index points at.
-}
viewStep : Model -> Maybe String -> Html Msg
viewStep model maybeToken =
    case currentStep model of
        Just Welcome ->
            viewWelcome

        Just UploadFirstBook ->
            viewUpload model maybeToken

        Just Consent ->
            viewConsent model

        Just Done ->
            viewDone

        Nothing ->
            text ""


viewWelcome : Html Msg
viewWelcome =
    div [ class "onboarding-overlay__step" ]
        [ h2 [ class "onboarding-overlay__title" ] [ text "Welcome to The Stacks" ]
        , p [ class "onboarding-overlay__tagline" ]
            [ text "Your personal collection, beautifully organised." ]
        , div [ class "onboarding-overlay__actions" ]
            [ primaryButton "Get started" NextStep
            , skipButton
            ]
        ]


viewUpload : Model -> Maybe String -> Html Msg
viewUpload model maybeToken =
    div [ class "onboarding-overlay__step" ]
        [ h2 [ class "onboarding-overlay__title" ] [ text "Add your first book" ]
        , p [ class "onboarding-overlay__tagline" ]
            [ text "Photograph a cover or barcode, or type an ISBN — we'll identify it and put it on a shelf." ]
        , div [ class "onboarding-overlay__embed", testId "onboarding-upload-embed" ]
            [ Html.map UploadMsg (Upload.view model.upload maybeToken NotAsked) ]
        , div [ class "onboarding-overlay__actions" ]
            [ skipButton ]
        ]


viewConsent : Model -> Html Msg
viewConsent model =
    div [ class "onboarding-overlay__step" ]
        [ h2 [ class "onboarding-overlay__title" ] [ text "Your privacy choices" ]
        , p [ class "onboarding-overlay__tagline" ]
            [ text "Both default to off. You can change either any time in Settings › Privacy." ]
        , div [ class "onboarding-overlay__embed", testId "onboarding-consent-embed" ]
            [ Html.map ConsentMsg (Consent.viewSection model.consent) ]
        , div [ class "onboarding-overlay__actions" ]
            [ primaryButton "Continue" ConfirmConsent
            , skipButton
            ]
        ]


viewDone : Html Msg
viewDone =
    div [ class "onboarding-overlay__step" ]
        [ h2 [ class "onboarding-overlay__title" ] [ text "Welcome to your library" ]
        , p [ class "onboarding-overlay__tagline" ]
            [ text "Your shelves are ready." ]
        , div [ class "onboarding-overlay__actions" ]
            [ primaryButton "Start exploring" NextStep ]
        ]


primaryButton : String -> Msg -> Html Msg
primaryButton label msg =
    button
        [ class "btn btn--primary"
        , onClick msg
        , testId "onboarding-continue-btn"
        ]
        [ text label ]


skipButton : Html Msg
skipButton =
    button
        [ class "btn btn--ghost"
        , onClick SkipOnboarding
        , testId "onboarding-skip-btn"
        ]
        [ text "Skip" ]


{-| Progress dots derived from the sequence: ONE dot per descriptor, the dot at
`currentIndex` marked active. Add a descriptor to `steps` → a dot appears here
with no edit. (No `transition` on the dot — the /indicator rule.)
-}
viewProgressDots : Model -> Html Msg
viewProgressDots model =
    div [ class "onboarding-overlay__dots" ]
        (List.indexedMap
            (\idx _ ->
                span
                    [ class
                        (if idx == model.currentIndex then
                            "onboarding-overlay__dot onboarding-overlay__dot--active"

                         else
                            "onboarding-overlay__dot"
                        )
                    ]
                    []
            )
            model.steps
        )
