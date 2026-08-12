module Page.HomeTest exposing (suite)

{-| Oracles for the two faces of `/` (,, 8c).

`Page.Home.view` branches on the model's constructor, which `init` chooses from
auth state: signed out → `Landing`, signed in → `Collection` with the shelf
preview. Each face is a pure view, so we assert its markup directly (Main.elm
itself is a `Browser.application` that cannot be program-tested).

⚠️ **The authed-home tests are the drift oracle.** The pre-8c home was a single
static `viewHome` in Main.elm that ALWAYS rendered the About / Marketplace
landing and NEVER an Add-Book CTA or a shelf glimpse. "authed home has a
persistent Add-Book CTA into the upload flow" and "authed home does not render
the Marketplace landing CTA" both fail on that old surface — that is the point.

-}

import Expect
import Html.Attributes as Attr
import Http
import Page.Home as Home exposing (Model(..), Msg(..), OutMsg(..))
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import TestHelpers exposing (namedPlacement)
import Types.Placement exposing (Placement)
import Types.RemoteData exposing (RemoteData(..))


suite : Test
suite =
    describe "Page.Home"
        [ describe "init branches on auth state"
            [ test "signed out → Landing, no request" <|
                \() ->
                    Home.init Nothing
                        |> Tuple.first
                        |> Expect.equal Landing
            , test "signed in → Collection with the preview Loading" <|
                \() ->
                    case Tuple.first (Home.init (Just "token-abc")) of
                        Collection { preview } ->
                            Expect.equal Loading preview

                        Landing ->
                            Expect.fail "expected Collection for a signed-in reader"
            ]
        , describe "Landing face (unauthenticated, CTAs)"
            [ test "renders the title and subtitle" <|
                \() ->
                    Home.view Landing
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.has [ Selector.tag "h1", Selector.text "The Stacks" ]
                            , Query.has [ Selector.text "Your personal collection, beautifully organised." ]
                            ]
            , test "renders the About CTA → /about" <|
                \() ->
                    Home.view Landing
                        |> Query.fromHtml
                        |> Query.find [ Selector.class "home__link--about" ]
                        |> Expect.all
                            [ Query.has [ Selector.attribute (Attr.href "/about") ]
                            , Query.has [ Selector.text "About The Stacks" ]
                            ]
            , test "renders the Marketplace CTA → /marketplace" <|
                \() ->
                    Home.view Landing
                        |> Query.fromHtml
                        |> Query.find [ Selector.class "home__link--marketplace" ]
                        |> Query.has [ Selector.attribute (Attr.href "/marketplace") ]
            , test "does NOT route into the collection (no Add-Book CTA)" <|
                \() ->
                    Home.view Landing
                        |> Query.fromHtml
                        |> Query.hasNot [ Selector.attribute (Attr.href "/upload") ]
            ]
        , describe "Collection face (authenticated) — the drift oracle"
            [ test "renders a persistent Add-Book CTA into the upload flow" <|
                \() ->
                    authedHome (Success [])
                        |> Query.find [ Selector.class "home-collection__add" ]
                        |> Expect.all
                            [ Query.has [ Selector.attribute (Attr.href "/upload") ]
                            , Query.has [ Selector.text "Add a book" ]
                            ]
            , test "renders a continue-reading entry point into the Reading Pile" <|
                \() ->
                    authedHome (Success [])
                        |> Query.find [ Selector.class "home-collection__continue" ]
                        |> Query.has [ Selector.attribute (Attr.href "/reading-pile") ]
            , test "does NOT render the unauth Marketplace landing CTA" <|
                \() ->
                    authedHome (Success [ namedPlacement "b1" "Dune" ])
                        |> Query.hasNot [ Selector.class "home__link--marketplace" ]
            , test "with placements, stages a shelf glimpse in the shelf-room aesthetic" <|
                \() ->
                    authedHome (Success [ namedPlacement "b1" "Dune", namedPlacement "b2" "Emma" ])
                        |> Query.find [ Selector.class "home-collection__room" ]
                        |> Expect.all
                            [ -- reuses the shelf-room family: wallpaper + brass label + a real shelf row
                              Query.has [ Selector.class "wallpaper" ]
                            , Query.has [ Selector.class "shelf-label" ]
                            , Query.has [ Selector.class "shelf-row" ]
                            , Query.has [ Selector.attribute (Attr.href "/library") ]
                            ]
            , test "a failed preview degrades to the CTAs, not a broken page" <|
                \() ->
                    let
                        rendered =
                            authedHome (Failure Http.Timeout)
                    in
                    rendered
                        |> Expect.all
                            [ -- Add-Book still present
                              Query.has [ Selector.class "home-collection__add" ]
                            , -- no glimpse room
                              Query.hasNot [ Selector.class "home-collection__room" ]
                            ]
            ]
        , describe "update"
            [ test "PreviewLoaded Ok flattens the shelves' placements into the preview" <|
                \() ->
                    let
                        shelf =
                            { id = "s1", position = 0, placements = [ namedPlacement "b1" "Dune" ] }

                        ( newModel, _, out ) =
                            Home.update (PreviewLoaded (Ok [ shelf ])) (collectionLoading ())
                    in
                    case ( newModel, out ) of
                        ( Collection { preview }, NoOut ) ->
                            Expect.equal (Success [ namedPlacement "b1" "Dune" ]) preview

                        _ ->
                            Expect.fail "expected Collection/NoOut with the flattened placements"
            , test "an unauthorised preview error signals SessionExpired" <|
                \() ->
                    let
                        ( _, _, out ) =
                            Home.update (PreviewLoaded (Err (Http.BadStatus 401))) (collectionLoading ())
                    in
                    Expect.equal SessionExpired out
            ]
        ]


authedHome : RemoteData Http.Error (List Placement) -> Query.Single Msg
authedHome preview =
    Home.view (Collection { preview = preview })
        |> Query.fromHtml


collectionLoading : () -> Model
collectionLoading () =
    Collection { preview = Loading }
