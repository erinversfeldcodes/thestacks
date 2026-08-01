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
            -- One request per press of the button. `Loading` and `Success` are
            -- both already-decided states; re-submitting from either is what
            -- burned the single-use token underneath a reset that had already
            -- worked (see `clearStaleError`).
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
                -- ⛔ A success is FINAL. Nothing that arrives afterwards may
                -- overwrite it — not a late response, not a duplicate. The
                -- reader has been told their password is reset; the one thing
                -- this page must never do is take that back.
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
            -- Only from a success. The timer is only ever started by one, but a
            -- message that can be delivered late must not assume the state it
            -- was scheduled in still holds.
            case model.submitting of
                Success _ ->
                    ( model, Cmd.none, AdvanceToLogin )

                _ ->
                    ( model, Cmd.none, NoOut )


{-| What typing in a field does to the request state: it clears a **stale error**
and nothing else.

⛔ This used to be a flat `submitting = NotAsked` on every keystroke, and that is
a state machine in which a finished request can be undone by the keyboard.

The reachable damage was on the `Loading` branch, because that is the state in
which the form is still on screen. Press "Reset password"; while the request is
in flight, correct a character in the confirm field; `submitting` drops to
`NotAsked`, the button un-disables itself and reads "Reset password" again. Press
it a second time and there are two requests against a **single-use** token. The
first returns 200 → "Your password has been reset." The second returns 400 →
"This reset link is invalid or has expired. Request a new one." — replacing the
confirmation, on a page where the reset genuinely succeeded. The reader is told
it worked and then told it did not, and the message they are left holding is the
false one.

`NotAsked` and `Loading` are therefore left alone: neither is an error, and
neither is something an edit should be able to revoke. `Success` is left alone
for the reason in `Completed` above.

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
    -- Reuse the login page's static scene (library background + dim + vignette)
    -- and centre the card in its overlay, so the reset page reached from the
    -- email link matches the login card. The animated door layers/ports are
    -- login-only, so this renders the background statically — no animation.
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
