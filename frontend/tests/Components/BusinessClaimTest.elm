module Components.BusinessClaimTest exposing (suite)

{-| The business opt-out link, and the two blocks that owe it.

The removal form has existed and worked for some time; what it did not have was
a way in. Its only inbound link lived on a page that is not routed, so the form
was reachable by typed URL and nothing else — a page can be built, tested, and
green while being, in practice, unreachable.

So the assertions that matter here are not "the component renders a link". They
are that the link appears on each block that publicly names a shop, and that it
stays away from the same block when it named nobody: the form's first question
is the listing's web address, and a reader looking at "No price data yet" has no
address to give.

-}

import Api exposing (AuthorEvent)
import Components.AuthorCard as AuthorCard
import Components.PriceInfo as PriceInfo
import Expect
import Html.Attributes as Attr
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Types.Book exposing (Author)
import Types.RemoteData exposing (RemoteData(..))


claim : Selector.Selector
claim =
    Selector.attribute (Attr.attribute "data-testid" "business-claim")


author : Author
author =
    { id = "a1"
    , name = "Umberto Eco"
    , bio = Nothing
    , website = Nothing
    }


event : AuthorEvent
event =
    { id = "e1"
    , title = "An evening with Umberto Eco"
    , eventDate = Just "2026-09-01T18:30:00Z"
    , location = Just "Cape Town"
    , url = Just "https://booklounge.co.za/events/eco"
    , storeName = Just "The Book Lounge"
    }


pricedAtOneStore : PriceInfo.PriceData
pricedAtOneStore =
    { editions =
        [ { formatLabel = "Paperback"
          , isbn = "9780749397050"
          , stores =
                [ { storeName = "Exclusive Books"
                  , priceZar = 400.0
                  , buyUrl = "https://exclusivebooks.co.za/products/9780749397050"
                  , trend = "down"
                  }
                ]
          }
        ]
    , lastUpdated = "2026-08-18"
    }


noEditions : PriceInfo.PriceData
noEditions =
    { editions = [], lastUpdated = "2026-08-18" }


renderPrices : RemoteData () PriceInfo.PriceData -> Query.Single msg
renderPrices data =
    PriceInfo.view data |> Query.fromHtml


renderAuthorCard : Maybe (List AuthorEvent) -> Query.Single msg
renderAuthorCard events =
    AuthorCard.view (Just author) Nothing events |> Query.fromHtml


suite : Test
suite =
    describe "Components.BusinessClaim"
        [ describe "the link points at the form"
            [ test "resolves to the routed removal form, not a hand-written path" <|
                \() ->
                    renderPrices (Success pricedAtOneStore)
                        |> Query.find [ claim ]
                        |> Expect.all
                            [ Query.has [ Selector.attribute (Attr.href "/listing-removal") ]
                            , Query.has [ Selector.text "Is this your business?" ]
                            ]
            ]
        , describe "where prices name a shop"
            [ test "a named store carries the opt-out beside its price" <|
                \() ->
                    renderPrices (Success pricedAtOneStore)
                        |> Expect.all
                            [ Query.has [ Selector.text "Exclusive Books" ]
                            , Query.has [ claim ]
                            ]
            , test "no editions means no shop was named, so no opt-out is offered" <|
                \() ->
                    renderPrices (Success noEditions)
                        |> Query.hasNot [ claim ]
            , test "the placeholder before prices load offers nothing to opt out of" <|
                \() ->
                    renderPrices Loading
                        |> Query.hasNot [ claim ]
            ]
        , describe "where author events name a shop"
            [ test "an event carries the opt-out beside the shop hosting it" <|
                \() ->
                    renderAuthorCard (Just [ event ])
                        |> Expect.all
                            [ Query.has [ Selector.text "The Book Lounge" ]
                            , Query.has [ claim ]
                            ]
            , test "an author with no listed events names no shop, so offers no opt-out" <|
                \() ->
                    renderAuthorCard (Just [])
                        |> Query.hasNot [ claim ]
            , test "the events stub is not a listing either" <|
                \() ->
                    renderAuthorCard Nothing
                        |> Query.hasNot [ claim ]
            ]
        ]
