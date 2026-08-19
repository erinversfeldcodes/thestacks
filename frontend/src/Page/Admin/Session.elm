module Page.Admin.Session exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , enrolmentSecret
    , init
    , initWithNotice
    , update
    , view
    )

{-| The admin sign-in gate — the module whose absence made every
admin page dead: `/api/admin/*` demands an MFA-verified `admin_session`
token (IP- and boot\_id-bound, 30-min MFA window), and the pages were
sending the ordinary token, 401ing every action. Two steps: password →
challenge, TOTP → admin token, held in memory only.
-}

import Api exposing (AdminAuthError(..), AdminMfaEnrolment)
import Html exposing (Html, button, div, form, h1, h2, input, label, li, ol, p, span, text)
import Html.Attributes exposing (attribute, autocomplete, class, disabled, for, id, type_, value)
import Html.Events exposing (onClick, onInput, onSubmit)
import Http
import Url
import Util.TestId exposing (testId)


{-| Where the operator is in the flow. Deliberately a union rather than a bag of `Maybe`s: the
credentials step and the code step ask for different things, and a model that could represent
"awaiting a code with no session id" would need a branch that cannot happen.
-}
type Step
    = Credentials
    | AwaitingCode String
    | Enrolling AdminMfaEnrolment


type alias Model =
    { step : Step
    , email : String
    , password : String
    , code : String
    , error : Maybe String
    , notice : Maybe String
    , busy : Bool
    }


type Msg
    = SetEmail String
    | SetPassword String
    | SetCode String
    | SubmitCredentials
    | LoggedIn (Result AdminAuthError Api.AdminSession)
    | SubmitCode
    | Verified (Result AdminAuthError String)
    | StartEnrolment
    | EnrolmentStarted (Result Http.Error AdminMfaEnrolment)
    | ConfirmEnrolment
    | EnrolmentConfirmed (Result Http.Error ())


type OutMsg
    = NoOut
    | Authenticated String


init : Model
init =
    { step = Credentials
    , email = ""
    , password = ""
    , code = ""
    , error = Nothing
    , notice = Nothing
    , busy = False
    }


{-| The gate, opened with something to say — the operator arrived here on
purpose (they ended their session) rather than by being turned away, and a form
with no explanation would read as the sign-in having failed.
-}
initWithNotice : String -> Model
initWithNotice notice =
    { init | notice = Just notice }


{-| The `secret=` parameter from an `otpauth://` provisioning URI, **base32, unmodified**.

`POST /api/admin/auth/mfa/confirm` takes it exactly as published — the endpoint was changed on
2026-07-29 to accept its own setup call's encoding, after demanding base64 that no client could
produce. Exposed so a test can assert the extraction without driving the whole flow.

-}
enrolmentSecret : AdminMfaEnrolment -> Maybe String
enrolmentSecret enrolment =
    enrolment.provisioningUri
        |> String.split "?"
        |> List.drop 1
        |> String.join "?"
        |> String.split "&"
        |> List.filterMap
            (\pair ->
                case String.split "=" pair of
                    "secret" :: rest ->
                        rest |> String.join "=" |> Url.percentDecode

                    _ ->
                        Nothing
            )
        |> List.head


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg, OutMsg )
update msg model ownerToken =
    case msg of
        SetEmail value ->
            ( { model | email = value }, Cmd.none, NoOut )

        SetPassword value ->
            ( { model | password = value }, Cmd.none, NoOut )

        SetCode value ->
            ( { model | code = value }, Cmd.none, NoOut )

        SubmitCredentials ->
            if String.isEmpty model.email || String.isEmpty model.password then
                ( model, Cmd.none, NoOut )

            else
                ( { model | busy = True, error = Nothing }
                , Api.adminLogin { email = model.email, password = model.password } LoggedIn
                , NoOut
                )

        LoggedIn (Ok session) ->
            ( { model | step = AwaitingCode session.sessionId, busy = False, password = "" }
            , Cmd.none
            , NoOut
            )

        LoggedIn (Err MfaNotEnrolled) ->
            ( { model | busy = False, error = Nothing, step = Credentials }
            , Cmd.none
            , NoOut
            )
                |> startEnrolmentIfPossible ownerToken

        LoggedIn (Err err) ->
            ( { model | busy = False, error = Just (authErrorMessage err) }, Cmd.none, NoOut )

        SubmitCode ->
            case model.step of
                AwaitingCode sessionId ->
                    if String.length (String.trim model.code) < 6 then
                        ( model, Cmd.none, NoOut )

                    else
                        ( { model | busy = True, error = Nothing }
                        , Api.adminVerifyMfa
                            { sessionId = sessionId, code = String.trim model.code }
                            Verified
                        , NoOut
                        )

                _ ->
                    ( model, Cmd.none, NoOut )

        Verified (Ok token) ->
            ( { model | busy = False, code = "" }, Cmd.none, Authenticated token )

        Verified (Err err) ->
            ( { model | busy = False, code = "", error = Just (authErrorMessage err) }
            , Cmd.none
            , NoOut
            )

        StartEnrolment ->
            ( { model | busy = True, error = Nothing }, Cmd.none, NoOut )
                |> startEnrolmentIfPossible ownerToken

        EnrolmentStarted (Ok enrolment) ->
            ( { model | step = Enrolling enrolment, busy = False }, Cmd.none, NoOut )

        EnrolmentStarted (Err _) ->
            ( { model | busy = False, error = Just "Could not start enrolment. Please try again." }
            , Cmd.none
            , NoOut
            )

        ConfirmEnrolment ->
            case ( model.step, ownerToken ) of
                ( Enrolling enrolment, Just token ) ->
                    case enrolmentSecret enrolment of
                        Just secret ->
                            ( { model | busy = True, error = Nothing }
                            , Api.adminMfaConfirm token
                                { code = String.trim model.code
                                , secret = secret
                                , recoveryCodes = enrolment.recoveryCodes
                                }
                                EnrolmentConfirmed
                            , NoOut
                            )

                        Nothing ->
                            ( { model | error = Just "That enrolment link looks malformed." }
                            , Cmd.none
                            , NoOut
                            )

                _ ->
                    ( model, Cmd.none, NoOut )

        EnrolmentConfirmed (Ok ()) ->
            ( { model
                | step = Credentials
                , busy = False
                , code = ""
                , error = Nothing
                , notice = Just "Your second factor is set up. Sign in to open an admin session."
              }
            , Cmd.none
            , NoOut
            )

        EnrolmentConfirmed (Err _) ->
            ( { model
                | busy = False
                , code = ""
                , error = Just "That code was not accepted. Check your authenticator and try again."
              }
            , Cmd.none
            , NoOut
            )


startEnrolmentIfPossible :
    Maybe String
    -> ( Model, Cmd Msg, OutMsg )
    -> ( Model, Cmd Msg, OutMsg )
startEnrolmentIfPossible ownerToken ( model, cmd, out ) =
    case ownerToken of
        Just token ->
            ( { model | busy = True }, Api.adminMfaSetup token EnrolmentStarted, out )

        Nothing ->
            ( { model
                | busy = False
                , error = Just "Sign in to The Stacks first, then return here."
              }
            , cmd
            , out
            )


{-| Each failure keeps the remedy the operator needs. "Something went wrong" would leave four very
different next actions indistinguishable.
-}
authErrorMessage : AdminAuthError -> String
authErrorMessage err =
    case err of
        InvalidCredentials ->
            "That email and password did not match."

        NotAnOwner ->
            "That account is not an owner, so it cannot hold an admin session."

        MfaNotEnrolled ->
            "This account has no second factor yet."

        InvalidCode ->
            "That code was not accepted. Codes expire every 30 seconds — try the current one."

        InvalidSession ->
            "That admin session is no longer valid — a network change or a deploy ends it. Start again."

        AlreadyVerified ->
            "That session is already verified. Reload the page."

        AdminAuthTransport Http.Timeout ->
            "The server took too long to answer. Try again."

        AdminAuthTransport Http.NetworkError ->
            "No connection to the server. Check your network, then try again."

        AdminAuthTransport _ ->
            "Could not reach the server. Please try again."


view : Model -> Html Msg
view model =
    div [ class "page page--admin admin-gate", testId "admin-gate" ]
        [ h1 [ class "page__title admin__title" ] [ text "Admin sign-in" ]
        , p [ class "admin__subtitle" ]
            [ text
                ("Admin surfaces need a second factor and a session of their own. Your ordinary "
                    ++ "session is untouched, and this one ends after 30 minutes."
                )
            ]
        , case model.notice of
            Just message ->
                p [ class "admin-gate__notice", testId "admin-gate-notice" ] [ text message ]

            Nothing ->
                text ""
        , case model.error of
            Just message ->
                p [ class "admin__error", testId "admin-gate-error" ] [ text message ]

            Nothing ->
                text ""
        , case model.step of
            Credentials ->
                viewCredentials model

            AwaitingCode _ ->
                viewCode model

            Enrolling enrolment ->
                viewEnrolling model enrolment
        ]


viewCredentials : Model -> Html Msg
viewCredentials model =
    form [ onSubmit SubmitCredentials ]
        [ div [ class "admin-gate__field" ]
            [ label [ for "admin-email" ] [ text "Owner email" ]
            , input
                [ id "admin-email"
                , type_ "email"
                , class "admin-gate__input"
                , value model.email
                , onInput SetEmail
                , autocomplete False
                , testId "admin-email"
                ]
                []
            ]
        , div [ class "admin-gate__field" ]
            [ label [ for "admin-password" ] [ text "Password" ]
            , input
                [ id "admin-password"
                , type_ "password"
                , class "admin-gate__input"
                , value model.password
                , onInput SetPassword
                , testId "admin-password"
                ]
                []
            ]
        , button
            [ type_ "submit"
            , class "admin-gate__submit"
            , disabled (model.busy || String.isEmpty model.email || String.isEmpty model.password)
            , testId "admin-continue"
            ]
            [ text
                (if model.busy then
                    "Checking…"

                 else
                    "Continue"
                )
            ]
        , button
            [ type_ "button"
            , class "admin-gate__secondary"
            , onClick StartEnrolment
            , disabled model.busy
            , testId "admin-enrol-start"
            ]
            [ text "Set up a second factor" ]
        ]


viewCode : Model -> Html Msg
viewCode model =
    form [ onSubmit SubmitCode ]
        [ p [ class "admin-gate__hint" ]
            [ text "Enter the current code from your authenticator." ]
        , div [ class "admin-gate__field" ]
            [ label [ for "admin-code" ] [ text "Six-digit code" ]
            , input
                [ id "admin-code"
                , type_ "text"
                , class "admin-gate__input admin-gate__input--code"
                , value model.code
                , onInput SetCode
                , autocomplete False
                , attribute "inputmode" "numeric"
                , attribute "maxlength" "6"
                , testId "admin-code"
                ]
                []
            ]
        , button
            [ type_ "submit"
            , class "admin-gate__submit"
            , disabled (model.busy || String.length (String.trim model.code) < 6)
            , testId "admin-verify"
            ]
            [ text
                (if model.busy then
                    "Verifying…"

                 else
                    "Verify"
                )
            ]
        ]


{-| Enrolment. The recovery codes are shown once and never again, so the copy says so plainly.
-}
viewEnrolling : Model -> AdminMfaEnrolment -> Html Msg
viewEnrolling model enrolment =
    form [ onSubmit ConfirmEnrolment, testId "admin-enrolling" ]
        [ h2 [ class "admin-gate__step" ] [ text "Set up your second factor" ]
        , p [ class "admin-gate__hint" ]
            [ text "Add this secret to your authenticator app, then enter the code it shows." ]
        , div [ class "admin-gate__secret", testId "admin-enrolment-secret" ]
            [ text (Maybe.withDefault "—" (enrolmentSecret enrolment)) ]
        , p [ class "admin-gate__hint admin-gate__hint--warning" ]
            [ text "Write these recovery codes down now. They are not shown again." ]
        , ol [ class "admin-gate__recovery", testId "admin-recovery-codes" ]
            (List.map (\c -> li [] [ span [ class "admin-gate__recovery-code" ] [ text c ] ])
                enrolment.recoveryCodes
            )
        , div [ class "admin-gate__field" ]
            [ label [ for "admin-enrol-code" ] [ text "Code from your authenticator" ]
            , input
                [ id "admin-enrol-code"
                , type_ "text"
                , class "admin-gate__input admin-gate__input--code"
                , value model.code
                , onInput SetCode
                , autocomplete False
                , attribute "inputmode" "numeric"
                , attribute "maxlength" "6"
                , testId "admin-enrol-code"
                ]
                []
            ]
        , button
            [ type_ "submit"
            , class "admin-gate__submit"
            , disabled (model.busy || String.length (String.trim model.code) < 6)
            , testId "admin-enrol-confirm"
            ]
            [ text
                (if model.busy then
                    "Confirming…"

                 else
                    "Confirm"
                )
            ]
        ]
