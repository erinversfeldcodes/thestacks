module GroupsTest exposing (suite)

import Expect
import Http
import Navigation.Route exposing (Route(..))
import Page.Groups as Groups
import Page.Groups.Detail as GroupsDetail
import Test exposing (Test, describe, test)
import Types.Group exposing (Group, GroupInvitation)
import Types.RemoteData exposing (RemoteData(..))


fakeGroup : Group
fakeGroup =
    { id = "group-1"
    , name = "Book Club"
    , type_ = "close_friends"
    , visibility = "invite_only"
    , ownerId = "user-1"
    }


fakeInvitation : GroupInvitation
fakeInvitation =
    { id = "inv-1"
    , groupId = "group-1"
    , invitedUserId = "user-2"
    , invitedById = "user-1"
    , status = "pending"
    }


groupsInit : Groups.Model
groupsInit =
    let
        ( m, _ ) =
            Groups.init "user-1" "token-abc"
    in
    m


detailInit : GroupsDetail.Model
detailInit =
    let
        ( m, _ ) =
            GroupsDetail.init "group-1" "user-1" "token-abc"
    in
    m


suite : Test
suite =
    describe "Groups"
        [ describe "Page.Groups"
            [ test "NameChanged updates createForm.name" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Groups.update (Groups.NameChanged "Book Club") groupsInit
                    in
                    model.createForm.name |> Expect.equal "Book Club"
            , test "SubmitCreate with empty name sets error" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Groups.update Groups.SubmitCreate groupsInit
                    in
                    model.createForm.error |> Expect.equal (Just "Name is required")
            , test "SubmitCreate with non-empty name sets submitting" <|
                \_ ->
                    let
                        withName =
                            let
                                ( m, _, _ ) =
                                    Groups.update (Groups.NameChanged "Book Club") groupsInit
                            in
                            m

                        ( model, _, _ ) =
                            Groups.update Groups.SubmitCreate withName
                    in
                    model.createForm.submitting |> Expect.equal True
            , test "GroupCreated Ok emits NavigateTo GroupDetail" <|
                \_ ->
                    let
                        ( _, _, outMsg ) =
                            Groups.update (Groups.GroupCreated (Ok fakeGroup)) groupsInit
                    in
                    outMsg |> Expect.equal (Groups.NavigateTo (GroupDetail "group-1"))
            , test "InvitationAccepted removes invitation from pending list" <|
                \_ ->
                    let
                        modelWithInvitations =
                            { groupsInit | pendingInvitations = Success [ fakeInvitation ] }

                        ( model, _, _ ) =
                            Groups.update (Groups.InvitationAccepted "inv-1" (Ok ())) modelWithInvitations
                    in
                    model.pendingInvitations |> Expect.equal (Success [])
            ]
        , describe "Page.Groups.Detail"
            [ test "InviteInputChanged updates inviteInput" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            GroupsDetail.update (GroupsDetail.InviteInputChanged "alice@example.com") detailInit
                    in
                    model.inviteInput |> Expect.equal "alice@example.com"
            , test "InviteSent Ok sets InviteSuccess and clears input" <|
                \_ ->
                    let
                        fakeInv =
                            { id = "inv-2"
                            , groupId = "group-1"
                            , invitedUserId = "user-3"
                            , invitedById = "user-1"
                            , status = "pending"
                            }

                        ( model, _, _ ) =
                            GroupsDetail.update (GroupsDetail.InviteSent (Ok fakeInv)) detailInit
                    in
                    Expect.all
                        [ \m -> m.inviteState |> Expect.equal GroupsDetail.InviteSuccess
                        , \m -> m.inviteInput |> Expect.equal ""
                        ]
                        model
            , test "InviteSent Err sets InviteFailed" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            GroupsDetail.update (GroupsDetail.InviteSent (Err Http.NetworkError)) detailInit
                    in
                    case model.inviteState of
                        GroupsDetail.InviteFailed _ ->
                            Expect.pass

                        _ ->
                            Expect.fail "Expected InviteFailed"
            , test "LeftGroup Ok emits NavigateTo Groups" <|
                \_ ->
                    let
                        ( _, _, outMsg ) =
                            GroupsDetail.update (GroupsDetail.LeftGroup (Ok ())) detailInit
                    in
                    outMsg |> Expect.equal (GroupsDetail.NavigateTo Groups)
            ]
        ]
