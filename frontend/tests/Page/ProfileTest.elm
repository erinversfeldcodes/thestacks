module Page.ProfileTest exposing (suite)

{-| #214 — the public profile hub at `/u/:handle`.

Drives `Page.Profile.update` through the fetch outcomes and asserts the view:
a loaded profile renders the reader's identity, meta, and one browse link per
visible bookshelf (pointing at `/u/:handle/:shelf`); a 404 renders the neutral
"not found" (a ghost and an absent user are indistinguishable); and a 401
raises `SessionExpired` rather than rendering.

-}

import Api exposing (ProfileShelfSummary, PublicProfile)
import Expect
import Html.Attributes as Attr
import Http
import Page.Profile as Profile exposing (Msg(..), OutMsg(..))
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector


sampleProfile : PublicProfile
sampleProfile =
    { handle = "adalovelace"
    , displayName = "Ada Lovelace"
    , websiteUrl = "https://ada.example"
    , city = "London"
    , countryCode = "GB"
    , bookshelves =
        [ ProfileShelfSummary "library"
        , ProfileShelfSummary "wishlist"
        ]
    }


{-| A model as it stands after `init` (Loading), ready to receive a GotProfile.
-}
loadingModel : Profile.Model
loadingModel =
    Profile.init Nothing "adalovelace" |> Tuple.first


received : Result Http.Error PublicProfile -> Profile.Model
received result =
    Profile.update (GotProfile result) loadingModel
        |> (\( model, _, _ ) -> model)


outMsgFor : Result Http.Error PublicProfile -> OutMsg
outMsgFor result =
    Profile.update (GotProfile result) loadingModel
        |> (\( _, _, out ) -> out)


suite : Test
suite =
    describe "Page.Profile — public profile hub (#214)"
        [ test "renders the reader's display name and handle" <|
            \_ ->
                received (Ok sampleProfile)
                    |> Profile.view
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.has [ Selector.text "Ada Lovelace" ]
                        , Query.has [ Selector.text "@adalovelace" ]
                        ]
        , test "renders profile meta (location + website)" <|
            \_ ->
                received (Ok sampleProfile)
                    |> Profile.view
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.has [ Selector.text "London, GB" ]
                        , Query.has [ Selector.attribute (Attr.href "https://ada.example") ]
                        ]
        , test "renders one browse link per visible bookshelf, pointing at /u/:handle/:shelf" <|
            \_ ->
                received (Ok sampleProfile)
                    |> Profile.view
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.has [ Selector.attribute (Attr.href "/u/adalovelace/library") ]
                        , Query.has [ Selector.attribute (Attr.href "/u/adalovelace/wishlist") ]
                        , Query.findAll [ Selector.class "profile__shelf" ]
                            >> Query.count (Expect.equal 2)
                        ]
        , test "an empty bookshelf list renders the empty-state copy" <|
            \_ ->
                received (Ok { sampleProfile | bookshelves = [] })
                    |> Profile.view
                    |> Query.fromHtml
                    |> Query.has [ Selector.text "No public bookshelves." ]
        , test "a 404 renders the neutral not-found (ghost = absent)" <|
            \_ ->
                received (Err (Http.BadStatus 404))
                    |> Profile.view
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.has [ Selector.text "Reader not found" ]
                        , Query.hasNot [ Selector.text "Ada Lovelace" ]
                        ]
        , test "a 404 does NOT raise SessionExpired" <|
            \_ ->
                outMsgFor (Err (Http.BadStatus 404))
                    |> Expect.equal NoOut
        , test "a 401 raises SessionExpired" <|
            \_ ->
                outMsgFor (Err (Http.BadStatus 401))
                    |> Expect.equal SessionExpired
        ]
