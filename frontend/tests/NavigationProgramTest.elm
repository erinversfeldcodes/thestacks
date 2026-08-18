module NavigationProgramTest exposing (suite)

{-| Navigation tests verifying that URL paths map to the correct routes
and that each routed page renders its distinctive content.

Main.elm uses Browser.application with a port (onSwipe), which requires
Nav.Key and cannot be constructed in pure Elm tests. Instead, we test:

1.  Route.fromUrl maps each URL path to the correct Route variant
2.  Each page's view function renders the expected CSS class and content

Together these prove that navigating to a URL renders the right page.

-}

import Expect
import Navigation.Route as Route exposing (Route(..))
import Page.Bookshelf as Bookshelf
import Page.Bookshelf.LookingForHome as LookingForHome
import Page.Bookshelf.ReadingPile as ReadingPile
import Page.Search as Search
import Page.Upload as Upload
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import TestHelpers
import Types.RemoteData exposing (RemoteData(..))
import Types.Shelf exposing (BookshelfResponse, Shelf)
import Url


{-| Parse a URL path into a Route, using a fake base URL.
-}
fromPath : String -> Route
fromPath path =
    case Url.fromString ("http://localhost" ++ path) of
        Just url ->
            Route.fromUrl url

        Nothing ->
            NotFound


suite : Test
suite =
    describe "Navigation"
        [ navigateToUpload
        , navigateToLibrary
        , navigateToSearch
        , navigateNotFound
        , navigateAwayMidLoad
        ]


{-| A shelf payload carrying one recognisable book, standing in for the
response to the bookshelf the user has just navigated AWAY from.
-}
staleLibraryResponse : BookshelfResponse
staleLibraryResponse =
    { shelves =
        [ Shelf "shelf-library-1" 0 [ TestHelpers.testPlacement ]
        ]
    , visibility = "owner"
    }


{-| — sad path.

Main.elm dispatches page messages by matching on the `Page` constructor
(`Main.elm:1347-1396`), so a response for a page the user has left is dropped
for every _cross-constructor_ move (Library -> Reading Pile, etc.).

Library, Antilibrary and Wish List, however, all share the single
`PageBookshelf` constructor (`Main.elm:542-549`), so a response for one of them
still reaches the model of another. `BookshelfResponse` carries no bookshelf
identity, so `Page.Bookshelf.update` cannot tell whose response it is holding.
These tests pin the invariant: only the response the CURRENT config asked for
may be applied.

-}
navigateAwayMidLoad : Test
navigateAwayMidLoad =
    describe "navigate away mid-load"
        [ staleSiblingShelfResponseIsDiscarded
        , staleSiblingShelfResponseDoesNotRender
        , matchingShelfResponseIsStillApplied
        , pilePagesStartIndependentlyLoading
        ]


{-| The core hazard: leave /library while its GET is in flight, land on
/antilibrary, and let the library response arrive afterwards. The antilibrary
model must still be Loading -- it has its own request outstanding.
-}
staleSiblingShelfResponseIsDiscarded : Test
staleSiblingShelfResponseIsDiscarded =
    test "navigate_away_mid_load: a Library response arriving after routing to the Antilibrary is discarded" <|
        \() ->
            let
                ( libraryModel, _ ) =
                    Bookshelf.init Bookshelf.libraryConfig (Just "test-token") "test-user-id"

                ( antiLibraryModel, _ ) =
                    Bookshelf.init Bookshelf.antiLibraryConfig (Just "test-token") "test-user-id"

                ( afterStale, _, _ ) =
                    Bookshelf.update
                        (Bookshelf.ShelvesLoaded
                            (Bookshelf.requestKey Bookshelf.libraryConfig)
                            (Ok staleLibraryResponse)
                        )
                        antiLibraryModel
            in
            Expect.all
                [ \_ -> libraryModel.shelves |> Expect.equal Loading
                , \_ -> afterStale.shelves |> Expect.equal Loading
                ]
                ()


{-| The user-visible consequence of the same hazard: the destination page must
not paint the previous shelf's books.
-}
staleSiblingShelfResponseDoesNotRender : Test
staleSiblingShelfResponseDoesNotRender =
    test "navigate_away_mid_load: the Antilibrary does not render the stale Library book" <|
        \() ->
            let
                ( antiLibraryModel, _ ) =
                    Bookshelf.init Bookshelf.antiLibraryConfig (Just "test-token") "test-user-id"

                ( afterStale, _, _ ) =
                    Bookshelf.update
                        (Bookshelf.ShelvesLoaded
                            (Bookshelf.requestKey Bookshelf.libraryConfig)
                            (Ok staleLibraryResponse)
                        )
                        antiLibraryModel
            in
            Bookshelf.view afterStale
                |> Query.fromHtml
                |> Query.hasNot [ Selector.text "The Power of Habit" ]


{-| Non-vacuity guard: discarding must be selective. The response the CURRENT
page actually asked for still has to be applied.
-}
matchingShelfResponseIsStillApplied : Test
matchingShelfResponseIsStillApplied =
    test "navigate_away_mid_load: the response the current bookshelf asked for is still applied" <|
        \() ->
            let
                ( libraryModel, _ ) =
                    Bookshelf.init Bookshelf.libraryConfig (Just "test-token") "test-user-id"

                ( afterFresh, _, _ ) =
                    Bookshelf.update
                        (Bookshelf.ShelvesLoaded
                            (Bookshelf.requestKey Bookshelf.libraryConfig)
                            (Ok staleLibraryResponse)
                        )
                        libraryModel
            in
            afterFresh.shelves
                |> Expect.equal (Success staleLibraryResponse.shelves)


{-| Reading Pile and Looking for a Home own separate models (`BooksLoaded` /
`books`), so the unified page's behaviour does not imply theirs. Each is the
sole route behind its own `Page` constructor (`Main.elm:551-563`), so the
constructor match in `Main.elm:1398-1459` already discards any response that
arrives after the user has routed away -- there is no same-constructor sibling
that could receive it.

This test pins the precondition that keeps that true: each page initialises its
OWN `books` field to `Loading`, independently of the other.

-}
pilePagesStartIndependentlyLoading : Test
pilePagesStartIndependentlyLoading =
    test "navigate_away_mid_load: Reading Pile and Looking for a Home hold independent Loading state" <|
        \() ->
            let
                ( readingPileModel, _ ) =
                    ReadingPile.init (Just "test-token")

                ( lookingForHomeModel, _ ) =
                    LookingForHome.init (Just "test-token")
            in
            Expect.all
                [ \_ -> readingPileModel.books |> Expect.equal Loading
                , \_ -> lookingForHomeModel.books |> Expect.equal Loading
                ]
                ()


navigateToUpload : Test
navigateToUpload =
    test "navigate_to_upload: /upload URL maps to Upload route and renders upload page content" <|
        \() ->
            let
                route =
                    fromPath "/upload"

                view =
                    Upload.view Upload.init (Just "test-token") Types.RemoteData.NotAsked
            in
            Expect.all
                [ \_ -> route |> Expect.equal Upload
                , \_ ->
                    view
                        |> Query.fromHtml
                        |> Query.has
                            [ Selector.class "page--upload" ]
                , \_ ->
                    view
                        |> Query.fromHtml
                        |> Query.has
                            [ Selector.text "Add a Book" ]
                ]
                ()


navigateToLibrary : Test
navigateToLibrary =
    test "navigate_to_library: /library URL maps to Library route and renders library page content" <|
        \() ->
            let
                route =
                    fromPath "/library"

                ( model, _ ) =
                    Bookshelf.init Bookshelf.libraryConfig Nothing "test-user-id"

                view =
                    Bookshelf.view model
            in
            Expect.all
                [ \_ -> route |> Expect.equal Library
                , \_ ->
                    view
                        |> Query.fromHtml
                        |> Query.has
                            [ Selector.class "page--shelf" ]
                , \_ ->
                    view
                        |> Query.fromHtml
                        |> Query.has
                            [ Selector.text "Library" ]
                ]
                ()


navigateToSearch : Test
navigateToSearch =
    test "navigate_to_search: /search URL maps to Search route and renders search page content" <|
        \() ->
            let
                route =
                    fromPath "/search"

                view =
                    Search.view True Search.init
            in
            Expect.all
                [ \_ -> route |> Expect.equal Search
                , \_ ->
                    view
                        |> Query.fromHtml
                        |> Query.has
                            [ Selector.class "page--search" ]
                , \_ ->
                    view
                        |> Query.fromHtml
                        |> Query.has
                            [ Selector.text "Search books & readers" ]
                ]
                ()


navigateNotFound : Test
navigateNotFound =
    test "navigate_not_found: unknown URL maps to NotFound route" <|
        \() ->
            let
                route =
                    fromPath "/this/does/not/exist"
            in
            route |> Expect.equal NotFound
