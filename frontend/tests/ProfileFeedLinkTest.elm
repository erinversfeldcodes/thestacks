module ProfileFeedLinkTest exposing (suite)

{-| Tests the Atom subscribe link on a public profile. Built-but-
unreachable in an unusual way: server, cache and rendering were all
finished, but `Api.elm` had no call — profiles are addressed by handle
while the feed endpoint was keyed by user\_id, and no page had both.
Pins the handle-keyed call and the link rendering only when the server
says the feed exists.
-}

import Api exposing (ProfileShelfSummary)
import Expect
import Html.Attributes as Attr
import Page.Profile as Profile
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector


shelf : String -> Bool -> ProfileShelfSummary
shelf name hasFeed =
    { name = name, hasFeed = hasFeed }


{-| Renders just the shelf list, which is the pure surface under test.
-}
render : List ProfileShelfSummary -> Query.Single Profile.Msg
render shelves =
    Profile.viewShelvesFor "erin" shelves |> Query.fromHtml


suite : Test
suite =
    describe "Profile — Atom subscribe link"
        [ test "offers a feed link for a bookshelf that has one" <|
            \_ ->
                render [ shelf "library" True ]
                    |> Query.findAll [ Selector.class "profile__shelf-feed" ]
                    |> Query.count (Expect.equal 1)
        , test "offers no feed link when the bookshelf has no feed" <|
            \_ ->
                render [ shelf "library" False ]
                    |> Query.findAll [ Selector.class "profile__shelf-feed" ]
                    |> Query.count (Expect.equal 0)
        , test "uses the handle-addressed URL, not a UUID" <|
            \_ ->
                render [ shelf "antilibrary" True ]
                    |> Query.find [ Selector.class "profile__shelf-feed" ]
                    |> Query.has
                        [ Selector.attribute
                            (Attr.href "/api/feeds/u/erin/antilibrary")
                        ]
        , test "marks the link as an Atom alternate so browsers can offer to subscribe" <|
            \_ ->
                render [ shelf "library" True ]
                    |> Query.find [ Selector.class "profile__shelf-feed" ]
                    |> Query.has
                        [ Selector.attribute (Attr.type_ "application/atom+xml") ]
        , test "still links to the bookshelf itself alongside the feed" <|
            \_ ->
                render [ shelf "library" True ]
                    |> Query.has
                        [ Selector.attribute (Attr.href "/u/erin/library") ]
        , test "mixed shelves get exactly one link each where a feed exists" <|
            \_ ->
                render
                    [ shelf "library" True
                    , shelf "antilibrary" False
                    , shelf "reading_pile" True
                    ]
                    |> Query.findAll [ Selector.class "profile__shelf-feed" ]
                    |> Query.count (Expect.equal 2)
        ]
