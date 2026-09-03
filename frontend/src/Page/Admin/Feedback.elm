module Page.Admin.Feedback exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

{-| The owner's feedback queue — the only surface in the SPA that renders what
readers wrote.

An empty queue and a failed load are drawn differently on purpose. "Nobody has
written yet" and "we could not ask" look identical if both fall through to the
same blank panel, and the second one silently reads as the first — which is how
a broken admin page goes unnoticed for a week.

-}

import Api exposing (AdminFeedbackEntry)
import Html exposing (Html, div, h1, li, p, span, text, ul)
import Html.Attributes exposing (class)
import Http
import Types.RemoteData exposing (RemoteData(..))
import Util.TestId exposing (testId)


type alias Model =
    { entries : RemoteData Http.Error (List AdminFeedbackEntry)
    }


type Msg
    = EntriesReceived (Result Http.Error (List AdminFeedbackEntry))


type OutMsg
    = NoOut
    | SessionExpired


init : Maybe String -> ( Model, Cmd Msg )
init maybeToken =
    ( { entries = Loading }
    , case maybeToken of
        Just token ->
            Api.getAdminFeedback token EntriesReceived

        Nothing ->
            Cmd.none
    )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        EntriesReceived (Ok entries) ->
            ( { model | entries = Success entries }, Cmd.none, NoOut )

        EntriesReceived (Err err) ->
            if Api.isUnauthorized err then
                ( model, Cmd.none, SessionExpired )

            else
                ( { model | entries = Failure err }, Cmd.none, NoOut )


view : Model -> Html Msg
view model =
    div [ class "page page--admin" ]
        [ h1 [ class "page__title" ] [ text "Feedback" ]
        , case model.entries of
            Success [] ->
                p [ class "admin__empty", testId "admin-feedback-empty" ]
                    [ text "Nothing has come in yet." ]

            Success entries ->
                ul [ class "admin-feedback__list" ] (List.map viewEntry entries)

            Failure _ ->
                p [ class "admin__error", testId "admin-feedback-error" ]
                    [ text "Could not load the feedback." ]

            _ ->
                p [ class "admin__loading" ] [ text "Loading…" ]
        ]


viewEntry : AdminFeedbackEntry -> Html Msg
viewEntry entry =
    li [ class "admin-feedback__entry", testId "admin-feedback-entry" ]
        [ div [ class "admin-feedback__meta" ]
            [ span [ class "admin-feedback__sender" ] [ text (senderLabel entry) ]
            , span [ class "admin-feedback__context" ] [ text (contextLabel entry) ]
            , span [ class "admin-feedback__when" ] [ text entry.createdAt ]
            ]
        , p [ class "admin-feedback__body" ] [ text entry.body ]
        ]


senderLabel : AdminFeedbackEntry -> String
senderLabel entry =
    case entry.senderHandle of
        Just handle ->
            "@" ++ handle

        Nothing ->
            "no handle"


contextLabel : AdminFeedbackEntry -> String
contextLabel entry =
    case entry.pageContext of
        Just context ->
            context

        Nothing ->
            "—"
