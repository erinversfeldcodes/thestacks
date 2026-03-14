module TestHelpers exposing
    ( libraryProgram
    , searchProgram
    , simulateBookResponse
    , simulateBookshelfResponse
    , simulatePollResponse
    , simulateSearchResponse
    , testBook
    , testPlacement
    , uploadProgram
    )

{-| Shared test infrastructure for elm-program-test based program tests.

Provides ProgramTest harnesses for each testable page, HTTP response
simulators, and test data builders.

-}

import Api exposing (PollResponse, PollStatus(..))
import Dict
import Http
import Json.Decode as Decode
import Json.Encode as Encode
import Page.Bookshelf.Library as Library exposing (Msg(..))
import Page.Search as Search exposing (Msg(..))
import Page.Upload as Upload exposing (Msg(..))
import ProgramTest exposing (ProgramDefinition, SimulatedEffect)
import SimulatedEffect.Cmd
import SimulatedEffect.Http
import SimulatedEffect.Process
import SimulatedEffect.Task
import Types.Book exposing (Book, VisibilityTier(..), bookDecoder)
import Types.Placement exposing (Placement, placementDecoder)
import Types.RemoteData exposing (RemoteData(..))



-- TEST DATA BUILDERS


{-| A default book with all fields populated, suitable for use in any test.
-}
testBook : Book
testBook =
    { id = "book-test-001"
    , isbn = "9780141988511"
    , title = "The Power of Habit"
    , author = { id = "author-test-001", name = "Charles Duhigg", bio = Nothing }
    , description = Just "A fascinating exploration of habit formation."
    , coverImageUrl = Just "https://example.com/covers/habit.jpg"
    , pageCount = Just 371
    , publisher = Just "Random House"
    , publicationYear = Just 2012
    , subjects = [ "Psychology", "Self-Help" ]
    , visibilityTier = Public
    }


{-| A default placement wrapping testBook, suitable for bookshelf tests.
-}
testPlacement : Placement
testPlacement =
    { id = "placement-test-001"
    , book = Just testBook
    , position = 1
    , placedAt = "2025-01-15T10:30:00Z"
    , formats = []
    , personalRating = Nothing
    , notes = Nothing
    }



-- JSON ENCODING HELPERS


encodeBook : Book -> Encode.Value
encodeBook book =
    Encode.object
        ([ ( "id", Encode.string book.id )
         , ( "isbn", Encode.string book.isbn )
         , ( "title", Encode.string book.title )
         , ( "author"
           , Encode.object
                ([ ( "id", Encode.string book.author.id )
                 , ( "name", Encode.string book.author.name )
                 ]
                    ++ (case book.author.bio of
                            Just bio ->
                                [ ( "bio", Encode.string bio ) ]

                            Nothing ->
                                []
                       )
                )
           )
         , ( "subjects", Encode.list Encode.string book.subjects )
         , ( "visibility_tier", encodeVisibilityTier book.visibilityTier )
         ]
            ++ encodeMaybe "description" Encode.string book.description
            ++ encodeMaybe "cover_image_url" Encode.string book.coverImageUrl
            ++ encodeMaybe "page_count" Encode.int book.pageCount
            ++ encodeMaybe "publisher" Encode.string book.publisher
            ++ encodeMaybe "publication_year" Encode.int book.publicationYear
        )


encodeVisibilityTier : VisibilityTier -> Encode.Value
encodeVisibilityTier tier =
    Encode.string <|
        case tier of
            Public ->
                "public"

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
        ([ ( "id", Encode.string placement.id )
         , ( "position", Encode.int placement.position )
         , ( "placed_at", Encode.string placement.placedAt )
         ]
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
                            , ( "isbn", Encode.string "9780000000000" )
                            , ( "title", Encode.string title )
                            , ( "author"
                              , Encode.object
                                    [ ( "id", Encode.string "author-1" )
                                    , ( "name", Encode.string authorName )
                                    ]
                              )
                            , ( "subjects", Encode.list Encode.string [] )
                            , ( "visibility_tier", Encode.string "public" )
                            ]
                      )
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


{-| Create an HTTP response for a search results listing.
-}
simulateSearchResponse : List Book -> Http.Response String
simulateSearchResponse books =
    let
        json =
            Encode.encode 0
                (Encode.list encodeBook books)
    in
    Http.GoodStatus_
        { url = "/api/books/search"
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

The Upload page uses:

  - Http.request (upload, poll, getBook, moveBook)
  - File.Select.files (cannot be simulated -- user-initiated)
  - Process.sleep via Task.perform

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
                                            , expect = SimulatedEffect.Http.expectJson Upload.GotDuplicateBook (Decode.field "book" bookDecoder)
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
                                                , expect = SimulatedEffect.Http.expectJson (Upload.GotIdentifiedBook bid) (Decode.field "book" bookDecoder)
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

        Upload.ConfirmDuplicateMove bookId ->
            case maybeToken of
                Just token ->
                    SimulatedEffect.Http.request
                        { method = "PUT"
                        , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                        , url = "/api/placements/" ++ bookId ++ "/move"
                        , body =
                            SimulatedEffect.Http.jsonBody
                                (Encode.object [ ( "bookshelf", Encode.string model.duplicateShelf ) ])
                        , expect = SimulatedEffect.Http.expectWhatever Upload.DuplicateMoveCompleted
                        , timeout = Nothing
                        , tracker = Nothing
                        }

                Nothing ->
                    SimulatedEffect.Cmd.none

        Upload.GotFiles _ _ ->
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


{-| Translate Library page Cmds into SimulatedEffects.
-}
libraryEffects : Library.Msg -> Library.Model -> SimulatedEffect Library.Msg
libraryEffects _ _ =
    SimulatedEffect.Cmd.none


{-| Translate Library init Cmds into SimulatedEffects.
-}
libraryInitEffects : Maybe String -> SimulatedEffect Library.Msg
libraryInitEffects maybeToken =
    case maybeToken of
        Just token ->
            SimulatedEffect.Http.request
                { method = "GET"
                , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                , url = "/api/bookshelves/library"
                , body = SimulatedEffect.Http.emptyBody
                , expect =
                    SimulatedEffect.Http.expectJson Library.BooksLoaded
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



-- PROGRAM TEST HARNESSES


{-| Create a ProgramTest harness for the Upload page.

The auth token is baked in at harness creation time because Upload.update
takes it as a third argument.

Usage:

    ProgramTest.start () (uploadProgram (Just "test-token"))

-}
uploadProgram : Maybe String -> ProgramDefinition () Upload.Model Upload.Msg (SimulatedEffect Upload.Msg)
uploadProgram maybeToken =
    ProgramTest.createElement
        { init = \() -> ( Upload.init, SimulatedEffect.Cmd.none )
        , update =
            \msg model ->
                let
                    ( newModel, _ ) =
                        Upload.update msg model maybeToken
                in
                ( newModel, uploadEffects msg model maybeToken )
        , view = \model -> Upload.view model maybeToken
        }
        |> ProgramTest.withSimulatedEffects identity


{-| Create a ProgramTest harness for the Library bookshelf page.

The auth token is baked in at harness creation time because Library.init
requires it to fire the initial HTTP request.

The OutMsg from Library.update is discarded in this harness. Tests that
need to assert on OutMsg should use the raw update function directly.

Usage:

    ProgramTest.start () (libraryProgram (Just "test-token"))

-}
libraryProgram : Maybe String -> ProgramDefinition () Library.Model Library.Msg (SimulatedEffect Library.Msg)
libraryProgram maybeToken =
    ProgramTest.createElement
        { init =
            \() ->
                let
                    ( model, _ ) =
                        Library.init maybeToken
                in
                ( model, libraryInitEffects maybeToken )
        , update =
            \msg model ->
                let
                    ( newModel, _, _ ) =
                        Library.update msg model
                in
                ( newModel, libraryEffects msg model )
        , view = Library.view
        }
        |> ProgramTest.withSimulatedEffects identity


{-| Create a ProgramTest harness for the Search page.

The auth token is baked in at harness creation time because Search.update
takes it as a third argument.

Usage:

    ProgramTest.start () (searchProgram (Just "test-token"))

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
