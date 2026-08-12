module Page.ResetPassword exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , advanceDelayMs
    , init
    , update
    , view
    )

import Api
import Html exposing (Html, a, button, div, h1, input, label, p, text)
import Html.Attributes exposing (attribute, class, disabled, for, href, id, placeholder, type_, value)
import Html.Events exposing (onClick, onInput)
import Http
import Navigation.Route as Route
import Process
import Task
import Types.PasswordRule as PasswordRule
import Types.RemoteData exposing (RemoteData(..))
import Util.TestId exposing (testId)


type alias Model =
    { token : String
    , password : String
    , confirmPassword : String
    , submitting : RemoteData Http.Error ()
    }


type Msg
    = SetPassword String
    | SetConfirmPassword String
    | Submit
    | Completed (Result Http.Error ())
    | AdvanceToSignIn


{-| What this page needs `Main` to do, because it cannot do it itself: the
navigation key lives up there.

`AdvanceToLogin` is raised once, `advanceDelayMs` after a successful reset, so
the reader is carried to the sign-in card rather than left on a dead page holding
a link. `Main.resetPasswordDestination` is the only thing that reads it.

-}
type OutMsg
    = NoOut
    | AdvanceToLogin


{-| How long the "your password has been reset" confirmation stays on screen
before the page carries the reader to sign in.

Long enough to read a six-word sentence and notice the page changed under them —
an instant redirect reads as "nothing happened, and now I am somewhere else".
The "Sign in" link stays on screen throughout, so this is a floor on how long the
confirmation is visible, never a wait imposed on anyone.

-}
advanceDelayMs : Float
advanceDelayMs =
    2000


init : String -> Model
init token =
    { token = token
    , password = ""
    , confirmPassword = ""
    , submitting = NotAsked
    }


{-| A blocking validation error, or Nothing when the form may be submitted.
-}
validate : Model -> Maybe String
validate model =
    if not (PasswordRule.isLongEnough model.password) then
        Just PasswordRule.tooShort

    else if model.password /= model.confirmPassword then
        Just "Passwords do not match."

    else
        Nothing


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        SetPassword val ->
            ( { model | password = val, submitting = clearStaleError model.submitting }
            , Cmd.none
            , NoOut
            )

        SetConfirmPassword val ->
            ( { model | confirmPassword = val, submitting = clearStaleError model.submitting }
            , Cmd.none
            , NoOut
            )

        Submit ->
            case ( model.submitting, validate model ) of
                ( Loading, _ ) ->
                    ( model, Cmd.none, NoOut )

                ( Success _, _ ) ->
                    ( model, Cmd.none, NoOut )

                ( _, Just _ ) ->
                    ( model, Cmd.none, NoOut )

                ( _, Nothing ) ->
                    ( { model | submitting = Loading }
                    , Api.resetPassword
                        { token = model.token, password = model.password }
                        Completed
                    , NoOut
                    )

        Completed result ->
            case ( model.submitting, result ) of
                ( Success _, _ ) ->
                    ( model, Cmd.none, NoOut )

                ( _, Ok _ ) ->
                    ( { model | submitting = Success () }
                    , Process.sleep advanceDelayMs |> Task.perform (\_ -> AdvanceToSignIn)
                    , NoOut
                    )

                ( _, Err err ) ->
                    ( { model | submitting = Failure err }, Cmd.none, NoOut )

        AdvanceToSignIn ->
            case model.submitting of
                Success _ ->
                    ( model, Cmd.none, AdvanceToLogin )

                _ ->
                    ( model, Cmd.none, NoOut )


{-| Typing in a field clears a STALE ERROR and nothing else.

⛔ The old flat `submitting = NotAsked` on every keystroke let the
keyboard undo a finished request: correcting a character while the
request was in flight re-enabled submit against a token the in-flight
request was about to consume. Only `Failure` resets; `Loading` and
`Success` are immune to keystrokes.

-}
clearStaleError : RemoteData Http.Error () -> RemoteData Http.Error ()
clearStaleError submitting =
    case submitting of
        Failure _ ->
            NotAsked

        other ->
            other


view : Model -> Html Msg
view model =
    div [ class "page page--login" ]
        [ div [ class "layer-arrival" ] []
        , div [ class "layer-bookshelf" ] []
        , div [ class "layer-bookshelf-dim" ] []
        , div [ class "layer-vignette" ] []
        , div [ class "login-overlay" ]
            [ div [ class "login-card" ]
                [ h1 [ class "login-card__title" ] [ text "Choose a new password" ]
                , case model.submitting of
                    Success _ ->
                        div [ testId "reset-success" ]
                            [ p
                                [ class "login-card__notice"
                                , attribute "role" "status"
                                ]
                                [ text "Your password has been reset. Taking you to sign in…" ]
                            , a
                                [ class "btn btn--primary"
                                , href (Route.toPath Route.Login)
                                , testId "reset-login-link"
                                ]
                                [ text "Sign in" ]
                            ]

                    _ ->
                        viewForm model
                ]
            ]
        ]


viewForm : Model -> Html Msg
viewForm model =
    let
        validationError =
            if
                model.submitting
                    == NotAsked
                    && (not (String.isEmpty model.password) || not (String.isEmpty model.confirmPassword))
            then
                validate model

            else
                Nothing
    in
    div []
        [ div [ class "login-card__field" ]
            [ label [ class "login-card__label", for "reset-password" ] [ text "New password" ]
            , input
                [ id "reset-password"
                , type_ "password"
                , class "login-card__input"
                , value model.password
                , onInput SetPassword
                , placeholder PasswordRule.requirementHint
                , testId "reset-password"
                ]
                []
            ]
        , div [ class "login-card__field" ]
            [ label [ class "login-card__label", for "reset-confirm" ] [ text "Confirm new password" ]
            , input
                [ id "reset-confirm"
                , type_ "password"
                , class "login-card__input"
                , value model.confirmPassword
                , onInput SetConfirmPassword
                , placeholder "Repeat new password"
                , testId "reset-confirm"
                ]
                []
            ]
        , case validationError of
            Just errMsg ->
                p [ class "login-card__error" ] [ text errMsg ]

            Nothing ->
                text ""
        , case model.submitting of
            Loading ->
                button [ class "login-card__submit", disabled True ]
                    [ text "Resetting..." ]

            _ ->
                button [ class "login-card__submit", onClick Submit, testId "reset-submit" ]
                    [ text "Reset password" ]
        , case model.submitting of
            Failure (Http.BadStatus 400) ->
                p [ class "login-card__error", testId "reset-error" ]
                    [ text "This reset link is invalid or has expired. Request a new one." ]

            Failure (Http.BadStatus 422) ->
                p [ class "login-card__error", testId "reset-error" ]
                    [ text PasswordRule.tooShort ]

            Failure _ ->
                p [ class "login-card__error", testId "reset-error" ]
                    [ text "Something went wrong. Please try again." ]

            _ ->
                text ""
        ]
