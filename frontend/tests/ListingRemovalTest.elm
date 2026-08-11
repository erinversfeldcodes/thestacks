module ListingRemovalTest exposing (suite)

{-| Tests the "Is this your business?" removal form (US-2.5.3, campaign G6).

The thing worth guarding is not that a form submits. It is that the **two outcomes stay
distinguishable**: a request from an address on the listing's own domain is applied
immediately, and anything else waits for a human with the listing **still live**. Telling
a business owner their listing is gone when it is not is a worse failure than telling them
there is a wait — they would stop checking.

-}

import Api exposing (RemovalOutcome(..))
import Expect
import Html.Attributes as Attr
import Http
import Page.ListingRemoval as ListingRemoval
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Types.RemoteData exposing (RemoteData(..))


filled : ListingRemoval.Model
filled =
    { url = "https://yourshop.example"
    , email = "owner@yourshop.example"
    , reason = ""
    , submitting = NotAsked
    }


render : ListingRemoval.Model -> Query.Single ListingRemoval.Msg
render model =
    ListingRemoval.view model |> Query.fromHtml


suite : Test
suite =
    describe "ListingRemoval"
        [ describe "the two outcomes are told apart"
            [ test "a verified removal says the listing is gone" <|
                \_ ->
                    render { filled | submitting = Success Removed }
                        |> Query.has [ Selector.text "Your listing has been removed." ]
            , test "a pending request does NOT say the listing is gone" <|
                \_ ->
                    render { filled | submitting = Success PendingReview }
                        |> Query.hasNot [ Selector.text "Your listing has been removed." ]
            , test "a pending request says plainly that the listing is still visible" <|
                \_ ->
                    render { filled | submitting = Success PendingReview }
                        |> Query.has
                            [ Selector.attribute (Attr.attribute "data-testid" "removal-pending") ]
            , test "the form is replaced by the outcome, not shown alongside it" <|
                \_ ->
                    render { filled | submitting = Success Removed }
                        |> Query.hasNot
                            [ Selector.attribute (Attr.attribute "data-testid" "removal-submit") ]
            ]
        , describe "validation"
            [ test "a missing URL blocks submission" <|
                \_ ->
                    ListingRemoval.validate { filled | url = "" }
                        |> Expect.notEqual Nothing
            , test "an address with no @ blocks submission" <|
                \_ ->
                    ListingRemoval.validate { filled | email = "not-an-address" }
                        |> Expect.notEqual Nothing
            , test "a complete form passes" <|
                \_ ->
                    ListingRemoval.validate filled
                        |> Expect.equal Nothing
            , test "the submit button is disabled while a field is missing" <|
                \_ ->
                    render { filled | url = "" }
                        |> Query.find
                            [ Selector.attribute (Attr.attribute "data-testid" "removal-submit") ]
                        |> Query.has [ Selector.disabled True ]
            , test "submitting an invalid form fires no request" <|
                \_ ->
                    ListingRemoval.update ListingRemoval.Submit { filled | url = "" }
                        |> Tuple.second
                        |> Expect.equal Cmd.none
            ]
        , describe "server errors are stated in the requester's terms"
            [ test "a 404 explains that no listing matched, not the status code" <|
                \_ ->
                    render { filled | submitting = Failure (Http.BadStatus 404) }
                        |> Query.has [ Selector.text "could not find a listing" ]
            , test "a 422 names the email as the problem" <|
                \_ ->
                    render { filled | submitting = Failure (Http.BadStatus 422) }
                        |> Query.has [ Selector.text "does not look valid" ]
            ]
        , describe "the form explains why an address is asked for"
            [ test "says a matching domain is acted on immediately" <|
                \_ ->
                    render filled
                        |> Query.has [ Selector.text "act immediately" ]
            , test "says any other address still works" <|
                \_ ->
                    render filled
                        |> Query.has [ Selector.text "still works" ]
            ]
        ]
