module ProtoDecoderTest exposing (suite)

{-| Round-trip and shape tests for the generated proto/gen/elm decoders.

These tests verify that:

1.  Each decoder parses the JSON shape defined by the corresponding .proto file.
2.  Each encoder produces JSON that the decoder can read back unchanged.

If these tests break after a .proto change, the proto/gen/elm/ decoders must
be regenerated or updated by hand to match the new schema.

-}

import Expect
import Json.Decode as D
import Json.Encode as E
import Stacks.Api.V1.Admin
    exposing
        ( CostBreakdown
        , CostItem
        , EnrichmentGaps
        , MetricsDashboard
        , MonthlyTotal
        , QualityTrendRow
        , SystemHealth
        , UsageMetrics
        , decodeCostBreakdown
        , decodeCostItem
        , decodeEnrichmentGaps
        , decodeMetricsDashboard
        , decodeMonthlyTotal
        , decodeQualityTrendRow
        , decodeSystemHealth
        , decodeUsageMetrics
        , defaultMetricsDashboard
        , defaultSystemHealth
        , defaultUsageMetrics
        , encodeCostBreakdown
        , encodeCostItem
        , encodeEnrichmentGaps
        , encodeMetricsDashboard
        , encodeMonthlyTotal
        , encodeQualityTrendRow
        , encodeSystemHealth
        , encodeUsageMetrics
        )
import Stacks.Api.V1.AuthResponses
    exposing
        ( AuthResponse
        , decodeAuthResponse
        , encodeAuthResponse
        )
import Stacks.Api.V1.BlogResponses
    exposing
        ( AssociationActionResponse
        , BlogPostListResponse
        , BlogPostResponse
        , BlogPostShowResponse
        , decodeAssociationActionResponse
        , decodeBlogPostListResponse
        , decodeBlogPostResponse
        , decodeBlogPostShowResponse
        , encodeAssociationActionResponse
        , encodeBlogPostListResponse
        , encodeBlogPostResponse
        , encodeBlogPostShowResponse
        )
import Stacks.Api.V1.BookResponses
    exposing
        ( BookDetailResponse
        , decodeBookDetailResponse
        , encodeBookDetailResponse
        )
import Stacks.Api.V1.BookshelfResponses
    exposing
        ( BookshelfResponse
        , decodeBookshelfResponse
        , encodeBookshelfResponse
        )
import Stacks.Api.V1.ListingResponses
    exposing
        ( ListingListResponse
        , ListingResponse
        , decodeListingListResponse
        , decodeListingResponse
        , encodeListingListResponse
        , encodeListingResponse
        )
import Stacks.Api.V1.SourceResponses
    exposing
        ( DiscoveredSource
        , SourceAdminListResponse
        , VisibilityUpdateResponse
        , decodeDiscoveredSource
        , decodeSourceAdminListResponse
        , decodeVisibilityUpdateResponse
        , encodeDiscoveredSource
        , encodeSourceAdminListResponse
        , encodeVisibilityUpdateResponse
        )
import Stacks.Common.V1.Blog
    exposing
        ( BlogPost
        , BlogVisibility(..)
        , BookAssociation
        , decodeBlogPost
        , decodeBlogPostSummary
        , decodeBlogVisibility
        , decodeBookAssociation
        , defaultBlogPost
        , encodeBlogPost
        , encodeBookAssociation
        )
import Stacks.Common.V1.Book
    exposing
        ( Book
        , Edition
        , VisibilityTier(..)
        , decodeBook
        , decodeEdition
        , decodeVisibilityTier
        , defaultBook
        , defaultEdition
        , encodeBook
        , encodeEdition
        )
import Stacks.Common.V1.Listing
    exposing
        ( Listing
        , decodeListing
        , defaultListing
        , encodeListing
        )
import Stacks.Common.V1.Location
    exposing
        ( City
        , Coordinates
        , Country
        , decodeCity
        , decodeCoordinates
        , decodeCountry
        , encodeCity
        , encodeCoordinates
        , encodeCountry
        )
import Stacks.Common.V1.Placement
    exposing
        ( PlacementDetail
        , decodePlacementDetail
        , encodePlacementDetail
        )
import Stacks.Common.V1.Upload
    exposing
        ( PollResponse
        , PollStatus(..)
        , decodePollResponse
        , decodePollStatus
        , decodeUploadAccepted
        , encodePollResponse
        )
import Stacks.Common.V1.User
    exposing
        ( User
        , decodeUser
        , encodeUser
        )
import Stacks.Internal.V1.EventBus
    exposing
        ( EventEnvelope
        , decodeEventEnvelope
        , encodeEventEnvelope
        )
import Stacks.Monitoring.V1.SourceHealthCheck
    exposing
        ( HealthStatus(..)
        , SourceHealthCheck
        , SourceType(..)
        , decodeHealthStatus
        , decodeSourceHealthCheck
        , decodeSourceType
        , encodeSourceHealthCheck
        )
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Proto gen Elm decoders"
        [ locationSuite
        , eventBusSuite
        , bookSuite
        , userSuite
        , placementSuite
        , sourceHealthCheckSuite
        , responseSuite
        , blogSuite
        , blogResponseSuite
        , listingSuite
        , listingResponseSuite
        , sourceResponseSuite
        , uploadSuite
        , adminSuite
        ]



-- ---------------------------------------------------------------------------
-- Location
-- ---------------------------------------------------------------------------


locationSuite : Test
locationSuite =
    describe "Location decoders"
        [ test "Country decodes required fields" <|
            \_ ->
                let
                    json =
                        """{"code":"ZA","name":"South Africa"}"""

                    result =
                        D.decodeString decodeCountry json
                in
                case result of
                    Ok c ->
                        Expect.all
                            [ \x -> Expect.equal "ZA" x.code
                            , \x -> Expect.equal "South Africa" x.name
                            ]
                            c

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "Country encode-decode round-trip" <|
            \_ ->
                let
                    original : Country
                    original =
                        { code = "ZA", name = "South Africa" }

                    encoded =
                        encodeCountry original

                    result =
                        D.decodeValue decodeCountry encoded
                in
                case result of
                    Ok decoded ->
                        Expect.equal original decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "Country defaults missing fields to empty string" <|
            \_ ->
                let
                    result =
                        D.decodeString decodeCountry """{"name":"South Africa"}"""
                in
                case result of
                    Ok c ->
                        Expect.equal "" c.code

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "City decodes name and country_code" <|
            \_ ->
                let
                    json =
                        """{"name":"Cape Town","country_code":"ZA"}"""

                    result =
                        D.decodeString decodeCity json
                in
                case result of
                    Ok c ->
                        Expect.all
                            [ \x -> Expect.equal "Cape Town" x.name
                            , \x -> Expect.equal "ZA" x.countryCode
                            ]
                            c

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "City encode-decode round-trip" <|
            \_ ->
                let
                    original : City
                    original =
                        { name = "Cape Town", countryCode = "ZA" }

                    result =
                        D.decodeValue decodeCity (encodeCity original)
                in
                case result of
                    Ok decoded ->
                        Expect.equal original decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "Coordinates decodes latitude and longitude" <|
            \_ ->
                let
                    json =
                        """{"latitude":-33.9249,"longitude":18.4241}"""

                    result =
                        D.decodeString decodeCoordinates json
                in
                case result of
                    Ok c ->
                        Expect.all
                            [ \x -> Expect.within (Expect.Absolute 0.0001) -33.9249 x.latitude
                            , \x -> Expect.within (Expect.Absolute 0.0001) 18.4241 x.longitude
                            ]
                            c

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "Coordinates encode-decode round-trip" <|
            \_ ->
                let
                    original : Coordinates
                    original =
                        { latitude = -33.9249, longitude = 18.4241 }

                    result =
                        D.decodeValue decodeCoordinates (encodeCoordinates original)
                in
                case result of
                    Ok decoded ->
                        Expect.all
                            [ \x -> Expect.within (Expect.Absolute 0.0001) original.latitude x.latitude
                            , \x -> Expect.within (Expect.Absolute 0.0001) original.longitude x.longitude
                            ]
                            decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        ]



-- ---------------------------------------------------------------------------
-- EventBus
-- ---------------------------------------------------------------------------


eventBusSuite : Test
eventBusSuite =
    describe "EventBus.EventEnvelope decoder"
        [ test "decodes all required fields" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "event_type": "book.created",
                            "aggregate_type": "book",
                            "aggregate_id": "abc-123",
                            "schema_version": 1,
                            "payload": {"isbn": "9780156001311"},
                            "metadata": {"user_id": "u-1"},
                            "occurred_at": "2026-03-19T10:00:00Z"
                        }
                        """

                    result =
                        D.decodeString decodeEventEnvelope json
                in
                case result of
                    Ok env ->
                        Expect.all
                            [ \e -> Expect.equal "book.created" e.eventType
                            , \e -> Expect.equal "book" e.aggregateType
                            , \e -> Expect.equal "abc-123" e.aggregateId
                            , \e -> Expect.equal 1 e.schemaVersion
                            , \e -> Expect.equal "2026-03-19T10:00:00Z" e.occurredAt
                            ]
                            env

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "optional fields default when absent" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "event_type": "user.registered",
                            "aggregate_type": "user",
                            "aggregate_id": "u-42"
                        }
                        """

                    result =
                        D.decodeString decodeEventEnvelope json
                in
                case result of
                    Ok env ->
                        Expect.all
                            [ \e -> Expect.equal 0 e.schemaVersion
                            , \e -> Expect.equal "" e.occurredAt
                            , \e -> Expect.equal Nothing e.publishedAt
                            ]
                            env

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "encode-decode round-trip preserves all fields" <|
            \_ ->
                let
                    original : EventEnvelope
                    original =
                        { eventType = "book.created"
                        , aggregateType = "book"
                        , aggregateId = "abc-123"
                        , schemaVersion = 2
                        , payload = E.object [ ( "isbn", E.string "9780156001311" ) ]
                        , metadata = E.object [ ( "source", E.string "upload" ) ]
                        , occurredAt = "2026-03-19T10:00:00Z"
                        , publishedAt = Just "2026-03-19T10:00:01Z"
                        }

                    result =
                        D.decodeValue decodeEventEnvelope (encodeEventEnvelope original)
                in
                case result of
                    Ok decoded ->
                        Expect.all
                            [ \e -> Expect.equal original.eventType e.eventType
                            , \e -> Expect.equal original.aggregateType e.aggregateType
                            , \e -> Expect.equal original.aggregateId e.aggregateId
                            , \e -> Expect.equal original.schemaVersion e.schemaVersion
                            , \e -> Expect.equal original.occurredAt e.occurredAt
                            ]
                            decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "publishedAt round-trips through Maybe" <|
            \_ ->
                let
                    withPublished : EventEnvelope
                    withPublished =
                        { eventType = "test"
                        , aggregateType = "test"
                        , aggregateId = "x"
                        , schemaVersion = 1
                        , payload = E.object []
                        , metadata = E.object []
                        , occurredAt = "2026-03-20T00:00:00Z"
                        , publishedAt = Just "2026-03-20T00:00:01Z"
                        }

                    withoutPublished : EventEnvelope
                    withoutPublished =
                        { withPublished | publishedAt = Nothing }
                in
                Expect.all
                    [ \_ ->
                        case D.decodeValue decodeEventEnvelope (encodeEventEnvelope withPublished) of
                            Ok decoded ->
                                Expect.equal (Just "2026-03-20T00:00:01Z") decoded.publishedAt

                            Err e ->
                                Expect.fail (D.errorToString e)
                    , \_ ->
                        case D.decodeValue decodeEventEnvelope (encodeEventEnvelope withoutPublished) of
                            Ok decoded ->
                                Expect.equal Nothing decoded.publishedAt

                            Err e ->
                                Expect.fail (D.errorToString e)
                    ]
                    ()
        , test "missing fields default per proto3 rules" <|
            \_ ->
                let
                    result =
                        D.decodeString decodeEventEnvelope
                            """{"aggregate_type":"book","aggregate_id":"x"}"""
                in
                case result of
                    Ok env ->
                        Expect.all
                            [ \e -> Expect.equal "" e.eventType
                            , \e -> Expect.equal "book" e.aggregateType
                            , \e -> Expect.equal "x" e.aggregateId
                            ]
                            env

                    Err e ->
                        Expect.fail (D.errorToString e)
        ]



-- ---------------------------------------------------------------------------
-- Book (enums + messages + embedded fields)
-- ---------------------------------------------------------------------------


bookSuite : Test
bookSuite =
    describe "Book decoders"
        [ test "Book decodes all fields including embedded author and editions" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "id": "b-1",
                            "title": "The Secret History",
                            "description": "A group of classics students...",
                            "subjects": ["fiction", "mystery"],
                            "visibility_tier": "VISIBILITY_TIER_PUBLIC",
                            "author": {"id": "a-1", "name": "Donna Tartt", "website": "", "rss_feed_url": "", "bio": ""},
                            "editions": [
                                {"id": "e-1", "book_id": "b-1", "isbn": "9780140167771", "format": "EDITION_FORMAT_PAPERBACK", "is_primary": true, "cover_image_url": "", "page_count": 559, "publisher": "Penguin", "publication_year": 1992, "format_label": "Paperback"}
                            ],
                            "edition_count": 1,
                            "primary_edition": {"id": "e-1", "book_id": "b-1", "isbn": "9780140167771", "format": "EDITION_FORMAT_PAPERBACK", "is_primary": true, "cover_image_url": "", "page_count": 559, "publisher": "Penguin", "publication_year": 1992, "format_label": "Paperback"},
                            "community_read_count": 42,
                            "language": "en",
                            "bisac_codes": ["FIC000000"]
                        }
                        """

                    result =
                        D.decodeString decodeBook json
                in
                case result of
                    Ok book ->
                        Expect.all
                            [ \b -> Expect.equal "b-1" b.id
                            , \b -> Expect.equal "The Secret History" b.title
                            , \b -> Expect.equal VisibilityTierPublic b.visibilityTier
                            , \b -> Expect.equal "Donna Tartt" b.author.name
                            , \b -> Expect.equal 1 (List.length b.editions)
                            , \b -> Expect.equal 42 b.communityReadCount
                            , \b -> Expect.equal "en" b.language
                            , \b -> Expect.equal [ "FIC000000" ] b.bisacCodes
                            , \b -> Expect.equal "9780140167771" b.primaryEdition.isbn
                            ]
                            book

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "Book encode-decode round-trip" <|
            \_ ->
                let
                    original : Book
                    original =
                        { id = "b-2"
                        , title = "If on a winter's night a traveler"
                        , authorId = ""
                        , description = "A novel about reading"
                        , subjects = [ "fiction", "postmodern" ]
                        , visibilityTier = VisibilityTierUnlisted
                        , author = { id = "a-2", name = "Italo Calvino", websiteUrl = "", rssFeedUrl = "", bio = "", openLibraryId = "", createdAt = "", updatedAt = "" }
                        , editions = []
                        , editionCount = 0
                        , primaryEdition = defaultEdition
                        , communityReadCount = 7
                        , language = "it"
                        , bisacCodes = []
                        , createdAt = ""
                        , updatedAt = ""
                        }

                    result =
                        D.decodeValue decodeBook (encodeBook original)
                in
                case result of
                    Ok decoded ->
                        Expect.all
                            [ \b -> Expect.equal original.id b.id
                            , \b -> Expect.equal original.title b.title
                            , \b -> Expect.equal original.visibilityTier b.visibilityTier
                            , \b -> Expect.equal original.author.name b.author.name
                            , \b -> Expect.equal original.communityReadCount b.communityReadCount
                            , \b -> Expect.equal original.language b.language
                            ]
                            decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "Book defaults embedded author and editions when absent" <|
            \_ ->
                let
                    result =
                        D.decodeString decodeBook """{"id":"b-3","title":"Minimal"}"""
                in
                case result of
                    Ok book ->
                        Expect.all
                            [ \b -> Expect.equal "b-3" b.id
                            , \b -> Expect.equal "" b.author.id
                            , \b -> Expect.equal [] b.editions
                            , \b -> Expect.equal 0 b.communityReadCount
                            , \b -> Expect.equal "" b.primaryEdition.id
                            ]
                            book

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "VisibilityTier decodes lowercase wire values" <|
            \_ ->
                Expect.all
                    [ \_ ->
                        case D.decodeString decodeVisibilityTier "\"public\"" of
                            Ok v ->
                                Expect.equal VisibilityTierPublic v

                            Err e ->
                                Expect.fail (D.errorToString e)
                    , \_ ->
                        case D.decodeString decodeVisibilityTier "\"age_gated\"" of
                            Ok v ->
                                Expect.equal VisibilityTierAgeGated v

                            Err e ->
                                Expect.fail (D.errorToString e)
                    , \_ ->
                        case D.decodeString decodeVisibilityTier "\"private\"" of
                            Ok v ->
                                Expect.equal VisibilityTierPrivate v

                            Err e ->
                                Expect.fail (D.errorToString e)
                    ]
                    ()
        , test "Edition encode-decode round-trip (>8 fields)" <|
            \_ ->
                let
                    original : Edition
                    original =
                        { id = "e-1"
                        , isbn = "9780140167771"
                        , isPrimary = True
                        , coverImageUrl = "https://example.com/cover.jpg"
                        , pageCount = 559
                        , publisher = "Penguin"
                        , publicationYear = 1992
                        , formatLabel = "Paperback"
                        , openLibraryId = ""
                        , googleBooksId = ""
                        , bookId = ""
                        , createdAt = ""
                        , updatedAt = ""
                        }

                    result =
                        D.decodeValue decodeEdition (encodeEdition original)
                in
                case result of
                    Ok decoded ->
                        Expect.all
                            [ \ed -> Expect.equal original.id ed.id
                            , \ed -> Expect.equal original.isbn ed.isbn
                            , \ed -> Expect.equal original.isPrimary ed.isPrimary
                            , \ed -> Expect.equal original.publicationYear ed.publicationYear
                            , \ed -> Expect.equal original.formatLabel ed.formatLabel
                            ]
                            decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        ]



-- ---------------------------------------------------------------------------
-- User (>8 fields, andThen pattern)
-- ---------------------------------------------------------------------------


userSuite : Test
userSuite =
    describe "User decoders"
        [ test "User decodes all 9 fields including 9th via andThen" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "id": "u-1",
                            "email": "user@example.com",
                            "display_name": "BookLover",
                            "role": "user",
                            "country_code": "ZA",
                            "city": "Cape Town",
                            "consent_analytics": true,
                            "age_verified": false,
                            "profile_visibility": "platform"
                        }
                        """

                    result =
                        D.decodeString decodeUser json
                in
                case result of
                    Ok user ->
                        Expect.all
                            [ \u -> Expect.equal "u-1" u.id
                            , \u -> Expect.equal "user@example.com" u.email
                            , \u -> Expect.equal "BookLover" u.displayName
                            , \u -> Expect.equal "user" u.role
                            , \u -> Expect.equal "ZA" u.countryCode
                            , \u -> Expect.equal "Cape Town" u.city
                            , \u -> Expect.equal True u.consentAnalytics
                            , \u -> Expect.equal False u.ageVerified
                            , \u -> Expect.equal "platform" u.profileVisibility
                            ]
                            user

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "User encode-decode round-trip" <|
            \_ ->
                let
                    original : User
                    original =
                        { id = "u-2"
                        , email = "owner@stacks.local"
                        , displayName = "Librarian"
                        , role = "owner"
                        , countryCode = "GB"
                        , city = "London"
                        , consentAnalytics = False
                        , consentWritingAssistant = False
                        , ageVerified = True
                        , ageVerifiedAt = ""
                        , ageVerificationProvider = ""
                        , profileVisibility = "owner"
                        , passwordHash = ""
                        , websiteUrl = ""
                        , consentAnalyticsAt = ""
                        , consentWritingAssistantAt = ""
                        , onboardingCompleted = False
                        , onboardingSteps = ""
                        , notifyWishlistAvailability = False
                        , notifyMarketplace = False
                        , notifyGroupInvitations = False
                        , notifyEventMatches = False
                        , emailConfirmed = False
                        , emailConfirmationToken = ""
                        , passwordResetToken = ""
                        , passwordResetSentAt = ""
                        , createdAt = ""
                        , updatedAt = ""
                        , failedLoginCount = 0
                        , failedLoginFirstAt = ""
                        , lockedUntil = ""
                        }

                    result =
                        D.decodeValue decodeUser (encodeUser original)
                in
                case result of
                    Ok decoded ->
                        Expect.equal original decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "User defaults missing fields per proto3 rules" <|
            \_ ->
                let
                    result =
                        D.decodeString decodeUser """{"id":"u-3"}"""
                in
                case result of
                    Ok user ->
                        Expect.all
                            [ \u -> Expect.equal "u-3" u.id
                            , \u -> Expect.equal "" u.email
                            , \u -> Expect.equal "" u.profileVisibility
                            , \u -> Expect.equal False u.consentAnalytics
                            ]
                            user

                    Err e ->
                        Expect.fail (D.errorToString e)
        ]



-- ---------------------------------------------------------------------------
-- Placement (cross-module reference to Book)
-- ---------------------------------------------------------------------------


placementSuite : Test
placementSuite =
    describe "PlacementDetail decoders"
        [ test "PlacementDetail decodes with embedded book from another module" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "id": "p-1",
                            "position": 3,
                            "placed_at": "2026-03-20T10:00:00Z",
                            "formats": ["physical"],
                            "personal_rating": 5,
                            "notes": "Great read",
                            "book": {
                                "id": "b-1",
                                "title": "The Name of the Rose",
                                "author": {"id": "a-1", "name": "Umberto Eco"}
                            }
                        }
                        """

                    result =
                        D.decodeString decodePlacementDetail json
                in
                case result of
                    Ok placement ->
                        Expect.all
                            [ \pd -> Expect.equal "p-1" pd.id
                            , \pd -> Expect.equal 3 pd.position
                            , \pd -> Expect.equal "2026-03-20T10:00:00Z" pd.placedAt
                            , \pd -> Expect.equal 5 pd.personalRating
                            , \pd -> Expect.equal "b-1" pd.book.id
                            , \pd -> Expect.equal "The Name of the Rose" pd.book.title
                            , \pd -> Expect.equal "Umberto Eco" pd.book.author.name
                            ]
                            placement

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "PlacementDetail defaults book when absent" <|
            \_ ->
                let
                    result =
                        D.decodeString decodePlacementDetail """{"id":"p-2","position":0}"""
                in
                case result of
                    Ok placement ->
                        Expect.all
                            [ \pd -> Expect.equal "p-2" pd.id
                            , \pd -> Expect.equal "" pd.book.id
                            , \pd -> Expect.equal "" pd.book.title
                            ]
                            placement

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "PlacementDetail encode-decode round-trip" <|
            \_ ->
                let
                    original : PlacementDetail
                    original =
                        { id = "p-3"
                        , position = 1
                        , placedAt = "2026-03-21T12:00:00Z"
                        , formats = [ "physical", "ebook" ]
                        , personalRating = 4
                        , notes = "Annotated copy"
                        , readingStatus = "reading"
                        , currentPage = 42
                        , startedAt = "2026-03-20T08:00:00Z"
                        , finishedAt = ""
                        , book =
                            { id = "b-3"
                            , title = "Pale Fire"
                            , authorId = ""
                            , description = ""
                            , subjects = []
                            , visibilityTier = VisibilityTierPublic
                            , author = { id = "a-3", name = "Vladimir Nabokov", websiteUrl = "", rssFeedUrl = "", bio = "", openLibraryId = "", createdAt = "", updatedAt = "" }
                            , editions = []
                            , editionCount = 0
                            , primaryEdition = defaultEdition
                            , communityReadCount = 0
                            , language = ""
                            , bisacCodes = []
                            , createdAt = ""
                            , updatedAt = ""
                            }
                        }

                    result =
                        D.decodeValue decodePlacementDetail (encodePlacementDetail original)
                in
                case result of
                    Ok decoded ->
                        Expect.all
                            [ \pd -> Expect.equal original.id pd.id
                            , \pd -> Expect.equal original.position pd.position
                            , \pd -> Expect.equal original.personalRating pd.personalRating
                            , \pd -> Expect.equal original.book.id pd.book.id
                            , \pd -> Expect.equal original.book.title pd.book.title
                            ]
                            decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        ]



-- ---------------------------------------------------------------------------
-- SourceHealthCheck (optional + enums + >8 fields)
-- ---------------------------------------------------------------------------


sourceHealthCheckSuite : Test
sourceHealthCheckSuite =
    describe "SourceHealthCheck decoders"
        [ test "SourceHealthCheck decodes all fields including enums and optionals" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "source_name": "takealot_scraper",
                            "source_type": "SOURCE_TYPE_SCRAPER_CONFIG",
                            "last_success_at": "2026-03-20T10:00:00Z",
                            "last_failure_at": "2026-03-19T08:00:00Z",
                            "last_failure_reason": "timeout",
                            "consecutive_failures": 0,
                            "total_successes": 100,
                            "total_failures": 3,
                            "status": "HEALTH_STATUS_HEALTHY"
                        }
                        """

                    result =
                        D.decodeString decodeSourceHealthCheck json
                in
                case result of
                    Ok check ->
                        Expect.all
                            [ \c -> Expect.equal "takealot_scraper" c.sourceName
                            , \c -> Expect.equal SourceTypeScraperConfig c.sourceType
                            , \c -> Expect.equal (Just "2026-03-20T10:00:00Z") c.lastSuccessAt
                            , \c -> Expect.equal (Just "2026-03-19T08:00:00Z") c.lastFailureAt
                            , \c -> Expect.equal (Just "timeout") c.lastFailureReason
                            , \c -> Expect.equal 0 c.consecutiveFailures
                            , \c -> Expect.equal 100 c.totalSuccesses
                            , \c -> Expect.equal 3 c.totalFailures
                            , \c -> Expect.equal HealthStatusHealthy c.status
                            ]
                            check

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "SourceHealthCheck decodes lowercase enum wire values" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "source_name": "rss_feed",
                            "source_type": "rss_feed",
                            "status": "degraded"
                        }
                        """

                    result =
                        D.decodeString decodeSourceHealthCheck json
                in
                case result of
                    Ok check ->
                        Expect.all
                            [ \c -> Expect.equal SourceTypeRssFeed c.sourceType
                            , \c -> Expect.equal HealthStatusDegraded c.status
                            ]
                            check

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "SourceHealthCheck optional fields are Nothing when absent" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "source_name": "new_source",
                            "source_type": "SOURCE_TYPE_LLM_OUTPUT",
                            "consecutive_failures": 0,
                            "total_successes": 0,
                            "total_failures": 0,
                            "status": "HEALTH_STATUS_HEALTHY"
                        }
                        """

                    result =
                        D.decodeString decodeSourceHealthCheck json
                in
                case result of
                    Ok check ->
                        Expect.all
                            [ \c -> Expect.equal Nothing c.lastSuccessAt
                            , \c -> Expect.equal Nothing c.lastFailureAt
                            , \c -> Expect.equal Nothing c.lastFailureReason
                            ]
                            check

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "SourceHealthCheck encode-decode round-trip" <|
            \_ ->
                let
                    original : SourceHealthCheck
                    original =
                        { sourceName = "loot_scraper"
                        , sourceType = SourceTypeScraperConfig
                        , lastSuccessAt = Just "2026-03-20T10:00:00Z"
                        , lastFailureAt = Nothing
                        , lastFailureReason = Nothing
                        , consecutiveFailures = 0
                        , totalSuccesses = 50
                        , totalFailures = 1
                        , status = HealthStatusHealthy
                        }

                    result =
                        D.decodeValue decodeSourceHealthCheck (encodeSourceHealthCheck original)
                in
                case result of
                    Ok decoded ->
                        Expect.all
                            [ \c -> Expect.equal original.sourceName c.sourceName
                            , \c -> Expect.equal original.sourceType c.sourceType
                            , \c -> Expect.equal original.lastSuccessAt c.lastSuccessAt
                            , \c -> Expect.equal original.lastFailureAt c.lastFailureAt
                            , \c -> Expect.equal original.lastFailureReason c.lastFailureReason
                            , \c -> Expect.equal original.totalSuccesses c.totalSuccesses
                            , \c -> Expect.equal original.status c.status
                            ]
                            decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "HealthStatus decodes both SCREAMING_SNAKE and lowercase" <|
            \_ ->
                Expect.all
                    [ \_ ->
                        case D.decodeString decodeHealthStatus "\"HEALTH_STATUS_BROKEN\"" of
                            Ok v ->
                                Expect.equal HealthStatusBroken v

                            Err e ->
                                Expect.fail (D.errorToString e)
                    , \_ ->
                        case D.decodeString decodeHealthStatus "\"broken\"" of
                            Ok v ->
                                Expect.equal HealthStatusBroken v

                            Err e ->
                                Expect.fail (D.errorToString e)
                    , \_ ->
                        case D.decodeString decodeHealthStatus "\"healthy\"" of
                            Ok v ->
                                Expect.equal HealthStatusHealthy v

                            Err e ->
                                Expect.fail (D.errorToString e)
                    ]
                    ()
        , test "SourceType decodes lowercase wire values" <|
            \_ ->
                Expect.all
                    [ \_ ->
                        case D.decodeString decodeSourceType "\"scraper_config\"" of
                            Ok v ->
                                Expect.equal SourceTypeScraperConfig v

                            Err e ->
                                Expect.fail (D.errorToString e)
                    , \_ ->
                        case D.decodeString decodeSourceType "\"llm_output\"" of
                            Ok v ->
                                Expect.equal SourceTypeLlmOutput v

                            Err e ->
                                Expect.fail (D.errorToString e)
                    ]
                    ()
        ]



-- ---------------------------------------------------------------------------
-- Response-level tests (BookDetailResponse, AuthResponse, BookshelfResponse)
-- ---------------------------------------------------------------------------


responseSuite : Test
responseSuite =
    describe "Response decoders"
        [ test "BookDetailResponse decodes with optional placement present" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "book": {
                                "id": "b-1",
                                "title": "The Secret History",
                                "author": {"id": "a-1", "name": "Donna Tartt"}
                            },
                            "placement": {
                                "id": "pl-1",
                                "book_id": "b-1",
                                "bookshelf_name": "library",
                                "formats": ["physical"],
                                "personal_rating": 5,
                                "notes": "Favourite"
                            },
                            "my_writing": [
                                {"id": "w-1", "title": "Review", "published_at": "2026-03-20T00:00:00Z"}
                            ]
                        }
                        """

                    result =
                        D.decodeString decodeBookDetailResponse json
                in
                case result of
                    Ok resp ->
                        Expect.all
                            [ \r -> Expect.equal "b-1" r.book.id
                            , \r -> Expect.equal "The Secret History" r.book.title
                            , \r -> Expect.equal (Just "pl-1") (Maybe.map .id r.placement)
                            , \r -> Expect.equal (Just "library") (Maybe.map .bookshelfName r.placement)
                            , \r -> Expect.equal 1 (List.length r.myWriting)
                            ]
                            resp

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "BookDetailResponse decodes with null placement" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "book": {"id": "b-2", "title": "Pale Fire"},
                            "my_writing": []
                        }
                        """

                    result =
                        D.decodeString decodeBookDetailResponse json
                in
                case result of
                    Ok resp ->
                        Expect.all
                            [ \r -> Expect.equal "b-2" r.book.id
                            , \r -> Expect.equal Nothing r.placement
                            , \r -> Expect.equal [] r.myWriting
                            ]
                            resp

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "BookDetailResponse encode-decode round-trip" <|
            \_ ->
                let
                    original : BookDetailResponse
                    original =
                        { book =
                            { id = "b-1"
                            , title = "The Secret History"
                            , authorId = ""
                            , description = "A group of classics students"
                            , subjects = [ "fiction" ]
                            , visibilityTier = VisibilityTierPublic
                            , author = { id = "a-1", name = "Donna Tartt", websiteUrl = "", rssFeedUrl = "", bio = "", openLibraryId = "", createdAt = "", updatedAt = "" }
                            , editions = []
                            , editionCount = 0
                            , primaryEdition = defaultEdition
                            , communityReadCount = 42
                            , language = "en"
                            , bisacCodes = []
                            , createdAt = ""
                            , updatedAt = ""
                            }
                        , placement =
                            Just
                                { id = "pl-1"
                                , bookId = "b-1"
                                , bookshelfName = "library"
                                , formats = [ "physical" ]
                                , personalRating = 5
                                , notes = "Great"
                                , visibility = "platform"
                                , bookshelfVisibility = "platform"
                                }
                        , myWriting = [ { id = "w-1", title = "Review", publishedAt = "2026-03-20T00:00:00Z" } ]
                        }

                    result =
                        D.decodeValue decodeBookDetailResponse (encodeBookDetailResponse original)
                in
                case result of
                    Ok decoded ->
                        Expect.all
                            [ \r -> Expect.equal original.book.id r.book.id
                            , \r -> Expect.equal original.book.title r.book.title
                            , \r -> Expect.equal (Just "pl-1") (Maybe.map .id r.placement)
                            , \r -> Expect.equal 1 (List.length r.myWriting)
                            ]
                            decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "AuthResponse decodes token and user" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "token": "jwt-abc-123",
                            "user": {
                                "id": "u-1",
                                "email": "user@example.com",
                                "display_name": "BookLover",
                                "role": "user",
                                "country_code": "ZA",
                                "city": "Cape Town",
                                "consent_analytics": true,
                                "age_verified": false,
                                "profile_visibility": "platform"
                            }
                        }
                        """

                    result =
                        D.decodeString decodeAuthResponse json
                in
                case result of
                    Ok resp ->
                        Expect.all
                            [ \r -> Expect.equal "jwt-abc-123" r.token
                            , \r -> Expect.equal "u-1" r.user.id
                            , \r -> Expect.equal "user@example.com" r.user.email
                            , \r -> Expect.equal "BookLover" r.user.displayName
                            , \r -> Expect.equal True r.user.consentAnalytics
                            ]
                            resp

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "AuthResponse encode-decode round-trip" <|
            \_ ->
                let
                    original : AuthResponse
                    original =
                        { token = "jwt-xyz"
                        , user =
                            { id = "u-2"
                            , email = "owner@stacks.local"
                            , displayName = "Librarian"
                            , role = "owner"
                            , countryCode = "GB"
                            , city = "London"
                            , consentAnalytics = False
                            , consentWritingAssistant = False
                            , ageVerified = True
                            , ageVerifiedAt = ""
                            , ageVerificationProvider = ""
                            , profileVisibility = "owner"
                            , passwordHash = ""
                            , websiteUrl = ""
                            , consentAnalyticsAt = ""
                            , consentWritingAssistantAt = ""
                            , onboardingCompleted = False
                            , onboardingSteps = ""
                            , notifyWishlistAvailability = False
                            , notifyMarketplace = False
                            , notifyGroupInvitations = False
                            , notifyEventMatches = False
                            , emailConfirmed = False
                            , emailConfirmationToken = ""
                            , passwordResetToken = ""
                            , passwordResetSentAt = ""
                            , createdAt = ""
                            , updatedAt = ""
                            , failedLoginCount = 0
                            , failedLoginFirstAt = ""
                            , lockedUntil = ""
                            }
                        }

                    result =
                        D.decodeValue decodeAuthResponse (encodeAuthResponse original)
                in
                case result of
                    Ok decoded ->
                        Expect.all
                            [ \r -> Expect.equal original.token r.token
                            , \r -> Expect.equal original.user.id r.user.id
                            , \r -> Expect.equal original.user.email r.user.email
                            , \r -> Expect.equal original.user.role r.user.role
                            ]
                            decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "AuthResponse defaults user when absent" <|
            \_ ->
                let
                    result =
                        D.decodeString decodeAuthResponse """{"token":"abc"}"""
                in
                case result of
                    Ok resp ->
                        Expect.all
                            [ \r -> Expect.equal "abc" r.token
                            , \r -> Expect.equal "" r.user.id
                            , \r -> Expect.equal "" r.user.email
                            ]
                            resp

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "BookshelfResponse decodes placements list" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "bookshelf": "library",
                            "count": 1,
                            "placements": [
                                {
                                    "id": "p-1",
                                    "position": 1,
                                    "placed_at": "2026-03-20T10:00:00Z",
                                    "formats": ["physical"],
                                    "personal_rating": 4,
                                    "notes": "",
                                    "book": {"id": "b-1", "title": "Pale Fire"}
                                }
                            ]
                        }
                        """

                    result =
                        D.decodeString decodeBookshelfResponse json
                in
                case result of
                    Ok resp ->
                        Expect.all
                            [ \r -> Expect.equal "library" r.bookshelf
                            , \r -> Expect.equal 1 r.count
                            , \r -> Expect.equal 1 (List.length r.placements)
                            ]
                            resp

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "BookshelfResponse encode-decode round-trip" <|
            \_ ->
                let
                    original : BookshelfResponse
                    original =
                        { bookshelf = "antilibrary"
                        , count = 0
                        , placements = []
                        }

                    result =
                        D.decodeValue decodeBookshelfResponse (encodeBookshelfResponse original)
                in
                case result of
                    Ok decoded ->
                        Expect.equal original decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "BookshelfResponse defaults when fields absent" <|
            \_ ->
                let
                    result =
                        D.decodeString decodeBookshelfResponse """{}"""
                in
                case result of
                    Ok resp ->
                        Expect.all
                            [ \r -> Expect.equal "" r.bookshelf
                            , \r -> Expect.equal 0 r.count
                            , \r -> Expect.equal [] r.placements
                            ]
                            resp

                    Err e ->
                        Expect.fail (D.errorToString e)
        ]



-- ---------------------------------------------------------------------------
-- Blog (BlogPost, BlogPostSummary, BookAssociation, BlogVisibility)
-- ---------------------------------------------------------------------------


blogSuite : Test
blogSuite =
    describe "Blog decoders"
        [ test "BlogPost decodes all fields" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "id": "bp-1",
                            "title": "On Reading Slowly",
                            "body": "Some thoughts on reading...",
                            "visibility": "owner",
                            "user_id": "u-1",
                            "associations": [
                                {"id": "a-1", "book_id": "b-1", "confidence": 0.95, "source": "llm", "visible": true, "reasoning": "mentioned by title"}
                            ],
                            "published_at": "2026-03-20T10:00:00Z",
                            "created_at": "2026-03-19T08:00:00Z",
                            "updated_at": "2026-03-20T12:00:00Z"
                        }
                        """

                    result =
                        D.decodeString decodeBlogPost json
                in
                case result of
                    Ok post ->
                        Expect.all
                            [ \p -> Expect.equal "bp-1" p.id
                            , \p -> Expect.equal "On Reading Slowly" p.title
                            , \p -> Expect.equal "Some thoughts on reading..." p.body
                            , \p -> Expect.equal BlogVisibilityOwner p.visibility
                            , \p -> Expect.equal "u-1" p.userId
                            , \p -> Expect.equal 1 (List.length p.associations)
                            , \p -> Expect.equal "2026-03-20T10:00:00Z" p.publishedAt
                            , \p -> Expect.equal "2026-03-19T08:00:00Z" p.createdAt
                            , \p -> Expect.equal "2026-03-20T12:00:00Z" p.updatedAt
                            ]
                            post

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "BlogPost encode-decode round-trip" <|
            \_ ->
                let
                    original : BlogPost
                    original =
                        { id = "bp-2"
                        , title = "Dark Academia"
                        , body = "Exploring the aesthetic..."
                        , visibility = BlogVisibilityPlatform
                        , userId = "u-2"
                        , associations = []
                        , publishedAt = "2026-03-21T00:00:00Z"
                        , createdAt = "2026-03-20T00:00:00Z"
                        , updatedAt = "2026-03-21T01:00:00Z"
                        , visibilityGroupId = ""
                        }

                    result =
                        D.decodeValue decodeBlogPost (encodeBlogPost original)
                in
                case result of
                    Ok decoded ->
                        Expect.all
                            [ \p -> Expect.equal original.id p.id
                            , \p -> Expect.equal original.title p.title
                            , \p -> Expect.equal original.body p.body
                            , \p -> Expect.equal original.visibility p.visibility
                            , \p -> Expect.equal original.userId p.userId
                            , \p -> Expect.equal original.publishedAt p.publishedAt
                            , \p -> Expect.equal original.updatedAt p.updatedAt
                            ]
                            decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "BlogPostSummary decodes fields" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "id": "bp-3",
                            "title": "Cottage Core Reading",
                            "visibility": "platform",
                            "created_at": "2026-03-22T00:00:00Z"
                        }
                        """

                    result =
                        D.decodeString decodeBlogPostSummary json
                in
                case result of
                    Ok summary ->
                        Expect.all
                            [ \s -> Expect.equal "bp-3" s.id
                            , \s -> Expect.equal "Cottage Core Reading" s.title
                            , \s -> Expect.equal BlogVisibilityPlatform s.visibility
                            , \s -> Expect.equal "2026-03-22T00:00:00Z" s.createdAt
                            ]
                            summary

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "BookAssociation encode-decode round-trip" <|
            \_ ->
                let
                    original : BookAssociation
                    original =
                        { id = "a-1"
                        , bookId = "b-1"
                        , confidence = 0.85
                        , source = "llm"
                        , visible = True
                        , reasoning = "title mentioned"
                        , bookTitle = "Test Book"
                        , status = "confirmed"
                        , postId = ""
                        , createdAt = ""
                        }

                    result =
                        D.decodeValue decodeBookAssociation (encodeBookAssociation original)
                in
                case result of
                    Ok decoded ->
                        Expect.all
                            [ \a -> Expect.equal original.id a.id
                            , \a -> Expect.equal original.bookId a.bookId
                            , \a -> Expect.within (Expect.Absolute 0.001) original.confidence a.confidence
                            , \a -> Expect.equal original.source a.source
                            , \a -> Expect.equal original.visible a.visible
                            , \a -> Expect.equal original.reasoning a.reasoning
                            ]
                            decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "BlogVisibility decodes lowercase wire values" <|
            \_ ->
                Expect.all
                    [ \_ ->
                        case D.decodeString decodeBlogVisibility "\"owner\"" of
                            Ok v ->
                                Expect.equal BlogVisibilityOwner v

                            Err e ->
                                Expect.fail (D.errorToString e)
                    , \_ ->
                        case D.decodeString decodeBlogVisibility "\"group\"" of
                            Ok v ->
                                Expect.equal BlogVisibilityGroup v

                            Err e ->
                                Expect.fail (D.errorToString e)
                    , \_ ->
                        case D.decodeString decodeBlogVisibility "\"platform\"" of
                            Ok v ->
                                Expect.equal BlogVisibilityPlatform v

                            Err e ->
                                Expect.fail (D.errorToString e)
                    ]
                    ()
        ]



-- ---------------------------------------------------------------------------
-- Listing
-- ---------------------------------------------------------------------------


listingSuite : Test
listingSuite =
    describe "Listing decoders"
        [ test "Listing decodes all fields" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "id": "l-1",
                            "condition": "good",
                            "pricing_mode": "fixed",
                            "price_cents": 15000,
                            "contact_info": "email@example.com",
                            "description": "Slightly worn copy",
                            "status": "active",
                            "created_at": "2026-03-20T10:00:00Z",
                            "currency": "ZAR",
                            "photo_urls": ["https://example.com/photo1.jpg"],
                            "listed_at": "2026-03-20T11:00:00Z",
                            "expires_at": "2026-04-20T11:00:00Z",
                            "sold_at": "",
                            "updated_at": "2026-03-20T12:00:00Z",
                            "book_id": "b-1",
                            "seller_id": "u-1"
                        }
                        """

                    result =
                        D.decodeString decodeListing json
                in
                case result of
                    Ok listing ->
                        Expect.all
                            [ \li -> Expect.equal "l-1" li.id
                            , \li -> Expect.equal "good" li.condition
                            , \li -> Expect.equal "fixed" li.pricingMode
                            , \li -> Expect.equal 15000 li.priceCents
                            , \li -> Expect.equal "email@example.com" li.contactInfo
                            , \li -> Expect.equal "ZAR" li.currency
                            , \li -> Expect.equal [ "https://example.com/photo1.jpg" ] li.photoUrls
                            , \li -> Expect.equal "b-1" li.bookId
                            , \li -> Expect.equal "u-1" li.sellerId
                            ]
                            listing

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "Listing encode-decode round-trip" <|
            \_ ->
                let
                    original : Listing
                    original =
                        { id = "l-2"
                        , condition = "like_new"
                        , pricingMode = "offer"
                        , priceCents = 5000
                        , contactInfo = "chat"
                        , description = "Great condition"
                        , status = "draft"
                        , createdAt = "2026-03-20T00:00:00Z"
                        , book = defaultBook
                        , currency = "ZAR"
                        , photoUrls = []
                        , listedAt = ""
                        , expiresAt = ""
                        , soldAt = ""
                        , updatedAt = "2026-03-20T00:00:00Z"
                        , bookId = "b-2"
                        , sellerId = "u-2"
                        }

                    result =
                        D.decodeValue decodeListing (encodeListing original)
                in
                case result of
                    Ok decoded ->
                        Expect.all
                            [ \li -> Expect.equal original.id li.id
                            , \li -> Expect.equal original.condition li.condition
                            , \li -> Expect.equal original.priceCents li.priceCents
                            , \li -> Expect.equal original.currency li.currency
                            , \li -> Expect.equal original.bookId li.bookId
                            , \li -> Expect.equal original.sellerId li.sellerId
                            ]
                            decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "Listing defaults when fields absent" <|
            \_ ->
                let
                    result =
                        D.decodeString decodeListing """{}"""
                in
                case result of
                    Ok listing ->
                        Expect.all
                            [ \li -> Expect.equal "" li.id
                            , \li -> Expect.equal 0 li.priceCents
                            , \li -> Expect.equal "" li.currency
                            , \li -> Expect.equal [] li.photoUrls
                            , \li -> Expect.equal "" li.bookId
                            ]
                            listing

                    Err e ->
                        Expect.fail (D.errorToString e)
        ]



-- ---------------------------------------------------------------------------
-- Blog response-level decoders
-- ---------------------------------------------------------------------------


blogResponseSuite : Test
blogResponseSuite =
    describe "Blog response-level decoders"
        [ test "BlogPostResponse decodes envelope with post" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "post": {
                                "id": "bp-1",
                                "title": "On Reading",
                                "body": "Thoughts...",
                                "visibility": "owner",
                                "user_id": "u-1",
                                "associations": [],
                                "published_at": "",
                                "created_at": "2026-03-20T00:00:00Z",
                                "updated_at": "2026-03-20T00:00:00Z"
                            }
                        }
                        """

                    result =
                        D.decodeString decodeBlogPostResponse json
                in
                case result of
                    Ok resp ->
                        Expect.all
                            [ \r -> Expect.equal "bp-1" r.post.id
                            , \r -> Expect.equal "On Reading" r.post.title
                            , \r -> Expect.equal BlogVisibilityOwner r.post.visibility
                            ]
                            resp

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "BlogPostResponse encode-decode round-trip" <|
            \_ ->
                let
                    original : BlogPostResponse
                    original =
                        { post =
                            { id = "bp-2"
                            , title = "Dark Academia"
                            , body = "Exploring..."
                            , visibility = BlogVisibilityPlatform
                            , userId = "u-2"
                            , associations = []
                            , publishedAt = "2026-03-21T00:00:00Z"
                            , createdAt = "2026-03-20T00:00:00Z"
                            , updatedAt = "2026-03-21T01:00:00Z"
                            , visibilityGroupId = ""
                            }
                        }

                    result =
                        D.decodeValue decodeBlogPostResponse (encodeBlogPostResponse original)
                in
                case result of
                    Ok decoded ->
                        Expect.all
                            [ \r -> Expect.equal original.post.id r.post.id
                            , \r -> Expect.equal original.post.title r.post.title
                            , \r -> Expect.equal original.post.visibility r.post.visibility
                            ]
                            decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "BlogPostListResponse decodes list of posts" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "posts": [
                                {"id": "bp-1", "title": "First"},
                                {"id": "bp-2", "title": "Second"}
                            ]
                        }
                        """

                    result =
                        D.decodeString decodeBlogPostListResponse json
                in
                case result of
                    Ok resp ->
                        Expect.equal 2 (List.length resp.posts)

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "BlogPostListResponse encode-decode round-trip" <|
            \_ ->
                let
                    original : BlogPostListResponse
                    original =
                        { posts = [] }

                    result =
                        D.decodeValue decodeBlogPostListResponse (encodeBlogPostListResponse original)
                in
                case result of
                    Ok decoded ->
                        Expect.equal original decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "BlogPostShowResponse decodes post with associations" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "post": {"id": "bp-1", "title": "Review"},
                            "associations": [
                                {"id": "a-1", "book_id": "b-1", "confidence": 0.9, "source": "llm", "visible": true, "reasoning": "mentioned"}
                            ]
                        }
                        """

                    result =
                        D.decodeString decodeBlogPostShowResponse json
                in
                case result of
                    Ok resp ->
                        Expect.all
                            [ \r -> Expect.equal "bp-1" r.post.id
                            , \r -> Expect.equal 1 (List.length r.associations)
                            , \r ->
                                case List.head r.associations of
                                    Just assoc ->
                                        Expect.equal "a-1" assoc.id

                                    Nothing ->
                                        Expect.fail "Expected at least one association"
                            ]
                            resp

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "BlogPostShowResponse encode-decode round-trip" <|
            \_ ->
                let
                    original : BlogPostShowResponse
                    original =
                        { post = defaultBlogPost
                        , associations =
                            [ { id = "a-1"
                              , bookId = "b-1"
                              , confidence = 0.85
                              , source = "llm"
                              , visible = True
                              , reasoning = "title mentioned"
                              , bookTitle = "Test Book"
                              , status = "confirmed"
                              , postId = ""
                              , createdAt = ""
                              }
                            ]
                        }

                    result =
                        D.decodeValue decodeBlogPostShowResponse (encodeBlogPostShowResponse original)
                in
                case result of
                    Ok decoded ->
                        Expect.all
                            [ \r -> Expect.equal original.post.id r.post.id
                            , \r -> Expect.equal 1 (List.length r.associations)
                            ]
                            decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "AssociationActionResponse decodes association envelope" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "association": {
                                "id": "a-1",
                                "book_id": "b-1",
                                "confidence": 0.95,
                                "source": "llm",
                                "visible": true,
                                "reasoning": "mentioned by title"
                            }
                        }
                        """

                    result =
                        D.decodeString decodeAssociationActionResponse json
                in
                case result of
                    Ok resp ->
                        Expect.all
                            [ \r -> Expect.equal "a-1" r.association.id
                            , \r -> Expect.equal "b-1" r.association.bookId
                            , \r -> Expect.equal True r.association.visible
                            ]
                            resp

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "AssociationActionResponse encode-decode round-trip" <|
            \_ ->
                let
                    original : AssociationActionResponse
                    original =
                        { association =
                            { id = "a-2"
                            , bookId = "b-2"
                            , confidence = 0.75
                            , source = "manual"
                            , visible = False
                            , reasoning = "user linked"
                            , bookTitle = "Another Book"
                            , status = "dismissed"
                            , postId = ""
                            , createdAt = ""
                            }
                        }

                    result =
                        D.decodeValue decodeAssociationActionResponse (encodeAssociationActionResponse original)
                in
                case result of
                    Ok decoded ->
                        Expect.all
                            [ \r -> Expect.equal original.association.id r.association.id
                            , \r -> Expect.equal original.association.bookId r.association.bookId
                            , \r -> Expect.within (Expect.Absolute 0.001) original.association.confidence r.association.confidence
                            , \r -> Expect.equal original.association.visible r.association.visible
                            ]
                            decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        ]



-- ---------------------------------------------------------------------------
-- Listing response-level decoders
-- ---------------------------------------------------------------------------


listingResponseSuite : Test
listingResponseSuite =
    describe "Listing response-level decoders"
        [ test "ListingResponse decodes listing envelope" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "listing": {
                                "id": "l-1",
                                "condition": "good",
                                "pricing_mode": "fixed",
                                "price_cents": 15000,
                                "contact_info": "email@example.com",
                                "description": "Slightly worn",
                                "status": "active",
                                "created_at": "2026-03-20T10:00:00Z",
                                "currency": "ZAR",
                                "photo_urls": [],
                                "listed_at": "",
                                "expires_at": "",
                                "sold_at": "",
                                "updated_at": "",
                                "book_id": "b-1",
                                "seller_id": "u-1"
                            }
                        }
                        """

                    result =
                        D.decodeString decodeListingResponse json
                in
                case result of
                    Ok resp ->
                        Expect.all
                            [ \r -> Expect.equal "l-1" r.listing.id
                            , \r -> Expect.equal "good" r.listing.condition
                            , \r -> Expect.equal 15000 r.listing.priceCents
                            , \r -> Expect.equal "ZAR" r.listing.currency
                            ]
                            resp

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "ListingResponse encode-decode round-trip" <|
            \_ ->
                let
                    original : ListingResponse
                    original =
                        { listing = defaultListing }

                    result =
                        D.decodeValue decodeListingResponse (encodeListingResponse original)
                in
                case result of
                    Ok decoded ->
                        Expect.equal original decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "ListingListResponse decodes listings array" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "listings": [
                                {"id": "l-1", "condition": "good"},
                                {"id": "l-2", "condition": "like_new"}
                            ]
                        }
                        """

                    result =
                        D.decodeString decodeListingListResponse json
                in
                case result of
                    Ok resp ->
                        Expect.all
                            [ \r -> Expect.equal 2 (List.length r.listings)
                            , \r ->
                                case List.head r.listings of
                                    Just first ->
                                        Expect.equal "l-1" first.id

                                    Nothing ->
                                        Expect.fail "Expected at least one listing"
                            ]
                            resp

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "ListingListResponse encode-decode round-trip" <|
            \_ ->
                let
                    original : ListingListResponse
                    original =
                        { listings = [], total = 0 }

                    result =
                        D.decodeValue decodeListingListResponse (encodeListingListResponse original)
                in
                case result of
                    Ok decoded ->
                        Expect.equal original decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        ]



-- ---------------------------------------------------------------------------
-- Source response-level decoders
-- ---------------------------------------------------------------------------


sourceResponseSuite : Test
sourceResponseSuite =
    describe "Source response-level decoders"
        [ test "SourceAdminListResponse decodes sources with pagination" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "sources": [
                                {
                                    "id": "src-1",
                                    "name": "Takealot",
                                    "type": "scraper_config",
                                    "url": "https://takealot.com",
                                    "confidence": 0.9,
                                    "discovered_via": "manual",
                                    "discovered_at": "2026-03-20T00:00:00Z",
                                    "status": "approved",
                                    "approved_at": "2026-03-21T00:00:00Z",
                                    "created_at": "2026-03-20T00:00:00Z"
                                }
                            ],
                            "total": 1,
                            "page": 1
                        }
                        """

                    result =
                        D.decodeString decodeSourceAdminListResponse json
                in
                case result of
                    Ok resp ->
                        Expect.all
                            [ \r -> Expect.equal 1 (List.length r.sources)
                            , \r -> Expect.equal 1 r.total
                            , \r -> Expect.equal 1 r.page
                            , \r ->
                                case List.head r.sources of
                                    Just src ->
                                        Expect.all
                                            [ \s -> Expect.equal "src-1" s.id
                                            , \s -> Expect.equal "Takealot" s.name
                                            , \s -> Expect.equal "scraper_config" s.type_
                                            , \s -> Expect.equal "approved" s.status
                                            ]
                                            src

                                    Nothing ->
                                        Expect.fail "Expected at least one source"
                            ]
                            resp

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "SourceAdminListResponse encode-decode round-trip" <|
            \_ ->
                let
                    original : SourceAdminListResponse
                    original =
                        { sources =
                            [ { id = "src-1"
                              , name = "Loot"
                              , type_ = "scraper_config"
                              , url = "https://loot.co.za"
                              , confidence = 0.85
                              , discoveredVia = "crawler"
                              , discoveredAt = "2026-03-20T00:00:00Z"
                              , status = "pending"
                              , approvedAt = ""
                              , createdAt = "2026-03-20T00:00:00Z"
                              }
                            ]
                        , total = 1
                        , page = 1
                        }

                    result =
                        D.decodeValue decodeSourceAdminListResponse (encodeSourceAdminListResponse original)
                in
                case result of
                    Ok decoded ->
                        Expect.all
                            [ \r -> Expect.equal original.total r.total
                            , \r -> Expect.equal original.page r.page
                            , \r -> Expect.equal 1 (List.length r.sources)
                            , \r ->
                                case List.head r.sources of
                                    Just src ->
                                        Expect.equal "src-1" src.id

                                    Nothing ->
                                        Expect.fail "Expected at least one source"
                            ]
                            decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "VisibilityUpdateResponse decodes id and visibility" <|
            \_ ->
                let
                    json =
                        """{"id":"res-1","visibility":"public"}"""

                    result =
                        D.decodeString decodeVisibilityUpdateResponse json
                in
                case result of
                    Ok resp ->
                        Expect.all
                            [ \r -> Expect.equal "res-1" r.id
                            , \r -> Expect.equal "public" r.visibility
                            ]
                            resp

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "VisibilityUpdateResponse encode-decode round-trip" <|
            \_ ->
                let
                    original : VisibilityUpdateResponse
                    original =
                        { id = "res-2"
                        , visibility = "owner"
                        }

                    result =
                        D.decodeValue decodeVisibilityUpdateResponse (encodeVisibilityUpdateResponse original)
                in
                case result of
                    Ok decoded ->
                        Expect.equal original decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "DiscoveredSource decodes all 10 fields" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "id": "ds-1",
                            "name": "RSS Feed",
                            "type": "rss_feed",
                            "url": "https://example.com/feed",
                            "confidence": 0.7,
                            "discovered_via": "crawler",
                            "discovered_at": "2026-03-20T00:00:00Z",
                            "status": "pending",
                            "approved_at": "",
                            "created_at": "2026-03-19T00:00:00Z"
                        }
                        """

                    result =
                        D.decodeString decodeDiscoveredSource json
                in
                case result of
                    Ok src ->
                        Expect.all
                            [ \s -> Expect.equal "ds-1" s.id
                            , \s -> Expect.equal "RSS Feed" s.name
                            , \s -> Expect.equal "rss_feed" s.type_
                            , \s -> Expect.equal "https://example.com/feed" s.url
                            , \s -> Expect.within (Expect.Absolute 0.001) 0.7 s.confidence
                            , \s -> Expect.equal "crawler" s.discoveredVia
                            , \s -> Expect.equal "pending" s.status
                            , \s -> Expect.equal "" s.approvedAt
                            , \s -> Expect.equal "2026-03-19T00:00:00Z" s.createdAt
                            ]
                            src

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "DiscoveredSource encode-decode round-trip" <|
            \_ ->
                let
                    original : DiscoveredSource
                    original =
                        { id = "ds-2"
                        , name = "LLM Source"
                        , type_ = "llm_output"
                        , url = ""
                        , confidence = 0.5
                        , discoveredVia = "manual"
                        , discoveredAt = "2026-03-22T00:00:00Z"
                        , status = "approved"
                        , approvedAt = "2026-03-23T00:00:00Z"
                        , createdAt = "2026-03-22T00:00:00Z"
                        }

                    result =
                        D.decodeValue decodeDiscoveredSource (encodeDiscoveredSource original)
                in
                case result of
                    Ok decoded ->
                        Expect.all
                            [ \s -> Expect.equal original.id s.id
                            , \s -> Expect.equal original.name s.name
                            , \s -> Expect.equal original.type_ s.type_
                            , \s -> Expect.within (Expect.Absolute 0.001) original.confidence s.confidence
                            , \s -> Expect.equal original.status s.status
                            , \s -> Expect.equal original.approvedAt s.approvedAt
                            , \s -> Expect.equal original.createdAt s.createdAt
                            ]
                            decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        ]



-- ---------------------------------------------------------------------------
-- Upload (UploadAccepted, PollResponse, PollStatus)
-- ---------------------------------------------------------------------------


uploadSuite : Test
uploadSuite =
    describe "Upload decoders"
        [ test "UploadAccepted decodes fields" <|
            \_ ->
                let
                    json =
                        """{"status":"accepted","image_id":"img-1"}"""

                    result =
                        D.decodeString decodeUploadAccepted json
                in
                case result of
                    Ok accepted ->
                        Expect.all
                            [ \a -> Expect.equal "accepted" a.status
                            , \a -> Expect.equal "img-1" a.imageId
                            ]
                            accepted

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "PollResponse decodes resolved status" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "image_id": "img-2",
                            "status": "resolved",
                            "book_id": "b-1",
                            "book_ids": ["b-1", "b-2"],
                            "rejection_reason": "",
                            "is_duplicate": false
                        }
                        """

                    result =
                        D.decodeString decodePollResponse json
                in
                case result of
                    Ok poll ->
                        Expect.all
                            [ \p -> Expect.equal "img-2" p.imageId
                            , \p -> Expect.equal "resolved" p.status
                            , \p -> Expect.equal "b-1" p.bookId
                            , \p -> Expect.equal [ "b-1", "b-2" ] p.bookIds
                            , \p -> Expect.equal False p.isDuplicate
                            ]
                            poll

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "PollResponse decodes rejected status" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "image_id": "img-3",
                            "status": "rejected",
                            "book_id": "",
                            "book_ids": [],
                            "rejection_reason": "not_a_book",
                            "is_duplicate": false
                        }
                        """

                    result =
                        D.decodeString decodePollResponse json
                in
                case result of
                    Ok poll ->
                        Expect.all
                            [ \p -> Expect.equal "rejected" p.status
                            , \p -> Expect.equal "not_a_book" p.rejectionReason
                            , \p -> Expect.equal [] p.bookIds
                            ]
                            poll

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "PollResponse encode-decode round-trip" <|
            \_ ->
                let
                    original : PollResponse
                    original =
                        { imageId = "img-4"
                        , status = "resolved"
                        , bookId = "b-5"
                        , bookIds = [ "b-5" ]
                        , rejectionReason = ""
                        , isDuplicate = True
                        }

                    result =
                        D.decodeValue decodePollResponse (encodePollResponse original)
                in
                case result of
                    Ok decoded ->
                        Expect.all
                            [ \p -> Expect.equal original.imageId p.imageId
                            , \p -> Expect.equal original.status p.status
                            , \p -> Expect.equal original.bookId p.bookId
                            , \p -> Expect.equal original.bookIds p.bookIds
                            , \p -> Expect.equal original.isDuplicate p.isDuplicate
                            ]
                            decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "PollStatus decodes lowercase wire values" <|
            \_ ->
                Expect.all
                    [ \_ ->
                        case D.decodeString decodePollStatus "\"pending\"" of
                            Ok v ->
                                Expect.equal PollStatusPending v

                            Err e ->
                                Expect.fail (D.errorToString e)
                    , \_ ->
                        case D.decodeString decodePollStatus "\"resolved\"" of
                            Ok v ->
                                Expect.equal PollStatusResolved v

                            Err e ->
                                Expect.fail (D.errorToString e)
                    , \_ ->
                        case D.decodeString decodePollStatus "\"rejected\"" of
                            Ok v ->
                                Expect.equal PollStatusRejected v

                            Err e ->
                                Expect.fail (D.errorToString e)
                    ]
                    ()
        ]



-- ---------------------------------------------------------------------------
-- Admin (MetricsDashboard, CostItem)
-- ---------------------------------------------------------------------------


adminSuite : Test
adminSuite =
    describe "Admin decoders"
        [ test "SystemHealth decodes all fields" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "db_size_bytes": 5000000,
                            "total_books": 1000,
                            "total_users": 42,
                            "total_placements": 800,
                            "generated_at": "2026-03-24T00:00:00Z"
                        }
                        """

                    result =
                        D.decodeString decodeSystemHealth json
                in
                case result of
                    Ok health ->
                        Expect.all
                            [ \h -> Expect.equal 5000000 h.dbSizeBytes
                            , \h -> Expect.equal 1000 h.totalBooks
                            , \h -> Expect.equal 42 h.totalUsers
                            , \h -> Expect.equal 800 h.totalPlacements
                            , \h -> Expect.equal "2026-03-24T00:00:00Z" h.generatedAt
                            ]
                            health

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "SystemHealth encode-decode round-trip" <|
            \_ ->
                let
                    original : SystemHealth
                    original =
                        { dbSizeBytes = 3000000
                        , totalBooks = 500
                        , totalUsers = 10
                        , totalPlacements = 300
                        , generatedAt = "2026-03-24T12:00:00Z"
                        }

                    result =
                        D.decodeValue decodeSystemHealth (encodeSystemHealth original)
                in
                case result of
                    Ok decoded ->
                        Expect.equal original decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "SystemHealth defaults missing fields" <|
            \_ ->
                let
                    result =
                        D.decodeString decodeSystemHealth """{}"""
                in
                case result of
                    Ok health ->
                        Expect.equal defaultSystemHealth health

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "CostItem decodes all fields" <|
            \_ ->
                let
                    json =
                        """{"service":"Neon","description":"Database storage","amount_cents":4250}"""

                    result =
                        D.decodeString decodeCostItem json
                in
                case result of
                    Ok item ->
                        Expect.all
                            [ \i -> Expect.equal "Neon" i.service
                            , \i -> Expect.equal "Database storage" i.description
                            , \i -> Expect.equal 4250 i.amountCents
                            ]
                            item

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "CostItem encode-decode round-trip" <|
            \_ ->
                let
                    original : CostItem
                    original =
                        { service = "Fly.io"
                        , description = "Compute"
                        , amountCents = 15000
                        }

                    result =
                        D.decodeValue decodeCostItem (encodeCostItem original)
                in
                case result of
                    Ok decoded ->
                        Expect.equal original decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "CostBreakdown decodes nested categories" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "total_cents": 20000,
                            "currency": "USD",
                            "cost_per_book": 0.42,
                            "categories": [
                                {
                                    "category": "hosting",
                                    "total_cents": 15000,
                                    "items": [
                                        {"service": "Fly.io", "description": "VM", "amount_cents": 15000}
                                    ]
                                }
                            ],
                            "metrics": {
                                "books": 100,
                                "uploads": 50,
                                "placements": 200,
                                "db_size_bytes": 1000000,
                                "avg_upload_payload_bytes": 500000,
                                "vision_jobs_this_month": 30
                            },
                            "monthly_totals": [
                                {"period_start": "2026-03-01", "period_end": "2026-03-31", "total_cents": 20000}
                            ],
                            "generated_at": "2026-03-24T12:00:00Z"
                        }
                        """

                    result =
                        D.decodeString decodeCostBreakdown json
                in
                case result of
                    Ok breakdown ->
                        Expect.all
                            [ \b -> Expect.equal 20000 b.totalCents
                            , \b -> Expect.equal "USD" b.currency
                            , \b -> Expect.within (Expect.Absolute 0.01) 0.42 b.costPerBook
                            , \b -> Expect.equal 1 (List.length b.categories)
                            , \b -> Expect.equal 100 b.metrics.books
                            , \b -> Expect.equal 1 (List.length b.monthlyTotals)
                            , \b -> Expect.equal "2026-03-24T12:00:00Z" b.generatedAt
                            ]
                            breakdown

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "CostBreakdown encode-decode round-trip" <|
            \_ ->
                let
                    original : CostBreakdown
                    original =
                        { totalCents = 20000
                        , currency = "USD"
                        , costPerBook = 0.42
                        , categories =
                            [ { category = "hosting"
                              , totalCents = 15000
                              , items =
                                    [ { service = "Fly.io"
                                      , description = "VM"
                                      , amountCents = 15000
                                      }
                                    ]
                              }
                            ]
                        , metrics = defaultUsageMetrics
                        , monthlyTotals =
                            [ { periodStart = "2026-03-01"
                              , periodEnd = "2026-03-31"
                              , totalCents = 20000
                              }
                            ]
                        , generatedAt = "2026-03-24T12:00:00Z"
                        }

                    result =
                        D.decodeValue decodeCostBreakdown (encodeCostBreakdown original)
                in
                case result of
                    Ok decoded ->
                        Expect.all
                            [ \b -> Expect.equal original.totalCents b.totalCents
                            , \b -> Expect.equal original.currency b.currency
                            , \b -> Expect.within (Expect.Absolute 0.01) original.costPerBook b.costPerBook
                            , \b -> Expect.equal 1 (List.length b.categories)
                            , \b -> Expect.equal original.generatedAt b.generatedAt
                            ]
                            decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "EnrichmentGaps decodes all fields" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "status": "ok",
                            "books_without_prices": 10,
                            "books_without_covers": 5,
                            "books_without_reviews": 20
                        }
                        """

                    result =
                        D.decodeString decodeEnrichmentGaps json
                in
                case result of
                    Ok gaps ->
                        Expect.all
                            [ \g -> Expect.equal "ok" g.status
                            , \g -> Expect.equal 10 g.booksWithoutPrices
                            , \g -> Expect.equal 5 g.booksWithoutCovers
                            , \g -> Expect.equal 20 g.booksWithoutReviews
                            ]
                            gaps

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "EnrichmentGaps encode-decode round-trip" <|
            \_ ->
                let
                    original : EnrichmentGaps
                    original =
                        { status = "ok"
                        , booksWithoutPrices = 15
                        , booksWithoutCovers = 8
                        , booksWithoutReviews = 25
                        }

                    result =
                        D.decodeValue decodeEnrichmentGaps (encodeEnrichmentGaps original)
                in
                case result of
                    Ok decoded ->
                        Expect.equal original decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "QualityTrendRow decodes all 10 fields" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "snapshot_date": "2026-03-24",
                            "total_books": 1000,
                            "books_with_covers": 800,
                            "books_with_prices": 600,
                            "books_with_reviews": 400,
                            "total_sources": 10,
                            "healthy_sources": 8,
                            "cover_pct": 80.0,
                            "price_pct": 60.0,
                            "review_pct": 40.0
                        }
                        """

                    result =
                        D.decodeString decodeQualityTrendRow json
                in
                case result of
                    Ok row ->
                        Expect.all
                            [ \r -> Expect.equal "2026-03-24" r.snapshotDate
                            , \r -> Expect.equal 1000 r.totalBooks
                            , \r -> Expect.equal 800 r.booksWithCovers
                            , \r -> Expect.within (Expect.Absolute 0.1) 80.0 r.coverPct
                            , \r -> Expect.within (Expect.Absolute 0.1) 60.0 r.pricePct
                            , \r -> Expect.within (Expect.Absolute 0.1) 40.0 r.reviewPct
                            ]
                            row

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "QualityTrendRow encode-decode round-trip" <|
            \_ ->
                let
                    original : QualityTrendRow
                    original =
                        { snapshotDate = "2026-03-24"
                        , totalBooks = 1000
                        , booksWithCovers = 800
                        , booksWithPrices = 600
                        , booksWithReviews = 400
                        , totalSources = 10
                        , healthySources = 8
                        , coverPct = 80.0
                        , pricePct = 60.0
                        , reviewPct = 40.0
                        }

                    result =
                        D.decodeValue decodeQualityTrendRow (encodeQualityTrendRow original)
                in
                case result of
                    Ok decoded ->
                        Expect.all
                            [ \r -> Expect.equal original.snapshotDate r.snapshotDate
                            , \r -> Expect.equal original.totalBooks r.totalBooks
                            , \r -> Expect.within (Expect.Absolute 0.1) original.coverPct r.coverPct
                            , \r -> Expect.within (Expect.Absolute 0.1) original.pricePct r.pricePct
                            , \r -> Expect.within (Expect.Absolute 0.1) original.reviewPct r.reviewPct
                            ]
                            decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "MonthlyTotal encode-decode round-trip" <|
            \_ ->
                let
                    original : MonthlyTotal
                    original =
                        { periodStart = "2026-03-01"
                        , periodEnd = "2026-03-31"
                        , totalCents = 18500
                        }

                    result =
                        D.decodeValue decodeMonthlyTotal (encodeMonthlyTotal original)
                in
                case result of
                    Ok decoded ->
                        Expect.equal original decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "UsageMetrics encode-decode round-trip" <|
            \_ ->
                let
                    original : UsageMetrics
                    original =
                        { books = 100
                        , uploads = 50
                        , placements = 200
                        , dbSizeBytes = 1000000
                        , avgUploadPayloadBytes = 500000
                        , visionJobsThisMonth = 30
                        }

                    result =
                        D.decodeValue decodeUsageMetrics (encodeUsageMetrics original)
                in
                case result of
                    Ok decoded ->
                        Expect.equal original decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "MetricsDashboard decodes nested structure" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "system_health": {
                                "db_size_bytes": 5000000,
                                "total_books": 1000,
                                "total_users": 42,
                                "total_placements": 800,
                                "generated_at": "2026-03-24T00:00:00Z"
                            },
                            "job_stats": [],
                            "costs": {
                                "total_cents": 20000,
                                "currency": "USD",
                                "cost_per_book": 0.42,
                                "categories": [],
                                "monthly_totals": [],
                                "generated_at": "2026-03-24T12:00:00Z"
                            },
                            "gdpr": {
                                "images_pending_deletion": 3,
                                "users_with_consent": 40,
                                "generated_at": "2026-03-24T00:00:00Z"
                            },
                            "quality_trends": [],
                            "source_health": [],
                            "enrichment_gaps": {
                                "books_without_prices": 10,
                                "books_without_covers": 5,
                                "books_without_reviews": 20
                            },
                            "generated_at": "2026-03-24T12:00:00Z"
                        }
                        """

                    result =
                        D.decodeString decodeMetricsDashboard json
                in
                case result of
                    Ok dashboard ->
                        Expect.all
                            [ \d -> Expect.equal 42 d.systemHealth.totalUsers
                            , \d -> Expect.equal 1000 d.systemHealth.totalBooks
                            , \d -> Expect.equal 20000 d.costs.totalCents
                            , \d -> Expect.equal 3 d.gdpr.imagesPendingDeletion
                            , \d -> Expect.equal 10 d.enrichmentGaps.booksWithoutPrices
                            , \d -> Expect.equal "2026-03-24T12:00:00Z" d.generatedAt
                            ]
                            dashboard

                    Err e ->
                        Expect.fail (D.errorToString e)
        , test "MetricsDashboard encode-decode round-trip" <|
            \_ ->
                let
                    original : MetricsDashboard
                    original =
                        defaultMetricsDashboard

                    result =
                        D.decodeValue decodeMetricsDashboard (encodeMetricsDashboard original)
                in
                case result of
                    Ok decoded ->
                        Expect.all
                            [ \d -> Expect.equal original.systemHealth.totalUsers d.systemHealth.totalUsers
                            , \d -> Expect.equal original.systemHealth.totalBooks d.systemHealth.totalBooks
                            , \d -> Expect.equal original.costs.totalCents d.costs.totalCents
                            , \d -> Expect.equal original.generatedAt d.generatedAt
                            ]
                            decoded

                    Err e ->
                        Expect.fail (D.errorToString e)
        ]
