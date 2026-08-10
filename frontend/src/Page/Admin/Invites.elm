module Page.Admin.Invites exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

{-| The owner's invitation desk (US-14.1.3): write an invitation, hand out the
code, revoke one, and see who came in.

The load-bearing property is the **show-once reveal**: the full code exists in
the clear only in the create response, is rendered once in a bordered block
with a copy affordance, and is gone the moment the owner writes another or
leaves — the list below only ever shows `code_prefix`. There is no way to ask
the server for it again, and this page must not pretend otherwise.

-}

import Api exposing (AdminInvite)
import Html exposing (Html, button, code, div, h1, h2, input, label, p, span, table, tbody, td, text, th, thead, tr)
import Html.Attributes exposing (class, disabled, for, id, placeholder, type_, value)
import Html.Events exposing (onClick, onInput)
import Http
import Types.RemoteData exposing (RemoteData(..))
import Util.TestId exposing (testId)


type alias Model =
    { invites : RemoteData Http.Error (List AdminInvite)

    -- The create form. `expiresInDays` stays a raw string so a half-typed
    -- number is not silently coerced; it parses at submit.
    , note : String
    , invitedEmail : String
    , maxUses : String
    , expiresInDays : String
    , creating : Bool

    -- The one place the full code ever appears (see the moduledoc).
    , revealed : Maybe ( AdminInvite, String )
    , revoking : Maybe String
    , error : Maybe String
    }


type Msg
    = InvitesReceived (Result Http.Error (List AdminInvite))
    | NoteChanged String
    | InvitedEmailChanged String
    | MaxUsesChanged String
    | ExpiresInDaysChanged String
    | CreateClicked
    | CreateCompleted (Result Http.Error ( AdminInvite, String ))
    | RevokeClicked String
    | RevokeCompleted (Result Http.Error ())


type OutMsg
    = NoOut
    | SessionExpired


init : Maybe String -> ( Model, Cmd Msg )
init maybeToken =
    ( { invites = Loading
      , note = ""
      , invitedEmail = ""
      , maxUses = "1"
      , expiresInDays = "30"
      , creating = False
      , revealed = Nothing
      , revoking = Nothing
      , error = Nothing
      }
    , fetch maybeToken
    )


fetch : Maybe String -> Cmd Msg
fetch maybeToken =
    case maybeToken of
        Just token ->
            Api.getAdminInvites token InvitesReceived

        Nothing ->
            Cmd.none


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg, OutMsg )
update msg model maybeToken =
    case msg of
        InvitesReceived (Ok invites) ->
            ( { model | invites = Success invites }, Cmd.none, NoOut )

        InvitesReceived (Err err) ->
            if Api.isUnauthorized err then
                ( model, Cmd.none, SessionExpired )

            else
                ( { model | invites = Failure err }, Cmd.none, NoOut )

        NoteChanged value ->
            ( { model | note = value }, Cmd.none, NoOut )

        InvitedEmailChanged value ->
            ( { model | invitedEmail = value }, Cmd.none, NoOut )

        MaxUsesChanged value ->
            ( { model | maxUses = value }, Cmd.none, NoOut )

        ExpiresInDaysChanged value ->
            ( { model | expiresInDays = value }, Cmd.none, NoOut )

        CreateClicked ->
            case maybeToken of
                Just token ->
                    ( { model | creating = True, error = Nothing }
                    , Api.createAdminInvite token
                        { note = model.note
                        , invitedEmail = model.invitedEmail
                        , maxUses = model.maxUses |> String.toInt |> Maybe.withDefault 1
                        , expiresInDays = String.toInt model.expiresInDays
                        }
                        CreateCompleted
                    , NoOut
                    )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        CreateCompleted (Ok ( invite, fullCode )) ->
            -- Prepend locally AND hold the reveal; a refetch would not carry
            -- the code, which exists only in this response.
            ( { model
                | creating = False
                , revealed = Just ( invite, fullCode )
                , note = ""
                , invitedEmail = ""
                , invites = Types.RemoteData.map (\invites -> invite :: invites) model.invites
              }
            , Cmd.none
            , NoOut
            )

        CreateCompleted (Err err) ->
            if Api.isUnauthorized err then
                ( model, Cmd.none, SessionExpired )

            else
                ( { model | creating = False, error = Just "Could not write the invitation." }
                , Cmd.none
                , NoOut
                )

        RevokeClicked inviteId ->
            case maybeToken of
                Just token ->
                    ( { model | revoking = Just inviteId, error = Nothing }
                    , Api.revokeAdminInvite token inviteId RevokeCompleted
                    , NoOut
                    )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        RevokeCompleted (Ok ()) ->
            -- Refetch: revocation is a timestamp the server wrote, and the row
            -- must now render exactly what the server holds.
            ( { model | revoking = Nothing }, fetch maybeToken, NoOut )

        RevokeCompleted (Err err) ->
            if Api.isUnauthorized err then
                ( model, Cmd.none, SessionExpired )

            else
                ( { model | revoking = Nothing, error = Just "Could not revoke the invitation." }
                , Cmd.none
                , NoOut
                )


view : Model -> Html Msg
view model =
    div [ class "admin-invites", testId "admin-invites-page" ]
        [ h1 [ class "admin-invites__title" ] [ text "Invitations" ]
        , viewCreateForm model
        , viewReveal model.revealed
        , case model.error of
            Just message ->
                p [ class "admin-invites__error" ] [ text message ]

            Nothing ->
                text ""
        , viewList model
        ]


viewCreateForm : Model -> Html Msg
viewCreateForm model =
    div [ class "admin-invites__form" ]
        [ h2 [ class "admin-invites__subtitle" ] [ text "Write an invitation" ]
        , div [ class "admin-invites__form-row" ]
            [ label [ class "admin-invites__label", for "invite-note" ] [ text "Private note" ]
            , input
                [ id "invite-note"
                , class "admin-invites__input"
                , type_ "text"
                , placeholder "Mara — book club"
                , value model.note
                , onInput NoteChanged
                ]
                []
            ]
        , div [ class "admin-invites__form-row" ]
            [ label [ class "admin-invites__label", for "invite-email" ] [ text "Bind to email (optional)" ]
            , input
                [ id "invite-email"
                , class "admin-invites__input"
                , type_ "email"
                , placeholder "mara@example.com"
                , value model.invitedEmail
                , onInput InvitedEmailChanged
                ]
                []
            ]
        , div [ class "admin-invites__form-row" ]
            [ label [ class "admin-invites__label", for "invite-max-uses" ] [ text "Uses" ]
            , input
                [ id "invite-max-uses"
                , class "admin-invites__input admin-invites__input--small"
                , type_ "number"
                , Html.Attributes.min "1"
                , value model.maxUses
                , onInput MaxUsesChanged
                ]
                []
            , label [ class "admin-invites__label", for "invite-expiry" ] [ text "Expires in (days)" ]
            , input
                [ id "invite-expiry"
                , class "admin-invites__input admin-invites__input--small"
                , type_ "number"
                , Html.Attributes.min "1"
                , value model.expiresInDays
                , onInput ExpiresInDaysChanged
                ]
                []
            ]
        , button
            [ class "admin-invites__create"
            , testId "admin-invite-create"
            , onClick CreateClicked
            , disabled model.creating
            ]
            [ text
                (if model.creating then
                    "Writing…"

                 else
                    "Write an invitation"
                )
            ]
        ]


{-| The show-once block. The warning line is copy, not decoration — the server
cannot re-show this code, and saying so here is what stops the owner learning
it the hard way.
-}
viewReveal : Maybe ( AdminInvite, String ) -> Html Msg
viewReveal revealed =
    case revealed of
        Nothing ->
            text ""

        Just ( _, fullCode ) ->
            div [ class "admin-invites__code-reveal", testId "admin-invite-code-reveal" ]
                [ code [ class "admin-invites__code" ] [ text fullCode ]
                , p [ class "admin-invites__code-warning" ]
                    [ text "This is the only time the full code is shown. Copy it now — the platform keeps only a fingerprint." ]
                ]


viewList : Model -> Html Msg
viewList model =
    case model.invites of
        Success [] ->
            p [ class "admin-invites__empty" ] [ text "No invitations written yet." ]

        Success invites ->
            table [ class "admin-invites__table" ]
                [ thead []
                    [ tr []
                        [ th [] [ text "Code" ]
                        , th [] [ text "Note" ]
                        , th [] [ text "Status" ]
                        , th [] [ text "Uses" ]
                        , th [] [ text "" ]
                        ]
                    ]
                , tbody [] (List.map (viewRow model.revoking) invites)
                ]

        Failure _ ->
            p [ class "admin-invites__error" ] [ text "Could not load the invitations." ]

        _ ->
            p [ class "admin-invites__empty" ] [ text "Loading…" ]


viewRow : Maybe String -> AdminInvite -> Html Msg
viewRow revoking invite =
    tr [ class "admin-invites__row" ]
        [ td [] [ code [] [ text (invite.codePrefix ++ "-…") ] ]
        , td [] [ text (Maybe.withDefault "—" invite.note) ]
        , td [] [ viewStatus invite ]
        , td [] [ text (String.fromInt invite.useCount ++ " / " ++ String.fromInt invite.maxUses) ]
        , td []
            [ if invite.revokedAt == Nothing && invite.useCount < invite.maxUses then
                button
                    [ class "admin-invites__revoke"
                    , onClick (RevokeClicked invite.id)
                    , disabled (revoking == Just invite.id)
                    ]
                    [ text "Revoke" ]

              else
                text ""
            ]
        ]


viewStatus : AdminInvite -> Html Msg
viewStatus invite =
    let
        ( label_, modifier ) =
            if invite.revokedAt /= Nothing then
                ( "Revoked", "admin-invites__status--revoked" )

            else if invite.useCount >= invite.maxUses then
                ( withHandle invite "Redeemed", "admin-invites__status--redeemed" )

            else
                ( "Open", "admin-invites__status--open" )
    in
    span [ class ("admin-invites__status " ++ modifier) ] [ text label_ ]


withHandle : AdminInvite -> String -> String
withHandle invite label_ =
    case invite.redeemedByHandle of
        Just handle ->
            label_ ++ " by @" ++ handle

        Nothing ->
            label_
