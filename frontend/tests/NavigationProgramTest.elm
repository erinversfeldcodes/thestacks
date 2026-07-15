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
import Page.Search as Search
import Page.Upload as Upload
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
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
        ]


navigateToUpload : Test
navigateToUpload =
    test "navigate_to_upload: /upload URL maps to Upload route and renders upload page content" <|
        \() ->
            let
                route =
                    fromPath "/upload"

                view =
                    Upload.view Upload.init (Just "test-token")
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
                    Search.view Search.init
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
