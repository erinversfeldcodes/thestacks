module Page.Settings.AuditLog exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

{-| Read-only audit-log page.

Lists the authenticated user's own audit history (action, resource, and
timestamp) fetched from `GET /api/settings/audit-log`. Metadata is decrypted
server-side; hashed IPs are never sent to the client.

-}

import Api exposing (AuditLogEntry, AuditLogResponse)
import Html exposing (Html, div, h1, p, span, table, tbody, td, text, th, thead, tr)
import Html.Attributes exposing (class)
import Http
import Types.RemoteData exposing (RemoteData(..))


type alias Model =
    { entries : RemoteData Http.Error AuditLogResponse
    }


type Msg
    = AuditLogReceived (Result Http.Error AuditLogResponse)


type OutMsg
    = NoOut
    | SessionExpired


init : Maybe String -> ( Model, Cmd Msg )
init maybeToken =
    case maybeToken of
        Just token ->
            ( { entries = Loading }
            , Api.getAuditLog token AuditLogReceived
            )

        Nothing ->
            ( { entries = NotAsked }, Cmd.none )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        AuditLogReceived result ->
            case result of
                Ok response ->
                    ( { model | entries = Success response }, Cmd.none, NoOut )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | entries = Failure err }, Cmd.none, NoOut )


view : Model -> Html Msg
view model =
    div [ class "page page--settings" ]
        [ h1 [ class "page__title" ] [ text "Audit Log" ]
        , p [ class "settings-section__desc" ]
            [ text "A record of significant actions on your account, most recent first." ]
        , viewContent model
        ]


viewContent : Model -> Html Msg
viewContent model =
    case model.entries of
        NotAsked ->
            text ""

        Loading ->
            div [ class "loading" ] [ text "Loading your audit log..." ]

        Failure _ ->
            p [ class "error" ] [ text "Failed to load your audit log. Please try again." ]

        Success response ->
            if List.isEmpty response.entries then
                div [ class "audit-log__empty" ]
                    [ p [] [ text "No audit entries yet." ] ]

            else
                table [ class "audit-log__table" ]
                    [ thead []
                        [ tr []
                            [ th [] [ text "Action" ]
                            , th [] [ text "Resource" ]
                            , th [] [ text "When" ]
                            ]
                        ]
                    , tbody []
                        (List.map viewRow response.entries)
                    ]


viewRow : AuditLogEntry -> Html Msg
viewRow entry =
    tr [ class "audit-log__row" ]
        [ td [ class "audit-log__action" ] [ text entry.action ]
        , td [ class "audit-log__resource" ] [ text entry.resourceType ]
        , td [ class "audit-log__when" ]
            [ span [ class "audit-log__timestamp" ] [ text entry.occurredAt ] ]
        ]
