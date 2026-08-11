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
    , isForgotDisabled
    , isResendDisabled
    , isSessionExpiry
    , isSubmitDisabled
    , resendTarget
    , update
    , validateDisplayName
    , validateEmail
    , validatePassword
    , validatePasswordConfirm
    , view
    , withInviteOnly
    )

import Api exposing (AuthResponse, RegisterError(..), RequestError(..))
import Html exposing (Html, a, button, div, h1, h3, input, label, p, span, text)
import Html.Attributes exposing (attribute, class, disabled, for, href, id, placeholder, type_, value)
import Html.Events exposing (onClick, onInput)
import Http
import Types.PasswordRule as PasswordRule
import Types.RemoteData exposing (RemoteData(..))
import Util.FailureCopy as FailureCopy
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
    , submitState : RemoteData SubmitError AuthResponse
    , emailValidation : FieldValidation
    , passwordValidation : FieldValidation
    , passwordConfirmValidation : FieldValidation
    , displayNameValidation : FieldValidation
    , arrival : Arrival
    , forgotState : RemoteData RequestError ()
    , resendState : RemoteData RequestError ()
    , inviteCode : String
    , inviteCheck : RemoteData Http.Error Api.InviteStatus
    , inviteOnly : Bool
    }


{-| Why the login card is on screen.

⛔ What this type makes impossible: this used to be three booleans on
`Login.Model` shadowed by three more on `Main.Model`, five inits raising
them, two view predicates reading them — and simultaneous "true"s
stacked notices for mutually-exclusive facts. One `Arrival` value: at
most one reason, named at the moment the card is built.

-}
type Arrival
    = Fresh
    | SessionExpired { draftSaved : Bool }
    | AccountDeleted
    | ForgotPassword
    | StoredSessionUnreadable String
    | ConfirmationExpired


{-| Whether a marketplace listing draft was saved on the way to this arrival. The ONE reader of that flag, so "was a draft saved" cannot be asked
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


{-| Whether the navigation being consumed is the one a session expiry
pushed (361's question). `Main.redirectAfterNavigation` must return an
expired reader to the page they were standing on; this is the same fact
as the expiry notice, so it is READ from the same `Arrival` value rather
than kept as a seventh boolean that could disagree.
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
    | ResendConfirmationMode


{-| A failed submission. Registration can fail with structured per-field
validation errors (a 422 body), which we keep so the message reflects the real
cause; either mode can be turned away by the rate limiter, which is its own
constructor because it is the one failure that carries a number and
because it is emphatically **not** a bad credential.
-}
type SubmitError
    = SubmitHttpError Http.Error
    | SubmitValidationError (List ( String, List String ))
    | SubmitRateLimited (Maybe Int)
    | SubmitInviteRefused String


type Msg
    = EmailChanged String
    | PasswordChanged String
    | PasswordConfirmChanged String
    | DisplayNameChanged String
    | ModeSwitched Mode
    | FormSubmitted
    | ForgotSubmitted
    | GotForgotResponse (Result RequestError ())
    | ResendRequested
    | GotResendResponse (Result RequestError ())
    | GotAuthResponse (Result RequestError AuthResponse)
    | GotRegisterResponse (Result RegisterError ())
    | InviteCodeChanged String
    | InviteSubmitted
    | GotInviteCheck (Result Http.Error Api.InviteStatus)


{-| What the card asks the shell to do. There is exactly one way to report a
successful sign-in — `LoggedIn` — and it is emitted on the same update that
decodes the `200`. The card has no "credential accepted but not yet handed over"
outcome to report, because it never holds one.
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

            ConfirmationExpired ->
                ResendConfirmationMode

            _ ->
                LoginMode
    , submitState = NotAsked
    , emailValidation = Pristine
    , passwordValidation = Pristine
    , passwordConfirmValidation = Pristine
    , displayNameValidation = Pristine
    , arrival = arrival
    , forgotState = NotAsked
    , resendState = NotAsked
    , inviteCode = ""
    , inviteCheck = NotAsked
    , inviteOnly = False
    }


{-| The address a resend is about.

⛔ Read from the card the reader is actually looking at, not from
`model.email` unconditionally. The "check your inbox" card NAMES an address in
its own copy — that address is carried in `RegistrationPending`'s payload — and
a "send it again" button underneath a sentence naming an address must send to
THAT address or it is lying. Everywhere else there is no such claim on screen,
so the typed field is the only candidate.

One function, so the button and the request can never target different things.

-}
resendTarget : Model -> String
resendTarget model =
    case model.mode of
        RegistrationPending email ->
            String.trim email

        _ ->
            String.trim model.email


{-| Whether asking (again) would be a mistake — the one rule behind both the
disabled attribute and the guard in `update`, so a button that looks pressable
cannot fire and a button that fires cannot look inert.

Covers the double-send: once a request is in flight, or has
succeeded, pressing again sends nothing. A FAILED attempt stays pressable, since
retrying is exactly what the reader should do.

-}
isResendDisabled : Model -> Bool
isResendDisabled model =
    String.isEmpty (resendTarget model)
        || (model.resendState == Loading)
        || (model.resendState == Success ())


{-| The same rule for the forgot-password send.

⛔ Must not read the email for anything except emptiness:
`/api/auth/forgot-password` answers 200 to every well-formed request —
the SPA is the other half of that no-enumeration property, and a
disabled state that differed by address would leak what the server
refuses to.

-}
isForgotDisabled : Model -> Bool
isForgotDisabled model =
    String.isEmpty (String.trim model.email)
        || (model.forgotState == Loading)
        || (model.forgotState == Success ())


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
                , arrival = Fresh
                , forgotState = NotAsked
                , resendState = NotAsked
              }
            , Cmd.none
            , NoOut
            )

        ForgotSubmitted ->
            if isForgotDisabled model then
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

        ResendRequested ->
            if isResendDisabled model then
                ( model, Cmd.none, NoOut )

            else
                ( { model | resendState = Loading }
                , Api.resendConfirmation (resendTarget model) GotResendResponse
                , NoOut
                )

        GotResendResponse result ->
            case result of
                Ok () ->
                    ( { model | resendState = Success () }, Cmd.none, NoOut )

                Err err ->
                    ( { model | resendState = Failure err }, Cmd.none, NoOut )

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
                                , inviteCode = model.inviteCode
                                }
                                GotRegisterResponse

                        RegistrationPending _ ->
                            Cmd.none

                        ForgotPasswordMode ->
                            Cmd.none

                        ResendConfirmationMode ->
                            Cmd.none
            in
            ( { model | submitState = Loading, arrival = Fresh }, cmd, NoOut )

        GotAuthResponse (Ok authResponse) ->
            ( { model | submitState = Success authResponse }
            , Cmd.none
            , LoggedIn authResponse
            )

        GotAuthResponse (Err err) ->
            ( { model | submitState = Failure (fromRequestError err) }, Cmd.none, NoOut )

        GotRegisterResponse (Ok ()) ->
            ( { model | mode = RegistrationPending model.email, submitState = NotAsked }
            , Cmd.none
            , RegistrationSucceeded model.email
            )

        GotRegisterResponse (Err registerError) ->
            ( { model | submitState = Failure (fromRegisterError registerError) }, Cmd.none, NoOut )

        InviteCodeChanged code ->
            ( { model | inviteCode = code, inviteCheck = NotAsked }, Cmd.none, NoOut )

        InviteSubmitted ->
            if String.trim model.inviteCode == "" then
                ( model, Cmd.none, NoOut )

            else
                ( { model | inviteCheck = Loading }
                , Api.checkInvite (String.trim model.inviteCode) GotInviteCheck
                , NoOut
                )

        GotInviteCheck result ->
            ( { model | inviteCheck = Types.RemoteData.fromResult result }, Cmd.none, NoOut )


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
            viewPendingCard model email

        _ ->
            viewFormCard model


{-| The "check your inbox" card shown after a successful registration.
No JWT is stored and no navigation occurs — the user must confirm via email.

Carries the resend affordance. This is the moment the
reader is most likely to need it — the email either arrives in the next minute or
it does not — and until now the card was a dead end: the only route out was to
register again with an address that was already taken.

-}
viewPendingCard : Model -> String -> Html Msg
viewPendingCard model email =
    div [ class "login-card login-card--pending", testId "registration-pending" ]
        [ h1 [ class "login-card__title" ] [ text "Check your inbox!" ]
        , p [ class "login-card__subtitle" ]
            [ text
                ("A confirmation email has been sent to "
                    ++ email
                    ++ ". Click the link in the email to confirm your address and activate your account."
                )
            ]
        , p [ class "login-card__subtitle" ]
            [ text "Nothing there? Check your spam folder, or we can send it again." ]
        , button
            [ class "login-card__submit"
            , type_ "button"
            , testId "resend-confirmation"
            , onClick ResendRequested
            , disabled (isResendDisabled model)
            ]
            [ case model.resendState of
                Loading ->
                    span [ class "spinner spinner--small" ] []

                _ ->
                    text "Send it again"
            ]
        , viewResendOutcome model
        , button
            [ class "login-card__back"
            , testId "back-to-sign-in"
            , onClick (ModeSwitched LoginMode)
            ]
            [ text "Back to Sign In" ]
        ]


{-| What became of the resend request. A `notice` for the same reason the
forgot-password acknowledgement is one: the reader's inbox is elsewhere, the
server deliberately says the same thing to everyone, and so this sentence is the
entire evidence that anything happened. `notice` stamps `role="status"`, so a
screen-reader user is told too.

The success copy is hedged exactly as the endpoint is. Saying "sent!" would
promise something the response does not contain — for an address that is already
confirmed, or has no account, nothing was sent at all — and the SPA must not
invent the certainty the API refused to give.

-}
viewResendOutcome : Model -> Html Msg
viewResendOutcome model =
    case model.resendState of
        Success _ ->
            notice
                [ class "login-card__notice", testId "resend-success" ]
                "If that address is waiting to be confirmed, a fresh link is on its way. It replaces any earlier one."

        Failure err ->
            notice
                [ class "login-card__error", testId "resend-error" ]
                (mailRequestError err)

        _ ->
            text ""


{-| Why one of the two "we will email you" requests did not go through.

Both endpoints answer identically for every address, so this function may not
branch on anything address-shaped — and it cannot, because a `RequestError`
carries nothing of the sort. What it does carry is worth saying: a throttle is a
different instruction from a dropped connection, and neither is "something went
wrong", which is what both of these used to read.

The timeout branch is the careful one. A request that timed out may still have
been served, so it must not claim the mail was not sent; the honest report is
that we stopped waiting.

-}
mailRequestError : RequestError -> String
mailRequestError err =
    case err of
        RateLimited retryAfter ->
            FailureCopy.rateLimited retryAfter

        RequestFailed Http.NetworkError ->
            "The library is unreachable. Check your connection, then try again."

        RequestFailed Http.Timeout ->
            "The library took too long to answer, so we cannot say whether the message was sent. Wait a moment before asking again."

        RequestFailed _ ->
            "Something went wrong at our end, and we cannot say what. Please try again in a moment."


{-| The standalone "send me a new link" form.

Reached by `/resend-confirmation`, which is where a dead confirmation link now
points. A mode of the login card rather than a page of its own, exactly like
`viewForgotForm` — same scene, same card, and the reader keeps the sign-in tab
one click away in case the account turned out to be confirmed already.

-}
viewResendForm : Model -> Html Msg
viewResendForm model =
    div [ class "login-card__forgot-form" ]
        [ p [ class "login-card__subtitle" ]
            [ text "That link has expired or has already been used. Enter your email and we'll send a fresh one." ]
        , div [ class (fieldClass model.emailValidation) ]
            [ label [ class "login-card__label", for "email" ] [ text "Email" ]
            , input
                [ id "email"
                , class "login-card__input"
                , testId "resend-email"
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
            , type_ "button"
            , testId "resend-confirmation"
            , onClick ResendRequested
            , disabled (isResendDisabled model)
            ]
            [ case model.resendState of
                Loading ->
                    span [ class "spinner spinner--small" ] []

                _ ->
                    text "Send a new link"
            ]
        , viewResendOutcome model
        , button
            [ class "login-card__back"
            , type_ "button"
            , testId "resend-back"
            , onClick (ModeSwitched LoginMode)
            ]
            [ text "Back to sign in" ]
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

                    ResendConfirmationMode ->
                        [ viewResendForm model ]

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

        ResendConfirmationMode ->
            "Confirm your email address"

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
            , disabled (isForgotDisabled model)
            ]
            [ case model.forgotState of
                Loading ->
                    span [ class "spinner spinner--small" ] []

                Success _ ->
                    text "Reset link sent"

                _ ->
                    text "Send reset link"
            ]
        , -- ⛔ The acknowledgement is a NOTICE, not a subtitle.
          case model.forgotState of
            Success _ ->
                notice
                    [ class "login-card__notice", testId "forgot-success" ]
                    "If that email is registered, a reset link is on its way. Check your inbox."

            Failure err ->
                notice
                    [ class "login-card__error", testId "forgot-error" ]
                    (mailRequestError err)

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
    viewTabs model
        :: (if model.mode == RegisterMode && registerGateLocked model then
                [ viewInviteOnlyPanel model ]

            else
                viewFormFields model
           )


{-| Whether the Register form is withheld: the gate is on and no code has been
accepted. "Unlocked" IS `inviteCheck = Success` — no second field to disagree.
-}
registerGateLocked : Model -> Bool
registerGateLocked model =
    model.inviteOnly && not (inviteUnlocked model)


inviteUnlocked : Model -> Bool
inviteUnlocked model =
    case model.inviteCheck of
        Success _ ->
            True

        _ ->
            False


viewTabs : Model -> Html Msg
viewTabs model =
    div
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


viewFormFields : Model -> List (Html Msg)
viewFormFields model =
    [ viewInviteField model
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


{-| Is the submit button locked? Derived from `submitState` ALONE: the old
second flag (`transitionState`) latched on a 200 with no reset path, so
a login whose door animation never finished (occluded window — rAF never
fires) left the card permanently locked for the rest of the tab's life.
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


{-| The one notice the arrival is owed, if any. Two functions used
to re-derive the same suppression independently and stack when both
their booleans were set. Casing over one `Arrival` means at most one
notice can exist, and the submit-failure suppression is written once.
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

            ConfirmationExpired ->
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
a modifier — hides every notice class from the gate, and their styling
could then be deleted with nothing to say so. Measured: doing exactly that took
the Elm class count from 802 to 799 while the gate stayed green.

-}
notice : List (Html.Attribute Msg) -> String -> Html Msg
notice attrs copy =
    div (attribute "role" "status" :: attrs) [ text copy ]


{-| Copy for the session-expiry notice. When a marketplace listing draft was
saved on the way here, reassure the user their work survived.
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


{-| The accepted invitation, shown above Display Name once the gate unlocks. Read-only: the code was just validated, and editing it here would
race the registration against a different code than the one checked.
-}
viewInviteField : Model -> Html Msg
viewInviteField model =
    if model.mode == RegisterMode && model.inviteOnly then
        div [ class "login-card__field login-card__field--invite login-card__field--valid" ]
            [ label [ class "login-card__label", for "invite-code" ]
                [ text "Invitation code" ]
            , input
                [ id "invite-code"
                , class "login-card__input"
                , testId "invite-code-input"
                , type_ "text"
                , value model.inviteCode
                , attribute "readonly" "readonly"
                , attribute "aria-required" "true"
                ]
                []
            , span [ class "login-card__invite-caption" ]
                [ text "Invitation accepted. Welcome — the door is open." ]
            ]

    else
        text ""


{-| The closed-beta panel an uninvited visitor sees on the Register tab. No email capture, no waitlist — the platform does not collect
addresses from people it has not invited.
-}
viewInviteOnlyPanel : Model -> Html Msg
viewInviteOnlyPanel model =
    div [ class "login-card__invite-only", testId "invite-only-panel" ]
        [ h3 [ class "login-card__invite-only-title" ]
            [ text "The Stacks is in closed beta." ]
        , p [ class "login-card__invite-only-copy" ]
            [ text
                ("New accounts are opened by invitation for now — a small, trusted circle "
                    ++ "while the shelves are still being built. If you have a code, paste it "
                    ++ "below. If you don't, the "
                )
            , a [ href "/faq" ] [ text "FAQ" ]
            , text " explains what The Stacks is and how the beta works."
            ]
        , div [ class "login-card__field login-card__field--invite" ]
            [ label [ class "login-card__label", for "invite-code" ]
                [ text "Invitation code" ]
            , input
                [ id "invite-code"
                , class "login-card__input"
                , testId "invite-code-input"
                , type_ "text"
                , placeholder "STK-XXXX-XXXX"
                , value model.inviteCode
                , onInput InviteCodeChanged
                , attribute "autocapitalize" "characters"
                , attribute "aria-required" "true"
                ]
                []
            , viewInviteRefusal model
            ]
        , button
            [ class "login-card__submit"
            , type_ "button"
            , testId "invite-redeem-button"
            , onClick InviteSubmitted
            , disabled (model.inviteCheck == Loading || String.trim model.inviteCode == "")
            ]
            [ case model.inviteCheck of
                Loading ->
                    span [ class "spinner spinner--small" ] []

                _ ->
                    text "Redeem"
            ]
        ]


viewInviteRefusal : Model -> Html Msg
viewInviteRefusal model =
    case model.inviteCheck of
        Failure err ->
            span [ class "login-card__invite-caption login-card__invite-caption--error" ]
                [ text (inviteErrorMessage err) ]

        _ ->
            text ""


{-| Refusal copy per status (sad paths). Revoked deliberately reads
as expired — the reader learns nothing about WHY it stopped working, and
neither wording implies the code was ever valid for someone else.
-}
inviteErrorMessage : Http.Error -> String
inviteErrorMessage err =
    case err of
        Http.BadStatus 404 ->
            "We don't recognise that code. Check it against the message you were sent."

        Http.BadStatus 410 ->
            "That invitation has expired. Ask whoever sent it for a fresh one."

        Http.BadStatus 403 ->
            "That invitation has expired. Ask whoever sent it for a fresh one."

        Http.BadStatus 409 ->
            "That invitation has already been used."

        Http.NetworkError ->
            "The library is unreachable. Your code is fine — try again in a moment."

        _ ->
            "Something went wrong checking that code. Please try again."


{-| Main applies the server's `inviteOnly` flag to a freshly built card, and
re-applies it when the background config fetch resolves. The MODEL defaults to
open (so the page's own tests read naturally); the fail-CLOSED guarantee lives
in `Main.defaultConfig` (inviteOnly = True until the server says otherwise),
which every production build site passes through here.
-}
withInviteOnly : Bool -> Model -> Model
withInviteOnly flag model =
    { model | inviteOnly = flag }


{-| Map an `Api.RegisterError` into the page's own submit-error representation.
-}
fromRegisterError : RegisterError -> SubmitError
fromRegisterError registerError =
    case registerError of
        RegisterValidationFailed errors ->
            SubmitValidationError errors

        RegisterRateLimited retryAfter ->
            SubmitRateLimited retryAfter

        RegisterInviteRefused reason ->
            SubmitInviteRefused reason

        RegisterRequestFailed err ->
            SubmitHttpError err


{-| A sign-in failure as a `SubmitError`.

The 429 is lifted out of `Http.Error` here rather than mapped in
`httpErrorMessage` because by the time a failure is an `Http.Error` its
`retry-after` is gone — that is the whole reason `Api.RequestError` exists.

-}
fromRequestError : RequestError -> SubmitError
fromRequestError requestError =
    case requestError of
        RateLimited retryAfter ->
            SubmitRateLimited retryAfter

        RequestFailed err ->
            SubmitHttpError err


errorMessage : Mode -> SubmitError -> String
errorMessage mode submitError =
    case submitError of
        SubmitValidationError errors ->
            registerValidationMessage errors

        SubmitRateLimited retryAfter ->
            FailureCopy.rateLimited retryAfter

        SubmitInviteRefused reason ->
            inviteRefusalMessage reason

        SubmitHttpError err ->
            httpErrorMessage mode err


{-| Registration-time refusal copy, keyed by the server's bounded reason
string. Revoked reads as expired on purpose — see
`inviteErrorMessage`.
-}
inviteRefusalMessage : String -> String
inviteRefusalMessage reason =
    case reason of
        "invite_required" ->
            "The Stacks is in closed beta — registration needs an invitation code."

        "invite_expired" ->
            "That invitation has expired. Ask whoever sent it for a fresh one."

        "invite_revoked" ->
            "That invitation has expired. Ask whoever sent it for a fresh one."

        "invite_exhausted" ->
            "That invitation has already been used."

        "invite_email_mismatch" ->
            "This invitation was written for a different email address."

        _ ->
            "We don't recognise that code. Check it against the message you were sent."


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
        PasswordRule.tooShort

    else if hasField "display_name" then
        "Please give a name for your reader's card."

    else
        "Registration could not be completed. Please check the details you entered."


{-| A sign-in or registration failure, named only as precisely as the
response allows.

⛔ The catch-all used to say "Invalid email or password" for ANY unlisted
status — a 500, a mid-deploy 502, a proxy 504 all told the reader their
credentials were wrong. Unknown statuses now get an honest "the library
door is stuck" with retry framing; only a 401 blames the credentials.

-}
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

        Http.BadStatus 429 ->
            FailureCopy.rateLimited Nothing

        Http.BadStatus 503 ->
            "The library is briefly overloaded. Please try again in a few seconds."

        Http.NetworkError ->
            "The library is unreachable. Please try again."

        Http.Timeout ->
            "The library took too long to respond."

        Http.BadStatus status ->
            if status >= 500 then
                "The library is having trouble at its own end. Nothing is wrong with what you entered — please try again in a moment."

            else
                unknownFailureMessage mode

        _ ->
            unknownFailureMessage mode


{-| What to say when the app genuinely does not know what happened.

Named, rather than inlined into the two branches that need it, so that a future
branch cannot quietly get a _different_ unknown message — and so that this
sentence's one job is visible: to be helpful without asserting anything.

-}
unknownFailureMessage : Mode -> String
unknownFailureMessage mode =
    case mode of
        RegisterMode ->
            "Registration could not be completed, and we cannot say why. Please try again in a moment."

        _ ->
            "The door would not open, and we cannot say why. Your details may be perfectly correct. Please try again in a moment."
