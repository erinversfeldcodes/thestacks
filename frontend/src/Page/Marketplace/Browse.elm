module Page.Marketplace.Browse exposing
    ( Model
    , Msg
    , init
    , update
    , view
    )

{-| Marketplace browse page.

Displays active listings in a grid. Each card shows the book cover,
title, condition badge, and price in ZAR. Clicking a card navigates
to the listing detail page.

-}

import Api
import Html exposing (Html, a, div, h1, h3, img, p, span, text)
import Html.Attributes exposing (class, href, src)
import Http
import Navigation.Route as Route
import Types.Book exposing (authorName, bookCoverImageUrl)
import Types.Listing exposing (Listing, ListingsResponse, conditionLabel)
import Types.RemoteData exposing (RemoteData(..))


type alias Model =
    { listings : RemoteData Http.Error ListingsResponse
    }


type Msg
    = ListingsReceived (Result Http.Error ListingsResponse)


init : Maybe String -> ( Model, Cmd Msg )
init maybeToken =
    ( { listings = Loading }
    , Api.getListings maybeToken ListingsReceived
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        ListingsReceived result ->
            case result of
                Ok response ->
                    ( { model | listings = Success response }, Cmd.none )

                Err err ->
                    ( { model | listings = Failure err }, Cmd.none )



-- VIEW


view : Model -> Html Msg
view model =
    div [ class "page page--marketplace-browse" ]
        [ h1 [ class "page__title" ] [ text "Marketplace" ]
        , p [ class "marketplace__subtitle" ]
            [ text "Browse books for sale from fellow collectors." ]
        , viewContent model
        ]


viewContent : Model -> Html Msg
viewContent model =
    case model.listings of
        NotAsked ->
            text ""

        Loading ->
            div [ class "loading" ] [ text "Loading listings..." ]

        Failure _ ->
            p [ class "error" ] [ text "Failed to load listings. Please try again." ]

        Success response ->
            if List.isEmpty response.listings then
                p [ class "marketplace__empty" ]
                    [ text "No active listings at the moment. Check back soon!" ]

            else
                div [ class "marketplace__grid" ]
                    (List.map viewListingCard response.listings)


viewListingCard : Listing -> Html Msg
viewListingCard listing =
    a
        [ class "marketplace__card"
        , href (Route.toPath (Route.MarketplaceDetail listing.id))
        ]
        [ viewListingCover listing
        , div [ class "marketplace__card-info" ]
            [ h3 [ class "marketplace__card-title" ]
                [ text (listingBookTitle listing) ]
            , p [ class "marketplace__card-author" ]
                [ text (listingBookAuthor listing) ]
            , span [ class ("marketplace__condition-badge marketplace__condition-badge--" ++ conditionCssClass listing.condition) ]
                [ text (conditionLabel listing.condition) ]
            , viewPrice listing
            ]
        ]


viewListingCover : Listing -> Html Msg
viewListingCover listing =
    case listing.book |> Maybe.andThen bookCoverImageUrl of
        Just url ->
            img
                [ src url
                , class "marketplace__card-cover"
                , Html.Attributes.alt (listingBookTitle listing ++ " cover")
                ]
                []

        Nothing ->
            div [ class "marketplace__card-cover-placeholder" ]
                [ span [] [ text (String.left 1 (listingBookTitle listing)) ] ]


viewPrice : Listing -> Html Msg
viewPrice listing =
    case listing.priceZar of
        Just price ->
            span [ class "marketplace__price" ]
                [ text ("R " ++ String.fromInt price) ]

        Nothing ->
            span [ class "marketplace__price marketplace__price--offer" ]
                [ text "Make an offer" ]



-- HELPERS


listingBookTitle : Listing -> String
listingBookTitle listing =
    listing.book
        |> Maybe.map .title
        |> Maybe.withDefault "Untitled"


listingBookAuthor : Listing -> String
listingBookAuthor listing =
    listing.book
        |> Maybe.map authorName
        |> Maybe.withDefault "Unknown Author"


conditionCssClass : Types.Listing.Condition -> String
conditionCssClass condition =
    case condition of
        Types.Listing.New ->
            "new"

        Types.Listing.LikeNew ->
            "like-new"

        Types.Listing.Good ->
            "good"

        Types.Listing.Fair ->
            "fair"

        Types.Listing.Poor ->
            "poor"
