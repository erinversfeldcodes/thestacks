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
import Stacks.Common.V1.Listing as Proto
import Types.Book exposing (Book, fromProtoBook)
import Types.ProtoHelpers exposing (emptyToNothing, zeroToNothing)


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



-- MAPPING


{-| Parse a condition string from the API.

Defaults to Good on unknown values for proto3 forward-compatibility:
new enum variants added server-side won't crash the decoder, they
degrade gracefully to the safest mid-range default.

-}
parseCondition : String -> Condition
parseCondition s =
    case s of
        "new" ->
            New

        "like_new" ->
            LikeNew

        "good" ->
            Good

        "fair" ->
            Fair

        "poor" ->
            Poor

        _ ->
            -- Proto3 resilience: unknown values default to Good (safe mid-range)
            Good


{-| Parse a pricing mode string from the API.

Defaults to Fixed on unknown values for proto3 forward-compatibility:
new pricing modes added server-side won't crash the decoder, they
degrade to Fixed which is the most conservative option.

-}
parsePricingMode : String -> PricingMode
parsePricingMode s =
    case s of
        "fixed" ->
            Fixed

        "offer" ->
            Offer

        _ ->
            -- Proto3 resilience: unknown values default to Fixed (conservative)
            Fixed


{-| Parse a listing status string from the API.

Defaults to Draft on unknown values for proto3 forward-compatibility:
new statuses added server-side won't crash the decoder, they degrade
to Draft which is the least-visible state (safest default).

-}
parseStatus : String -> ListingStatus
parseStatus s =
    case s of
        "draft" ->
            Draft

        "active" ->
            Active

        "sold" ->
            Sold

        "expired" ->
            Expired

        "removed" ->
            Removed

        _ ->
            -- Proto3 resilience: unknown values default to Draft (least visible)
            Draft


fromProtoListing : Proto.Listing -> Listing
fromProtoListing pl =
    let
        maybeBook =
            if pl.book.id == "" && pl.book.title == "" then
                Nothing

            else
                Just (fromProtoBook pl.book)
    in
    { id = pl.id
    , book = maybeBook
    , condition = parseCondition pl.condition
    , pricingMode = parsePricingMode pl.pricingMode
    , priceZar = zeroToNothing pl.priceCents
    , contactInfo = pl.contactInfo
    , description = emptyToNothing pl.description
    , status = parseStatus pl.status
    , createdAt = emptyToNothing pl.createdAt
    }



-- DECODERS


listingDecoder : Decoder Listing
listingDecoder =
    Decode.map fromProtoListing Proto.decodeListing


{-| Decode a ListingsResponse from JSON.

Decodes the listings array and total count. The total field fallback
computes length from the listings array for defensive compatibility.

-}
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
