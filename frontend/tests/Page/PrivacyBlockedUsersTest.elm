module Page.PrivacyBlockedUsersTest exposing (suite)

{-| State-machine tests for the "Blocked Users" section added to
Page.Settings.Privacy (Issue #193, US-10.1.2 frontend). Covers loading the
list on entry, rendering each blocked reader with an Unblock control, the
happy unblock path (row removed), a not\_found unblock, and the 401 escalation.
-}

import Api
import Expect
import Http
import Page.Settings.Privacy as Privacy exposing (Msg(..))
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Types.RemoteData exposing (RemoteData(..))


blocked : List Api.BlockedUser
blocked =
    [ { id = "u-2", displayName = "Ada Lovelace", blockedAt = "2026-07-14T00:00:00Z" }
    , { id = "u-3", displayName = "Grace Hopper", blockedAt = "2026-07-13T00:00:00Z" }
    ]


baseModel : Privacy.Model
baseModel =
    Tuple.first (Privacy.initWithToken (Just "tok"))


suite : Test
suite =
    describe "Page.Settings.Privacy — Blocked Users"
        [ test "initWithToken with a token requests the list (Loading)" <|
            \_ ->
                baseModel.blockedUsers |> Expect.equal Loading
        , test "initWithToken without a token does not fetch (NotAsked)" <|
            \_ ->
                Tuple.first (Privacy.initWithToken Nothing)
                    |> .blockedUsers
                    |> Expect.equal NotAsked
        , test "GotBlockedUsers Ok stores the returned list" <|
            \_ ->
                let
                    ( m, _, _ ) =
                        Privacy.update
                            (GotBlockedUsers (Ok { blockedUsers = blocked, total = 2, page = 1 }))
                            baseModel
                            (Just "tok")
                in
                m.blockedUsers |> Expect.equal (Success blocked)
        , test "view lists each blocked reader with an Unblock button" <|
            \_ ->
                Privacy.view { baseModel | blockedUsers = Success blocked }
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.has [ Selector.text "Ada Lovelace" ]
                        , Query.has [ Selector.text "Grace Hopper" ]
                        , Query.findAll [ Selector.class "blocked-user__unblock" ]
                            >> Query.count (Expect.equal 2)
                        ]
        , test "UserClicksUnblock marks that row in-flight" <|
            \_ ->
                let
                    ( m, _, _ ) =
                        Privacy.update (UserClicksUnblock "u-2")
                            { baseModel | blockedUsers = Success blocked }
                            (Just "tok")
                in
                m.unblocking |> Expect.equal (Just "u-2")
        , test "GotUnblockResponse Ok removes the reader from the list" <|
            \_ ->
                let
                    started =
                        { baseModel | blockedUsers = Success blocked, unblocking = Just "u-2" }

                    ( m, _, _ ) =
                        Privacy.update (GotUnblockResponse "u-2" (Ok ())) started (Just "tok")
                in
                Expect.all
                    [ \x -> x.unblocking |> Expect.equal Nothing
                    , \x ->
                        x.blockedUsers
                            |> Expect.equal (Success (List.filter (\b -> b.id /= "u-2") blocked))
                    ]
                    m
        , test "GotUnblockResponse not_found clears the in-flight flag but keeps the row" <|
            \_ ->
                let
                    started =
                        { baseModel | blockedUsers = Success blocked, unblocking = Just "u-2" }

                    ( m, _, out ) =
                        Privacy.update (GotUnblockResponse "u-2" (Err (Http.BadStatus 404))) started (Just "tok")
                in
                Expect.all
                    [ \_ -> m.unblocking |> Expect.equal Nothing
                    , \_ -> m.blockedUsers |> Expect.equal (Success blocked)
                    , \_ -> out |> Expect.equal Privacy.NoOut
                    ]
                    ()
        , test "GotUnblockResponse non-401 failure surfaces an error and keeps the row" <|
            \_ ->
                let
                    started =
                        { baseModel | blockedUsers = Success blocked, unblocking = Just "u-2" }

                    ( m, _, out ) =
                        Privacy.update (GotUnblockResponse "u-2" (Err (Http.BadStatus 500))) started (Just "tok")
                in
                Expect.all
                    [ \_ -> m.unblocking |> Expect.equal Nothing
                    , \_ -> m.blockedUsers |> Expect.equal (Success blocked)
                    , \_ -> out |> Expect.equal Privacy.NoOut
                    , \_ ->
                        Privacy.view m
                            |> Query.fromHtml
                            |> Query.has [ Selector.text "We couldn't unblock that reader. Please try again." ]
                    ]
                    ()
        , test "GotBlockedUsers 401 escalates to SessionExpired" <|
            \_ ->
                let
                    ( _, _, out ) =
                        Privacy.update (GotBlockedUsers (Err (Http.BadStatus 401))) baseModel (Just "tok")
                in
                out |> Expect.equal Privacy.SessionExpired
        , test "an empty list shows a friendly empty state" <|
            \_ ->
                Privacy.view { baseModel | blockedUsers = Success [] }
                    |> Query.fromHtml
                    |> Query.has [ Selector.text "You haven't blocked anyone." ]
        , test "Load more appears when fewer readers are loaded than the total" <|
            \_ ->
                Privacy.view { baseModel | blockedUsers = Success blocked, blockedTotal = 25, blockedPage = 1 }
                    |> Query.fromHtml
                    |> Query.has [ Selector.class "privacy__blocked-load-more" ]
        , test "Load more is hidden once every blocked reader is loaded" <|
            \_ ->
                Privacy.view { baseModel | blockedUsers = Success blocked, blockedTotal = 2, blockedPage = 1 }
                    |> Query.fromHtml
                    |> Query.hasNot [ Selector.class "privacy__blocked-load-more" ]
        , test "LoadMoreBlocked requests the next page and marks loadingMore" <|
            \_ ->
                let
                    started =
                        { baseModel | blockedUsers = Success blocked, blockedTotal = 25, blockedPage = 1 }

                    ( m, _, _ ) =
                        Privacy.update LoadMoreBlocked started (Just "tok")
                in
                m.loadingMore |> Expect.equal True
        , test "GotBlockedUsers page 2 appends to the readers already loaded" <|
            \_ ->
                let
                    more =
                        [ { id = "u-4", displayName = "Katherine Johnson", blockedAt = "2026-07-12T00:00:00Z" } ]

                    started =
                        { baseModel | blockedUsers = Success blocked, blockedTotal = 3, blockedPage = 1 }

                    ( m, _, _ ) =
                        Privacy.update
                            (GotBlockedUsers (Ok { blockedUsers = more, total = 3, page = 2 }))
                            started
                            (Just "tok")
                in
                m.blockedUsers |> Expect.equal (Success (blocked ++ more))
        ]
