module Components.BlockUserModalTest exposing (suite)

{-| State-machine tests for the reusable "Block a user" overflow menu +
confirmation modal (Issue #193, US-10.1.2 frontend). Exercises the full
lifecycle: open menu -> request -> confirm -> in-flight -> success/failure,
plus the sad paths the backend returns (already\_blocked, not\_found) and the
401 session-expiry escalation.
-}

import Api
import Components.BlockUserModal as BlockModal exposing (Msg(..), OutMsg(..))
import Expect
import Http
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Types.RemoteData exposing (RemoteData(..))


target : BlockModal.Target
target =
    { userId = "user-2", displayName = "Ada Lovelace" }


initModel : BlockModal.Model
initModel =
    BlockModal.init target


suite : Test
suite =
    describe "Components.BlockUserModal"
        [ test "init starts closed, not confirming, NotAsked" <|
            \_ ->
                Expect.all
                    [ \m -> m.menuOpen |> Expect.equal False
                    , \m -> m.confirming |> Expect.equal False
                    , \m -> m.status |> Expect.equal NotAsked
                    ]
                    initModel
        , test "MenuToggled opens the overflow menu" <|
            \_ ->
                let
                    ( m, _, _ ) =
                        BlockModal.update MenuToggled initModel (Just "tok")
                in
                m.menuOpen |> Expect.equal True
        , test "BlockRequested opens the confirmation modal and closes the menu" <|
            \_ ->
                let
                    opened =
                        { initModel | menuOpen = True }

                    ( m, _, _ ) =
                        BlockModal.update BlockRequested opened (Just "tok")
                in
                Expect.all
                    [ \x -> x.confirming |> Expect.equal True
                    , \x -> x.menuOpen |> Expect.equal False
                    ]
                    m
        , test "BlockConfirmed with a token sets status to Loading" <|
            \_ ->
                let
                    confirming =
                        { initModel | confirming = True }

                    ( m, _, _ ) =
                        BlockModal.update BlockConfirmed confirming (Just "tok")
                in
                m.status |> Expect.equal Loading
        , test "BlockConfirmed without a token does not fire (stays NotAsked)" <|
            \_ ->
                let
                    confirming =
                        { initModel | confirming = True }

                    ( m, _, out ) =
                        BlockModal.update BlockConfirmed confirming Nothing
                in
                Expect.all
                    [ \_ -> m.status |> Expect.equal NotAsked
                    , \_ -> out |> Expect.equal NoOut
                    ]
                    ()
        , test "BlockConfirmed is ignored while a block is already in flight" <|
            \_ ->
                let
                    inFlight =
                        { initModel | confirming = True, status = Loading }

                    ( m, _, out ) =
                        BlockModal.update BlockConfirmed inFlight (Just "tok")
                in
                Expect.all
                    [ \_ -> m.status |> Expect.equal Loading
                    , \_ -> out |> Expect.equal NoOut
                    ]
                    ()
        , test "BlockCompleted Ok marks Success and emits UserBlocked with the id" <|
            \_ ->
                let
                    loading =
                        { initModel | confirming = True, status = Loading }

                    ( m, _, out ) =
                        BlockModal.update (BlockCompleted (Ok ())) loading (Just "tok")
                in
                Expect.all
                    [ \_ -> m.status |> Expect.equal (Success ())
                    , \_ -> m.confirming |> Expect.equal False
                    , \_ -> out |> Expect.equal UserBlocked
                    ]
                    ()
        , test "BlockCompleted already_blocked shows a distinct message and stays local" <|
            \_ ->
                let
                    loading =
                        { initModel | confirming = True, status = Loading }

                    ( m, _, out ) =
                        BlockModal.update (BlockCompleted (Err Api.AlreadyBlocked)) loading (Just "tok")
                in
                Expect.all
                    [ \_ -> m.status |> Expect.equal (Failure Api.AlreadyBlocked)
                    , \_ -> out |> Expect.equal NoOut
                    , \_ ->
                        BlockModal.view m
                            |> Query.fromHtml
                            |> Query.has [ Selector.text "You've already blocked this reader." ]
                    ]
                    ()
        , test "BlockCompleted not_found shows a distinct message" <|
            \_ ->
                let
                    loading =
                        { initModel | confirming = True, status = Loading }

                    ( m, _, out ) =
                        BlockModal.update (BlockCompleted (Err Api.NotFound)) loading (Just "tok")
                in
                Expect.all
                    [ \_ -> m.status |> Expect.equal (Failure Api.NotFound)
                    , \_ -> out |> Expect.equal NoOut
                    , \_ ->
                        BlockModal.view m
                            |> Query.fromHtml
                            |> Query.has [ Selector.text "That reader no longer exists." ]
                    ]
                    ()
        , test "BlockCompleted 401 escalates to SessionExpired" <|
            \_ ->
                let
                    loading =
                        { initModel | confirming = True, status = Loading }

                    ( _, _, out ) =
                        BlockModal.update
                            (BlockCompleted (Err (Api.BlockRequestFailed (Http.BadStatus 401))))
                            loading
                            (Just "tok")
                in
                out |> Expect.equal SessionExpired
        , test "BlockDismissed closes the modal and clears status" <|
            \_ ->
                let
                    failed =
                        { initModel | confirming = True, status = Failure Api.AlreadyBlocked }

                    ( m, _, _ ) =
                        BlockModal.update BlockDismissed failed (Just "tok")
                in
                Expect.all
                    [ \x -> x.confirming |> Expect.equal False
                    , \x -> x.status |> Expect.equal NotAsked
                    ]
                    m
        , test "view renders the overflow trigger by default" <|
            \_ ->
                BlockModal.view initModel
                    |> Query.fromHtml
                    |> Query.has [ Selector.class "block-user__trigger" ]
        , test "an open menu offers a Block action labelled with the target name" <|
            \_ ->
                BlockModal.view { initModel | menuOpen = True }
                    |> Query.fromHtml
                    |> Query.has [ Selector.text "Block Ada Lovelace" ]
        , test "the confirmation modal disables the confirm button while blocking" <|
            \_ ->
                BlockModal.view { initModel | confirming = True, status = Loading }
                    |> Query.fromHtml
                    |> Query.find [ Selector.class "block-user__confirm" ]
                    |> Query.has [ Selector.disabled True ]
        ]
