module Page.Groups.Detail exposing (InviteState(..), Model, Msg(..), OutMsg(..), init, update, view)

import Api
import Html exposing (Html, button, div, h1, input, p, text)
import Html.Attributes exposing (class, disabled, placeholder, type_, value)
import Html.Events exposing (onClick, onInput, onSubmit)
import Http
import Navigation.Route exposing (Route(..))
import Types.Group exposing (Group, GroupInvitation)
import Types.RemoteData exposing (RemoteData(..))


type InviteState
    = InviteIdle
    | InviteSending
    | InviteSuccess
    | InviteFailed String


type alias Model =
    { groupId : String
    , group : RemoteData Http.Error Group
    , inviteInput : String
    , inviteState : InviteState
    , currentUserId : String
    , token : String
    }


type Msg
    = GroupLoaded (Result Http.Error Group)
    | InviteInputChanged String
    | SubmitInvite
    | InviteSent (Result Http.Error GroupInvitation)
    | RemoveMember String
    | MemberRemoved String (Result Http.Error ())
    | LeaveGroup
    | LeftGroup (Result Http.Error ())


type OutMsg
    = NoOut
    | NavigateTo Route


init : String -> String -> String -> ( Model, Cmd Msg )
init groupId userId token =
    ( { groupId = groupId
      , group = Loading
      , inviteInput = ""
      , inviteState = InviteIdle
      , currentUserId = userId
      , token = token
      }
    , Api.getGroup groupId token GroupLoaded
    )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        GroupLoaded (Ok group) ->
            ( { model | group = Success group }, Cmd.none, NoOut )

        GroupLoaded (Err err) ->
            ( { model | group = Failure err }, Cmd.none, NoOut )

        InviteInputChanged val ->
            ( { model | inviteInput = val, inviteState = InviteIdle }, Cmd.none, NoOut )

        SubmitInvite ->
            ( { model | inviteState = InviteSending }
            , Api.inviteToGroup model.groupId model.inviteInput model.token InviteSent
            , NoOut
            )

        InviteSent (Ok _) ->
            ( { model | inviteState = InviteSuccess, inviteInput = "" }, Cmd.none, NoOut )

        InviteSent (Err _) ->
            ( { model | inviteState = InviteFailed "Could not send invitation. Check the username or email." }
            , Cmd.none
            , NoOut
            )

        RemoveMember userId ->
            ( model
            , Api.removeMember model.groupId userId model.token (MemberRemoved userId)
            , NoOut
            )

        MemberRemoved _ (Ok ()) ->
            ( model
            , Api.getGroup model.groupId model.token GroupLoaded
            , NoOut
            )

        MemberRemoved _ (Err _) ->
            ( model, Cmd.none, NoOut )

        LeaveGroup ->
            ( model
            , Api.leaveGroup model.groupId model.token LeftGroup
            , NoOut
            )

        LeftGroup (Ok ()) ->
            ( model, Cmd.none, NavigateTo Groups )

        LeftGroup (Err _) ->
            ( model, Cmd.none, NoOut )


view : Model -> Html Msg
view model =
    div [ class "page page--groups-detail" ]
        (case model.group of
            Loading ->
                [ p [] [ text "Loading..." ] ]

            Failure _ ->
                [ p [] [ text "Could not load group." ] ]

            NotAsked ->
                []

            Success group ->
                [ h1 [] [ text group.name ]
                , viewMembers group
                , if group.ownerId == model.currentUserId then
                    viewInviteForm model

                  else
                    text ""
                , if group.ownerId /= model.currentUserId then
                    button [ class "groups-detail__leave", onClick LeaveGroup ] [ text "Leave Group" ]

                  else
                    text ""
                ]
        )


viewMembers : Group -> Html Msg
viewMembers group =
    div [ class "groups-detail__members" ]
        [ div [ class "groups-detail__member" ] [ text group.ownerId ]
        ]


viewInviteForm : Model -> Html Msg
viewInviteForm model =
    Html.form [ class "groups-detail__invite-form", onSubmit SubmitInvite ]
        [ input
            [ type_ "text"
            , placeholder "Username or email"
            , value model.inviteInput
            , onInput InviteInputChanged
            , disabled (model.inviteState == InviteSending)
            ]
            []
        , button
            [ type_ "submit"
            , disabled (model.inviteState == InviteSending)
            ]
            [ text "Invite" ]
        , case model.inviteState of
            InviteSuccess ->
                p [ class "groups-detail__invite-success" ] [ text "Invitation sent!" ]

            InviteFailed err ->
                p [ class "groups-detail__invite-error" ] [ text err ]

            _ ->
                text ""
        ]
