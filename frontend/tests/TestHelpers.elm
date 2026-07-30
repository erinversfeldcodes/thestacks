module TestHelpers exposing
    ( BookDetailTestModel
    , ReadingPileTestModel
    , bookDetailOverlayProgramWithOut
    , bookDetailProgram
    , bookDetailProgramWithOut
    , bookshelfProgram
    , libraryProgram
    , loginProgram
    , namedPlacement
    , placementWithPages
    , profileShelfProgram
    , readingPileProgram
    , searchProgram
    , simulateAuthErrorResponse
    , simulateAuthResponse
    , simulateBookDetailResponse
    , simulateBookDetailResponseWithPlacement
    , simulateBookDetailResponseWithVisibility
    , simulateBookPricesResponse
    , simulateBookResponse
    , simulateBookshelfErrorResponse
    , simulateBookshelfResponse
    , simulateEmptyBookPricesResponse
    , simulateMergeFormatResponse
    , simulateMultiShelfResponse
    , simulatePlacementVisibilityResponse
    , simulateRegisterResponse
    , simulateRegisterValidationResponse
    , testBook
    , testPlacement
    , uploadProgram
    )

{-| Shared test infrastructure for elm-program-test based program tests.

Provides ProgramTest harnesses for each testable page, HTTP response
simulators, and test data builders.

-}

import Api exposing (PollStatus(..), RegisterError(..), streamEventDecoder)
import Components.ISBNInput
import Dict
import Http
import Json.Decode as Decode
import Json.Encode as Encode
import Navigation.Route exposing (Route)
import Page.BookDetail as BookDetail
import Page.Bookshelf as Bookshelf
import Page.Bookshelf.ReadingPile as ReadingPile
import Page.Login as Login
import Page.Search as Search
import Page.Upload as Upload
import ProgramTest exposing (ProgramDefinition, SimulatedEffect)
import SimulatedEffect.Cmd
import SimulatedEffect.Http
import SimulatedEffect.Process
import SimulatedEffect.Task
import Types.Book exposing (Book, Edition, VisibilityTier(..))
import Types.Placement exposing (Placement, readingStatusToString)
import Types.RemoteData
import Types.Shelf exposing (bookshelfResponseDecoder, shelvesResponseDecoder)
import Types.Visibility



-- TEST DATA BUILDERS


{-| A default edition for tests.
-}
testEdition : Edition
testEdition =
    { id = "edition-test-001"
    , isbn = "9780141988511"
    , formatLabel = Just "Paperback"
    , coverImageUrl = Just "https://example.com/covers/habit.jpg"
    , pageCount = Just 371
    , publisher = Just "Random House"
    , publicationYear = Just 2012
    , isPrimary = True
    }


{-| A default book with all fields populated, suitable for use in any test.
-}
testBook : Book
testBook =
    { id = "book-test-001"
    , title = "The Power of Habit"
    , author = Just { id = "author-test-001", name = "Charles Duhigg", bio = Nothing, website = Nothing }
    , description = Just "A fascinating exploration of habit formation."
    , editions = [ testEdition ]
    , primaryEdition = Just testEdition
    , editionCount = 1
    , subjects = [ "Psychology", "Self-Help" ]
    , visibilityTier = Public
    }


{-| A placement wrapping a distinguishable book: its own book id and title, so
several of them can be told apart in the rendered DOM (each clickable spine
carries `id="spine-<bookId>"` and renders its title in `.book__title`).
-}
namedPlacement : String -> String -> Placement
namedPlacement bookId title =
    { testPlacement
        | id = "placement-" ++ bookId
        , book = Just { testBook | id = bookId, title = title }
    }


{-| A placement whose book has an explicit page count, which is what
`Components.Spine.spineWidth` (and therefore `groupIntoRows`) keys off.
-}
placementWithPages : String -> Int -> Placement
placementWithPages bookId pageCount =
    let
        edition =
            { testEdition | id = "edition-" ++ bookId, pageCount = Just pageCount }
    in
    { testPlacement
        | id = "placement-" ++ bookId
        , book =
            Just
                { testBook
                    | id = bookId
                    , editions = [ edition ]
                    , primaryEdition = Just edition
                }
    }


{-| A default placement wrapping testBook, suitable for bookshelf tests.
-}
testPlacement : Placement
testPlacement =
    { id = "placement-test-001"
    , book = Just testBook
    , position = Just 1
    , placedAt = Just "2025-01-15T10:30:00Z"
    , formats = []
    , personalRating = Nothing
    , notes = Nothing
    , bookshelfName = Just "library"
    , readingStatus = Nothing
    , currentPage = Nothing
    , startedAt = Nothing
    , finishedAt = Nothing
    , visibility = Nothing
    , hasUserWriting = False
    }



-- JSON ENCODING HELPERS


encodeEdition : Edition -> Encode.Value
encodeEdition edition =
    Encode.object
        ([ ( "id", Encode.string edition.id )
         , ( "isbn", Encode.string edition.isbn )
         , ( "is_primary", Encode.bool edition.isPrimary )
         ]
            ++ encodeMaybe "format_label" Encode.string edition.formatLabel
            ++ encodeMaybe "cover_image_url" Encode.string edition.coverImageUrl
            ++ encodeMaybe "page_count" Encode.int edition.pageCount
            ++ encodeMaybe "publisher" Encode.string edition.publisher
            ++ encodeMaybe "publication_year" Encode.int edition.publicationYear
        )


encodeBook : Book -> Encode.Value
encodeBook book =
    Encode.object
        ([ ( "id", Encode.string book.id )
         , ( "title", Encode.string book.title )
         , ( "author"
           , case book.author of
                Just author ->
                    Encode.object
                        ([ ( "id", Encode.string author.id )
                         , ( "name", Encode.string author.name )
                         ]
                            ++ (case author.bio of
                                    Just bio ->
                                        [ ( "bio", Encode.string bio ) ]

                                    Nothing ->
                                        []
                               )
                            ++ (case author.website of
                                    Just url ->
                                        [ ( "website", Encode.string url ) ]

                                    Nothing ->
                                        []
                               )
                        )

                Nothing ->
                    Encode.null
           )
         , ( "editions", Encode.list encodeEdition book.editions )
         , ( "edition_count", Encode.int book.editionCount )
         , ( "subjects", Encode.list Encode.string book.subjects )
         , ( "visibility_tier", encodeVisibilityTier book.visibilityTier )
         ]
            ++ encodeMaybe "description" Encode.string book.description
            ++ (case book.primaryEdition of
                    Just ed ->
                        [ ( "primary_edition", encodeEdition ed ) ]

                    Nothing ->
                        []
               )
        )


encodeVisibilityTier : VisibilityTier -> Encode.Value
encodeVisibilityTier tier =
    Encode.string <|
        case tier of
            Public ->
                "public"

            AgeGated ->
                "age_gated"

            Unlisted ->
                "unlisted"

            Private ->
                "private"


encodeMaybe : String -> (a -> Encode.Value) -> Maybe a -> List ( String, Encode.Value )
encodeMaybe key encoder maybeVal =
    case maybeVal of
        Just val ->
            [ ( key, encoder val ) ]

        Nothing ->
            []


encodePlacement : Placement -> Encode.Value
encodePlacement placement =
    Encode.object
        ([ ( "id", Encode.string placement.id ) ]
            ++ encodeMaybe "position" Encode.int placement.position
            ++ encodeMaybe "placed_at" Encode.string placement.placedAt
            ++ (case placement.book of
                    Just book ->
                        [ ( "book", encodeBook book ) ]

                    Nothing ->
                        []
               )
            ++ (case placement.personalRating of
                    Just rating ->
                        [ ( "personal_rating", Encode.int rating ) ]

                    Nothing ->
                        []
               )
            ++ (case placement.notes of
                    Just notes ->
                        [ ( "notes", Encode.string notes ) ]

                    Nothing ->
                        []
               )
            ++ (case placement.readingStatus of
                    Just status ->
                        [ ( "reading_status", Encode.string (readingStatusToString status) ) ]

                    Nothing ->
                        []
               )
            ++ encodeMaybe "current_page" Encode.int placement.currentPage
            ++ encodeMaybe "started_at" Encode.string placement.startedAt
            ++ encodeMaybe "finished_at" Encode.string placement.finishedAt
        )



-- HTTP RESPONSE SIMULATORS


{-| Create an HTTP response containing a single book JSON payload.
Parameters: bookId, title, authorName.
-}
simulateBookResponse : String -> String -> String -> Http.Response String
simulateBookResponse bookId title authorName =
    let
        json =
            Encode.encode 0
                (Encode.object
                    [ ( "book"
                      , Encode.object
                            [ ( "id", Encode.string bookId )
                            , ( "title", Encode.string title )
                            , ( "author"
                              , Encode.object
                                    [ ( "id", Encode.string "author-1" )
                                    , ( "name", Encode.string authorName )
                                    ]
                              )
                            , ( "editions", Encode.list identity [] )
                            , ( "edition_count", Encode.int 0 )
                            , ( "subjects", Encode.list Encode.string [] )
                            , ( "visibility_tier", Encode.string "public" )
                            ]
                      )
                    , ( "placement", Encode.null )
                    ]
                )
    in
    Http.GoodStatus_
        { url = "/api/books/" ++ bookId
        , statusCode = 200
        , statusText = "OK"
        , headers = Dict.empty
        }
        json


{-| Create an HTTP response for a bookshelf listing.
Wraps placements in a single default shelf within the shelves response shape.
-}
simulateBookshelfResponse : List Placement -> Http.Response String
simulateBookshelfResponse placements =
    let
        shelfJson =
            Encode.object
                [ ( "id", Encode.string "shelf-default" )
                , ( "position", Encode.int 0 )
                , ( "placements", Encode.list encodePlacement placements )
                ]

        json =
            Encode.encode 0
                (Encode.object
                    [ ( "shelves", Encode.list identity [ shelfJson ] ) ]
                )
    in
    Http.GoodStatus_
        { url = "/api/bookshelves/library"
        , statusCode = 200
        , statusText = "OK"
        , headers = Dict.empty
        }
        json


{-| Create an HTTP response for a bookshelf listing carrying several shelves,
each with its own id, `position` and placements — the real
`GET /api/bookshelves/:name` shape. Unlike `simulateBookshelfResponse` (one
default shelf) this lets a test observe how the page flattens _across_ shelves,
which is what makes per-shelf ordering observable.
-}
simulateMultiShelfResponse : List { id : String, position : Int, placements : List Placement } -> Http.Response String
simulateMultiShelfResponse shelves =
    let
        encodeShelf shelf =
            Encode.object
                [ ( "id", Encode.string shelf.id )
                , ( "position", Encode.int shelf.position )
                , ( "placements", Encode.list encodePlacement shelf.placements )
                ]

        json =
            Encode.encode 0
                (Encode.object
                    [ ( "shelves", Encode.list encodeShelf shelves ) ]
                )
    in
    Http.GoodStatus_
        { url = "/api/bookshelves/library"
        , statusCode = 200
        , statusText = "OK"
        , headers = Dict.empty
        }
        json


{-| Create an error HTTP response for a bookshelf listing with the given status code.
-}
simulateBookshelfErrorResponse : Int -> Http.Response String
simulateBookshelfErrorResponse statusCode =
    Http.BadStatus_
        { url = "/api/bookshelves/library"
        , statusCode = statusCode
        , statusText = "Error"
        , headers = Dict.empty
        }
        ""


{-| Create an HTTP response for a successful merge-format call.
Parameters: bookId, editionId, isbn, formatLabel.
-}
simulateMergeFormatResponse : String -> String -> String -> String -> Http.Response String
simulateMergeFormatResponse bookId editionId isbn formatLabel =
    let
        json =
            Encode.encode 0
                (Encode.object
                    [ ( "edition"
                      , Encode.object
                            [ ( "id", Encode.string editionId )
                            , ( "isbn", Encode.string isbn )
                            , ( "is_primary", Encode.bool False )
                            , ( "format_label", Encode.string formatLabel )
                            ]
                      )
                    ]
                )
    in
    Http.GoodStatus_
        { url = "/api/books/" ++ bookId ++ "/merge-format"
        , statusCode = 200
        , statusText = "OK"
        , headers = Dict.empty
        }
        json


{-| Create a successful auth HTTP response.
Parameters: token, userId, email, displayName.
-}
simulateAuthResponse : String -> String -> String -> String -> Http.Response String
simulateAuthResponse token userId email displayName =
    let
        json =
            Encode.encode 0
                (Encode.object
                    [ ( "token", Encode.string token )
                    , ( "user"
                      , Encode.object
                            [ ( "id", Encode.string userId )
                            , ( "email", Encode.string email )
                            , ( "display_name", Encode.string displayName )
                            ]
                      )
                    ]
                )
    in
    Http.GoodStatus_
        { url = "/api/auth/login"
        , statusCode = 200
        , statusText = "OK"
        , headers = Dict.empty
        }
        json


{-| A successful registration HTTP response (201 with confirmation message).
The backend returns `{"message": "confirmation_email_sent"}` on register — NOT
an auth response with a token.
-}
simulateRegisterResponse : Http.Response String
simulateRegisterResponse =
    Http.GoodStatus_
        { url = "/api/auth/register"
        , statusCode = 201
        , statusText = "Created"
        , headers = Dict.empty
        }
        (Encode.encode 0
            (Encode.object [ ( "message", Encode.string "confirmation_email_sent" ) ])
        )


{-| Create a 422 registration validation error response carrying per-field
error messages, mirroring the backend's `{"errors": {field: [msg, ...]}}` shape
(see `format_errors/1` in the Elixir `ChangesetHelpers`).
-}
simulateRegisterValidationResponse : List ( String, List String ) -> Http.Response String
simulateRegisterValidationResponse fieldErrors =
    Http.BadStatus_
        { url = "/api/auth/register"
        , statusCode = 422
        , statusText = "Unprocessable Entity"
        , headers = Dict.empty
        }
        (Encode.encode 0
            (Encode.object
                [ ( "errors"
                  , Encode.object
                        (List.map
                            (\( field, messages ) -> ( field, Encode.list Encode.string messages ))
                            fieldErrors
                        )
                  )
                ]
            )
        )


{-| Create an auth error HTTP response with the given status code.
-}
simulateAuthErrorResponse : Int -> Http.Response String
simulateAuthErrorResponse statusCode =
    Http.BadStatus_
        { url = "/api/auth/login"
        , statusCode = statusCode
        , statusText = "Error"
        , headers = Dict.empty
        }
        ""


{-| An HTTP response for `GET /api/books/:id/prices`.

Two editions of one work at one store, which is the case the endpoint exists to
represent: shops stock whichever editions they stock, at different prices.

-}
simulateBookPricesResponse : String -> Http.Response String
simulateBookPricesResponse bookId =
    Http.GoodStatus_
        { url = "/api/books/" ++ bookId ++ "/prices"
        , statusCode = 200
        , statusText = "OK"
        , headers = Dict.empty
        }
        """
        {"prices": [
          {"book_edition_id": "ed-1", "isbn": "9780749397050",
           "format_label": "Paperback", "store_id": "st-1",
           "store_name": "Exclusive Books", "price_cents": 40000,
           "currency": "ZAR", "in_stock": true,
           "url": "https://exclusivebooks.co.za/products/9780749397050",
           "scraped_at": "2026-07-28T06:00:00Z"},
          {"book_edition_id": "ed-2", "isbn": "9788497592581",
           "format_label": "Paperback", "store_id": "st-1",
           "store_name": "Exclusive Books", "price_cents": 41100,
           "currency": "ZAR", "in_stock": true,
           "url": "https://exclusivebooks.co.za/products/9788497592581",
           "scraped_at": "2026-07-28T06:00:00Z"}
        ]}
        """


{-| An empty price response — a book nothing has priced yet, which is the honest
default for most of the catalogue.
-}
simulateEmptyBookPricesResponse : String -> Http.Response String
simulateEmptyBookPricesResponse bookId =
    Http.GoodStatus_
        { url = "/api/books/" ++ bookId ++ "/prices"
        , statusCode = 200
        , statusText = "OK"
        , headers = Dict.empty
        }
        """{"prices": []}"""


{-| Create an HTTP response containing a book detail JSON payload with no placement.
Uses encodeBook to create a proper response wrapping a Book value.
-}
simulateBookDetailResponse : String -> Book -> Http.Response String
simulateBookDetailResponse bookId book =
    let
        json =
            Encode.encode 0
                (Encode.object
                    [ ( "book", encodeBook book )
                    , ( "placement", Encode.null )
                    ]
                )
    in
    Http.GoodStatus_
        { url = "/api/books/" ++ bookId
        , statusCode = 200
        , statusText = "OK"
        , headers = Dict.empty
        }
        json


{-| An HTTP response for `GET /api/books/:id` carrying a placement.

The placement object is exactly what `StacksWeb.ProtoJSON.book_placement/1`
emits (`apps/core/lib/stacks_web/proto_json.ex:311-322`): a `Map.take` of
`[:id, :book_id, :personal_rating, :notes]` off the placement, merged with
`bookshelf_name`, `formats`, `visibility` and `bookshelf_visibility`. That
allow-list is the whole contract — nothing else can reach the client on this
endpoint. (`bookshelf_visibility` is the #194 ceiling and has its own fixture,
`simulateBookDetailResponseWithVisibility`, which sets both visibility keys
explicitly; here they stay at the "bookshelf association not loaded" value the
serializer emits, `null`.)

In particular the reading-progress quartet — `reading_status`, `current_page`,
`started_at`, `finished_at` — is NOT emitted here. This fixture used to send it
anyway, which made `Components.PlacementCard` look like it renders a live
progress badge on page load when in production the card always opens at its
"To Read" default with no page count (Issue #328; the contract question is
Issue #314). Those four keys only ever arrive from
`PUT /api/placements/:id/progress` via `ProtoJSON.reading_progress/1`
(`proto_json.ex:688-696`) — fold them in from a progress response, never from
here.

`position` and `placed_at` are likewise outside the allow-list: they belong to
the bookshelf payload's `PlacementDetail`, not to `book_placement/1`.

-}
simulateBookDetailResponseWithPlacement : String -> Book -> Placement -> Http.Response String
simulateBookDetailResponseWithPlacement bookId book placement =
    let
        placementJson =
            Encode.object
                ([ ( "id", Encode.string placement.id )
                 , ( "book_id", Encode.string bookId )
                 , ( "formats", Encode.list Encode.string [] )
                 , ( "visibility"
                   , placement.visibility
                        |> Maybe.map Encode.string
                        |> Maybe.withDefault Encode.null
                   )
                 ]
                    ++ (case placement.bookshelfName of
                            Just name ->
                                [ ( "bookshelf_name", Encode.string name ) ]

                            Nothing ->
                                []
                       )
                    ++ (case placement.personalRating of
                            Just rating ->
                                [ ( "personal_rating", Encode.int rating ) ]

                            Nothing ->
                                []
                       )
                    ++ (case placement.notes of
                            Just notes ->
                                [ ( "notes", Encode.string notes ) ]

                            Nothing ->
                                []
                       )
                )

        json =
            Encode.encode 0
                (Encode.object
                    [ ( "book", encodeBook book )
                    , ( "placement", placementJson )
                    ]
                )
    in
    Http.GoodStatus_
        { url = "/api/books/" ++ bookId
        , statusCode = 200
        , statusText = "OK"
        , headers = Dict.empty
        }
        json


{-| A book-detail response carrying a placement with an explicit visibility and
a denormalised parent-shelf ceiling (`bookshelf_visibility`). Drives the
placement-visibility dropdown and its ceiling-greying.
-}
simulateBookDetailResponseWithVisibility : String -> Book -> String -> String -> Http.Response String
simulateBookDetailResponseWithVisibility bookId book visibility bookshelfVisibility =
    let
        placementJson =
            Encode.object
                [ ( "id", Encode.string "placement-vis-001" )
                , ( "formats", Encode.list Encode.string [] )
                , ( "bookshelf_name", Encode.string "library" )
                , ( "visibility", Encode.string visibility )
                , ( "bookshelf_visibility", Encode.string bookshelfVisibility )
                ]

        json =
            Encode.encode 0
                (Encode.object
                    [ ( "book", encodeBook book )
                    , ( "placement", placementJson )
                    ]
                )
    in
    Http.GoodStatus_
        { url = "/api/books/" ++ bookId
        , statusCode = 200
        , statusText = "OK"
        , headers = Dict.empty
        }
        json


{-| A successful `PUT /api/placements/:id/visibility` response: `{id, visibility}`.
-}
simulatePlacementVisibilityResponse : String -> String -> Http.Response String
simulatePlacementVisibilityResponse placementId visibility =
    Http.GoodStatus_
        { url = "/api/placements/" ++ placementId ++ "/visibility"
        , statusCode = 200
        , statusText = "OK"
        , headers = Dict.empty
        }
        (Encode.encode 0
            (Encode.object
                [ ( "id", Encode.string placementId )
                , ( "visibility", Encode.string visibility )
                ]
            )
        )



-- DECODERS (not exposed from Api, rebuilt here for simulated effects)
-- SIMULATED EFFECT TRANSLATORS


{-| Translate Upload page Cmds into SimulatedEffects.
-}
uploadEffects : Upload.Msg -> Upload.Model -> Maybe String -> SimulatedEffect Upload.Msg
uploadEffects msg model maybeToken =
    case msg of
        Upload.UploadAccepted (Ok _) ->
            SimulatedEffect.Cmd.none

        Upload.StatusReceived (Ok response) ->
            case response.status of
                Pending ->
                    SimulatedEffect.Cmd.none

                Resolved ->
                    let
                        ids =
                            if List.isEmpty response.bookIds then
                                case response.bookId of
                                    Just bid ->
                                        [ bid ]

                                    Nothing ->
                                        []

                            else
                                response.bookIds
                    in
                    case ( ids, maybeToken ) of
                        ( [], _ ) ->
                            SimulatedEffect.Cmd.none

                        ( bookIds, Just token ) ->
                            if response.isDuplicate then
                                case bookIds of
                                    [ singleId ] ->
                                        SimulatedEffect.Http.request
                                            { method = "GET"
                                            , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                                            , url = "/api/books/" ++ singleId
                                            , body = SimulatedEffect.Http.emptyBody
                                            , expect = SimulatedEffect.Http.expectJson Upload.GotDuplicateBook Api.bookDetailResponseDecoder
                                            , timeout = Nothing
                                            , tracker = Nothing
                                            }

                                    _ ->
                                        SimulatedEffect.Cmd.none

                            else
                                SimulatedEffect.Cmd.batch
                                    (List.map
                                        (\bid ->
                                            SimulatedEffect.Http.request
                                                { method = "GET"
                                                , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                                                , url = "/api/books/" ++ bid
                                                , body = SimulatedEffect.Http.emptyBody
                                                , expect = SimulatedEffect.Http.expectJson (Upload.GotIdentifiedBook bid) Api.bookDetailResponseDecoder
                                                , timeout = Nothing
                                                , tracker = Nothing
                                                }
                                        )
                                        bookIds
                                    )

                        _ ->
                            SimulatedEffect.Cmd.none

                Rejected ->
                    SimulatedEffect.Cmd.none

        Upload.SubmitManualIsbn ->
            if Components.ISBNInput.isValidISBN model.manualIsbn then
                case maybeToken of
                    Just token ->
                        SimulatedEffect.Http.request
                            { method = "GET"
                            , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                            , url = "/api/books/isbn/" ++ model.manualIsbn
                            , body = SimulatedEffect.Http.emptyBody
                            , expect = SimulatedEffect.Http.expectJson Upload.IsbnLookupResult Api.bookDetailResponseDecoder
                            , timeout = Nothing
                            , tracker = Nothing
                            }

                    Nothing ->
                        SimulatedEffect.Cmd.none

            else
                SimulatedEffect.Cmd.none

        Upload.ConfirmMergeFormat bookId ->
            case maybeToken of
                Just token ->
                    SimulatedEffect.Http.request
                        { method = "POST"
                        , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                        , url = "/api/books/" ++ bookId ++ "/merge-format"
                        , body = SimulatedEffect.Http.emptyBody
                        , expect = SimulatedEffect.Http.expectJson Upload.MergeFormatCompleted Api.mergeFormatResponseDecoder
                        , timeout = Nothing
                        , tracker = Nothing
                        }

                Nothing ->
                    SimulatedEffect.Cmd.none

        Upload.StreamEvent rawJson ->
            case Decode.decodeString streamEventDecoder rawJson of
                Ok response ->
                    uploadEffects (Upload.StatusReceived (Ok response)) model maybeToken

                Err _ ->
                    SimulatedEffect.Cmd.none

        Upload.RejectIdentification ->
            case ( model.step, model.uploadState, maybeToken ) of
                ( Upload.Verifying book, Types.RemoteData.Success imageId, Just token ) ->
                    SimulatedEffect.Http.request
                        { method = "POST"
                        , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                        , url = "/api/upload/" ++ imageId ++ "/reject-identification"
                        , body =
                            SimulatedEffect.Http.jsonBody
                                (Encode.object
                                    [ ( "rejected_book_ids"
                                      , Encode.list Encode.string (model.rejectedBookIds ++ [ book.id ])
                                      )
                                    ]
                                )
                        , expect = SimulatedEffect.Http.expectWhatever Upload.RejectIdentificationCompleted
                        , timeout = Nothing
                        , tracker = Nothing
                        }

                _ ->
                    SimulatedEffect.Cmd.none

        Upload.GotFile _ ->
            case maybeToken of
                Just token ->
                    SimulatedEffect.Http.request
                        { method = "POST"
                        , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                        , url = "/api/upload"
                        , body = SimulatedEffect.Http.stringBody "multipart/form-data" "simulated-file-upload"
                        , expect = SimulatedEffect.Http.expectJson Upload.UploadAccepted (Decode.field "image_id" Decode.string)
                        , timeout = Nothing
                        , tracker = Nothing
                        }

                Nothing ->
                    SimulatedEffect.Cmd.none

        Upload.ConfirmPlacement ->
            -- Mirrors Upload.update: place the book, and (when the user ticked
            -- "adults only") ALSO fire the raise-only user age-gate PUT.
            case ( model.step, maybeToken ) of
                ( Upload.ChoosingShelf book, Just token ) ->
                    let
                        placementEffect =
                            SimulatedEffect.Http.request
                                { method = "POST"
                                , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                                , url = "/api/bookshelves/" ++ model.selectedShelf ++ "/placements"
                                , body =
                                    SimulatedEffect.Http.jsonBody
                                        (Encode.object [ ( "book_id", Encode.string book.id ) ])
                                , expect = SimulatedEffect.Http.expectStringResponse Upload.PlacementCompleted Api.placeResponseToResult
                                , timeout = Nothing
                                , tracker = Nothing
                                }

                        ageGateEffect =
                            if model.ageGatingEnabled && model.markAdultsOnly then
                                [ SimulatedEffect.Http.request
                                    { method = "PUT"
                                    , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                                    , url = "/api/books/" ++ book.id ++ "/age-gate"
                                    , body =
                                        SimulatedEffect.Http.jsonBody
                                            (Encode.object [ ( "adults_only", Encode.bool True ) ])
                                    , expect = SimulatedEffect.Http.expectWhatever Upload.AgeGateSet
                                    , timeout = Nothing
                                    , tracker = Nothing
                                    }
                                ]

                            else
                                []
                    in
                    SimulatedEffect.Cmd.batch (placementEffect :: ageGateEffect)

                _ ->
                    SimulatedEffect.Cmd.none

        _ ->
            SimulatedEffect.Cmd.none


{-| Translate Bookshelf page Cmds into SimulatedEffects.
-}
libraryEffects : Bookshelf.Msg -> SimulatedEffect Bookshelf.Msg
libraryEffects msg =
    case msg of
        _ ->
            SimulatedEffect.Cmd.none


{-| Translate the owner-mode `Page.Bookshelf.init` Cmd into a SimulatedEffect.

Mirrors `Page.Bookshelf.init`'s own structure: with no token there is no
request at all, and with a token the GET targets `config.apiName` and tags the
response with `requestKey config` (Issue #274). Keyed off the config so the
Library / Antilibrary / Wish List harnesses all share one mirror.

-}
bookshelfInitEffects : Bookshelf.Config -> Maybe String -> SimulatedEffect Bookshelf.Msg
bookshelfInitEffects config maybeToken =
    case maybeToken of
        Just token ->
            SimulatedEffect.Http.request
                { method = "GET"
                , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                , url = "/api/bookshelves/" ++ config.apiName
                , body = SimulatedEffect.Http.emptyBody
                , expect =
                    SimulatedEffect.Http.expectJson
                        (Bookshelf.ShelvesLoaded (Bookshelf.requestKey config))
                        bookshelfResponseDecoder
                , timeout = Nothing
                , tracker = Nothing
                }

        Nothing ->
            SimulatedEffect.Cmd.none


{-| Translate the read-only profile-shelf init Cmd into a SimulatedEffect.

Mirrors `Api.getProfileShelf`: an optional-auth GET to the profile endpoint
(`/api/u/:handle/bookshelves/:name`), decoding into `Bookshelf.ShelvesLoaded`.

-}
profileShelfInitEffects : Maybe String -> String -> String -> SimulatedEffect Bookshelf.Msg
profileShelfInitEffects maybeToken handle bookshelfName =
    let
        headers =
            case maybeToken of
                Just token ->
                    [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]

                Nothing ->
                    []
    in
    SimulatedEffect.Http.request
        { method = "GET"
        , headers = headers
        , url = "/api/u/" ++ handle ++ "/bookshelves/" ++ bookshelfName
        , body = SimulatedEffect.Http.emptyBody
        , expect =
            -- Mirror Api.getProfileShelf: the read-only profile payload carries
            -- no visibility, so map it into the shared ShelvesLoaded response
            -- shape with the "owner" default (RSS is never rendered here).
            SimulatedEffect.Http.expectJson
                (Bookshelf.ShelvesLoaded
                    (Bookshelf.requestKey (Bookshelf.profileConfig handle bookshelfName))
                    << Result.map (\shelves -> { shelves = shelves, visibility = "owner" })
                )
                shelvesResponseDecoder
        , timeout = Nothing
        , tracker = Nothing
        }


{-| Translate Search page Cmds into SimulatedEffects.
-}
searchEffects : Search.Msg -> Search.Model -> Maybe String -> SimulatedEffect Search.Msg
searchEffects msg model maybeToken =
    case msg of
        Search.QueryChanged _ ->
            let
                newCount =
                    model.debounceCount + 1
            in
            SimulatedEffect.Task.perform (\_ -> Search.DebounceExpired newCount) (SimulatedEffect.Process.sleep 300)

        Search.DebounceExpired count ->
            if count == model.debounceCount && not (String.isEmpty model.query) then
                let
                    booksEffect =
                        -- The scope follows the current toggle state (#284): deep
                        -- appends `&scope=deep`, default emits no param.
                        searchBooksEffect model.query model.deepSearch maybeToken

                    readersEffect =
                        SimulatedEffect.Http.request
                            { method = "GET"
                            , headers = authHeaderList maybeToken
                            , url = "/api/search/users?q=" ++ model.query
                            , body = SimulatedEffect.Http.emptyBody
                            , expect =
                                SimulatedEffect.Http.expectJson Search.ReadersCompleted
                                    (Decode.field "users" (Decode.list Api.publicProfileSummaryDecoder))
                            , timeout = Nothing
                            , tracker = Nothing
                            }
                in
                SimulatedEffect.Cmd.batch [ booksEffect, readersEffect ]

            else
                SimulatedEffect.Cmd.none

        Search.DeepSearchToggled deep ->
            -- Mirror `Page.Search.update`: flipping the toggle with a non-empty
            -- query re-fires ONLY the book search, under the new scope. `model` is
            -- the pre-update model, whose `query` the toggle does not change; the
            -- new scope comes from the Msg's `deep` value, not `model.deepSearch`.
            if String.isEmpty model.query then
                SimulatedEffect.Cmd.none

            else
                searchBooksEffect model.query deep maybeToken

        _ ->
            SimulatedEffect.Cmd.none


{-| The book-search SimulatedEffect, shared by the debounce and deep-toggle paths
so the mirror URL (`/api/search?q=…` + optional `&scope=deep`) and the reused
`Api.searchResponseDecoder` can never drift from the real wire (#284/#292). Fires
nothing without a token (book search is authenticated-only).
-}
searchBooksEffect : String -> Bool -> Maybe String -> SimulatedEffect Search.Msg
searchBooksEffect query deep maybeToken =
    case maybeToken of
        Just token ->
            SimulatedEffect.Http.request
                { method = "GET"
                , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                , url =
                    "/api/search?q="
                        ++ query
                        ++ (if deep then
                                "&scope=deep"

                            else
                                ""
                           )
                , body = SimulatedEffect.Http.emptyBody
                , expect = SimulatedEffect.Http.expectJson Search.SearchCompleted Api.searchResponseDecoder
                , timeout = Nothing
                , tracker = Nothing
                }

        Nothing ->
            SimulatedEffect.Cmd.none


authHeaderList : Maybe String -> List SimulatedEffect.Http.Header
authHeaderList maybeToken =
    case maybeToken of
        Just token ->
            [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]

        Nothing ->
            []


{-| Translate BookDetail page Cmds into SimulatedEffects.
-}
bookDetailEffects : BookDetail.Msg -> BookDetail.Model -> Maybe String -> SimulatedEffect BookDetail.Msg
bookDetailEffects msg model maybeToken =
    case msg of
        BookDetail.ConfirmMove ->
            case ( model.placement, maybeToken ) of
                ( Just placement, Just token ) ->
                    SimulatedEffect.Http.request
                        { method = "PUT"
                        , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                        , url = "/api/placements/" ++ placement.id ++ "/move"
                        , body =
                            SimulatedEffect.Http.jsonBody
                                (Encode.object [ ( "bookshelf", Encode.string model.selectedBookshelf ) ])
                        , expect =
                            -- Mirrors Api.expectMove: the 422 reading_pile_full
                            -- body must reach MoveCompleted as its own error.
                            SimulatedEffect.Http.expectStringResponse
                                BookDetail.MoveCompleted
                                Api.moveResponseToResult
                        , timeout = Nothing
                        , tracker = Nothing
                        }

                _ ->
                    SimulatedEffect.Cmd.none

        BookDetail.ConfirmRemove ->
            case ( model.placement, maybeToken ) of
                ( Just placement, Just token ) ->
                    SimulatedEffect.Http.request
                        { method = "DELETE"
                        , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                        , url = "/api/placements/" ++ placement.id
                        , body = SimulatedEffect.Http.emptyBody
                        , expect = SimulatedEffect.Http.expectWhatever BookDetail.RemoveCompleted
                        , timeout = Nothing
                        , tracker = Nothing
                        }

                _ ->
                    SimulatedEffect.Cmd.none

        BookDetail.ConfirmPlace ->
            case ( model.book, maybeToken ) of
                ( Types.RemoteData.Success book, Just token ) ->
                    SimulatedEffect.Http.request
                        { method = "POST"
                        , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                        , url = "/api/bookshelves/" ++ model.selectedBookshelf ++ "/placements"
                        , body =
                            SimulatedEffect.Http.jsonBody
                                (Encode.object [ ( "book_id", Encode.string book.id ) ])
                        , expect = SimulatedEffect.Http.expectStringResponse (BookDetail.PlaceCompleted model.selectedBookshelf) Api.placeResponseToResult
                        , timeout = Nothing
                        , tracker = Nothing
                        }

                _ ->
                    SimulatedEffect.Cmd.none

        BookDetail.ProgressCardMsg _ ->
            -- `model` is the post-update model. A Loading progressSaveState means
            -- the card emitted ProgressUpdateRequested and a PUT should be issued.
            case ( model.placement, maybeToken, model.progressSaveState ) of
                ( Just placement, Just token, Types.RemoteData.Loading ) ->
                    SimulatedEffect.Http.request
                        { method = "PUT"
                        , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                        , url = "/api/placements/" ++ placement.id ++ "/progress"
                        , body = SimulatedEffect.Http.emptyBody
                        , expect =
                            SimulatedEffect.Http.expectStringResponse
                                BookDetail.ProgressSaved
                                Api.progressResponseToResult
                        , timeout = Nothing
                        , tracker = Nothing
                        }

                _ ->
                    SimulatedEffect.Cmd.none

        BookDetail.RecordReadRequested ->
            case ( model.placement, maybeToken ) of
                ( Just placement, Just token ) ->
                    SimulatedEffect.Http.request
                        { method = "PUT"
                        , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                        , url = "/api/placements/" ++ placement.id ++ "/move"
                        , body =
                            SimulatedEffect.Http.jsonBody
                                (Encode.object [ ( "bookshelf", Encode.string "library" ) ])
                        , expect =
                            SimulatedEffect.Http.expectStringResponse
                                BookDetail.MoveCompleted
                                Api.moveResponseToResult
                        , timeout = Nothing
                        , tracker = Nothing
                        }

                _ ->
                    SimulatedEffect.Cmd.none

        BookDetail.PlacementVisibilitySelected _ ->
            -- `model` here is the post-update model (bookDetailProgram passes
            -- newModel). A Loading visibilityState means the client-side ceiling
            -- guard passed and a PUT should be issued.
            case ( model.placement, maybeToken, model.visibilityState ) of
                ( Just placement, Just token, Types.RemoteData.Loading ) ->
                    SimulatedEffect.Http.request
                        { method = "PUT"
                        , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                        , url = "/api/placements/" ++ placement.id ++ "/visibility"
                        , body =
                            SimulatedEffect.Http.jsonBody
                                (Encode.object
                                    [ ( "visibility"
                                      , Encode.string (Types.Visibility.toString model.placementVisibility)
                                      )
                                    ]
                                )
                        , expect = SimulatedEffect.Http.expectJson BookDetail.PlacementVisibilityUpdated (Decode.field "visibility" Decode.string)
                        , timeout = Nothing
                        , tracker = Nothing
                        }

                _ ->
                    SimulatedEffect.Cmd.none

        _ ->
            SimulatedEffect.Cmd.none


{-| Translate BookDetail init Cmds into SimulatedEffects.
-}
bookDetailInitEffects : String -> Maybe String -> SimulatedEffect BookDetail.Msg
bookDetailInitEffects bookId maybeToken =
    case maybeToken of
        Just token ->
            SimulatedEffect.Cmd.batch
                [ SimulatedEffect.Http.request
                    { method = "GET"
                    , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                    , url = "/api/books/" ++ bookId
                    , body = SimulatedEffect.Http.emptyBody
                    , expect = SimulatedEffect.Http.expectJson BookDetail.BookLoaded Api.bookDetailResponseDecoder
                    , timeout = Nothing
                    , tracker = Nothing
                    }
                , SimulatedEffect.Http.request
                    { method = "GET"
                    , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                    , url = "/api/books/" ++ bookId ++ "/availability"
                    , body = SimulatedEffect.Http.emptyBody
                    , expect = SimulatedEffect.Http.expectJson BookDetail.AvailabilityLoaded BookDetail.availabilityDecoder
                    , timeout = Nothing
                    , tracker = Nothing
                    }
                , SimulatedEffect.Http.request
                    { method = "GET"
                    , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                    , url = "/api/books/" ++ bookId ++ "/prices"
                    , body = SimulatedEffect.Http.emptyBody
                    , expect = SimulatedEffect.Http.expectJson BookDetail.PricesLoaded BookDetail.pricesDecoder
                    , timeout = Nothing
                    , tracker = Nothing
                    }
                ]

        Nothing ->
            SimulatedEffect.Cmd.none



-- PROGRAM TEST HARNESSES


{-| Create a ProgramTest harness for the Upload page. `ageGatingEnabled`
seeds the server-config flag (ADR-020) so tests can drive both the
flag-on (age UI present) and flag-off (age UI hidden) states.
-}
uploadProgram : Bool -> Maybe String -> ProgramDefinition () Upload.Model Upload.Msg (SimulatedEffect Upload.Msg)
uploadProgram ageGatingEnabled maybeToken =
    let
        baseModel =
            Upload.init

        initModel =
            { baseModel | ageGatingEnabled = ageGatingEnabled }
    in
    ProgramTest.createElement
        { init = \() -> ( initModel, SimulatedEffect.Cmd.none )
        , update =
            \msg model ->
                let
                    ( newModel, _, _ ) =
                        Upload.update msg model maybeToken
                in
                ( newModel, uploadEffects msg model maybeToken )
        , view = \model -> Upload.view model maybeToken
        }
        |> ProgramTest.withSimulatedEffects identity


{-| Create a ProgramTest harness for the Bookshelf page in its Library config.
-}
libraryProgram : Maybe String -> ProgramDefinition () Bookshelf.Model Bookshelf.Msg (SimulatedEffect Bookshelf.Msg)
libraryProgram =
    bookshelfProgram Bookshelf.libraryConfig


{-| Create a ProgramTest harness for `Page.Bookshelf` under any owner-mode
config. Library, Antilibrary and Wish List all render through this one module,
so the only thing that varies between them is the `Config` — pass
`Bookshelf.antiLibraryConfig` / `Bookshelf.wishListConfig` to drive those
surfaces (Issue #112 punch #5/#6).
-}
bookshelfProgram : Bookshelf.Config -> Maybe String -> ProgramDefinition () Bookshelf.Model Bookshelf.Msg (SimulatedEffect Bookshelf.Msg)
bookshelfProgram config maybeToken =
    ProgramTest.createElement
        { init =
            \() ->
                let
                    ( model, _ ) =
                        Bookshelf.init config maybeToken "test-user-id"
                in
                ( model, bookshelfInitEffects config maybeToken )
        , update =
            \msg model ->
                let
                    ( newModel, _, _ ) =
                        Bookshelf.update msg model
                in
                ( newModel, libraryEffects msg )
        , view = Bookshelf.view
        }
        |> ProgramTest.withSimulatedEffects identity


{-| Harness model for the Reading Pile program test.

`Page.Bookshelf.ReadingPile.update` returns a third `OutMsg` element that the
page itself cannot observe — `Main` consumes it. Recording the most recent
`OutMsg` alongside the page model lets a program test assert the navigation
intent a book click produces (Issue #112 punch #7) rather than only the model
change, without reaching past the page into `Main`.

-}
type alias ReadingPileTestModel =
    { page : ReadingPile.Model
    , lastOut : ReadingPile.OutMsg
    }


{-| Create a ProgramTest harness for the Reading Pile page.
-}
readingPileProgram : Maybe String -> ProgramDefinition () ReadingPileTestModel ReadingPile.Msg (SimulatedEffect ReadingPile.Msg)
readingPileProgram maybeToken =
    ProgramTest.createElement
        { init =
            \() ->
                let
                    ( model, _ ) =
                        ReadingPile.init maybeToken
                in
                ( { page = model, lastOut = ReadingPile.NoOut }
                , readingPileInitEffects maybeToken
                )
        , update =
            \msg model ->
                let
                    ( newPage, _, out ) =
                        ReadingPile.update msg model.page
                in
                ( { page = newPage, lastOut = out }, readingPileEffects msg newPage maybeToken )
        , view = \model -> ReadingPile.view model.page
        }
        |> ProgramTest.withSimulatedEffects identity


{-| Translate Reading Pile page Cmds into SimulatedEffects.

Mirrors `ReadingPile.update`'s progress + record-read paths: a `CardMsg` that
left `saveState = Loading` issues the `PUT /progress`; `RecordReadRequested`
issues the `PUT /move` to the library. The request bodies are placeholders —
tests supply the response, and the expect mapping (reused from `Api`) is what
routes it back into the page.

-}
readingPileEffects : ReadingPile.Msg -> ReadingPile.Model -> Maybe String -> SimulatedEffect ReadingPile.Msg
readingPileEffects msg newPage maybeToken =
    case ( msg, maybeToken ) of
        ( ReadingPile.CardMsg placementId _, Just token ) ->
            case newPage.saveState of
                Types.RemoteData.Loading ->
                    SimulatedEffect.Http.request
                        { method = "PUT"
                        , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                        , url = "/api/placements/" ++ placementId ++ "/progress"
                        , body = SimulatedEffect.Http.emptyBody
                        , expect =
                            SimulatedEffect.Http.expectStringResponse
                                (ReadingPile.ProgressSaved placementId)
                                Api.progressResponseToResult
                        , timeout = Nothing
                        , tracker = Nothing
                        }

                _ ->
                    SimulatedEffect.Cmd.none

        ( ReadingPile.RecordReadRequested placementId, Just token ) ->
            SimulatedEffect.Http.request
                { method = "PUT"
                , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                , url = "/api/placements/" ++ placementId ++ "/move"
                , body =
                    SimulatedEffect.Http.jsonBody
                        (Encode.object [ ( "bookshelf", Encode.string "library" ) ])
                , expect =
                    SimulatedEffect.Http.expectStringResponse
                        (ReadingPile.RecordReadDone placementId)
                        Api.moveResponseToResult
                , timeout = Nothing
                , tracker = Nothing
                }

        _ ->
            SimulatedEffect.Cmd.none


{-| Translate the Reading Pile init Cmd into a SimulatedEffect.

Mirrors `ReadingPile.init`: `GET /api/bookshelves/reading_pile`, dropping the
response's `visibility` (the pile has no RSS affordance) so only the shelves
reach `BooksLoaded`.

-}
readingPileInitEffects : Maybe String -> SimulatedEffect ReadingPile.Msg
readingPileInitEffects maybeToken =
    case maybeToken of
        Just token ->
            SimulatedEffect.Http.request
                { method = "GET"
                , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                , url = "/api/bookshelves/reading_pile"
                , body = SimulatedEffect.Http.emptyBody
                , expect =
                    SimulatedEffect.Http.expectJson
                        (ReadingPile.BooksLoaded << Result.map .shelves)
                        bookshelfResponseDecoder
                , timeout = Nothing
                , tracker = Nothing
                }

        Nothing ->
            SimulatedEffect.Cmd.none


{-| Create a ProgramTest harness for the read-only profile-shelf browse view
(`Page.Bookshelf` in its `profileConfig` — US-10.5.3 / Issue #215).
-}
profileShelfProgram : Maybe String -> String -> String -> ProgramDefinition () Bookshelf.Model Bookshelf.Msg (SimulatedEffect Bookshelf.Msg)
profileShelfProgram maybeToken handle bookshelfName =
    let
        config =
            Bookshelf.profileConfig handle bookshelfName
    in
    ProgramTest.createElement
        { init =
            \() ->
                let
                    ( model, _ ) =
                        Bookshelf.init config maybeToken "viewer-user-id"
                in
                ( model, profileShelfInitEffects maybeToken handle bookshelfName )
        , update =
            \msg model ->
                let
                    ( newModel, _, _ ) =
                        Bookshelf.update msg model
                in
                ( newModel, libraryEffects msg )
        , view = Bookshelf.view
        }
        |> ProgramTest.withSimulatedEffects identity


{-| Create a ProgramTest harness for the Search page.
-}
searchProgram : Maybe String -> ProgramDefinition () Search.Model Search.Msg (SimulatedEffect Search.Msg)
searchProgram maybeToken =
    ProgramTest.createElement
        { init = \() -> ( Search.init, SimulatedEffect.Cmd.none )
        , update =
            \msg model ->
                let
                    ( newModel, _, _ ) =
                        Search.update msg model maybeToken
                in
                ( newModel, searchEffects msg model maybeToken )
        , view = Search.view
        }
        |> ProgramTest.withSimulatedEffects identity


{-| Mirror `Api.expectRegister`: decode the 422 `{"errors": ...}` body so program
tests exercise the same field-error surfacing as production rather than losing
the body the way `expectJson` would.
-}
registerResponseResult : Http.Response String -> Result RegisterError ()
registerResponseResult response =
    case response of
        Http.BadUrl_ url ->
            Err (RegisterRequestFailed (Http.BadUrl url))

        Http.Timeout_ ->
            Err (RegisterRequestFailed Http.Timeout)

        Http.NetworkError_ ->
            Err (RegisterRequestFailed Http.NetworkError)

        Http.BadStatus_ metadata bodyText ->
            if metadata.statusCode == 422 then
                case Decode.decodeString (Decode.field "errors" (Decode.keyValuePairs (Decode.list Decode.string))) bodyText of
                    Ok errors ->
                        Err (RegisterValidationFailed errors)

                    Err _ ->
                        Err (RegisterRequestFailed (Http.BadStatus metadata.statusCode))

            else
                Err (RegisterRequestFailed (Http.BadStatus metadata.statusCode))

        Http.GoodStatus_ _ bodyText ->
            case Decode.decodeString Api.registrationResponseDecoder bodyText of
                Ok value ->
                    Ok value

                Err err ->
                    Err (RegisterRequestFailed (Http.BadBody (Decode.errorToString err)))


{-| Translate Login page Cmds into SimulatedEffects.
-}
loginEffects : Login.Msg -> Login.Model -> SimulatedEffect Login.Msg
loginEffects msg model =
    case msg of
        Login.FormSubmitted ->
            case model.mode of
                Login.LoginMode ->
                    SimulatedEffect.Http.request
                        { method = "POST"
                        , headers = []
                        , url = "/api/auth/login"
                        , body =
                            SimulatedEffect.Http.jsonBody
                                (Encode.object
                                    [ ( "email", Encode.string model.email )
                                    , ( "password", Encode.string model.password )
                                    ]
                                )
                        , expect = SimulatedEffect.Http.expectJson Login.GotAuthResponse Api.authResponseDecoder
                        , timeout = Nothing
                        , tracker = Nothing
                        }

                Login.RegisterMode ->
                    SimulatedEffect.Http.request
                        { method = "POST"
                        , headers = []
                        , url = "/api/auth/register"
                        , body =
                            SimulatedEffect.Http.jsonBody
                                (Encode.object
                                    [ ( "email", Encode.string model.email )
                                    , ( "password", Encode.string model.password )
                                    , ( "display_name", Encode.string model.displayName )
                                    ]
                                )
                        , expect = SimulatedEffect.Http.expectStringResponse Login.GotRegisterResponse registerResponseResult
                        , timeout = Nothing
                        , tracker = Nothing
                        }

                Login.RegistrationPending _ ->
                    SimulatedEffect.Cmd.none

                Login.ForgotPasswordMode ->
                    SimulatedEffect.Cmd.none

        _ ->
            SimulatedEffect.Cmd.none


{-| Create a ProgramTest harness for the Login page.
-}
loginProgram : ProgramDefinition () Login.Model Login.Msg (SimulatedEffect Login.Msg)
loginProgram =
    ProgramTest.createElement
        { init = \() -> ( Login.init, SimulatedEffect.Cmd.none )
        , update =
            \msg model ->
                let
                    ( newModel, _, _ ) =
                        Login.update msg model
                in
                ( newModel, loginEffects msg model )
        , view = Login.view
        }
        |> ProgramTest.withSimulatedEffects identity


{-| Create a ProgramTest harness for the BookDetail page. Age-gating is
enabled (ADR-020) so the 403-driven age-gate block renders under test; the
production default is off, which hides it (covered by the flag guard).
-}
bookDetailProgram : String -> Maybe String -> ProgramDefinition () BookDetail.Model BookDetail.Msg (SimulatedEffect BookDetail.Msg)
bookDetailProgram bookId maybeToken =
    ProgramTest.createElement
        { init =
            \() ->
                let
                    ( model, _ ) =
                        BookDetail.init bookId maybeToken Nothing
                in
                ( model, bookDetailInitEffects bookId maybeToken )
        , update =
            \msg model ->
                let
                    ( newModel, _, _ ) =
                        BookDetail.update msg model maybeToken
                in
                ( newModel, bookDetailEffects msg newModel maybeToken )
        , view = BookDetail.view
        }
        |> ProgramTest.withSimulatedEffects identity


{-| Harness model that records the most recent BookDetail `OutMsg` alongside the
page model. `Page.BookDetail.update` returns a third `OutMsg` element that the
page itself cannot observe — `Main` consumes it. Recording it (as
`ReadingPileTestModel` does for the Reading Pile) lets a program test assert the
navigation intent a confirmed remove produces (`NavigateTo previousRoute`)
rather than only the rendered model change.
-}
type alias BookDetailTestModel =
    { page : BookDetail.Model
    , lastOut : BookDetail.OutMsg
    }


{-| A BookDetail harness identical to `bookDetailProgram` except that it records
the page's `OutMsg`. `bookDetailProgram` discards it; this one keeps the latest
one so a test can observe `NavigateTo previousRoute` from a confirmed remove.
Takes the previous route so the navigation target is a concrete, asserted value.
-}
bookDetailProgramWithOut : String -> Maybe String -> Maybe Route -> ProgramDefinition () BookDetailTestModel BookDetail.Msg (SimulatedEffect BookDetail.Msg)
bookDetailProgramWithOut bookId maybeToken maybePreviousRoute =
    ProgramTest.createElement
        { init =
            \() ->
                let
                    ( model, _ ) =
                        BookDetail.init bookId maybeToken maybePreviousRoute
                in
                ( { page = model, lastOut = BookDetail.NoOut }
                , bookDetailInitEffects bookId maybeToken
                )
        , update =
            \msg model ->
                let
                    ( newModel, _, out ) =
                        BookDetail.update msg model.page maybeToken
                in
                ( { page = newModel, lastOut = out }, bookDetailEffects msg newModel maybeToken )
        , view = \model -> BookDetail.view model.page
        }
        |> ProgramTest.withSimulatedEffects identity


{-| Like `bookDetailProgramWithOut`, but renders `BookDetail.overlayView` (the
modal chrome: backdrop, close button, focus sentinel) instead of the routed
`view`. Records the page's `OutMsg` so a test can assert that dismissing the
overlay via the X button or a backdrop click emits `RequestCloseOverlay`.
-}
bookDetailOverlayProgramWithOut : String -> Maybe String -> Maybe Route -> ProgramDefinition () BookDetailTestModel BookDetail.Msg (SimulatedEffect BookDetail.Msg)
bookDetailOverlayProgramWithOut bookId maybeToken maybePreviousRoute =
    ProgramTest.createElement
        { init =
            \() ->
                let
                    ( model, _ ) =
                        BookDetail.init bookId maybeToken maybePreviousRoute
                in
                ( { page = model, lastOut = BookDetail.NoOut }
                , bookDetailInitEffects bookId maybeToken
                )
        , update =
            \msg model ->
                let
                    ( newModel, _, out ) =
                        BookDetail.update msg model.page maybeToken
                in
                ( { page = newModel, lastOut = out }, bookDetailEffects msg newModel maybeToken )
        , view = \model -> BookDetail.overlayView model.page
        }
        |> ProgramTest.withSimulatedEffects identity
