module Components.AdminChrome exposing (Model, Msg(..), OutMsg(..), init, update, updateWithEffect, view)

{-| The strip of chrome every admin surface wears, and the one place an admin
session can be ended on purpose.

⛔ An admin session used to have no way OUT. `DELETE /api/admin/auth/logout`
was routed and revoked properly, and nothing called it: the token was held in
memory, so the only ways to be rid of one were to wait out the 30-minute window
or to close the tab — neither of which revokes anything server-side. An
operator who finished a task and walked away left a live admin session behind
them.

The affordance is deliberately quiet — admin surfaces are a workspace, not a
place that should shout — but it is on every one of them, so it is never more
than a glance away from wherever the work happened.

@docs Model, Msg, OutMsg, init, update, updateWithEffect, view

-}

import Api
import Effect exposing (Effect)
import Html exposing (Html, button, div, p, span, text)
import Html.Attributes exposing (class, disabled, type_)
import Html.Events exposing (onClick)
import Http
import Util.TestId exposing (testId)


{-| `ending` is in flight, not "ended" — the session is over only once the
server says the token is revoked, and `Main` learns that through `OutMsg`.
-}
type alias Model =
    { ending : Bool
    , error : Maybe String
    }


{-| -}
type Msg
    = EndSession
    | Ended (Http.Response String)


{-| What the chrome needs `Main` to do. The chrome cannot drop the admin token
itself — `Main` owns it — so ending a session is a request, made only once the
server has actually revoked it.
-}
type OutMsg
    = NoOut
    | SessionEnded


{-| -}
init : Model
init =
    { ending = False, error = Nothing }


{-| `updateWithEffect` composed with `Effect.perform`.
-}
update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg, OutMsg )
update msg model adminToken =
    let
        ( newModel, effect, out ) =
            updateWithEffect msg model adminToken
    in
    ( newModel, Effect.perform effect, out )


{-| `update`, with its effect as data, so a program test reads the request this
decides on rather than deciding a second time by hand.

⚠️ A transport failure keeps the token and says so. Clearing local state on a
revoke that never landed is the ORIGINAL defect wearing a button: the operator
would be told the session had ended while it stayed open server-side for the
rest of its window. A 401 is the one failure that does end it — the token is
already gone — so it re-gates rather than nagging.

-}
updateWithEffect : Msg -> Model -> Maybe String -> ( Model, Effect Msg, OutMsg )
updateWithEffect msg model adminToken =
    case msg of
        EndSession ->
            case ( model.ending, adminToken ) of
                ( True, _ ) ->
                    ( model, Effect.none, NoOut )

                ( False, Just token ) ->
                    ( { model | ending = True, error = Nothing }
                    , Effect.authed Api.adminLogoutRequest token Ended
                    , NoOut
                    )

                ( False, Nothing ) ->
                    -- No token to revoke: whatever put the operator here, the
                    -- session is already not usable. Re-gate instead of
                    -- sending an unauthenticated request that would 401.
                    ( init, Effect.none, SessionEnded )

        Ended response ->
            case response of
                Http.GoodStatus_ _ _ ->
                    ( init, Effect.none, SessionEnded )

                Http.BadStatus_ metadata _ ->
                    if metadata.statusCode == 401 then
                        ( init, Effect.none, SessionEnded )

                    else
                        ( { model | ending = False, error = Just serverRefused }
                        , Effect.none
                        , NoOut
                        )

                _ ->
                    ( { model | ending = False, error = Just didNotArrive }
                    , Effect.none
                    , NoOut
                    )


serverRefused : String
serverRefused =
    "The server would not end this admin session. It is still open — try again."


didNotArrive : String
didNotArrive =
    "That did not reach the server, so this admin session is still open. Check your connection and try again."


{-| Wrap an admin page in its chrome. Takes the caller's own `Msg` wrapper, so
the page's messages and the chrome's travel the same route to `Main` without
the chrome having to know what a page is.
-}
view : (Msg -> msg) -> Model -> Html msg -> Html msg
view toSelf model content =
    div [ testId "admin-surface" ]
        [ Html.map toSelf (viewBar model)
        , content
        ]


viewBar : Model -> Html Msg
viewBar model =
    div [ class "admin-surface__bar" ]
        [ span [ class "admin-surface__label" ] [ text "Admin session" ]
        , button
            [ type_ "button"
            , class "admin-surface__end"
            , onClick EndSession
            , disabled model.ending
            , testId "admin-end-session"
            ]
            [ text
                (if model.ending then
                    "Ending…"

                 else
                    "End admin session"
                )
            ]
        , case model.error of
            Just message ->
                p
                    [ class "admin-surface__error"
                    , testId "admin-end-session-error"
                    ]
                    [ text message ]

            Nothing ->
                text ""
        ]
