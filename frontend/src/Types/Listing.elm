module Types.Listing exposing
    ( Condition(..)
    , Listing
    , ListingStatus(..)
    , ListingsResponse
    , PricingMode(..)
    , conditionLabel
    , conditionToString
    , listingDecoder
    , listingsResponseDecoder
    , statusLabel
    )

import Json.Decode as Decode exposing (Decoder)
import Types.Book exposing (Book, bookDecoder)


type Condition
    = New
    | LikeNew
    | Good
    | Fair
    | Poor


type PricingMode
    = Fixed
    | Offer


type ListingStatus
    = Draft
    | Active
    | Sold
    | Expired
    | Removed


type alias Listing =
    { id : String
    , book : Maybe Book
    , condition : Condition
    , pricingMode : PricingMode
    , priceZar : Maybe Int
    , contactInfo : String
    , description : Maybe String
    , status : ListingStatus
    , createdAt : Maybe String
    }


type alias ListingsResponse =
    { listings : List Listing
    , total : Int
    }



-- HELPERS


conditionLabel : Condition -> String
conditionLabel condition =
    case condition of
        New ->
            "New"

        LikeNew ->
            "Like New"

        Good ->
            "Good"

        Fair ->
            "Fair"

        Poor ->
            "Poor"


conditionToString : Condition -> String
conditionToString condition =
    case condition of
        New ->
            "new"

        LikeNew ->
            "like_new"

        Good ->
            "good"

        Fair ->
            "fair"

        Poor ->
            "poor"


statusLabel : ListingStatus -> String
statusLabel status =
    case status of
        Draft ->
            "Draft"

        Active ->
            "Active"

        Sold ->
            "Sold"

        Expired ->
            "Expired"

        Removed ->
            "Removed"



-- DECODERS


conditionDecoder : Decoder Condition
conditionDecoder =
    Decode.string
        |> Decode.andThen
            (\s ->
                case s of
                    "new" ->
                        Decode.succeed New

                    "like_new" ->
                        Decode.succeed LikeNew

                    "good" ->
                        Decode.succeed Good

                    "fair" ->
                        Decode.succeed Fair

                    "poor" ->
                        Decode.succeed Poor

                    _ ->
                        Decode.fail ("Unknown condition: " ++ s)
            )


pricingModeDecoder : Decoder PricingMode
pricingModeDecoder =
    Decode.string
        |> Decode.andThen
            (\s ->
                case s of
                    "fixed" ->
                        Decode.succeed Fixed

                    "offer" ->
                        Decode.succeed Offer

                    _ ->
                        Decode.fail ("Unknown pricing mode: " ++ s)
            )


statusDecoder : Decoder ListingStatus
statusDecoder =
    Decode.string
        |> Decode.andThen
            (\s ->
                case s of
                    "draft" ->
                        Decode.succeed Draft

                    "active" ->
                        Decode.succeed Active

                    "sold" ->
                        Decode.succeed Sold

                    "expired" ->
                        Decode.succeed Expired

                    "removed" ->
                        Decode.succeed Removed

                    _ ->
                        Decode.fail ("Unknown listing status: " ++ s)
            )


listingDecoder : Decoder Listing
listingDecoder =
    Decode.map8
        (\id book condition pricingMode priceZar contactInfo description status ->
            { id = id
            , book = book
            , condition = condition
            , pricingMode = pricingMode
            , priceZar = priceZar
            , contactInfo = contactInfo
            , description = description
            , status = status
            , createdAt = Nothing
            }
        )
        (Decode.field "id" Decode.string)
        (Decode.maybe (Decode.field "book" bookDecoder))
        (Decode.field "condition" conditionDecoder)
        (Decode.field "pricing_mode" pricingModeDecoder)
        (Decode.maybe (Decode.field "price_zar" Decode.int))
        (Decode.field "contact_info" Decode.string)
        (Decode.maybe (Decode.field "description" Decode.string))
        (Decode.field "status" statusDecoder)
        |> Decode.andThen
            (\partial ->
                Decode.map (\ca -> { partial | createdAt = ca })
                    (Decode.maybe (Decode.field "created_at" Decode.string))
            )


listingsResponseDecoder : Decoder ListingsResponse
listingsResponseDecoder =
    Decode.map2 ListingsResponse
        (Decode.field "listings" (Decode.list listingDecoder))
        (Decode.oneOf
            [ Decode.field "total" Decode.int
            , Decode.field "listings" (Decode.list listingDecoder)
                |> Decode.map List.length
            ]
        )
