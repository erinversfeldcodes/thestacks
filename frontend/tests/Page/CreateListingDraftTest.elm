module Page.CreateListingDraftTest exposing (suite)

{-| Tests for — preserve an in-progress marketplace listing when the
session expires mid-compose.

Seam contract:

  - A 401 on `ListingCreated` must bubble `SessionExpiredWithDraft` carrying the
    encoded draft (the six persisted fields + the composing user's `userId`), so
    `Main` can persist it to localStorage before redirecting to `/login`.
  - A NON-401 `ListingCreated` error must stay LOCAL (`NoOut`) and must NOT
    persist a draft (non-vacuity guard).
  - `DraftLoaded` hydrates the form only when the stamped `userId` matches the
    current user; a mismatched or undecodable draft is discarded (`ClearDraft`),
    never shown (cross-user leak guard).
  - A successful `ListingCreated` clears the draft (`ClearDraft`).
  - `DiscardDraft` clears the draft and resets the form.
  - `encodeDraft`/`decodeDraft` round-trip is identity.

-}

import Expect
import Http
import Json.Decode as Decode
import Json.Encode
import Page.Marketplace.CreateListing as CreateListing
import Test exposing (Test, describe, test)
import Types.Listing exposing (Condition(..), ListingStatus(..), PricingMode(..))


unauthorized : Http.Error
unauthorized =
    Http.BadStatus 401


nonAuth : Http.Error
nonAuth =
    Http.NetworkError


{-| A form part-way through composition.
-}
filledModel : CreateListing.Model
filledModel =
    let
        base =
            Tuple.first (CreateListing.init (Just "tok"))
    in
    { base
        | selectedBookId = Just "plc-1"
        , condition = New
        , pricingMode = Offer
        , priceInput = "150"
        , contactInfo = "me@example.com"
        , description = "A well-loved copy"
    }


emptyModel : CreateListing.Model
emptyModel =
    Tuple.first (CreateListing.init (Just "tok"))


sampleDraft : CreateListing.Draft
sampleDraft =
    { userId = "user-1"
    , selectedBookId = Just "plc-9"
    , condition = LikeNew
    , pricingMode = Fixed
    , priceInput = "99"
    , contactInfo = "hello@example.com"
    , description = "First edition"
    }


sampleListing : Types.Listing.Listing
sampleListing =
    { id = "listing-1"
    , book = Nothing
    , condition = Good
    , pricingMode = Fixed
    , priceZar = Just 100
    , contactInfo = "me@example.com"
    , description = Nothing
    , status = Draft
    , createdAt = Nothing
    }


suite : Test
suite =
    describe "— preserve CreateListing draft on session expiry"
        [ describe "(a) 401 on ListingCreated → SessionExpiredWithDraft carrying the draft"
            [ test "encoded value round-trips to the six fields + current userId" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            CreateListing.update
                                (CreateListing.ListingCreated (Err unauthorized))
                                filledModel
                                (Just "tok")
                                (Just "user-1")
                    in
                    case outMsg of
                        CreateListing.SessionExpiredWithDraft value ->
                            Decode.decodeValue CreateListing.decodeDraft value
                                |> Expect.equal
                                    (Ok
                                        { userId = "user-1"
                                        , selectedBookId = Just "plc-1"
                                        , condition = New
                                        , pricingMode = Offer
                                        , priceInput = "150"
                                        , contactInfo = "me@example.com"
                                        , description = "A well-loved copy"
                                        }
                                    )

                        _ ->
                            Expect.fail "expected SessionExpiredWithDraft"
            ]
        , describe "(f) NON-401 ListingCreated error does NOT persist a draft"
            [ test "network error → NoOut (stays local, no SessionExpiredWithDraft)" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            CreateListing.update
                                (CreateListing.ListingCreated (Err nonAuth))
                                filledModel
                                (Just "tok")
                                (Just "user-1")
                    in
                    outMsg |> Expect.equal CreateListing.NoOut
            ]
        , describe "(b) DraftLoaded userId guard"
            [ test "matching userId hydrates all six fields" <|
                \() ->
                    let
                        ( newModel, _, outMsg ) =
                            CreateListing.update
                                (CreateListing.DraftLoaded (CreateListing.encodeDraft sampleDraft))
                                emptyModel
                                (Just "tok")
                                (Just "user-1")
                    in
                    ( outMsg
                    , ( newModel.selectedBookId
                      , newModel.condition
                      , newModel.pricingMode
                      )
                    , ( newModel.priceInput
                      , newModel.contactInfo
                      , newModel.description
                      )
                    )
                        |> Expect.equal
                            ( CreateListing.NoOut
                            , ( Just "plc-9", LikeNew, Fixed )
                            , ( "99", "hello@example.com", "First edition" )
                            )
            , test "mismatched userId does NOT hydrate and clears the draft" <|
                \() ->
                    let
                        ( newModel, _, outMsg ) =
                            CreateListing.update
                                (CreateListing.DraftLoaded (CreateListing.encodeDraft sampleDraft))
                                emptyModel
                                (Just "tok")
                                (Just "someone-else")
                    in
                    ( newModel.selectedBookId, newModel.contactInfo, outMsg )
                        |> Expect.equal ( Nothing, "", CreateListing.ClearDraft )
            , test "undecodable value is a no-op that clears the draft" <|
                \() ->
                    let
                        ( newModel, _, outMsg ) =
                            CreateListing.update
                                (CreateListing.DraftLoaded (Json.Encode.string "not-a-draft"))
                                emptyModel
                                (Just "tok")
                                (Just "user-1")
                    in
                    ( newModel.contactInfo, outMsg )
                        |> Expect.equal ( "", CreateListing.ClearDraft )
            ]
        , describe "(c) encodeDraft → decodeDraft round-trip is identity"
            [ test "with a selected placement" <|
                \() ->
                    Decode.decodeValue CreateListing.decodeDraft (CreateListing.encodeDraft sampleDraft)
                        |> Expect.equal (Ok sampleDraft)
            , test "with no selected placement" <|
                \() ->
                    let
                        draft =
                            { sampleDraft | selectedBookId = Nothing, condition = Fair, pricingMode = Offer }
                    in
                    Decode.decodeValue CreateListing.decodeDraft (CreateListing.encodeDraft draft)
                        |> Expect.equal (Ok draft)
            ]
        , describe "(d) successful ListingCreated clears the draft"
            [ test "Ok → ClearDraft and the listing is shown" <|
                \() ->
                    let
                        ( newModel, _, outMsg ) =
                            CreateListing.update
                                (CreateListing.ListingCreated (Ok sampleListing))
                                filledModel
                                (Just "tok")
                                (Just "user-1")
                    in
                    ( outMsg, newModel.createdListing )
                        |> Expect.equal ( CreateListing.ClearDraft, Just sampleListing )
            ]
        , describe "(e) DiscardDraft clears the draft and resets the form"
            [ test "fields reset to defaults + ClearDraft" <|
                \() ->
                    let
                        ( newModel, _, outMsg ) =
                            CreateListing.update
                                CreateListing.DiscardDraft
                                filledModel
                                (Just "tok")
                                (Just "user-1")
                    in
                    ( outMsg
                    , ( newModel.selectedBookId, newModel.contactInfo, newModel.description )
                    , ( newModel.condition, newModel.pricingMode, newModel.priceInput )
                    )
                        |> Expect.equal
                            ( CreateListing.ClearDraft
                            , ( Nothing, "", "" )
                            , ( Good, Fixed, "" )
                            )
            ]
        ]
