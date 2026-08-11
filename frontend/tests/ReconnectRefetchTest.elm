module ReconnectRefetchTest exposing (suite)

{-| The scoped reconnect-refetch decision. Live drive: the app cleared its
own offline banner on reconnect and left the shelf saying "unreachable"
on a working connection. `Main.reconnectShouldRefetch` is gated three
ways (owner-decided scope) and each gate has a test that is FALSE
without it: only on offline→online, only for connectivity-shaped
failures, only for the shelf surfaces in scope.
-}

import Components.BookList as BookList
import Components.ViewModeToggle exposing (ShelfViewMode(..))
import Expect
import Http
import Main exposing (Connectivity(..))
import Page.Bookshelf as Bookshelf
import Test exposing (Test, describe, test)
import Types.RemoteData exposing (RemoteData(..))
import Types.Shelf exposing (Shelf)


{-| A bookshelf page whose shelves are in the given state.
-}
bookshelfIn : RemoteData Http.Error (List Shelf) -> Main.Page
bookshelfIn shelves =
    Main.PageBookshelf
        { shelves = shelves
        , showAgeGate = False
        , config = Bookshelf.libraryConfig
        , userId = "reader-1"
        , visibility = "owner"
        , rssLink = { showUrl = False }
        , viewMode = SpineView
        , sortState = { column = BookList.Title, direction = BookList.Asc }
        , token = Nothing
        , organiser = { dragging = Nothing }
        , organiserBusy = False
        , organiserError = Nothing
        , undoToast = Bookshelf.ToastHidden
        , focusedSpine = Nothing
        }


suite : Test
suite =
    describe "reconnectShouldRefetch"
        [ test "offline→online with the shelf lost to the network refetches" <|
            \_ ->
                Main.reconnectShouldRefetch Offline
                    Online
                    (bookshelfIn (Failure Http.NetworkError))
                    |> Expect.equal True
        , test "a repeated online event does not refetch — transition only" <|
            \_ ->
                Main.reconnectShouldRefetch Online
                    Online
                    (bookshelfIn (Failure Http.NetworkError))
                    |> Expect.equal False
        , test "going offline never refetches" <|
            \_ ->
                Main.reconnectShouldRefetch Online
                    Offline
                    (bookshelfIn (Failure Http.NetworkError))
                    |> Expect.equal False
        , test "a Timeout does not refetch — reconnecting is not what fixes it" <|
            \_ ->
                Main.reconnectShouldRefetch Offline
                    Online
                    (bookshelfIn (Failure Http.Timeout))
                    |> Expect.equal False
        , test "a 500 does not refetch" <|
            \_ ->
                Main.reconnectShouldRefetch Offline
                    Online
                    (bookshelfIn (Failure (Http.BadStatus 500)))
                    |> Expect.equal False
        , test "a healthy shelf does not refetch" <|
            \_ ->
                Main.reconnectShouldRefetch Offline
                    Online
                    (bookshelfIn (Success []))
                    |> Expect.equal False
        , test "a page outside the opted-in family keeps today's behaviour" <|
            \_ ->
                Main.reconnectShouldRefetch Offline Online Main.PageNotFound
                    |> Expect.equal False
        ]
