module MainViewTest exposing (suite)

{-| Render tests for the three static top-level views in Main.elm:
`viewHome`, `viewFooter`, and `viewNotFound`.

These mirror the `MainNavTest`/`viewNav` pattern — Main.elm is a
`Browser.application` with ports and a `Nav.Key`, so the full update loop
cannot be program-tested. We assert the shipped markup of each pure view
directly.

The home CTAs asserted here are the post-#235 shipped surface (About +
Marketplace), not the pre-#235 "View Antilibrary / Add a Book" markup.

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
        [ describe "viewHome (shipped #235 CTAs)"
            [ test "renders the h1 title 'The Stacks'" <|
                \() ->
                    Main.viewHome
                        |> Query.fromHtml
                        |> Query.find [ Selector.tag "h1" ]
                        |> Query.has [ Selector.text "The Stacks" ]
            , test "renders the subtitle" <|
                \() ->
                    Main.viewHome
                        |> Query.fromHtml
                        |> Query.has
                            [ Selector.text "Your personal collection, beautifully organised." ]
            , test "renders the primary About CTA linking to /about" <|
                \() ->
                    Main.viewHome
                        |> Query.fromHtml
                        |> Query.find
                            [ Selector.class "home__link--about" ]
                        |> Expect.all
                            [ Query.has [ Selector.class "btn--primary" ]
                            , Query.has [ Selector.attribute (Attr.href "/about") ]
                            , Query.has [ Selector.text "About The Stacks" ]
                            ]
            , test "renders the secondary Marketplace CTA linking to /marketplace" <|
                \() ->
                    Main.viewHome
                        |> Query.fromHtml
                        |> Query.find
                            [ Selector.class "home__link--marketplace" ]
                        |> Expect.all
                            [ Query.has [ Selector.class "btn--secondary" ]
                            , Query.has [ Selector.attribute (Attr.href "/marketplace") ]
                            , Query.has [ Selector.text "Browse the Marketplace" ]
                            ]
            , test "does not render the pre-#235 Antilibrary / Add a Book CTAs" <|
                \() ->
                    Main.viewHome
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.hasNot [ Selector.text "View Antilibrary" ]
                            , Query.hasNot [ Selector.text "Add a Book" ]
                            ]
            ]
        , describe "viewFooter"
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
