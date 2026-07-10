module Page.Login exposing
    ( FieldValidation(..)
    , Mode(..)
    , Model
    , Msg(..)
    , OutMsg(..)
    , SubmitError(..)
    , TransitionState(..)
    , errorMessage
    , expiredInit
    , init
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
    , submitState : RemoteData SubmitError AuthResponse
    , transitionState : TransitionState
    , emailValidation : FieldValidation
    , passwordValidation : FieldValidation
    , passwordConfirmValidation : FieldValidation
    , displayNameValidation : FieldValidation

    -- Set by the global session-expiry interceptor (Issue #173) when the user is
    -- redirected here after their token expired/was revoked. Drives a notice
    -- distinct from invalid-credentials, and is cleared once they interact.
    , sessionExpired : Bool
    }


type Mode
    = LoginMode
    | RegisterMode
    | RegistrationPending String


{-| A failed submission. Login failures are always transport/status errors;
registration can additionally fail with structured per-field validation errors
(a 422 body), which we keep so the message reflects the real cause.
-}
type SubmitError
    = SubmitHttpError Http.Error
    | SubmitValidationError (List ( String, List String ))


type TransitionState
    = Idle
    | Transitioning
    | Complete


type Msg
    = EmailChanged String
    | PasswordChanged String
    | PasswordConfirmChanged String
    | DisplayNameChanged String
    | ModeSwitched Mode
    | FormSubmitted
    | GotAuthResponse (Result Http.Error AuthResponse)
    | GotRegisterResponse (Result RegisterError ())
    | TransitionCompleted AuthResponse


type OutMsg
    = NoOut
    | StartTransition AuthResponse
    | LoggedIn AuthResponse
    | RegistrationSucceeded String


init : Model
init =
    { email = ""
    , password = ""
    , passwordConfirm = ""
    , displayName = ""
    , mode = LoginMode
    , submitState = NotAsked
    , transitionState = Idle
    , emailValidation = Pristine
    , passwordValidation = Pristine
    , passwordConfirmValidation = Pristine
    , displayNameValidation = Pristine
    , sessionExpired = False
    }


{-| Initial login state to show after a global session-expiry redirect: identical
to `init` but with the session-expired notice raised. See `Main.sessionExpired`.
-}
expiredInit : Model
expiredInit =
    { init | sessionExpired = True }


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

    else if String.length password >= 8 then
        Valid

    else
        Invalid "Password must be at least 8 characters"


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
                , sessionExpired = False
              }
            , Cmd.none
            , NoOut
            )

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
            in
            ( { model | submitState = Loading, sessionExpired = False }, cmd, NoOut )

        GotAuthResponse (Ok authResponse) ->
            ( { model | submitState = Success authResponse, transitionState = Transitioning }
            , Cmd.none
            , StartTransition authResponse
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

        TransitionCompleted authResponse ->
            ( { model | transitionState = Complete }
            , Cmd.none
            , LoggedIn authResponse
            )


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
        [ h1 [ class "login-card__title" ] [ text "The Stacks" ]
        , p [ class "login-card__subtitle" ]
            [ text
                (case model.mode of
                    RegisterMode ->
                        "Register for entry to the collection"

                    LoginMode ->
                        "Present your credentials to enter"

                    RegistrationPending _ ->
                        "Present your credentials to enter"
                )
            ]
        , viewSessionExpiredNotice model
        , div
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

                _ ->
                    text
                        (case model.mode of
                            RegisterMode ->
                                "Request Entry"

                            LoginMode ->
                                "Enter the Stacks"

                            RegistrationPending _ ->
                                "Enter the Stacks"
                        )
            ]
        ]


isSubmitDisabled : Model -> Bool
isSubmitDisabled model =
    let
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

                RegistrationPending _ ->
                    True
    in
    model.submitState == Loading || model.transitionState /= Idle || fieldsInvalid


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


{-| Notice shown when the user was redirected here by the global session-expiry
interceptor (Issue #173). Deliberately distinct from the invalid-credentials
error so an expired session reads differently from a wrong password. Suppressed
once a submit failure is showing so the more-specific message wins.
-}
viewSessionExpiredNotice : Model -> Html Msg
viewSessionExpiredNotice model =
    let
        submitFailed =
            case model.submitState of
                Failure _ ->
                    True

                _ ->
                    False
    in
    if model.sessionExpired && model.mode == LoginMode && not submitFailed then
        div
            [ attribute "role" "status"
            , class "login-card__notice login-card__notice--session-expired"
            , testId "session-expired-notice"
            ]
            [ text "The library closed your session for safekeeping — sign in again to return." ]

    else
        text ""


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
        "That password is too slight; please choose at least eight characters."

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

                LoginMode ->
                    "Please ensure all fields are properly filled."

                RegistrationPending _ ->
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

                LoginMode ->
                    "The door remains shut. Invalid email or password."

                RegistrationPending _ ->
                    "The door remains shut. Invalid email or password."
