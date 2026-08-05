module MainViewTest exposing (suite)

{-| Render tests for the static top-level views in Main.elm:
`viewFooter` and `viewNotFound`.

These mirror the `MainNavTest`/`viewNav` pattern — Main.elm is a
`Browser.application` with ports and a `Nav.Key`, so the full update loop
cannot be program-tested. We assert the shipped markup of each pure view
directly.

The home page moved out of Main.elm into `Page.Home` (Wave 8 #318, 8c) so its
two auth-branched faces can be view-tested directly — see `Page.HomeTest`.

-}

import Expect
import Html.Attributes as Attr
import Main
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector


suite : Test
suite =
    describe "Main static views"
        [ describe "viewFooter"
            [ test "renders a footer.app-footer" <|
                \() ->
                    Main.viewFooter
                        |> Query.fromHtml
                        |> Query.has
                            [ Selector.tag "footer"
                            , Selector.class "app-footer"
                            ]
            , test "renders the tagline in p.app-footer__text" <|
                \() ->
                    Main.viewFooter
                        |> Query.fromHtml
                        |> Query.find [ Selector.class "app-footer__text" ]
                        |> Expect.all
                            [ Query.has [ Selector.tag "p" ]
                            , Query.has
                                [ Selector.text "The Stacks — open source book management" ]
                            ]
            ]
        , describe "viewNotFound"
            [ test "renders the 'Page Not Found' heading" <|
                \() ->
                    Main.viewNotFound
                        |> Query.fromHtml
                        |> Query.find [ Selector.tag "h1" ]
                        |> Query.has [ Selector.text "Page Not Found" ]
            , test "renders the explanation copy" <|
                \() ->
                    Main.viewNotFound
                        |> Query.fromHtml
                        |> Query.has
                            [ Selector.text "The page you're looking for doesn't exist." ]
            , test "renders a 'Go Home' link to /" <|
                \() ->
                    Main.viewNotFound
                        |> Query.fromHtml
                        |> Query.find [ Selector.tag "a" ]
                        |> Expect.all
                            [ Query.has [ Selector.attribute (Attr.href "/") ]
                            , Query.has [ Selector.text "Go Home" ]
                            ]
            ]
        ]
