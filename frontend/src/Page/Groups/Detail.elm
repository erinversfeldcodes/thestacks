module Page.Groups.Detail exposing (InviteState(..), Model, Msg(..), OutMsg(..), Tab(..), init, update, view)

import Api
import Components.FeedItem
import Html exposing (Html, button, div, h1, input, p, text)
import Html.Attributes exposing (class, disabled, placeholder, type_, value)
import Html.Events exposing (onClick, onInput, onSubmit)
import Http
import Navigation.Route exposing (Route(..))
import Types.FeedItem exposing (FeedResponse)
import Types.Group exposing (Group, GroupInvitation)
import Types.RemoteData exposing (RemoteData(..))


type InviteState
    = InviteIdle
    | InviteSending
    | InviteSuccess
    | InviteFailed String


type Tab
    = MembersTab
    | FeedTab


type alias Model =
    { groupId : String
    , group : RemoteData Http.Error Group
    , inviteInput : String
    , inviteState : InviteState
    , currentUserId : String
    , token : String
    , activeTab : Tab
    , feed : RemoteData Http.Error FeedResponse
    , loadingMoreFeed : Bool
    }


type Msg
    = GroupLoaded (Result Http.Error Group)
    | InviteInputChanged String
    | SubmitInvite
    | InviteSent (Result Http.Error GroupInvitation)
    | LeaveGroup
    | LeftGroup (Result Http.Error ())
    | TabChanged Tab
    | FeedLoaded (Result Http.Error FeedResponse)
    | LoadMoreFeed
    | MoreFeedLoaded (Result Http.Error FeedResponse)


type OutMsg
    = NoOut
    | NavigateTo Route
    | SessionExpired


init : String -> String -> String -> ( Model, Cmd Msg )
init groupId userId token =
    ( { groupId = groupId
      , group = Loading
      , inviteInput = ""
      , inviteState = InviteIdle
      , currentUserId = userId
      , token = token
      , activeTab = MembersTab
      , feed = NotAsked
      , loadingMoreFeed = False
      }
    , Api.getGroup groupId token GroupLoaded
    )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        GroupLoaded (Ok group) ->
            ( { model | group = Success group }, Cmd.none, NoOut )

        GroupLoaded (Err err) ->
            if Api.isUnauthorized err then
                ( model, Cmd.none, SessionExpired )

            else
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

        InviteSent (Err err) ->
            if Api.isUnauthorized err then
                ( model, Cmd.none, SessionExpired )

            else
                ( { model | inviteState = InviteFailed "Could not send invitation. Check the username or email." }
                , Cmd.none
                , NoOut
                )

        LeaveGroup ->
            ( model
            , Api.leaveGroup model.groupId model.token LeftGroup
            , NoOut
            )

        LeftGroup (Ok ()) ->
            ( model, Cmd.none, NavigateTo Groups )

        LeftGroup (Err err) ->
            if Api.isUnauthorized err then
                ( model, Cmd.none, SessionExpired )

            else
                ( model, Cmd.none, NoOut )

        TabChanged FeedTab ->
            case model.feed of
                NotAsked ->
                    ( { model | activeTab = FeedTab, feed = Loading }
                    , Api.getGroupFeed model.groupId model.token Nothing FeedLoaded
                    , NoOut
                    )

                _ ->
                    ( { model | activeTab = FeedTab }, Cmd.none, NoOut )

        TabChanged MembersTab ->
            ( { model | activeTab = MembersTab }, Cmd.none, NoOut )

        FeedLoaded (Ok resp) ->
            ( { model | feed = Success resp }, Cmd.none, NoOut )

        FeedLoaded (Err e) ->
            if Api.isUnauthorized e then
                ( model, Cmd.none, SessionExpired )

            else
                ( { model | feed = Failure e }, Cmd.none, NoOut )

        LoadMoreFeed ->
            case model.feed of
                Success resp ->
                    case resp.nextCursor of
                        Just _ ->
                            ( { model | loadingMoreFeed = True }
                            , Api.getGroupFeed model.groupId model.token resp.nextCursor MoreFeedLoaded
                            , NoOut
                            )

                        Nothing ->
                            ( model, Cmd.none, NoOut )

                _ ->
                    ( model, Cmd.none, NoOut )

        MoreFeedLoaded (Ok newResp) ->
            case model.feed of
                Success oldResp ->
                    ( { model
                        | feed =
                            Success
                                { data = oldResp.data ++ newResp.data
                                , nextCursor = newResp.nextCursor
                                }
                        , loadingMoreFeed = False
                      }
                    , Cmd.none
                    , NoOut
                    )

                _ ->
                    ( { model | loadingMoreFeed = False }, Cmd.none, NoOut )

        MoreFeedLoaded (Err err) ->
            if Api.isUnauthorized err then
                ( model, Cmd.none, SessionExpired )

            else
                ( { model | loadingMoreFeed = False }, Cmd.none, NoOut )


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
                , div [ class "groups-detail__tabs" ]
                    [ button
                        [ onClick (TabChanged MembersTab)
                        , class
                            (if model.activeTab == MembersTab then
                                "tab tab--active"

                             else
                                "tab"
                            )
                        ]
                        [ text "Members" ]
                    , button
                        [ onClick (TabChanged FeedTab)
                        , class
                            (if model.activeTab == FeedTab then
                                "tab tab--active"

                             else
                                "tab"
                            )
                        ]
                        [ text "Feed" ]
                    ]
                , case model.activeTab of
                    MembersTab ->
                        div []
                            [ viewMembers group
                            , if group.ownerId == model.currentUserId then
                                viewInviteForm model

                              else
                                text ""
                            , if group.ownerId /= model.currentUserId then
                                button [ class "groups-detail__leave", onClick LeaveGroup ] [ text "Leave Group" ]

                              else
                                text ""
                            ]

                    FeedTab ->
                        viewFeed model
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


viewFeed : Model -> Html Msg
viewFeed model =
    div [ class "groups-detail__feed" ]
        (case model.feed of
            NotAsked ->
                [ p [] [ text "Select the Feed tab to load activity." ] ]

            Loading ->
                [ p [] [ text "Loading feed..." ] ]

            Failure _ ->
                [ p [] [ text "Could not load feed." ] ]

            Success resp ->
                if List.isEmpty resp.data then
                    [ p [ class "groups-detail__feed-empty" ] [ text "No activity yet." ] ]

                else
                    List.map Components.FeedItem.view resp.data
                        ++ [ if resp.nextCursor /= Nothing then
                                button
                                    [ class "groups-detail__load-more"
                                    , onClick LoadMoreFeed
                                    , disabled model.loadingMoreFeed
                                    ]
                                    [ text
                                        (if model.loadingMoreFeed then
                                            "Loading..."

                                         else
                                            "Load more"
                                        )
                                    ]

                             else
                                text ""
                           ]
        )
