module Page.LookingForHomeRoomTest exposing (suite)

{-| Oracle for: the Looking-for-a-Home shelf renders
as a **real room in the shelf-room family** — wallpaper, lamplight, and a
brass-plate label — with the pile-view of cover cards staged _inside_ that room.

⚠️ **Drift oracle.** The pre-8c view was a flat page: `div.page.page--bookshelf`
holding an `h1.page__title` and a bare `.pile-view`, with no room scaffold. The
assertions below (room scaffold present; the pile-view is a descendant of
`.shelf-room`; the flat `h1.page__title` is gone) all fail on that surface.

-}

import Expect
import Page.Bookshelf.LookingForHome as LookingForHome
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import TestHelpers exposing (namedPlacement)
import Types.RemoteData exposing (RemoteData(..))


populated : LookingForHome.Model
populated =
    { books = Success [ namedPlacement "b1" "Dune", namedPlacement "b2" "Emma" ]
    , showAgeGate = False
    }


empty : LookingForHome.Model
empty =
    { books = Success [], showAgeGate = False }


suite : Test
suite =
    describe "Page.Bookshelf.LookingForHome — room scaffold"
        [ test "renders the shelf-room family scaffold (wallpaper, lighting, room, brass label)" <|
            \() ->
                LookingForHome.view populated
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.has [ Selector.class "wallpaper" ]
                        , Query.has [ Selector.class "lighting" ]
                        , Query.has [ Selector.class "shelf-room" ]
                        , Query.has [ Selector.class "shelf-label" ]
                        ]
        , test "the brass label carries the shelf name, not a flat h1.page__title" <|
            \() ->
                LookingForHome.view populated
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.find [ Selector.class "shelf-label" ]
                            >> Query.has [ Selector.text "Looking for a Home" ]
                        , Query.hasNot [ Selector.class "page__title" ]
                        ]
        , test "the pile-view of cover cards is staged INSIDE the room" <|
            \() ->
                LookingForHome.view populated
                    |> Query.fromHtml
                    |> Query.find [ Selector.class "shelf-room" ]
                    |> Query.find [ Selector.class "pile-view" ]
                    |> Query.has [ Selector.class "pile-view__book" ]
        , test "the empty state renders inside the room, not on a stripped page" <|
            \() ->
                LookingForHome.view empty
                    |> Query.fromHtml
                    |> Query.find [ Selector.class "shelf-room" ]
                    |> Query.has [ Selector.text "Nothing here yet — these are books looking for a new home." ]
        ]
