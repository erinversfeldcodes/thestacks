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
    , simulatePollResponse
    , testBook
    , testPlacement
    , uploadProgram
    )

{-| Shared test infrastructure for elm-program-test based program tests.

Provides ProgramTest harnesses for each testable page, HTTP response
simulators, and test data builders.

-}

import Api exposing (AuthResponse, BookDetailResponse, PollResponse, PollStatus(..))
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
import Types.RemoteData exposing (RemoteData(..))



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


{-| Create an HTTP response for a poll status check.
Parameters: status, optional bookId, isDuplicate flag.
-}
simulatePollResponse : PollStatus -> Maybe String -> Bool -> Http.Response String
simulatePollResponse status maybeBookId isDuplicate =
    let
        statusStr =
            case status of
                Pending ->
                    "pending"

                Resolved ->
                    "resolved"

                Rejected ->
                    "rejected"

        bookIdField =
            case maybeBookId of
                Just bid ->
                    [ ( "book_id", Encode.string bid )
                    , ( "book_ids", Encode.list Encode.string [ bid ] )
                    ]

                Nothing ->
                    [ ( "book_ids", Encode.list Encode.string [] ) ]

        json =
            Encode.encode 0
                (Encode.object
                    ([ ( "image_id", Encode.string "img-test-001" )
                     , ( "status", Encode.string statusStr )
                     , ( "is_duplicate", Encode.bool isDuplicate )
                     ]
                        ++ bookIdField
                    )
                )
    in
    Http.GoodStatus_
        { url = "/api/upload/img-test-001/status"
        , statusCode = 200
        , statusText = "OK"
        , headers = Dict.empty
        }
        json


{-| Create an HTTP response for a bookshelf listing.
-}
simulateBookshelfResponse : List Placement -> Http.Response String
simulateBookshelfResponse placements =
    let
        json =
            Encode.encode 0
                (Encode.object
                    [ ( "placements", Encode.list encodePlacement placements ) ]
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


{-| Decode a PollStatus from its JSON string representation.
-}
decodePollStatus : Decode.Decoder PollStatus
decodePollStatus =
    Decode.string
        |> Decode.andThen
            (\s ->
                case s of
                    "pending" ->
                        Decode.succeed Pending

                    "resolved" ->
                        Decode.succeed Resolved

                    "rejected" ->
                        Decode.succeed Rejected

                    _ ->
                        Decode.fail ("Unknown upload status: " ++ s)
            )


{-| Decode a PollResponse. Mirrors Api.pollResponseDecoder which is not exposed.
-}
decodePollResponse : Decode.Decoder PollResponse
decodePollResponse =
    Decode.map6 PollResponse
        (Decode.field "image_id" Decode.string)
        (Decode.field "status" decodePollStatus)
        (Decode.maybe (Decode.field "book_id" Decode.string))
        (Decode.field "book_ids" (Decode.list Decode.string)
            |> Decode.maybe
            |> Decode.map (Maybe.withDefault [])
        )
        (Decode.maybe (Decode.field "rejection_reason" Decode.string))
        (Decode.maybe (Decode.field "is_duplicate" Decode.bool))



-- SIMULATED EFFECT TRANSLATORS


{-| Translate Upload page Cmds into SimulatedEffects.
-}
uploadEffects : Upload.Msg -> Upload.Model -> Maybe String -> SimulatedEffect Upload.Msg
uploadEffects msg model maybeToken =
    case msg of
        Upload.CheckStatus ->
            case ( model.uploadState, maybeToken ) of
                ( Success imageId, Just token ) ->
                    if model.pollCount >= 150 then
                        SimulatedEffect.Cmd.none

                    else
                        SimulatedEffect.Http.request
                            { method = "GET"
                            , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                            , url = "/api/upload/" ++ imageId ++ "/status"
                            , body = SimulatedEffect.Http.emptyBody
                            , expect = SimulatedEffect.Http.expectJson Upload.StatusReceived decodePollResponse
                            , timeout = Nothing
                            , tracker = Nothing
                            }

                _ ->
                    SimulatedEffect.Cmd.none

        Upload.UploadAccepted (Ok _) ->
            SimulatedEffect.Task.perform (\_ -> Upload.CheckStatus) (SimulatedEffect.Process.sleep 2000)

        Upload.StatusReceived (Ok response) ->
            case response.status of
                Pending ->
                    SimulatedEffect.Task.perform (\_ -> Upload.CheckStatus) (SimulatedEffect.Process.sleep 2000)

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
libraryEffects : SimulatedEffect Bookshelf.Msg
libraryEffects =
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
                    SimulatedEffect.Http.expectJson Bookshelf.BooksLoaded
                        (Decode.field "placements" (Decode.list placementDecoder))
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


{-| Translate BookDetail init Cmds into SimulatedEffects.
-}
bookDetailInitEffects : String -> Maybe String -> SimulatedEffect BookDetail.Msg
bookDetailInitEffects bookId maybeToken =
    case maybeToken of
        Just token ->
            SimulatedEffect.Http.request
                { method = "GET"
                , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                , url = "/api/books/" ++ bookId
                , body = SimulatedEffect.Http.emptyBody
                , expect = SimulatedEffect.Http.expectJson BookDetail.BookLoaded decodeBookDetailResponse
                , timeout = Nothing
                , tracker = Nothing
                }

        Nothing ->
            SimulatedEffect.Cmd.none



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
                ( newModel, libraryEffects )
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
    Decode.map4 AuthResponse
        (Decode.field "token" Decode.string)
        (Decode.at [ "user", "id" ] Decode.string)
        (Decode.at [ "user", "email" ] Decode.string)
        (Decode.at [ "user", "display_name" ] Decode.string)


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
                        , expect = SimulatedEffect.Http.expectJson Login.GotAuthResponse decodeAuthResponse
                        , timeout = Nothing
                        , tracker = Nothing
                        }

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
