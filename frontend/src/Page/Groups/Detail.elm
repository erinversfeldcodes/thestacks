module Page.Groups.Detail exposing (InviteState(..), Model, Msg(..), OutMsg(..), Tab(..), init, update, view)

import Api
import Components.BlockUserModal as BlockModal
import Components.FeedItem
import Dict exposing (Dict)
import Html exposing (Html, button, div, h1, input, p, span, text)
import Html.Attributes exposing (class, disabled, placeholder, type_, value)
import Html.Events exposing (onClick, onInput, onSubmit)
import Http
import Navigation.Route exposing (Route(..))
import Types.FeedItem exposing (FeedItem, FeedResponse, feedItemUserDisplayName, feedItemUserId)
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
    , blockModals : Dict String BlockModal.Model
    , members : RemoteData Http.Error (List Api.GroupMember)
    , removingMemberId : Maybe String
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
    | BlockModalMsg String BlockModal.Msg
    | MembersLoaded (Result Http.Error (List Api.GroupMember))
    | RemoveMember String
    | MemberRemoved String (Result Http.Error ())
    | EscapePressed


type OutMsg
    = NoOut
    | NavigateTo Route
    | SessionExpired
    | EscapeUnhandled


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
      , blockModals = Dict.empty
      , members = Loading
      , removingMemberId = Nothing
      }
    , Cmd.batch
        [ Api.getGroup groupId token GroupLoaded
        , Api.getGroupMembers groupId token MembersLoaded
        ]
    )


{-| The first block affordance (by user id) whose menu or confirm modal is open.
At most one should be open at a time, but folding is robust to more.
-}
firstOpenBlockModal : Dict String BlockModal.Model -> Maybe ( String, BlockModal.Model )
firstOpenBlockModal blockModals =
    blockModals
        |> Dict.toList
        |> List.filter (\( _, bm ) -> bm.menuOpen || bm.confirming)
        |> List.head


{-| Ensure a block affordance exists for every OTHER member seen in the feed.
Own activity is never blockable, and existing modals are preserved so an
in-flight confirmation survives a "load more".
-}
mergeBlockModals : String -> List FeedItem -> Dict String BlockModal.Model -> Dict String BlockModal.Model
mergeBlockModals currentUserId items dict =
    List.foldl
        (\item acc ->
            let
                uid =
                    feedItemUserId item
            in
            if uid == currentUserId || Dict.member uid acc then
                acc

            else
                Dict.insert uid
                    (BlockModal.init { userId = uid, displayName = feedItemUserDisplayName item })
                    acc
        )
        dict
        items


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

        MembersLoaded (Ok members) ->
            ( { model | members = Success members }, Cmd.none, NoOut )

        MembersLoaded (Err e) ->
            if Api.isUnauthorized e then
                ( model, Cmd.none, SessionExpired )

            else
                ( { model | members = Failure e }, Cmd.none, NoOut )

        RemoveMember memberUserId ->
            ( { model | removingMemberId = Just memberUserId }
            , Api.removeGroupMember model.groupId memberUserId model.token (MemberRemoved memberUserId)
            , NoOut
            )

        MemberRemoved memberUserId (Ok ()) ->
            -- Drop the row locally rather than refetching: the server has already
            -- agreed, and a refetch would blink the whole list for one removal.
            ( { model
                | removingMemberId = Nothing
                , members =
                    case model.members of
                        Success ms ->
                            Success (List.filter (\m -> m.userId /= memberUserId) ms)

                        other ->
                            other
              }
            , Cmd.none
            , NoOut
            )

        MemberRemoved _ (Err e) ->
            if Api.isUnauthorized e then
                ( model, Cmd.none, SessionExpired )

            else
                ( { model | removingMemberId = Nothing, members = Failure e }, Cmd.none, NoOut )

        FeedLoaded (Ok resp) ->
            ( { model
                | feed = Success resp
                , blockModals = mergeBlockModals model.currentUserId resp.data model.blockModals
              }
            , Cmd.none
            , NoOut
            )

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
                        , blockModals = mergeBlockModals model.currentUserId newResp.data model.blockModals
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

        BlockModalMsg uid subMsg ->
            case Dict.get uid model.blockModals of
                Just blockModal ->
                    let
                        ( newBlockModal, subCmd, outMsg ) =
                            BlockModal.update subMsg blockModal (Just model.token)

                        modelWith bm =
                            { model | blockModals = Dict.insert uid bm model.blockModals }
                    in
                    case outMsg of
                        BlockModal.NoOut ->
                            ( modelWith newBlockModal, Cmd.map (BlockModalMsg uid) subCmd, NoOut )

                        BlockModal.UserBlocked ->
                            ( { model
                                | blockModals = Dict.insert uid newBlockModal model.blockModals
                                , feed = Loading
                              }
                            , Cmd.batch
                                [ Cmd.map (BlockModalMsg uid) subCmd
                                , Api.getGroupFeed model.groupId model.token Nothing FeedLoaded
                                ]
                            , NoOut
                            )

                        BlockModal.SessionExpired ->
                            ( model, Cmd.none, SessionExpired )

                        BlockModal.Dismissed ->
                            ( modelWith newBlockModal, Cmd.map (BlockModalMsg uid) subCmd, NoOut )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        EscapePressed ->
            case firstOpenBlockModal model.blockModals of
                Just ( uid, blockModal ) ->
                    let
                        ( newBlockModal, subCmd, outMsg ) =
                            BlockModal.update BlockModal.EscapePressed blockModal (Just model.token)
                    in
                    case outMsg of
                        BlockModal.Dismissed ->
                            ( { model | blockModals = Dict.insert uid newBlockModal model.blockModals }
                            , Cmd.map (BlockModalMsg uid) subCmd
                            , NoOut
                            )

                        _ ->
                            ( model, Cmd.none, EscapeUnhandled )

                Nothing ->
                    ( model, Cmd.none, EscapeUnhandled )


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
                            [ viewMembers model group
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


{-| The members list.

This used to render `group.ownerId` — a raw UUID, and only the owner's — because
the members endpoint had no client. The owner's remove control lives here too:
the API has always supported removing a member and nothing in the app called it,
so a group owner could invite people and then never remove them.

-}
viewMembers : Model -> Group -> Html Msg
viewMembers model group =
    div [ class "groups-detail__members" ]
        [ case model.members of
            NotAsked ->
                text ""

            Loading ->
                div [ class "groups-detail__members-loading" ] [ text "Loading members…" ]

            Failure _ ->
                p [ class "groups-detail__members-error" ]
                    [ text "Could not load the members. Please try again." ]

            Success [] ->
                p [ class "groups-detail__members-empty" ]
                    [ text "No members yet — invite someone to get started." ]

            Success members ->
                div [] (List.map (viewMember model group) members)
        ]


viewMember : Model -> Group -> Api.GroupMember -> Html Msg
viewMember model group member =
    let
        isOwnerViewing =
            group.ownerId == model.currentUserId

        isSelf =
            member.userId == model.currentUserId
    in
    div [ class "groups-detail__member" ]
        [ span [ class "groups-detail__member-name" ] [ text member.displayName ]
        , if member.role == "owner" then
            span [ class "groups-detail__member-role" ] [ text "Owner" ]

          else
            text ""

        -- The owner can remove anyone but themselves; removing the owner would
        -- leave the group without one, and leaving is the owner's own path out.
        , if isOwnerViewing && not isSelf then
            button
                [ class "groups-detail__member-remove"
                , onClick (RemoveMember member.userId)
                , disabled (model.removingMemberId == Just member.userId)
                ]
                [ text
                    (if model.removingMemberId == Just member.userId then
                        "Removing…"

                     else
                        "Remove"
                    )
                ]

          else
            text ""
        ]


{-| A feed row: the activity plus, for ANOTHER member's activity, a reusable
block affordance (⋯ → "Block name"). Own activity carries no affordance.
-}
viewFeedRow : Model -> FeedItem -> Html Msg
viewFeedRow model item =
    let
        uid =
            feedItemUserId item
    in
    div [ class "feed-item-row" ]
        [ Components.FeedItem.view item
        , if uid == model.currentUserId then
            text ""

          else
            case Dict.get uid model.blockModals of
                Just blockModal ->
                    Html.map (BlockModalMsg uid) (BlockModal.view blockModal)

                Nothing ->
                    text ""
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
                    List.map (viewFeedRow model) resp.data
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
