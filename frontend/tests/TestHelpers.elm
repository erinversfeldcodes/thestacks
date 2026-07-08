module TestHelpers exposing
    ( bookDetailProgram
    , libraryProgram
    , loginProgram
    , searchProgram
    , simulateAuthErrorResponse
    , simulateAuthResponse
    , simulateBookDetailResponse
    , simulateBookDetailResponseWithPlacement
    , simulateBookResponse
    , simulateBookshelfErrorResponse
    , simulateBookshelfResponse
    , simulateMergeFormatResponse
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

import Api exposing (AuthResponse, BookDetailResponse, PollStatus(..), RegisterError(..), streamEventDecoder)
import Components.ISBNInput
import Dict
import Http
import Json.Decode as Decode
import Json.Encode as Encode
import Page.BookDetail as BookDetail
import Page.Bookshelf as Bookshelf
import Page.Login as Login
import Page.Search as Search
import Page.Upload as Upload
import ProgramTest exposing (ProgramDefinition, SimulatedEffect)
import SimulatedEffect.Cmd
import SimulatedEffect.Http
import SimulatedEffect.Process
import SimulatedEffect.Task
import Types.Book exposing (Book, Edition, VisibilityTier(..), bookDecoder)
import Types.Placement exposing (Placement, placementDecoder)
import Types.RemoteData
import Types.Shelf exposing (shelvesResponseDecoder)



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


{-| Create an HTTP response containing a book detail JSON payload with a placement.
-}
simulateBookDetailResponseWithPlacement : String -> Book -> Placement -> Http.Response String
simulateBookDetailResponseWithPlacement bookId book placement =
    let
        placementJson =
            Encode.object
                ([ ( "id", Encode.string placement.id )
                 , ( "formats", Encode.list Encode.string [] )
                 ]
                    ++ encodeMaybe "position" Encode.int placement.position
                    ++ encodeMaybe "placed_at" Encode.string placement.placedAt
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
                            if response.isDuplicate == Just True then
                                case bookIds of
                                    [ singleId ] ->
                                        SimulatedEffect.Http.request
                                            { method = "GET"
                                            , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                                            , url = "/api/books/" ++ singleId
                                            , body = SimulatedEffect.Http.emptyBody
                                            , expect = SimulatedEffect.Http.expectJson Upload.GotDuplicateBook decodeBookDetailResponse
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
                                                , expect = SimulatedEffect.Http.expectJson (Upload.GotIdentifiedBook bid) decodeBookDetailResponse
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
                            , expect = SimulatedEffect.Http.expectJson Upload.IsbnLookupResult decodeBookDetailResponse
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
                        , expect = SimulatedEffect.Http.expectJson Upload.MergeFormatCompleted decodeMergeFormatResponse
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

        _ ->
            SimulatedEffect.Cmd.none


{-| Translate Bookshelf page Cmds into SimulatedEffects.
-}
libraryEffects : Bookshelf.Msg -> Bookshelf.Model -> Maybe String -> SimulatedEffect Bookshelf.Msg
libraryEffects msg model maybeToken =
    case msg of
        Bookshelf.AddShelf ->
            case maybeToken of
                Just token ->
                    SimulatedEffect.Http.request
                        { method = "POST"
                        , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                        , url = "/api/bookshelves/" ++ model.config.apiName ++ "/shelves"
                        , body = SimulatedEffect.Http.emptyBody
                        , expect =
                            SimulatedEffect.Http.expectJson Bookshelf.ShelfAdded
                                Types.Shelf.shelfDecoder
                        , timeout = Nothing
                        , tracker = Nothing
                        }

                Nothing ->
                    SimulatedEffect.Cmd.none

        _ ->
            SimulatedEffect.Cmd.none


{-| Translate Bookshelf init Cmds into SimulatedEffects.
-}
libraryInitEffects : Maybe String -> SimulatedEffect Bookshelf.Msg
libraryInitEffects maybeToken =
    case maybeToken of
        Just token ->
            SimulatedEffect.Http.request
                { method = "GET"
                , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                , url = "/api/bookshelves/library"
                , body = SimulatedEffect.Http.emptyBody
                , expect =
                    SimulatedEffect.Http.expectJson Bookshelf.ShelvesLoaded
                        shelvesResponseDecoder
                , timeout = Nothing
                , tracker = Nothing
                }

        Nothing ->
            SimulatedEffect.Cmd.none


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
                case maybeToken of
                    Just token ->
                        SimulatedEffect.Http.request
                            { method = "GET"
                            , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                            , url = "/api/books/search?q=" ++ model.query
                            , body = SimulatedEffect.Http.emptyBody
                            , expect = SimulatedEffect.Http.expectJson Search.SearchCompleted (Decode.list bookDecoder)
                            , timeout = Nothing
                            , tracker = Nothing
                            }

                    Nothing ->
                        SimulatedEffect.Cmd.none

            else
                SimulatedEffect.Cmd.none

        _ ->
            SimulatedEffect.Cmd.none


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
                        , expect = SimulatedEffect.Http.expectWhatever BookDetail.MoveCompleted
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
                        , expect = SimulatedEffect.Http.expectJson (BookDetail.PlaceCompleted model.selectedBookshelf) (Decode.field "placement" placementDecoder)
                        , timeout = Nothing
                        , tracker = Nothing
                        }

                _ ->
                    SimulatedEffect.Cmd.none

        _ ->
            SimulatedEffect.Cmd.none


{-| Decode a BookDetailResponse. Mirrors Api.bookDetailResponseDecoder which is not exposed.
-}
decodeBookDetailResponse : Decode.Decoder BookDetailResponse
decodeBookDetailResponse =
    Decode.map2 BookDetailResponse
        (Decode.field "book" bookDecoder)
        (Decode.maybe (Decode.field "placement" placementDecoder))


{-| Decode a MergeFormatResponse. Mirrors Api.mergeFormatResponseDecoder which is not exposed.
-}
decodeMergeFormatResponse : Decode.Decoder Api.MergeFormatResponse
decodeMergeFormatResponse =
    Decode.map (\ed -> { edition = ed })
        (Decode.field "edition"
            (Decode.map8
                (\id isbn isPrimary formatLabel coverImageUrl pageCount publisher publicationYear ->
                    { id = id
                    , isbn = isbn
                    , isPrimary = isPrimary
                    , formatLabel = formatLabel
                    , coverImageUrl = coverImageUrl
                    , pageCount = pageCount
                    , publisher = publisher
                    , publicationYear = publicationYear
                    }
                )
                (Decode.field "id" Decode.string)
                (Decode.field "isbn" Decode.string)
                (Decode.field "is_primary" Decode.bool)
                (Decode.maybe (Decode.field "format_label" Decode.string))
                (Decode.maybe (Decode.field "cover_image_url" Decode.string))
                (Decode.maybe (Decode.field "page_count" Decode.int))
                (Decode.maybe (Decode.field "publisher" Decode.string))
                (Decode.maybe (Decode.field "publication_year" Decode.int))
            )
        )


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
                    , expect = SimulatedEffect.Http.expectJson BookDetail.BookLoaded decodeBookDetailResponse
                    , timeout = Nothing
                    , tracker = Nothing
                    }
                , SimulatedEffect.Http.request
                    { method = "GET"
                    , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                    , url = "/api/books/" ++ bookId ++ "/availability"
                    , body = SimulatedEffect.Http.emptyBody
                    , expect = SimulatedEffect.Http.expectJson BookDetail.AvailabilityLoaded decodeAvailabilityResponse
                    , timeout = Nothing
                    , tracker = Nothing
                    }
                ]

        Nothing ->
            SimulatedEffect.Cmd.none


{-| Decode an availability response. Mirrors BookDetail.availabilityDecoder.
-}
decodeAvailabilityResponse : Decode.Decoder (List BookDetail.AvailabilityItem)
decodeAvailabilityResponse =
    Decode.field "availability"
        (Decode.list
            (Decode.map5 BookDetail.AvailabilityItem
                (Decode.field "partner_name" Decode.string)
                (Decode.field "price_cents" Decode.int)
                (Decode.field "condition" Decode.string)
                (Decode.field "quantity" Decode.int)
                (Decode.field "isbn" Decode.string)
            )
        )



-- PROGRAM TEST HARNESSES


{-| Create a ProgramTest harness for the Upload page.
-}
uploadProgram : Maybe String -> ProgramDefinition () Upload.Model Upload.Msg (SimulatedEffect Upload.Msg)
uploadProgram maybeToken =
    ProgramTest.createElement
        { init = \() -> ( Upload.init, SimulatedEffect.Cmd.none )
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


{-| Create a ProgramTest harness for the Bookshelf page.
-}
libraryProgram : Maybe String -> ProgramDefinition () Bookshelf.Model Bookshelf.Msg (SimulatedEffect Bookshelf.Msg)
libraryProgram maybeToken =
    ProgramTest.createElement
        { init =
            \() ->
                let
                    ( model, _ ) =
                        Bookshelf.init Bookshelf.libraryConfig maybeToken "test-user-id"
                in
                ( model, libraryInitEffects maybeToken )
        , update =
            \msg model ->
                let
                    ( newModel, _, _ ) =
                        Bookshelf.update msg model
                in
                ( newModel, libraryEffects msg model maybeToken )
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
                    ( newModel, _ ) =
                        Search.update msg model maybeToken
                in
                ( newModel, searchEffects msg model maybeToken )
        , view = Search.view
        }
        |> ProgramTest.withSimulatedEffects identity


{-| Decode an AuthResponse. Mirrors Api.authResponseDecoder which is not exposed.
-}
decodeAuthResponse : Decode.Decoder AuthResponse
decodeAuthResponse =
    Decode.map5 AuthResponse
        (Decode.field "token" Decode.string)
        (Decode.at [ "user", "id" ] Decode.string)
        (Decode.at [ "user", "email" ] Decode.string)
        (Decode.at [ "user", "display_name" ] Decode.string)
        (Decode.oneOf
            [ Decode.at [ "user", "role" ] Decode.string
            , Decode.succeed "user"
            ]
        )


{-| Decode a registration response. Mirrors Api.registrationResponseDecoder,
which only checks for the `"message"` key and does NOT attempt to read a token.
-}
decodeRegistrationResponse : Decode.Decoder ()
decodeRegistrationResponse =
    Decode.map (\_ -> ()) (Decode.field "message" Decode.string)


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
            case Decode.decodeString decodeRegistrationResponse bodyText of
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
                        , expect = SimulatedEffect.Http.expectJson Login.GotAuthResponse decodeAuthResponse
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


{-| Create a ProgramTest harness for the BookDetail page.
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
