module Page.Marketplace.ListingDetail exposing
    ( Model
    , Msg
    , init
    , update
    , view
    )

{-| Listing detail page.

Displays full details for a single marketplace listing: book metadata,
condition badge, price, description, and seller contact info (visible
only on active listings).

-}

import Html exposing (Html, a, div, h1, h2, img, p, span, text)
import Html.Attributes exposing (class, href, src)
import Http
import Json.Decode
import Navigation.Route as Route
import Types.Book exposing (authorName, bookCoverImageUrl, bookIsbn, bookPageCount, bookPublicationYear)
import Types.Listing exposing (Listing, ListingStatus(..), conditionLabel, statusLabel)
import Types.RemoteData exposing (RemoteData(..))


type alias Model =
    { listingId : String
    , listing : RemoteData Http.Error Listing
    }


type Msg
    = ListingReceived (Result Http.Error Listing)


init : String -> Maybe String -> ( Model, Cmd Msg )
init listingId maybeToken =
    ( { listingId = listingId
      , listing = Loading
      }
    , fetchListing listingId maybeToken
    )


fetchListing : String -> Maybe String -> Cmd Msg
fetchListing listingId maybeToken =
    Http.request
        { method = "GET"
        , headers =
            case maybeToken of
                Just token ->
                    [ Http.header "Authorization" ("Bearer " ++ token) ]

                Nothing ->
                    []
        , url = "/api/listings/" ++ listingId
        , body = Http.emptyBody
        , expect = Http.expectJson ListingReceived (Json.Decode.field "listing" Types.Listing.listingDecoder)
        , timeout = Nothing
        , tracker = Nothing
        }


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        ListingReceived result ->
            case result of
                Ok listing ->
                    ( { model | listing = Success listing }, Cmd.none )

                Err err ->
                    ( { model | listing = Failure err }, Cmd.none )



-- VIEW


view : Model -> Html Msg
view model =
    div [ class "page page--marketplace-detail" ]
        [ viewContent model ]


viewContent : Model -> Html Msg
viewContent model =
    case model.listing of
        NotAsked ->
            text ""

        Loading ->
            div [ class "loading" ] [ text "Loading listing..." ]

        Failure _ ->
            p [ class "error" ] [ text "Failed to load listing. Please try again." ]

        Success listing ->
            viewListing listing


viewListing : Listing -> Html Msg
viewListing listing =
    let
        bookTitle =
            listing.book
                |> Maybe.map .title
                |> Maybe.withDefault "Untitled"
    in
    div [ class "marketplace-detail" ]
        [ div [ class "marketplace-detail__header" ]
            [ viewCover listing
            , div [ class "marketplace-detail__meta" ]
                [ h1 [ class "marketplace-detail__title" ] [ text bookTitle ]
                , p [ class "marketplace-detail__author" ]
                    [ text (listing.book |> Maybe.map authorName |> Maybe.withDefault "Unknown Author") ]
                , span [ class ("marketplace__status-badge marketplace__status-badge--" ++ statusCssClass listing.status) ]
                    [ text (statusLabel listing.status) ]
                , span [ class ("marketplace__condition-badge marketplace__condition-badge--" ++ conditionCssClass listing.condition) ]
                    [ text (conditionLabel listing.condition) ]
                , viewDetailPrice listing
                ]
            ]
        , viewBookInfo listing
        , viewDescription listing
        , viewContact listing
        , div [ class "marketplace-detail__back" ]
            [ a [ href (Route.toPath Route.MarketplaceBrowse), class "btn btn--secondary" ]
                [ text "Back to Marketplace" ]
            ]
        ]


viewCover : Listing -> Html Msg
viewCover listing =
    case listing.book |> Maybe.andThen bookCoverImageUrl of
        Just url ->
            img
                [ src url
                , class "marketplace-detail__cover"
                , Html.Attributes.alt
                    ((listing.book |> Maybe.map .title |> Maybe.withDefault "Book") ++ " cover")
                ]
                []

        Nothing ->
            div [ class "marketplace-detail__cover-placeholder" ]
                [ span []
                    [ text
                        (listing.book
                            |> Maybe.map .title
                            |> Maybe.withDefault "?"
                            |> String.left 1
                        )
                    ]
                ]


viewDetailPrice : Listing -> Html Msg
viewDetailPrice listing =
    case listing.priceZar of
        Just price ->
            div [ class "marketplace-detail__price" ]
                [ text ("R " ++ String.fromInt price) ]

        Nothing ->
            div [ class "marketplace-detail__price marketplace-detail__price--offer" ]
                [ text "Open to offers" ]


viewBookInfo : Listing -> Html Msg
viewBookInfo listing =
    case listing.book of
        Just book ->
            div [ class "marketplace-detail__book-info" ]
                [ h2 [] [ text "Book Details" ]
                , viewInfoRow "ISBN" (bookIsbn book)
                , viewMaybeInfoRow "Pages" (bookPageCount book |> Maybe.map String.fromInt)
                , viewMaybeInfoRow "Published" (bookPublicationYear book |> Maybe.map String.fromInt)
                ]

        Nothing ->
            text ""


viewInfoRow : String -> String -> Html Msg
viewInfoRow label val =
    if String.isEmpty val then
        text ""

    else
        p [ class "marketplace-detail__info-row" ]
            [ span [ class "marketplace-detail__info-label" ] [ text (label ++ ": ") ]
            , text val
            ]


viewMaybeInfoRow : String -> Maybe String -> Html Msg
viewMaybeInfoRow label maybeVal =
    case maybeVal of
        Just val ->
            viewInfoRow label val

        Nothing ->
            text ""


viewDescription : Listing -> Html Msg
viewDescription listing =
    case listing.description of
        Just desc ->
            if String.isEmpty desc then
                text ""

            else
                div [ class "marketplace-detail__description" ]
                    [ h2 [] [ text "Description" ]
                    , p [] [ text desc ]
                    ]

        Nothing ->
            text ""


viewContact : Listing -> Html Msg
viewContact listing =
    case listing.status of
        Active ->
            if String.isEmpty listing.contactInfo then
                text ""

            else
                div [ class "marketplace-detail__contact" ]
                    [ h2 [] [ text "Seller Contact" ]
                    , p [] [ text listing.contactInfo ]
                    ]

        _ ->
            text ""



-- HELPERS


statusCssClass : Types.Listing.ListingStatus -> String
statusCssClass status =
    case status of
        Draft ->
            "draft"

        Active ->
            "active"

        Sold ->
            "sold"

        Expired ->
            "expired"

        Removed ->
            "removed"


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
