module TestHelpers exposing
    ( BookDetailTestModel
    , ReadingPileTestModel
    , authedRequestFromSpec
    , bookDetailOverlayProgramWithOut
    , bookDetailProgram
    , bookDetailProgramWithOut
    , bookshelfProgram
    , bookshelfUndoProgram
    , libraryProgram
    , loginProgram
    , loginProgramFrom
    , namedPlacement
    , placementWithPages
    , profileShelfProgram
    , readingPileProgram
    , searchProgram
    , simulateAuthErrorResponse
    , simulateAuthResponse
    , simulateBookDetailResponse
    , simulateBookDetailResponseWithFormats
    , simulateBookDetailResponseWithPlacement
    , simulateBookDetailResponseWithPlacements
    , simulateBookDetailResponseWithVisibility
    , simulateBookPricesResponse
    , simulateBookResponse
    , simulateBookshelfErrorResponse
    , simulateBookshelfResponse
    , simulateConfirmMergeRequiredResponse
    , simulateConfirmResponse
    , simulateEffect
    , simulateEmptyBookPricesResponse
    , simulateMergeFormatResponse
    , simulateMultiShelfResponse
    , simulatePlacementFormatsResponse
    , simulatePlacementShelfResponse
    , simulatePlacementVisibilityResponse
    , simulateRegisterResponse
    , simulateRegisterValidationResponse
    , testBook
    , testPlacement
    , uploadProgram
    , uploadProgramWithInbox
    )

{-| Shared test infrastructure for elm-program-test based program tests.

Provides ProgramTest harnesses for each testable page, HTTP response
simulators, and test data builders.

-}

import Api
import Dict
import Effect
import Http
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
import Types.Visibility


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
    , verificationSource = "open_library"
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
error messages, mirroring the backend's `{"errors": {field: [msg,...]}}` shape
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


{-| An HTTP response for `GET /api/books/:id` carrying a placement,
matching `ProtoJSON.book_placement/1` exactly: the take-list of
id/book\_id/personal\_rating/notes plus bookshelf\_name, formats,
visibility, bookshelf\_visibility. That allow-list is the whole
contract — fixtures must not invent keys the wire can never carry.
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
                        |> Maybe.map (Types.Visibility.toString >> Encode.string)
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


{-| A book-detail response carrying SEVERAL placements of the same book — the
legal multi-shelf state. Each entry is `{placement_id, bookshelf_name}`;
the response emits both the `placements` list and the legacy singular
`placement` key (the first entry), exactly as the controller does.
-}
simulateBookDetailResponseWithPlacements :
    String
    -> Book
    -> List { placementId : String, bookshelfName : String }
    -> Http.Response String
simulateBookDetailResponseWithPlacements bookId book entries =
    let
        encodeOne entry =
            Encode.object
                [ ( "id", Encode.string entry.placementId )
                , ( "book_id", Encode.string bookId )
                , ( "bookshelf_name", Encode.string entry.bookshelfName )
                , ( "formats", Encode.list Encode.string [] )
                , ( "visibility", Encode.null )
                , ( "bookshelf_visibility", Encode.null )
                ]

        json =
            Encode.encode 0
                (Encode.object
                    [ ( "book", encodeBook book )
                    , ( "placement"
                      , entries
                            |> List.head
                            |> Maybe.map encodeOne
                            |> Maybe.withDefault Encode.null
                      )
                    , ( "placements", Encode.list encodeOne entries )
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


{-| A `POST /api/books/confirm` success body, exactly as
`StacksWeb.BookController.confirm_payload/4` builds it
(`apps/core/lib/stacks_web/controllers/book_controller.ex:97-106`) and as
`proto/stacks/api/v1/book_responses.proto`'s `BookConfirmResponse` declares it:
`book`, the singular `placement` this request produced or matched, the full
`placements` list, and — on the two non-created branches only — `source`.

`source` is `Nothing` for the 201 created branch (the controller omits the key
entirely there), `Just "catalogue"` when the work already existed and this
request placed it, and `Just "collection"` when it was already on the requested
bookshelf.

-}
simulateConfirmResponse :
    { statusCode : Int
    , bookId : String
    , title : String
    , authorName : String
    , source : Maybe String
    , placements : List { placementId : String, bookshelfName : String }
    }
    -> Http.Response String
simulateConfirmResponse config =
    let
        book =
            { testBook
                | id = config.bookId
                , title = config.title
                , author =
                    Just
                        { id = "author-confirm-1"
                        , name = config.authorName
                        , bio = Nothing
                        , website = Nothing
                        }
            }

        encodeOne entry =
            Encode.object
                [ ( "id", Encode.string entry.placementId )
                , ( "book_id", Encode.string config.bookId )
                , ( "bookshelf_name", Encode.string entry.bookshelfName )
                , ( "formats", Encode.list Encode.string [] )
                , ( "visibility", Encode.null )
                , ( "bookshelf_visibility", Encode.null )
                ]

        json =
            Encode.encode 0
                (Encode.object
                    ([ ( "book", encodeBook book )
                     , ( "placement"
                       , config.placements
                            |> List.head
                            |> Maybe.map encodeOne
                            |> Maybe.withDefault Encode.null
                       )
                     , ( "placements", Encode.list encodeOne config.placements )
                     ]
                        ++ encodeMaybe "source" Encode.string config.source
                    )
                )
    in
    Http.GoodStatus_
        { url = "/api/books/confirm"
        , statusCode = config.statusCode
        , statusText = "OK"
        , headers = Dict.empty
        }
        json


{-| The 409 `POST /api/books/confirm` body — `Books.confirm/2` found an
existing work whose title+author fuzzy-matches (Jaro-Winkler > 0.8) the
metadata this ISBN resolved to, so it refused to mint a second work and named
the one to merge into (`book_controller.ex:71-74`).
-}
simulateConfirmMergeRequiredResponse : String -> Http.Response String
simulateConfirmMergeRequiredResponse workId =
    Http.BadStatus_
        { url = "/api/books/confirm"
        , statusCode = 409
        , statusText = "Conflict"
        , headers = Dict.empty
        }
        (Encode.encode 0
            (Encode.object
                [ ( "error", Encode.string "merge_required" )
                , ( "work_id", Encode.string workId )
                ]
            )
        )


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


{-| A book-detail response carrying a placement that already owns `formats`.
Drives the format picker, whose starting state decides which way a click
toggles.
-}
simulateBookDetailResponseWithFormats : String -> Book -> List String -> Http.Response String
simulateBookDetailResponseWithFormats bookId book formats =
    let
        placementJson =
            Encode.object
                [ ( "id", Encode.string "placement-fmt-001" )
                , ( "formats", Encode.list Encode.string formats )
                , ( "bookshelf_name", Encode.string "library" )
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


{-| A successful `PUT /api/placements/:id/formats` response:
`{placement: {id, formats}}`.
-}
simulatePlacementFormatsResponse : String -> List String -> Http.Response String
simulatePlacementFormatsResponse placementId formats =
    Http.GoodStatus_
        { url = "/api/placements/" ++ placementId ++ "/formats"
        , statusCode = 200
        , statusText = "OK"
        , headers = Dict.empty
        }
        (Encode.encode 0
            (Encode.object
                [ ( "placement"
                  , Encode.object
                        [ ( "id", Encode.string placementId )
                        , ( "formats", Encode.list Encode.string formats )
                        ]
                  )
                ]
            )
        )


{-| A successful `PUT /api/placements/:id/shelf` response, in the shape
`ProtoJSON.placement_ref/1` emits: `{placement: {id, shelf_id, …}}`.

The `shelf_id` is a parameter rather than a copy of what was asked for, so a
test can hand back a DIFFERENT row and see whether the page believes the server
or itself.

-}
simulatePlacementShelfResponse : String -> String -> Http.Response String
simulatePlacementShelfResponse placementId shelfId =
    Http.GoodStatus_
        { url = "/api/placements/" ++ placementId ++ "/shelf"
        , statusCode = 200
        , statusText = "OK"
        , headers = Dict.empty
        }
        (Encode.encode 0
            (Encode.object
                [ ( "placement"
                  , Encode.object
                        [ ( "id", Encode.string placementId )
                        , ( "shelf_id", Encode.string shelfId )
                        , ( "position", Encode.int 0 )
                        ]
                  )
                ]
            )
        )


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


{-| A simulated request derived from the REAL `Api.*` request definition.

Hand-copying the method/url/body here is the request-side twin of the decoder
mirrors removed: the copy and the fixture agree with each other while
drifting from production, and the drift is invisible — hardcoding
`Api.confirmBook`'s `shelf_name` left all 1,353 tests green. Deriving from
`Api.RequestSpec` means a change to the production request is a change to what
these tests assert against.

-}
authedRequestFromSpec :
    Api.RequestSpec
    -> String
    -> SimulatedEffect.Http.Expect msg
    -> SimulatedEffect msg
authedRequestFromSpec spec token expect =
    requestFromSpec spec (Just token) expect


{-| Run a page's `Effect` in the simulated runtime — the twin of
`Effect.perform`, and the reason a harness no longer decides for itself which
request a Msg fires.

`Effect.Custom` holds a real `Cmd` (a file picker, a focus task) that no
simulated runtime can run; it becomes no effect here, which is exactly what
these harnesses did with those before.

-}
simulateEffect : Effect.Effect msg -> SimulatedEffect msg
simulateEffect effect =
    case effect of
        Effect.None ->
            SimulatedEffect.Cmd.none

        Effect.Batch effects ->
            SimulatedEffect.Cmd.batch (List.map simulateEffect effects)

        Effect.Request plan ->
            requestFromSpec plan.spec
                plan.token
                (SimulatedEffect.Http.expectStringResponse
                    (\result ->
                        case result of
                            Ok msg ->
                                msg

                            Err impossible ->
                                never impossible
                    )
                    (Ok << plan.onResponse)
                )

        Effect.Sleep millis msg ->
            SimulatedEffect.Task.perform (\_ -> msg) (SimulatedEffect.Process.sleep millis)

        Effect.Custom _ ->
            SimulatedEffect.Cmd.none


{-| `authedRequestFromSpec` for an optional-auth endpoint: the `Authorization`
header appears only when the viewer has a token, which is what
`Api.authHeaders` does on the production side.
-}
requestFromSpec :
    Api.RequestSpec
    -> Maybe String
    -> SimulatedEffect.Http.Expect msg
    -> SimulatedEffect msg
requestFromSpec spec maybeToken expect =
    SimulatedEffect.Http.request
        { method = spec.method
        , headers = authHeaderList maybeToken
        , url = spec.url
        , body =
            case spec.body of
                Just value ->
                    SimulatedEffect.Http.jsonBody value

                Nothing ->
                    SimulatedEffect.Http.emptyBody
        , expect = expect
        , timeout = Nothing
        , tracker = Nothing
        }


authHeaderList : Maybe String -> List SimulatedEffect.Http.Header
authHeaderList maybeToken =
    case maybeToken of
        Just token ->
            [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]

        Nothing ->
            []


{-| Create a ProgramTest harness for the Upload page. `ageGatingEnabled`
seeds the server-config flag so tests can drive both the
flag-on (age UI present) and flag-off (age UI hidden) states.
-}
uploadProgram : Bool -> Maybe String -> ProgramDefinition () Upload.Model Upload.Msg (SimulatedEffect Upload.Msg)
uploadProgram ageGatingEnabled maybeToken =
    uploadProgramWithInbox ageGatingEnabled maybeToken Types.RemoteData.NotAsked


{-| The upload page with an inbox already loaded.

The inbox lives on `Main`, not on `Page.Upload` — one list feeding both the
page's listing and the navigation badge, so the two cannot disagree — so it
arrives as a view argument rather than through this program's `update`. That
makes it a fixture here, which is exactly right: these tests are about what the
page does WITH the list, not about fetching it (`MainNavTest` covers the badge's
own reading of the same value, and `UploadControllerTest` covers the query).

-}
uploadProgramWithInbox :
    Bool
    -> Maybe String
    -> Types.RemoteData.RemoteData Http.Error (List Api.InboxItem)
    -> ProgramDefinition () Upload.Model Upload.Msg (SimulatedEffect Upload.Msg)
uploadProgramWithInbox ageGatingEnabled maybeToken inbox =
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
                    ( newModel, effect, _ ) =
                        Upload.updateWithEffect msg model maybeToken
                in
                ( newModel, simulateEffect effect )
        , view = \model -> Upload.view model maybeToken inbox
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
surfaces.
-}
bookshelfProgram : Bookshelf.Config -> Maybe String -> ProgramDefinition () Bookshelf.Model Bookshelf.Msg (SimulatedEffect Bookshelf.Msg)
bookshelfProgram config maybeToken =
    ProgramTest.createElement
        { init =
            \() ->
                let
                    ( model, effect ) =
                        Bookshelf.initWithEffect config maybeToken "test-user-id"
                in
                ( model, simulateEffect effect )
        , update =
            \msg model ->
                let
                    ( newModel, effect, _ ) =
                        Bookshelf.updateWithEffect msg model
                in
                ( newModel, simulateEffect effect )
        , view = Bookshelf.view
        }
        |> ProgramTest.withSimulatedEffects identity


{-| Harness model for the Reading Pile program test.

`Page.Bookshelf.ReadingPile.update` returns a third `OutMsg` element that the
page itself cannot observe — `Main` consumes it. Recording the most recent
`OutMsg` alongside the page model lets a program test assert the navigation
intent a book click produces rather than only the model
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
                    ( model, effect ) =
                        ReadingPile.initWithEffect maybeToken
                in
                ( { page = model, lastOut = ReadingPile.NoOut }
                , simulateEffect effect
                )
        , update =
            \msg model ->
                let
                    ( newPage, effect, out ) =
                        ReadingPile.updateWithEffect msg model.page
                in
                ( { page = newPage, lastOut = out }, simulateEffect effect )
        , view = \model -> ReadingPile.view model.page
        }
        |> ProgramTest.withSimulatedEffects identity


{-| A bookshelf harness for a reader who has just removed a book and been
returned to their shelf (extension,).

Seeds the toast through production's own `Bookshelf.withPendingUndo` — the
function `Main.applyPendingUndo` calls — rather than hand-building a model with
`undoToast` set. A harness that constructs the state directly would keep passing
if `withPendingUndo` stopped producing it.

Takes the `Config`, so the SAME setup drives the owner shelf and the read-only
profile shelf; `BookshelfUndoRemoveTest` runs both and requires them to differ.

-}
bookshelfUndoProgram :
    Bookshelf.Config
    -> Maybe String
    -> Bookshelf.Removal
    -> ProgramDefinition () Bookshelf.Model Bookshelf.Msg (SimulatedEffect Bookshelf.Msg)
bookshelfUndoProgram config maybeToken removal =
    ProgramTest.createElement
        { init =
            \() ->
                let
                    ( model, effect ) =
                        Bookshelf.initWithEffect config maybeToken "test-user-id"

                    ( seeded, _ ) =
                        Bookshelf.withPendingUndo (Just removal) ( model, Cmd.none )
                in
                ( seeded, simulateEffect effect )
        , update =
            \msg model ->
                let
                    ( newModel, effect, _ ) =
                        Bookshelf.updateWithEffect msg model
                in
                ( newModel, simulateEffect effect )
        , view = Bookshelf.view
        }
        |> ProgramTest.withSimulatedEffects identity


{-| Create a ProgramTest harness for the read-only profile-shelf browse view
(`Page.Bookshelf` in its `profileConfig` — /).
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
                    ( model, effect ) =
                        Bookshelf.initWithEffect config maybeToken "viewer-user-id"
                in
                ( model, simulateEffect effect )
        , update =
            \msg model ->
                let
                    ( newModel, effect, _ ) =
                        Bookshelf.updateWithEffect msg model
                in
                ( newModel, simulateEffect effect )
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
                    ( newModel, effect, _ ) =
                        Search.updateWithEffect msg model maybeToken
                in
                ( newModel, simulateEffect effect )
        , view = Search.view (maybeToken /= Nothing)
        }
        |> ProgramTest.withSimulatedEffects identity


{-| Create a ProgramTest harness for the Login page.
-}
loginProgram : ProgramDefinition () Login.Model Login.Msg (SimulatedEffect Login.Msg)
loginProgram =
    loginProgramFrom Login.Fresh


{-| The same harness, for a reader who arrived for a REASON.

`loginProgram` is this with `Fresh`. Deep-linked arrivals — `/forgot-password`,
`/resend-confirmation` — open the card on a mode an ordinary visitor cannot click
their way to, so driving those journeys means starting the program the way `Main`
starts it, from the arrival.

-}
loginProgramFrom : Login.Arrival -> ProgramDefinition () Login.Model Login.Msg (SimulatedEffect Login.Msg)
loginProgramFrom arrival =
    ProgramTest.createElement
        { init = \() -> ( Login.init arrival, SimulatedEffect.Cmd.none )
        , update =
            \msg model ->
                let
                    ( newModel, effect, _ ) =
                        Login.updateWithEffect msg model
                in
                ( newModel, simulateEffect effect )
        , view = Login.view
        }
        |> ProgramTest.withSimulatedEffects identity


{-| Create a ProgramTest harness for the BookDetail page. Age-gating is
enabled so the 403-driven age-gate block renders under test; the
production default is off, which hides it (covered by the flag guard).
-}
bookDetailProgram : String -> Maybe String -> ProgramDefinition () BookDetail.Model BookDetail.Msg (SimulatedEffect BookDetail.Msg)
bookDetailProgram bookId maybeToken =
    ProgramTest.createElement
        { init =
            \() ->
                let
                    ( model, effect ) =
                        BookDetail.initWithEffect bookId maybeToken Nothing
                in
                ( model, simulateEffect effect )
        , update =
            \msg model ->
                let
                    ( newModel, effect, _ ) =
                        BookDetail.updateWithEffect msg model maybeToken
                in
                ( newModel, simulateEffect effect )
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
                    ( model, effect ) =
                        BookDetail.initWithEffect bookId maybeToken maybePreviousRoute
                in
                ( { page = model, lastOut = BookDetail.NoOut }
                , simulateEffect effect
                )
        , update =
            \msg model ->
                let
                    ( newModel, effect, out ) =
                        BookDetail.updateWithEffect msg model.page maybeToken
                in
                ( { page = newModel, lastOut = out }, simulateEffect effect )
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
                    ( model, effect ) =
                        BookDetail.initWithEffect bookId maybeToken maybePreviousRoute
                in
                ( { page = model, lastOut = BookDetail.NoOut }
                , simulateEffect effect
                )
        , update =
            \msg model ->
                let
                    ( newModel, effect, out ) =
                        BookDetail.updateWithEffect msg model.page maybeToken
                in
                ( { page = newModel, lastOut = out }, simulateEffect effect )
        , view = \model -> BookDetail.overlayView model.page
        }
        |> ProgramTest.withSimulatedEffects identity
