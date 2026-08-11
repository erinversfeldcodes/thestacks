module Page.AboutTest exposing (suite)

{-| Oracle for the About page copy (sibling;, 8c).

The page now carries the owner's approved launch copy
(`plans/318-about-page-copy-draft.md`), section by section.

⚠️ **Drift oracle.** The pre-8c About was placeholder prose — a single lede
("Placeholder copy — the owner will refine this.") plus the transparency links.
It had none of the narrative below (the antilibrary framing, the five shelves,
"Add a book by its cover", the wider shelf, the closing line), so every content
assertion here fails on that surface. The transparency links are asserted too,
because they are preserved (About is still their only entry point).

-}

import Expect
import Html.Attributes as Attr
import Page.About as About
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector


rendered : Query.Single msg
rendered =
    About.view |> Query.fromHtml


suite : Test
suite =
    describe "Page.About — owner launch copy"
        [ test "hero lede sets the one-liner" <|
            \() ->
                rendered
                    |> Query.has
                        [ Selector.text "A quiet place for the books you own, the pieces you've read, and the knowledge you're still circling." ]
        , test "'What The Stacks is' names the antilibrary conviction" <|
            \() ->
                rendered
                    |> Expect.all
                        [ Query.has [ Selector.text "What The Stacks is" ]
                        , Query.has [ Selector.text "antilibrary" ]
                        ]
        , test "'The five shelves' lists all five by name" <|
            \() ->
                rendered
                    |> Query.find [ Selector.class "about__shelves" ]
                    |> Expect.all
                        [ Query.has [ Selector.text "Antilibrary" ]
                        , Query.has [ Selector.text "Library" ]
                        , Query.has [ Selector.text "Reading pile" ]
                        , Query.has [ Selector.text "Wishlist" ]
                        , Query.has [ Selector.text "Looking for a home" ]
                        ]
        , test "'What you can do' leads with the cover-scan capability" <|
            \() ->
                rendered
                    |> Query.find [ Selector.class "about__do-list" ]
                    |> Query.has [ Selector.text "Add a book by its cover." ]
        , test "'Built to be yours' states the open-source / self-host framing" <|
            \() ->
                rendered
                    |> Query.has
                        [ Selector.text "The Stacks is open source and privately hosted, though you are also welcome to self-host." ]
        , test "'The wider shelf' is PRESENT-TENSE (owner ruling) — no 'coming soon' hedge" <|
            \() ->
                rendered
                    |> Expect.all
                        [ Query.has [ Selector.text "The wider shelf" ]
                        , Query.has
                            [ Selector.text "Bookshops, reading groups, and cafés can share what they're up to" ]
                        ]
        , test "closes with the invitation" <|
            \() ->
                rendered
                    |> Query.has
                        [ Selector.text "Pull up a chair. The Stacks is quieter than the internet, and it's here to give you the space to think." ]
        , test "preserves the transparency links (still About's only entry point)" <|
            \() ->
                rendered
                    |> Expect.all
                        [ Query.find [ Selector.attribute (Attr.attribute "data-testid" "about-metrics-link") ]
                            >> Query.has [ Selector.attribute (Attr.href "/metrics") ]
                        , Query.find [ Selector.attribute (Attr.attribute "data-testid" "about-costs-link") ]
                            >> Query.has [ Selector.attribute (Attr.href "/costs") ]
                        ]
        ]
