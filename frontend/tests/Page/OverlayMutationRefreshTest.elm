module Page.OverlayMutationRefreshTest exposing (suite)

{-| The overlay opens ON TOP of a page that stays mounted. Drive evidence: move
a book out of the Library through the overlay, close it, and the shelf behind
still shows the book on the shelf it just left — a successful write and a stale
read, correct only until the reader presses reload.

The correction is a hand-off in three parts, and each part is pinned here:
the overlay reports a completed placement write (`BookDetail.PlacementMutated`),
`Main` hands that to the page underneath without disturbing it, and the page
answers by re-reading its own shelves from its own endpoint — the reader's, or
the profile's if they are browsing someone else's.

-}

import Components.BookList as BookList
import Components.ViewModeToggle exposing (ShelfViewMode(..))
import Dict
import Expect
import Http
import Main
import Navigation.Route as Route
import Page.BookDetail as BookDetail
import Page.Bookshelf as Bookshelf
import Page.Bookshelf.ReadingPile as ReadingPile
import ProgramTest
import Test exposing (Test, describe, test)
import TestHelpers
    exposing
        ( bookDetailOverlayProgramWithOut
        , bookshelfProgram
        , profileShelfProgram
        , readingPileProgram
        , simulateBookDetailResponseWithPlacement
        , simulateBookshelfResponse
        , testBook
        , testPlacement
        )
import Types.RemoteData exposing (RemoteData(..))
import Types.Shelf exposing (Shelf)


suite : Test
suite =
    describe "a placement write in the overlay reaches the page behind it"
        [ overlayMoveReportsAMutation
        , overlayMoveFailureReportsNothing
        , overlayFormatsReportsAMutation
        , shelfAnswersAReloadRequest
        , profileShelfReloadReadsTheProfileShelf
        , readingPileAnswersAReloadRequest
        , shelvesSourceNamesTheProfileRead
        , shelvesSourceNamesTheOwnersRead
        , shelvesSourceAsksForNothingWithoutCredentials
        , refreshReachesTheShelfWithoutBlankingIt
        , refreshReachesTheReadingPile
        , refreshLeavesOtherPagesAlone
        ]



-- THE OVERLAY'S HALF


moveEndpoint : String
moveEndpoint =
    "/api/placements/placement-test-001/move"


{-| The overlay, showing a book that sits on the Library, with the shelf mover
opened and a move confirmed — the PUT in flight.
-}
overlayMidMove : ProgramTest.ProgramTest TestHelpers.BookDetailTestModel BookDetail.Msg (ProgramTest.SimulatedEffect BookDetail.Msg)
overlayMidMove =
    ProgramTest.start ()
        (bookDetailOverlayProgramWithOut "book-test-001" (Just "test-token") (Just Route.Library))
        |> ProgramTest.simulateHttpResponse "GET"
            "/api/books/book-test-001"
            (simulateBookDetailResponseWithPlacement "book-test-001" testBook testPlacement)
        |> ProgramTest.clickButton "Choose Bookshelf"
        |> ProgramTest.clickButton "Move"


moveResponse : Http.Response String
moveResponse =
    Http.GoodStatus_
        { url = moveEndpoint
        , statusCode = 200
        , statusText = "OK"
        , headers = Dict.empty
        }
        ""


overlayFormatsReportsAMutation : Test
overlayFormatsReportsAMutation =
    test "overlay_formats_reports_a_mutation: a stored formats change tells the host the placement changed" <|
        \() ->
            ProgramTest.start ()
                (bookDetailOverlayProgramWithOut "book-test-001" (Just "test-token") (Just Route.Library))
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/books/book-test-001"
                    (simulateBookDetailResponseWithPlacement "book-test-001" testBook testPlacement)
                |> ProgramTest.clickButton "Physical"
                |> ProgramTest.simulateHttpResponse "PUT"
                    "/api/placements/placement-test-001/formats"
                    (TestHelpers.simulatePlacementFormatsResponse "placement-test-001" [ "physical" ])
                |> ProgramTest.expectModel
                    (\model ->
                        Expect.equal BookDetail.PlacementMutated model.lastOut
                    )


overlayMoveReportsAMutation : Test
overlayMoveReportsAMutation =
    test "overlay_move_reports_a_mutation: a completed move tells the host the placement changed" <|
        \() ->
            overlayMidMove
                |> ProgramTest.simulateHttpResponse "PUT" moveEndpoint moveResponse
                |> ProgramTest.expectModel
                    (\model ->
                        Expect.equal BookDetail.PlacementMutated model.lastOut
                    )


{-| The signal has to mean "the server changed", not "the reader tried". A
refetch on a rejected move would re-read a shelf that never changed and, worse,
teach the host to trust a signal that is sometimes about nothing.
-}
overlayMoveFailureReportsNothing : Test
overlayMoveFailureReportsNothing =
    test "overlay_move_failure_reports_nothing: a rejected move raises no mutation signal" <|
        \() ->
            overlayMidMove
                |> ProgramTest.simulateHttpResponse "PUT"
                    moveEndpoint
                    (Http.BadStatus_
                        { url = moveEndpoint
                        , statusCode = 500
                        , statusText = "Internal Server Error"
                        , headers = Dict.empty
                        }
                        ""
                    )
                |> ProgramTest.expectModel
                    (\model ->
                        Expect.equal BookDetail.NoOut model.lastOut
                    )



-- THE SHELF'S HALF


shelfAnswersAReloadRequest : Test
shelfAnswersAReloadRequest =
    test "shelf_answers_a_reload_request: the owner's shelf re-reads its own bookshelf" <|
        \() ->
            ProgramTest.start () (bookshelfProgram Bookshelf.libraryConfig (Just "owner-token"))
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/library"
                    (simulateBookshelfResponse [ testPlacement ])
                |> ProgramTest.update Bookshelf.ReloadRequested
                |> ProgramTest.expectHttpRequests "GET"
                    "/api/bookshelves/library"
                    (List.length >> Expect.equal 1)


{-| The latent half of the same defect. A reader browsing `/u/alice/library`
is looking at ALICE's shelf; a refetch that reads `/api/bookshelves/library`
would fetch the VIEWER's books and paint them into Alice's page — and because
the response carries the profile's `requestKey`, nothing downstream could tell
that the shelf on screen now belongs to the wrong person.
-}
profileShelfReloadReadsTheProfileShelf : Test
profileShelfReloadReadsTheProfileShelf =
    test "profile_shelf_reload_reads_the_profile_shelf: a refetch while browsing stays on that reader's shelf" <|
        \() ->
            ProgramTest.start () (profileShelfProgram (Just "viewer-token") "alice" "library")
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/u/alice/bookshelves/library"
                    (simulateBookshelfResponse [ testPlacement ])
                |> ProgramTest.update Bookshelf.ReloadRequested
                |> Expect.all
                    [ ProgramTest.expectHttpRequests "GET"
                        "/api/u/alice/bookshelves/library"
                        (List.length >> Expect.equal 1)
                    , ProgramTest.expectHttpRequests "GET"
                        "/api/bookshelves/library"
                        (List.length >> Expect.equal 0)
                    ]


{-| The pile is where a placement write is most likely to happen behind an
overlay: finishing a book moves it to the Library, and the pile it left has to
notice.
-}
readingPileAnswersAReloadRequest : Test
readingPileAnswersAReloadRequest =
    test "reading_pile_answers_a_reload_request: the pile re-reads itself" <|
        \() ->
            ProgramTest.start () (readingPileProgram (Just "owner-token"))
                |> ProgramTest.simulateHttpResponse "GET"
                    "/api/bookshelves/reading_pile"
                    (simulateBookshelfResponse [ testPlacement ])
                |> ProgramTest.update ReadingPile.ReloadRequested
                |> ProgramTest.expectHttpRequests "GET"
                    "/api/bookshelves/reading_pile"
                    (List.length >> Expect.equal 1)


shelvesSourceNamesTheProfileRead : Test
shelvesSourceNamesTheProfileRead =
    test "shelves_source_profile: browsing a profile shelf reads the profile endpoint" <|
        \() ->
            Bookshelf.shelvesSource (Bookshelf.profileConfig "alice" "library") (Just "viewer-token")
                |> Expect.equal (Bookshelf.ProfileShelf (Just "viewer-token") "alice" "library")


shelvesSourceNamesTheOwnersRead : Test
shelvesSourceNamesTheOwnersRead =
    test "shelves_source_own: a reader's own shelf reads their own bookshelf" <|
        \() ->
            Bookshelf.shelvesSource Bookshelf.libraryConfig (Just "owner-token")
                |> Expect.equal (Bookshelf.OwnShelf "owner-token" "library")


{-| A signed-out reader on their own shelf route has nothing to read, and asking
anyway would be an unauthenticated request the page cannot use.
-}
shelvesSourceAsksForNothingWithoutCredentials : Test
shelvesSourceAsksForNothingWithoutCredentials =
    test "shelves_source_none: no token on an owner shelf means no read at all" <|
        \() ->
            Bookshelf.shelvesSource Bookshelf.libraryConfig Nothing
                |> Expect.equal Bookshelf.NoShelvesRequest



-- MAIN'S HALF


loadedShelf : Bookshelf.Config -> Bookshelf.Model
loadedShelf config =
    { shelves = Success [ Shelf "shelf-1" 0 [ testPlacement ] ]
    , showAgeGate = False
    , config = config
    , userId = "reader-1"
    , visibility = "owner"
    , rssLink = { showUrl = False }
    , viewMode = ListView
    , sortState = { column = BookList.Author, direction = BookList.Desc }
    , token = Just "owner-token"
    , organiser = { dragging = Nothing }
    , organiserBusy = False
    , organiserError = Nothing
    , undoToast = Bookshelf.ToastHidden
    , focusedSpine = Nothing
    }


{-| The page is still on screen underneath the overlay, so correcting it must
not empty it: dropping the shelves back to `Loading` (as rebuilding the page
would) flashes an empty bookcase behind the reader's own dialog. The refetch
replaces the content when it lands, not before.
-}
refreshReachesTheShelfWithoutBlankingIt : Test
refreshReachesTheShelfWithoutBlankingIt =
    test "refresh_keeps_the_shelf_on_screen: correcting the page behind does not blank it" <|
        \() ->
            let
                shelf =
                    loadedShelf Bookshelf.libraryConfig
            in
            case Main.refreshShelfBehindOverlay (Main.PageBookshelf shelf) of
                Just ( Main.PageBookshelf refreshed, _ ) ->
                    Expect.all
                        [ \m -> Expect.equal shelf.shelves m.shelves
                        , \m -> Expect.equal ListView m.viewMode
                        , \m -> Expect.equal BookList.Author m.sortState.column
                        ]
                        refreshed

                Nothing ->
                    Expect.fail "the shelf behind the overlay was left holding its stale read"

                _ ->
                    Expect.fail "the refresh replaced which page was underneath the overlay"


refreshReachesTheReadingPile : Test
refreshReachesTheReadingPile =
    test "refresh_reaches_the_reading_pile: the pile behind the overlay is corrected too" <|
        \() ->
            let
                ( pile, _ ) =
                    ReadingPile.init (Just "owner-token")
            in
            case Main.refreshShelfBehindOverlay (Main.PageReadingPile { pile | books = Success [ testPlacement ] }) of
                Just ( Main.PageReadingPile refreshed, _ ) ->
                    Expect.equal (Success [ testPlacement ]) refreshed.books

                Nothing ->
                    Expect.fail "the pile behind the overlay was left holding its stale read"

                _ ->
                    Expect.fail "the refresh replaced which page was underneath the overlay"


{-| A placement write changes nothing on a page that renders no placements, and
re-entering one would throw away whatever the reader had done there.
-}
refreshLeavesOtherPagesAlone : Test
refreshLeavesOtherPagesAlone =
    test "refresh_leaves_other_pages_alone: a page that shows no placements is untouched" <|
        \() ->
            case Main.refreshShelfBehindOverlay Main.PageAbout of
                Nothing ->
                    Expect.pass

                Just _ ->
                    Expect.fail "a page with no placements on it was rebuilt by a placement mutation"
