module Page.Login exposing
    ( Arrival(..)
    , FieldValidation(..)
    , Mode(..)
    , Model
    , Msg(..)
    , OutMsg(..)
    , SubmitError(..)
    , draftWasSaved
    , errorMessage
    , init
    , isSessionExpiry
    , isSubmitDisabled
    , update
    , validateDisplayName
    , validateEmail
    , validatePassword
    , validatePasswordConfirm
    , view
    )

import Api exposing (AuthResponse, RegisterError(..))
import Html exposing (Html, button, div, h1, input, label, p, span, text)
import Html.Attributes exposing (attribute, class, disabled, for, id, placeholder, type_, value)
import Html.Events exposing (onClick, onInput)
import Http
import Types.PasswordRule as PasswordRule
import Types.RemoteData exposing (RemoteData(..))
import Util.TestId exposing (testId)


type FieldValidation
    = Pristine
    | Valid
    | Invalid String


type alias Model =
    { email : String
    , password : String
    , passwordConfirm : String
    , displayName : String
    , mode : Mode

    -- The whole lifecycle of a submission: `Loading` while the request is in
    -- flight, `Success authResponse` once the shell has been handed the
    -- credential, `Failure` otherwise. Deliberately the ONLY record of that
    -- lifecycle — see `isSubmitDisabled` for why a second flag was removed.
    , submitState : RemoteData SubmitError AuthResponse
    , emailValidation : FieldValidation
    , passwordValidation : FieldValidation
    , passwordConfirmValidation : FieldValidation
    , displayNameValidation : FieldValidation

    -- Why this reader is standing at the door. See `Arrival` — this ONE field
    -- replaced three independently-settable booleans.
    , arrival : Arrival

    -- Outcome of a forgot-password request (ForgotPasswordMode). The email
    -- reuses the shared `email` field.
    , forgotState : RemoteData Http.Error ()
    }


{-| Why the login card is on screen (Issue #360).

⛔ The point of this type is what it makes impossible. This used to be three
booleans on `Login.Model` (`sessionExpired`, `draftSaved`, `accountDeleted`),
shadowed by three more on `Main.Model` (`sessionExpiredNotice`,
`draftSavedNotice`, `accountDeletedNotice`), raised by five separate inits and
read by two view predicates. The reasons are mutually exclusive in life —
a reader's session either expired, or they closed their account, or they asked
to reset a password, or they simply came to sign in — but nothing in that shape
said so. `{ sessionExpired = True, accountDeleted = True }` type-checked and
rendered both notices, one under the other; so did a `draftSaved = True` with no
expiry, which claimed a listing had been saved when none had. The six booleans
could also disagree with each other across the `Main`/`Login` boundary, because
they were copied rather than passed.

Now there is one value, `Main` holds it, `Login.init` receives it, and the
notice view cases over it. Two reasons at once is a compile error, and there is
no second copy to fall out of step with.

  - `Fresh` — they came to sign in. No notice.
  - `SessionExpired { draftSaved }` — Issue #173/#182. `draftSaved` lives INSIDE
    this constructor because it only means anything about an expiry: a saved
    marketplace draft with no expiry is not a state, and can no longer be built.
  - `AccountDeleted` — Issue #188. A warm farewell, deliberately distinct from an
    expiry: this was something they chose.
  - `ForgotPassword` — the `/forgot-password` deep link. Not a page: the login
    card opened straight onto its reset mode.
  - `StoredSessionUnreadable reason` — Issue #360. A stored credential was
    present at boot and could not be read. Before this existed the app read that
    as "logged out" and said nothing, which is indistinguishable to the reader
    from a real sign-out — and is why the private-session auth bug took so long
    to diagnose. `reason` is the decoder's own account of the failure, carried so
    it can be shown rather than discarded.

-}
type Arrival
    = Fresh
    | SessionExpired { draftSaved : Bool }
    | AccountDeleted
    | ForgotPassword
    | StoredSessionUnreadable String


{-| Whether a marketplace listing draft was saved on the way to this arrival
(Issue #182). The ONE reader of that flag, so "was a draft saved" cannot be asked
of an arrival where the question is meaningless — every non-expiry arrival
answers `False` by construction rather than by a forgotten `&&`.

Exposed because `Main` has to keep the flag STICKY across a second expiry: a
later plain expiry must not erase a reassurance an earlier draft-expiry raised.

-}
draftWasSaved : Arrival -> Bool
draftWasSaved arrival =
    case arrival of
        SessionExpired details ->
            details.draftSaved

        _ ->
            False


{-| Whether the navigation now being consumed is the one a session expiry
pushed (#361's question, #360's value).

⛔ `Main.redirectAfterNavigation` needs to know "did the session die underneath
this reader", because an expiry bounce must return them to the page they were
standing on rather than to nothing. That used to be `model.sessionExpiredNotice`
— one of the six booleans. It is the same fact, so it is read from the same
value rather than kept as a seventh: an expiry that raises the notice but not
the redirect (or the reverse) is now unwritable.

Named here beside `draftWasSaved` for the same reason `Main.currentAuth` is the
only reader of `AuthState`: a `case` on `Arrival` scattered through `update` is
how one site starts disagreeing with another about what counts as an expiry.

-}
isSessionExpiry : Arrival -> Bool
isSessionExpiry arrival =
    case arrival of
        SessionExpired _ ->
            True

        _ ->
            False


type Mode
    = LoginMode
    | RegisterMode
    | RegistrationPending String
    | ForgotPasswordMode


{-| A failed submission. Login failures are always transport/status errors;
registration can additionally fail with structured per-field validation errors
(a 422 body), which we keep so the message reflects the real cause.
-}
type SubmitError
    = SubmitHttpError Http.Error
    | SubmitValidationError (List ( String, List String ))


type Msg
    = EmailChanged String
    | PasswordChanged String
    | PasswordConfirmChanged String
    | DisplayNameChanged String
    | ModeSwitched Mode
    | FormSubmitted
    | ForgotSubmitted
    | GotForgotResponse (Result Http.Error ())
    | GotAuthResponse (Result Http.Error AuthResponse)
    | GotRegisterResponse (Result RegisterError ())


{-| What the card asks the shell to do. There is exactly one way to report a
successful sign-in — `LoggedIn` — and it is emitted on the same update that
decodes the `200`. The card has no "credential accepted but not yet handed over"
outcome to report, because it never holds one (#359).
-}
type OutMsg
    = NoOut
    | LoggedIn AuthResponse
    | RegistrationSucceeded String


{-| Build the login card for the reason the reader is looking at it.

⛔ The ONE way to build this page. There used to be five — `init`, `forgotInit`,
`expiredInit`, `expiredDraftInit`, `farewellInit` — each a record update setting
a different subset of the three notice booleans. Adding a sixth reason meant
adding a sixth init and remembering which flags it must NOT set; `expiredInit`
and `expiredDraftInit` differed by exactly one field, and nothing stopped a
future `expiredFarewellInit`. Taking the reason as an argument makes the set of
buildable cards exactly the set of `Arrival` constructors — no more, no fewer.

The card's initial `mode` is derived here rather than passed separately, so
`/forgot-password` cannot open a card in login mode while claiming to be a reset.

-}
init : Arrival -> Model
init arrival =
    { email = ""
    , password = ""
    , passwordConfirm = ""
    , displayName = ""
    , mode =
        case arrival of
            ForgotPassword ->
                ForgotPasswordMode

            _ ->
                LoginMode
    , submitState = NotAsked
    , emailValidation = Pristine
    , passwordValidation = Pristine
    , passwordConfirmValidation = Pristine
    , displayNameValidation = Pristine
    , arrival = arrival
    , forgotState = NotAsked
    }


validateEmail : String -> FieldValidation
validateEmail email =
    if String.isEmpty email then
        Pristine

    else if String.contains "@" email && String.contains "." email then
        Valid

    else
        Invalid "Please enter a valid email address"


validatePassword : String -> FieldValidation
validatePassword password =
    if String.isEmpty password then
        Pristine

    else if PasswordRule.isLongEnough password then
        Valid

    else
        Invalid PasswordRule.tooShort


validateDisplayName : String -> FieldValidation
validateDisplayName name =
    if String.isEmpty name then
        Pristine

    else
        Valid


{-| Validate the confirm-password field against the entered password.
Pristine when empty, Valid when it matches, Invalid otherwise.
-}
validatePasswordConfirm : String -> String -> FieldValidation
validatePasswordConfirm password confirm =
    if String.isEmpty confirm then
        Pristine

    else if confirm == password then
        Valid

    else
        Invalid "Passwords do not match"


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        EmailChanged email ->
            ( { model | email = email, submitState = NotAsked, emailValidation = validateEmail email }, Cmd.none, NoOut )

        PasswordChanged password ->
            ( { model
                | password = password
                , submitState = NotAsked
                , passwordValidation = validatePassword password
                , passwordConfirmValidation = validatePasswordConfirm password model.passwordConfirm
              }
            , Cmd.none
            , NoOut
            )

        PasswordConfirmChanged confirm ->
            ( { model
                | passwordConfirm = confirm
                , submitState = NotAsked
                , passwordConfirmValidation = validatePasswordConfirm model.password confirm
              }
            , Cmd.none
            , NoOut
            )

        DisplayNameChanged name ->
            ( { model | displayName = name, submitState = NotAsked, displayNameValidation = validateDisplayName name }, Cmd.none, NoOut )

        ModeSwitched mode ->
            ( { model
                | mode = mode
                , submitState = NotAsked
                , emailValidation = Pristine
                , passwordValidation = Pristine
                , passwordConfirmValidation = Pristine
                , displayNameValidation = Pristine

                -- Switching tabs is the reader moving on from whatever brought
                -- them here, so the arrival is spent. One assignment now clears
                -- what used to be three, which is why they can no longer be
                -- cleared unevenly.
                , arrival = Fresh
                , forgotState = NotAsked
              }
            , Cmd.none
            , NoOut
            )

        ForgotSubmitted ->
            if String.isEmpty (String.trim model.email) then
                ( model, Cmd.none, NoOut )

            else
                ( { model | forgotState = Loading }
                , Api.forgotPassword model.email GotForgotResponse
                , NoOut
                )

        GotForgotResponse result ->
            case result of
                Ok () ->
                    ( { model | forgotState = Success () }, Cmd.none, NoOut )

                Err err ->
                    ( { model | forgotState = Failure err }, Cmd.none, NoOut )

        FormSubmitted ->
            let
                cmd =
                    case model.mode of
                        LoginMode ->
                            Api.login
                                { email = model.email, password = model.password }
                                GotAuthResponse

                        RegisterMode ->
                            Api.register
                                { email = model.email
                                , password = model.password
                                , displayName = model.displayName
                                }
                                GotRegisterResponse

                        RegistrationPending _ ->
                            Cmd.none

                        ForgotPasswordMode ->
                            Cmd.none
            in
            ( { model | submitState = Loading, arrival = Fresh }, cmd, NoOut )

        GotAuthResponse (Ok authResponse) ->
            -- ⛔ Persist-first (#359). The credential is handed to the shell on the
            -- SAME update as the 200 — no port round-trip, no animation, nothing a
            -- browser is free to decline to run. This branch used to emit
            -- `StartTransition` and wait for a Web Animations `finished` promise
            -- before `Main` was allowed to store the token; `requestAnimationFrame`
            -- never fires while the window is occluded or backgrounded, so the
            -- promise never settled and the credential was silently discarded —
            -- three logins returning 200 with nothing in localStorage, driven live
            -- 2026-07-30. The door animation is decoration and now runs strictly
            -- after the token is durable.
            --
            -- Shape mirrors `GotRegisterResponse (Ok ())` below: decide here, hand
            -- the outcome up exactly once, leave no half-finished state on the card.
            ( { model | submitState = Success authResponse }
            , Cmd.none
            , LoggedIn authResponse
            )

        GotAuthResponse (Err err) ->
            ( { model | submitState = Failure (SubmitHttpError err) }, Cmd.none, NoOut )

        GotRegisterResponse (Ok ()) ->
            -- Registration succeeded: the backend has sent a confirmation email.
            -- Do NOT store a JWT, do NOT play the door animation, do NOT navigate.
            -- Switch to the pending state so the user is told to check their inbox.
            ( { model | mode = RegistrationPending model.email, submitState = NotAsked }
            , Cmd.none
            , RegistrationSucceeded model.email
            )

        GotRegisterResponse (Err registerError) ->
            ( { model | submitState = Failure (fromRegisterError registerError) }, Cmd.none, NoOut )


view : Model -> Html Msg
view model =
    div [ class "page page--login" ]
        [ div [ class "layer-arrival" ] []
        , div [ class "layer-passage", id "passage" ] []
        , div [ class "layer-passage-bright", id "passageBright" ] []
        , div [ class "layer-bookshelf", id "bookshelf" ] []
        , div [ class "layer-bookshelf-dim", id "bookshelfDim" ] []
        , div [ class "layer-vignette", id "vignette" ] []
        , div [ class "layer-wash", id "wash" ] []
        , div [ class "login-overlay", id "overlay" ]
            [ viewLoginCard model ]
        ]


viewLoginCard : Model -> Html Msg
viewLoginCard model =
    case model.mode of
        RegistrationPending email ->
            viewPendingCard email

        _ ->
            viewFormCard model


{-| The "check your inbox" card shown after a successful registration.
No JWT is stored and no navigation occurs — the user must confirm via email.
-}
viewPendingCard : String -> Html Msg
viewPendingCard email =
    div [ class "login-card login-card--pending", testId "registration-pending" ]
        [ h1 [ class "login-card__title" ] [ text "Check your inbox!" ]
        , p [ class "login-card__subtitle" ]
            [ text
                ("A confirmation email has been sent to "
                    ++ email
                    ++ ". Click the link in the email to confirm your address and activate your account."
                )
            ]
        , button
            [ class "login-card__back"
            , testId "back-to-sign-in"
            , onClick (ModeSwitched LoginMode)
            ]
            [ text "Back to Sign In" ]
        ]


viewFormCard : Model -> Html Msg
viewFormCard model =
    div [ class "login-card", testId "login-form" ]
        (h1 [ class "login-card__title" ] [ text "The Stacks" ]
            :: p [ class "login-card__subtitle" ] [ text (cardSubtitle model.mode) ]
            :: viewArrivalNotice model
            :: (case model.mode of
                    ForgotPasswordMode ->
                        [ viewForgotForm model ]

                    _ ->
                        viewCredentialsForm model
               )
        )


cardSubtitle : Mode -> String
cardSubtitle mode =
    case mode of
        RegisterMode ->
            "Register for entry to the collection"

        ForgotPasswordMode ->
            "Reset your password"

        _ ->
            "Present your credentials to enter"


{-| The in-card "reset your password" form — a mode of the login card so it
inherits the same styling and the library background, rather than a bare
standalone page.
-}
viewForgotForm : Model -> Html Msg
viewForgotForm model =
    div [ class "login-card__forgot-form" ]
        [ p [ class "login-card__subtitle" ]
            [ text "Enter your email and we'll send you a link to set a new password." ]
        , div [ class (fieldClass model.emailValidation) ]
            [ label [ class "login-card__label", for "email" ] [ text "Email" ]
            , input
                [ id "email"
                , class "login-card__input"
                , testId "forgot-email"
                , type_ "email"
                , placeholder "you@example.com"
                , value model.email
                , onInput EmailChanged
                , attribute "aria-required" "true"
                ]
                []
            , viewFieldHint model.emailValidation
            ]
        , button
            [ class "login-card__submit"
            , testId "forgot-submit"
            , onClick ForgotSubmitted
            , disabled (model.forgotState == Loading || String.isEmpty (String.trim model.email))
            ]
            [ case model.forgotState of
                Loading ->
                    span [ class "spinner spinner--small" ] []

                _ ->
                    text "Send reset link"
            ]
        , -- ⛔ The acknowledgement is a NOTICE, not a subtitle.
          --
          -- Sending the reset mail is the entire point of this form, and the only
          -- evidence it happened is this sentence — the reader's inbox is
          -- somewhere else, and the endpoint deliberately answers the same way
          -- whether or not the address is registered, so there is nothing else to
          -- go on. It was rendered as `login-card__subtitle`: the same class as
          -- the "Enter your email and we'll send you a link" helper text two
          -- elements above, in a live region belonging to nobody. A screen-reader
          -- user pressed the button and was told nothing at all; a sighted one
          -- got a line of helper text where a confirmation should be.
          --
          -- `notice` is the card's own component and already stamps
          -- `role="status"`, which is why this is an adoption and not an
          -- invention. The class literal stays here at the call site — see
          -- `notice`'s own note on #356.
          case model.forgotState of
            Success _ ->
                notice
                    [ class "login-card__notice", testId "forgot-success" ]
                    "If that email is registered, a reset link is on its way. Check your inbox."

            Failure _ ->
                notice
                    [ class "login-card__error", testId "forgot-error" ]
                    "Something went wrong. Please try again."

            _ ->
                text ""
        , button
            [ class "login-card__back"
            , type_ "button"
            , testId "forgot-back"
            , onClick (ModeSwitched LoginMode)
            ]
            [ text "Back to sign in" ]
        ]


viewCredentialsForm : Model -> List (Html Msg)
viewCredentialsForm model =
    [ div
        [ class "login-card__tabs"
        , attribute "role" "tablist"
        ]
        [ button
            [ class
                (if model.mode == LoginMode then
                    "login-card__tab login-card__tab--active"

                 else
                    "login-card__tab"
                )
            , attribute "role" "tab"
            , attribute "aria-selected"
                (if model.mode == LoginMode then
                    "true"

                 else
                    "false"
                )
            , onClick (ModeSwitched LoginMode)
            ]
            [ text "Sign In" ]
        , button
            [ class
                (if model.mode == RegisterMode then
                    "login-card__tab login-card__tab--active"

                 else
                    "login-card__tab"
                )
            , attribute "role" "tab"
            , attribute "aria-selected"
                (if model.mode == RegisterMode then
                    "true"

                 else
                    "false"
                )
            , onClick (ModeSwitched RegisterMode)
            ]
            [ text "Register" ]
        ]
    , case model.mode of
        RegisterMode ->
            div [ class (fieldClass model.displayNameValidation) ]
                [ label [ class "login-card__label", for "display-name" ]
                    [ text "Display Name" ]
                , input
                    [ id "display-name"
                    , class "login-card__input"
                    , type_ "text"
                    , placeholder "Your name"
                    , value model.displayName
                    , onInput DisplayNameChanged
                    ]
                    []
                , viewFieldHint model.displayNameValidation
                ]

        _ ->
            text ""
    , div [ class (fieldClass model.emailValidation) ]
        [ label [ class "login-card__label", for "email" ]
            [ text "Email" ]
        , input
            [ id "email"
            , class "login-card__input"
            , testId "login-email"
            , type_ "email"
            , placeholder "you@example.com"
            , value model.email
            , onInput EmailChanged
            , attribute "aria-required" "true"
            ]
            []
        , viewFieldHint model.emailValidation
        ]
    , div [ class (fieldClass model.passwordValidation) ]
        [ label [ class "login-card__label", for "password" ]
            [ text "Password" ]
        , input
            [ id "password"
            , class "login-card__input"
            , testId "login-password"
            , type_ "password"
            , placeholder "Enter your password"
            , value model.password
            , onInput PasswordChanged
            , attribute "aria-required" "true"
            ]
            []
        , viewFieldHint model.passwordValidation
        ]
    , case model.mode of
        RegisterMode ->
            div [ class (fieldClass model.passwordConfirmValidation) ]
                [ label [ class "login-card__label", for "password-confirm" ]
                    [ text "Confirm Password" ]
                , input
                    [ id "password-confirm"
                    , class "login-card__input"
                    , testId "login-password-confirm"
                    , type_ "password"
                    , placeholder "Re-enter your password"
                    , value model.passwordConfirm
                    , onInput PasswordConfirmChanged
                    , attribute "aria-required" "true"
                    ]
                    []
                , viewFieldHint model.passwordConfirmValidation
                ]

        _ ->
            text ""
    , viewError model
    , button
        [ class "login-card__submit"
        , testId "login-submit"
        , onClick FormSubmitted
        , disabled (isSubmitDisabled model)
        ]
        [ case model.submitState of
            Loading ->
                span [ class "spinner spinner--small" ] []

            -- A handed-over credential keeps spinning: the shell has the token and
            -- is navigating, so snapping the label back to "Enter the Stacks" would
            -- read as "nothing happened" for the frame before the page changes.
            Success _ ->
                span [ class "spinner spinner--small" ] []

            _ ->
                text
                    (case model.mode of
                        RegisterMode ->
                            "Request Entry"

                        _ ->
                            "Enter the Stacks"
                    )
        ]
    , case model.mode of
        LoginMode ->
            button
                [ class "login-card__forgot"
                , type_ "button"
                , onClick (ModeSwitched ForgotPasswordMode)
                , testId "forgot-password-link"
                ]
                [ text "Forgot your password?" ]

        _ ->
            text ""
    ]


{-| Is the submit button locked?

⛔ Derived from `submitState` alone, on purpose. This used to read a SECOND flag,
`transitionState`, which latched to `Transitioning` the moment a 200 arrived and
had no reset path anywhere — not on `ModeSwitched`, not on a keystroke. A login
whose door animation never finished (an occluded window: `requestAnimationFrame`
does not fire, so the completion signal never arrives) therefore left the card
permanently unable to submit, with no way back short of a reload — the visible
half of #359. Deleting the duplicate makes that trap unrepresentable rather than
merely reset: there is one field, and `ModeSwitched` already clears it.

`Success` still locks the button — the shell has been handed the credential and
is navigating; a second submit would be a second login.

-}
isSubmitDisabled : Model -> Bool
isSubmitDisabled model =
    let
        submissionHandedOver =
            case model.submitState of
                Loading ->
                    True

                Success _ ->
                    True

                _ ->
                    False

        isInvalidOrPristine validation =
            case validation of
                Valid ->
                    False

                _ ->
                    True

        fieldsInvalid =
            case model.mode of
                LoginMode ->
                    isInvalidOrPristine model.emailValidation
                        || isInvalidOrPristine model.passwordValidation

                RegisterMode ->
                    isInvalidOrPristine model.emailValidation
                        || isInvalidOrPristine model.passwordValidation
                        || isInvalidOrPristine model.passwordConfirmValidation
                        || isInvalidOrPristine model.displayNameValidation

                _ ->
                    True
    in
    submissionHandedOver || fieldsInvalid


fieldClass : FieldValidation -> String
fieldClass validation =
    case validation of
        Pristine ->
            "login-card__field"

        Valid ->
            "login-card__field login-card__field--valid"

        Invalid _ ->
            "login-card__field login-card__field--error"


viewFieldHint : FieldValidation -> Html Msg
viewFieldHint validation =
    case validation of
        Invalid msg ->
            div [ class "login-card__hint login-card__hint--error" ] [ text msg ]

        Valid ->
            div [ class "login-card__hint login-card__hint--valid" ] [ text "Looks good" ]

        Pristine ->
            text ""


{-| The one notice the arrival is owed, if any (Issue #360).

⛔ This was two functions — `viewSessionExpiredNotice` and
`viewAccountDeletedNotice` — each re-deriving the same `submitFailed`
suppression, each independently deciding whether to render, and each blind to
the other. When both booleans were set they both rendered, stacked. Casing over
one `Arrival` means at most one notice exists to render, and the suppression
rule is written once.

Suppressed once a submit failure is showing: the reader has since tried to sign
in and failed, and that more-specific message must win. The mode check keeps the
expiry notice out of the register and reset tabs, where it would be answering a
question nobody asked.

-}
viewArrivalNotice : Model -> Html Msg
viewArrivalNotice model =
    let
        submitFailed =
            case model.submitState of
                Failure _ ->
                    True

                _ ->
                    False
    in
    if submitFailed then
        text ""

    else
        case model.arrival of
            Fresh ->
                text ""

            ForgotPassword ->
                text ""

            SessionExpired details ->
                if model.mode == LoginMode then
                    notice
                        [ class "login-card__notice login-card__notice--session-expired"
                        , testId "session-expired-notice"
                        ]
                        (sessionExpiredNoticeText details.draftSaved)

                else
                    text ""

            AccountDeleted ->
                notice
                    [ class "login-card__notice login-card__notice--account-deleted"
                    , testId "account-deleted-notice"
                    ]
                    "Your account deletion has been queued. We're sorry to see you go — thank you for the time you spent in The Stacks."

            StoredSessionUnreadable reason ->
                -- ⛔ The reader is TOLD. A stored credential that will not decode
                -- used to be silently treated as "signed out", which is exactly
                -- what a real sign-out looks like — so nobody could tell a bug
                -- from a logout, and the app threw away the one thing that would
                -- have explained it. The decoder's own account of the failure
                -- rides along in `title` so it is recoverable from the page
                -- without a debugger, without putting decoder jargon in the copy.
                notice
                    [ class "login-card__notice login-card__notice--stored-session-unreadable"
                    , testId "stored-session-unreadable-notice"
                    , attribute "title" reason
                    ]
                    "A saved sign-in was found here but could not be read, so you have been signed out. Please sign in again."


{-| One notice, one shape. Five hand-written notice blocks would be five
chances for the `role="status"` that makes a notice announce itself to be
present on only four of them — and that is not hypothetical: the
forgot-password acknowledgement was written by hand, as a `login-card__subtitle`
paragraph, and had no live region at all until it was routed through here.

⚠️ The class stays at each CALL SITE, spelled as a literal `class "…"`.
`scripts/check-orphan-classes.sh` finds classes by matching `class "…"` in Elm
source, so folding them in here as a `className` field — or assembling one from
a modifier — hides every notice class from the gate (#356), and their styling
could then be deleted with nothing to say so. Measured: doing exactly that took
the Elm class count from 802 to 799 while the gate stayed green.

-}
notice : List (Html.Attribute Msg) -> String -> Html Msg
notice attrs copy =
    div (attribute "role" "status" :: attrs) [ text copy ]


{-| Copy for the session-expiry notice. When a marketplace listing draft was
saved on the way here (Issue #182), reassure the user their work survived.
-}
sessionExpiredNoticeText : Bool -> String
sessionExpiredNoticeText draftSaved =
    if draftSaved then
        "The library closed your session for safekeeping — your listing draft is saved. Sign in and return to Sell a Book to finish it."

    else
        "The library closed your session for safekeeping — sign in again to return."


viewError : Model -> Html Msg
viewError model =
    case model.submitState of
        Failure err ->
            div [ attribute "aria-live" "polite", testId "login-error" ]
                [ p [ class "login-card__error" ]
                    [ text (errorMessage model.mode err) ]
                ]

        _ ->
            text ""


{-| Map an `Api.RegisterError` into the page's own submit-error representation.
-}
fromRegisterError : RegisterError -> SubmitError
fromRegisterError registerError =
    case registerError of
        RegisterValidationFailed errors ->
            SubmitValidationError errors

        RegisterRequestFailed err ->
            SubmitHttpError err


errorMessage : Mode -> SubmitError -> String
errorMessage mode submitError =
    case submitError of
        SubmitValidationError errors ->
            registerValidationMessage errors

        SubmitHttpError err ->
            httpErrorMessage mode err


{-| Turn a 422's per-field validation errors into a warm, specific message.
Known fields get bespoke copy; anything else falls back to a general note. When
several fields fail we lead with the email (the most common register snag).
-}
registerValidationMessage : List ( String, List String ) -> String
registerValidationMessage errors =
    let
        hasField name =
            List.any (\( key, _ ) -> key == name) errors
    in
    if hasField "email" then
        "A reader with that email already frequents these halls. Try signing in instead."

    else if hasField "password" then
        -- ⛔ The one branch of this warm, in-world copy that does NOT get its own
        -- voice. The rest of this function speaks the library's language because
        -- each message is the only thing the reader is told. This one is not:
        -- the register card has already shown the length rule inline under the
        -- field (`validatePassword`, above), so a second, differently-worded
        -- version of the same requirement — "eight" where the hint said "8" —
        -- reads as a second, different requirement. One rule, one sentence.
        PasswordRule.tooShort

    else if hasField "display_name" then
        "Please give a name for your reader's card."

    else
        "Registration could not be completed. Please check the details you entered."


httpErrorMessage : Mode -> Http.Error -> String
httpErrorMessage mode err =
    case err of
        Http.BadStatus 401 ->
            "The door remains shut. Invalid credentials."

        Http.BadStatus 403 ->
            "Please confirm your email address before signing in. Check your inbox for the confirmation email."

        Http.BadStatus 409 ->
            "A reader by that name already frequents these halls."

        Http.BadStatus 422 ->
            case mode of
                RegisterMode ->
                    "A reader with that email already frequents these halls. Try signing in instead."

                _ ->
                    "Please ensure all fields are properly filled."

        Http.BadStatus 423 ->
            "This account is temporarily locked after too many failed attempts. Please try again in a little while."

        Http.BadStatus 503 ->
            "The library is briefly overloaded. Please try again in a few seconds."

        Http.NetworkError ->
            "The library is unreachable. Please try again."

        Http.Timeout ->
            "The library took too long to respond."

        _ ->
            case mode of
                RegisterMode ->
                    "Registration could not be completed. The email may already be in use."

                _ ->
                    "The door remains shut. Invalid email or password."
