module Page.Groups exposing (Model, Msg(..), OutMsg(..), init, update, view)

import Api
import Effect exposing (Effect)
import Html exposing (Html, button, div, form, h1, h2, input, p, text)
import Html.Attributes exposing (class, disabled, placeholder, type_, value)
import Html.Events exposing (onClick, onInput, onSubmit)
import Http
import Json.Decode as Decode
import Navigation.Route exposing (Route(..))
import Types.Group exposing (Group, GroupInvitation)
import Types.RemoteData exposing (RemoteData(..))


type alias CreateForm =
    { name : String
    , submitting : Bool
    , error : Maybe String
    }


type alias Model =
    { groups : RemoteData Http.Error (List Group)
    , pendingInvitations : RemoteData Http.Error (List GroupInvitation)
    , createForm : CreateForm
    , currentUserId : String
    , token : Api.Credentials
    }


type Msg
    = NameChanged String
    | SessionExpiryDetected
    | SubmitCreate
    | GroupCreated (Result Http.Error Group)
    | AcceptInvitation String String
    | DeclineInvitation String String
    | InvitationAccepted String (Result Http.Error ())
    | InvitationDeclined String (Result Http.Error ())


type OutMsg
    = NoOut
    | NavigateTo Route
    | SessionExpired


init : String -> Api.Credentials -> ( Model, Cmd Msg )
init userId token =
    ( { groups = Success []
      , pendingInvitations = Success []
      , createForm =
            { name = ""
            , submitting = False
            , error = Nothing
            }
      , currentUserId = userId
      , token = token
      }
    , Cmd.none
    )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    let
        ( newModel, effect, out ) =
            updateWithEffect msg model
    in
    ( newModel, Effect.perform effect, out )


updateWithEffect : Msg -> Model -> ( Model, Effect Msg, OutMsg )
updateWithEffect msg model =
    case msg of
        SessionExpiryDetected ->
            ( model, Effect.None, SessionExpired )

        NameChanged name ->
            let
                oldForm =
                    model.createForm

                newForm =
                    { oldForm | name = name }
            in
            ( { model | createForm = newForm }, Effect.None, NoOut )

        SubmitCreate ->
            let
                oldForm =
                    model.createForm
            in
            if String.isEmpty (String.trim oldForm.name) then
                ( { model | createForm = { oldForm | error = Just "Name is required" } }
                , Effect.None
                , NoOut
                )

            else
                ( { model | createForm = { oldForm | submitting = True, error = Nothing } }
                , Effect.authed (Api.createGroupRequest oldForm.name)
                    model.token
                    { onExpired = SessionExpiryDetected
                    , onResponse =
                        Api.resolveJson (Decode.field "group" Types.Group.groupDecoder)
                            >> GroupCreated
                    }
                , NoOut
                )

        GroupCreated (Ok group) ->
            ( model, Effect.None, NavigateTo (GroupDetail group.id) )

        GroupCreated (Err err) ->
            if Api.isUnauthorized err then
                ( model, Effect.None, SessionExpired )

            else
                let
                    oldForm =
                        model.createForm
                in
                ( { model | createForm = { oldForm | error = Just "Could not create group. Please try again.", submitting = False } }
                , Effect.None
                , NoOut
                )

        AcceptInvitation groupId invId ->
            ( model
            , Effect.authed (Api.invitationAnswerRequest groupId invId Api.AcceptInvitation)
                model.token
                { onExpired = SessionExpiryDetected
                , onResponse = Api.resolveWhatever >> InvitationAccepted invId
                }
            , NoOut
            )

        DeclineInvitation groupId invId ->
            ( model
            , Effect.authed (Api.invitationAnswerRequest groupId invId Api.DeclineInvitation)
                model.token
                { onExpired = SessionExpiryDetected
                , onResponse = Api.resolveWhatever >> InvitationDeclined invId
                }
            , NoOut
            )

        InvitationAccepted invId (Ok ()) ->
            let
                filterInv =
                    Types.RemoteData.map (List.filter (\inv -> inv.id /= invId))
            in
            ( { model | pendingInvitations = filterInv model.pendingInvitations }
            , Effect.None
            , NoOut
            )

        InvitationAccepted _ (Err err) ->
            if Api.isUnauthorized err then
                ( model, Effect.None, SessionExpired )

            else
                ( model, Effect.None, NoOut )

        InvitationDeclined invId (Ok ()) ->
            let
                filterInv =
                    Types.RemoteData.map (List.filter (\inv -> inv.id /= invId))
            in
            ( { model | pendingInvitations = filterInv model.pendingInvitations }
            , Effect.None
            , NoOut
            )

        InvitationDeclined _ (Err err) ->
            if Api.isUnauthorized err then
                ( model, Effect.None, SessionExpired )

            else
                ( model, Effect.None, NoOut )


view : Model -> Html Msg
view model =
    div [ class "page page--groups" ]
        [ h1 [] [ text "My Groups" ]
        , viewCreateForm model.createForm
        , viewInvitations model.pendingInvitations
        , viewGroupsList model.groups
        ]


viewCreateForm : CreateForm -> Html Msg
viewCreateForm createForm =
    form [ class "groups__create-form", onSubmit SubmitCreate ]
        [ h2 [] [ text "Create a Group" ]
        , input
            [ type_ "text"
            , placeholder "Group name"
            , value createForm.name
            , onInput NameChanged
            ]
            []
        , button
            [ type_ "submit"
            , disabled createForm.submitting
            ]
            [ text "Create" ]
        , case createForm.error of
            Just err ->
                p [ class "groups__error" ] [ text err ]

            Nothing ->
                text ""
        ]


viewGroupsList : RemoteData Http.Error (List Group) -> Html Msg
viewGroupsList groups =
    div [ class "groups__list" ]
        (case groups of
            Success list ->
                if List.isEmpty list then
                    [ p [] [ text "You haven't created or joined any groups yet." ] ]

                else
                    List.map viewGroupItem list

            Loading ->
                [ p [] [ text "Loading..." ] ]

            Failure _ ->
                [ p [] [ text "Could not load groups." ] ]

            NotAsked ->
                []
        )


viewGroupItem : Group -> Html Msg
viewGroupItem group =
    div [ class "groups__item" ]
        [ text group.name ]


viewInvitations : RemoteData Http.Error (List GroupInvitation) -> Html Msg
viewInvitations invitations =
    case invitations of
        Success list ->
            if List.isEmpty list then
                text ""

            else
                div [ class "groups__invitations" ]
                    [ h2 [] [ text "Pending Invitations" ]
                    , div [] (List.map viewInvitationCard list)
                    ]

        _ ->
            text ""


viewInvitationCard : GroupInvitation -> Html Msg
viewInvitationCard invitation =
    div [ class "groups__invitation-card" ]
        [ p [] [ text ("Invitation to group " ++ invitation.groupId) ]
        , button [ onClick (AcceptInvitation invitation.groupId invitation.id) ] [ text "Accept" ]
        , button [ onClick (DeclineInvitation invitation.groupId invitation.id) ] [ text "Decline" ]
        ]
