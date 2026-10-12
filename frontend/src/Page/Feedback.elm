module Page.Feedback exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

{-| The reader's end of the beta feedback channel: a box, a send button, and
an honest answer about where it went.

Two things here are load-bearing rather than decorative.

The first is that a failed send **keeps the draft**. Discarding someone's bug
report because the network dropped would punish the diligence the channel
exists to collect, so `SendCompleted (Err _)` leaves `message` untouched and
says the words are still there.

The second is that success says what actually happened and nothing more. There
is no ticket number, because a number implies a queue with someone working it
to a deadline, and a one-person beta has no such thing. Inventing one would be
exactly the small dishonesty a feedback form is supposed to be the cure for.

-}

import Api
import Html exposing (Html, button, div, h1, label, p, text, textarea)
import Html.Attributes exposing (class, disabled, for, id, placeholder, value)
import Html.Events exposing (onClick, onInput)
import Http
import Types.RemoteData exposing (RemoteData(..))
import Util.TestId exposing (testId)


{-| The longest message the server will take. Kept in step with the context's
own cap so the reader learns about the limit here rather than from a 422.
-}
maxLength : Int
maxLength =
    5000


type alias Model =
    { message : String
    , pageContext : String
    , sending : RemoteData Http.Error ()
    }


type Msg
    = MessageChanged String
    | SendClicked
    | SendCompleted (Result Http.Error ())
    | SessionExpiryDetected


type OutMsg
    = NoOut
    | SessionExpired


{-| `pageContext` is where the reader came from, passed in by `Main` — a short
label, never a path. A path would carry ids and other readers' handles into a
support record, which is not what a bug report needs to be reproducible.
-}
init : String -> Model
init pageContext =
    { message = ""
    , pageContext = pageContext
    , sending = NotAsked
    }


isSendable : Model -> Bool
isSendable model =
    let
        trimmed =
            String.trim model.message
    in
    not (String.isEmpty trimmed)
        && (String.length trimmed <= maxLength)
        && (model.sending /= Loading)


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg, OutMsg )
update msg model maybeToken =
    case msg of
        MessageChanged value ->
            ( { model | message = value, sending = NotAsked }, Cmd.none, NoOut )

        SendClicked ->
            case ( isSendable model, maybeToken ) of
                ( True, Just token ) ->
                    ( { model | sending = Loading }
                    , Api.sendFeedback
                        { body = String.trim model.message
                        , pageContext = model.pageContext
                        }
                        (Api.authed token
                            { onExpired = SessionExpiryDetected
                            , onResult = SendCompleted
                            }
                        )
                    , NoOut
                    )

                _ ->
                    ( model, Cmd.none, NoOut )

        SendCompleted (Ok ()) ->
            ( { model | message = "", sending = Success () }, Cmd.none, NoOut )

        -- The draft survives. See the module comment: a lost network is not a
        -- reason to throw away what someone took the trouble to write.
        SendCompleted (Err err) ->
            ( { model | sending = Failure err }, Cmd.none, NoOut )

        SessionExpiryDetected ->
            ( model, Cmd.none, SessionExpired )


view : Model -> Html Msg
view model =
    div [ class "page page--feedback" ]
        [ h1 [ class "page__title" ] [ text "Tell us" ]
        , p [ class "feedback__lede" ]
            [ text "You're one of a small number of people using this while it's still being built. What you notice is the most useful thing we have." ]
        , div [ class "feedback__form" ]
            [ label [ class "feedback__label", for "feedback-message" ]
                [ text "What happened?" ]
            , textarea
                [ id "feedback-message"
                , class "feedback__message"
                , testId "feedback-message"
                , placeholder "As much or as little as you like."
                , value model.message
                , onInput MessageChanged
                ]
                []
            , viewLengthWarning model
            , button
                [ class "feedback__send"
                , testId "feedback-send"
                , onClick SendClicked
                , disabled (not (isSendable model))
                ]
                [ text
                    (if model.sending == Loading then
                        "Sending…"

                     else
                        "Send"
                    )
                ]
            , viewOutcome model.sending
            ]
        ]


viewLengthWarning : Model -> Html Msg
viewLengthWarning model =
    if String.length (String.trim model.message) > maxLength then
        p [ class "feedback__count feedback__count--over", testId "feedback-too-long" ]
            [ text "That's longer than we can take — 5,000 characters. Could you send the shorter version, or two?" ]

    else
        text ""


{-| Every branch says something true. `NotAsked` says nothing at all, which is
also true, and is why the acknowledgement cannot be mistaken for a default.
-}
viewOutcome : RemoteData Http.Error () -> Html Msg
viewOutcome sending =
    case sending of
        Success () ->
            p [ class "feedback__outcome feedback__outcome--sent", testId "feedback-sent" ]
                [ text "Read and filed. Thank you — if it's a bug, it's now on a list with a person looking at it." ]

        Failure (Http.BadStatus 429) ->
            p [ class "feedback__outcome feedback__outcome--failed", testId "feedback-failed" ]
                [ text "You've sent a few already — thank you, genuinely. Try again in a little while; your message is still here." ]

        Failure _ ->
            p [ class "feedback__outcome feedback__outcome--failed", testId "feedback-failed" ]
                [ text "That didn't get through. Your message is still here — try again when you're back online." ]

        _ ->
            text ""
