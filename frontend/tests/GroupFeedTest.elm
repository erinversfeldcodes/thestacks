module GroupFeedTest exposing (suite)

import Expect
import Http
import Page.Groups.Detail as Detail
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Types.FeedItem exposing (FeedItem(..), FeedResponse)
import Types.Group exposing (Group)
import Types.RemoteData exposing (RemoteData(..))


detailInit : Detail.Model
detailInit =
    let
        ( m, _ ) =
            Detail.init "group-1" "user-1" "token-abc"
    in
    m


fakePlacement : FeedItem
fakePlacement =
    PlacementCreated
        { placementId = "p-1"
        , bookId = "b-1"
        , bookTitle = "Dune"
        , bookCoverUrl = Nothing
        , userId = "user-2"
        , userDisplayName = "Alice"
        , occurredAt = "2026-03-30T00:00:00Z"
        }


fakeBlogPost : FeedItem
fakeBlogPost =
    BlogPost
        { postId = "bp-1"
        , postTitle = "On Reading"
        , postVisibility = "platform"
        , userId = "user-3"
        , userDisplayName = "Bob"
        , occurredAt = "2026-03-29T12:00:00Z"
        }


fakeFeedResponse : FeedResponse
fakeFeedResponse =
    { data = [ fakePlacement, fakeBlogPost ]
    , nextCursor = Just "2026-03-29T12:00:00Z"
    }


fakeFeedResponseNoMore : FeedResponse
fakeFeedResponseNoMore =
    { data = [ fakePlacement ]
    , nextCursor = Nothing
    }


fakeGroup : Group
fakeGroup =
    { id = "group-1"
    , name = "Book Club"
    , type_ = "close_friends"
    , visibility = "invite_only"
    , ownerId = "user-1"
    }


modelOnFeedTab : Detail.Model
modelOnFeedTab =
    { detailInit
        | activeTab = Detail.FeedTab
        , group = Success fakeGroup
    }


suite : Test
suite =
    describe "Group Feed"
        [ test "TabChanged FeedTab sets activeTab to FeedTab" <|
            \_ ->
                let
                    ( model, _, _ ) =
                        Detail.update (Detail.TabChanged Detail.FeedTab) detailInit
                in
                model.activeTab |> Expect.equal Detail.FeedTab
        , test "TabChanged MembersTab sets activeTab to MembersTab" <|
            \_ ->
                let
                    onFeed =
                        let
                            ( m, _, _ ) =
                                Detail.update (Detail.TabChanged Detail.FeedTab) detailInit
                        in
                        m

                    ( model, _, _ ) =
                        Detail.update (Detail.TabChanged Detail.MembersTab) onFeed
                in
                model.activeTab |> Expect.equal Detail.MembersTab
        , test "FeedLoaded Ok sets feed to Success" <|
            \_ ->
                let
                    ( model, _, _ ) =
                        Detail.update (Detail.FeedLoaded (Ok fakeFeedResponse)) detailInit
                in
                model.feed |> Expect.equal (Success fakeFeedResponse)
        , test "FeedLoaded Err sets feed to Failure" <|
            \_ ->
                let
                    ( model, _, _ ) =
                        Detail.update (Detail.FeedLoaded (Err Http.NetworkError)) detailInit
                in
                case model.feed of
                    Failure _ ->
                        Expect.pass

                    _ ->
                        Expect.fail "Expected Failure"
        , test "LoadMoreFeed with nextCursor sets loadingMoreFeed to True" <|
            \_ ->
                let
                    withFeed =
                        { detailInit | feed = Success fakeFeedResponse }

                    ( model, _, _ ) =
                        Detail.update Detail.LoadMoreFeed withFeed
                in
                model.loadingMoreFeed |> Expect.equal True
        , test "MoreFeedLoaded Ok appends items and resets loadingMoreFeed" <|
            \_ ->
                let
                    withFeed =
                        { detailInit | feed = Success fakeFeedResponse, loadingMoreFeed = True }

                    newResp =
                        { data = [ fakePlacement ]
                        , nextCursor = Nothing
                        }

                    ( model, _, _ ) =
                        Detail.update (Detail.MoreFeedLoaded (Ok newResp)) withFeed
                in
                Expect.all
                    [ \m -> m.loadingMoreFeed |> Expect.equal False
                    , \m ->
                        case m.feed of
                            Success resp ->
                                List.length resp.data |> Expect.equal 3

                            _ ->
                                Expect.fail "Expected Success"
                    ]
                    model
        , test "view renders empty state when feed has no items" <|
            \_ ->
                let
                    emptyModel =
                        { modelOnFeedTab
                            | feed = Success { data = [], nextCursor = Nothing }
                        }
                in
                Detail.view emptyModel
                    |> Query.fromHtml
                    |> Query.find [ Selector.class "groups-detail__feed-empty" ]
                    |> Query.has [ Selector.text "No activity yet." ]
        , test "view shows Load More button only when nextCursor is present" <|
            \_ ->
                let
                    withCursor =
                        { modelOnFeedTab
                            | feed = Success fakeFeedResponse
                        }

                    withoutCursor =
                        { modelOnFeedTab
                            | feed = Success fakeFeedResponseNoMore
                        }
                in
                Expect.all
                    [ \_ ->
                        Detail.view withCursor
                            |> Query.fromHtml
                            |> Query.findAll [ Selector.class "groups-detail__load-more" ]
                            |> Query.count (Expect.equal 1)
                    , \_ ->
                        Detail.view withoutCursor
                            |> Query.fromHtml
                            |> Query.findAll [ Selector.class "groups-detail__load-more" ]
                            |> Query.count (Expect.equal 0)
                    ]
                    ()
        ]
