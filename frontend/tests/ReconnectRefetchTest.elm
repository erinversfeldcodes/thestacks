module ReconnectRefetchTest exposing (suite)

{-| #368 — the scoped reconnect-refetch decision.

The Wave 6 drive proved the defect live: the app cleared its own offline
banner on reconnect and left the shelf reading "unreachable … try again" on a
working connection. The fix is Main's `reconnectShouldRefetch`, gated three
ways (owner-decided scope), and each gate has a test that is FALSE without it:

  - only the offline→online TRANSITION (not a repeated `online`, not going
    offline);
  - only the CURRENTLY routed page;
  - only a `NetworkError` loss — `Timeout` and 5xx keep #362's distinct
    treatment, because reconnecting is not what fixes those.

Verified by unit rather than live drive: `navigator.onLine` cannot be forced
from the driver (the #368 filing's own harness note), so the pure decision is
pinned here and the wiring runs through the same `initPage` path every
navigation exercises.

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
    describe "reconnectShouldRefetch (#368)"
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
        , test "a Timeout does not refetch — reconnecting is not what fixes it (#362's split)" <|
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
