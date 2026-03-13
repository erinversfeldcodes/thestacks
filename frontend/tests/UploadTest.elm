module UploadTest exposing (suite)

import Api exposing (PollResponse, PollStatus(..))
import Expect
import Http
import Page.Upload as Upload exposing (Msg(..), UploadResult(..))
import Test exposing (Test, describe, test)
import Types.Book exposing (Book, VisibilityTier(..))
import Types.RemoteData exposing (RemoteData(..))


dummyBook : Book
dummyBook =
    { id = "book-1"
    , isbn = "9780141988511"
    , title = "Test Book"
    , author = { id = "author-1", name = "Test Author", bio = Nothing }
    , description = Nothing
    , coverImageUrl = Nothing
    , pageCount = Nothing
    , publisher = Nothing
    , publicationYear = Nothing
    , subjects = []
    , visibilityTier = Public
    }


pendingPoll : PollResponse
pendingPoll =
    { imageId = "img-1"
    , status = Pending
    , bookId = Nothing
    , bookIds = []
    , rejectionReason = Nothing
    , isDuplicate = Nothing
    }


rejectedPoll : PollResponse
rejectedPoll =
    { imageId = "img-1"
    , status = Rejected
    , bookId = Nothing
    , bookIds = []
    , rejectionReason = Just "isbn_not_found"
    , isDuplicate = Nothing
    }


resolvedNewBook : PollResponse
resolvedNewBook =
    { imageId = "img-1"
    , status = Resolved
    , bookId = Just "book-1"
    , bookIds = [ "book-1" ]
    , rejectionReason = Nothing
    , isDuplicate = Just False
    }


resolvedDuplicate : PollResponse
resolvedDuplicate =
    { imageId = "img-1"
    , status = Resolved
    , bookId = Just "book-1"
    , bookIds = [ "book-1" ]
    , rejectionReason = Nothing
    , isDuplicate = Just True
    }


resolvedNotABook : PollResponse
resolvedNotABook =
    { imageId = "img-1"
    , status = Resolved
    , bookId = Nothing
    , bookIds = []
    , rejectionReason = Just "not_a_book"
    , isDuplicate = Nothing
    }


modelWithImage : Upload.Model
modelWithImage =
    let
        base =
            Upload.init
    in
    { base | uploadState = Success "img-1" }


suite : Test
suite =
    describe "Page.Upload"
        [ describe "UploadAccepted"
            [ test "Ok imageId sets uploadState to Success and resets pollCount" <|
                \_ ->
                    let
                        ( model, _ ) =
                            Upload.update (UploadAccepted (Ok "img-1")) Upload.init (Just "tok")
                    in
                    Expect.all
                        [ \m -> m.uploadState |> Expect.equal (Success "img-1")
                        , \m -> m.pollCount |> Expect.equal 0
                        ]
                        model
            , test "Err sets uploadState to Failure" <|
                \_ ->
                    let
                        ( model, _ ) =
                            Upload.update (UploadAccepted (Err Http.NetworkError)) Upload.init (Just "tok")
                    in
                    model.uploadState |> Expect.equal (Failure Http.NetworkError)
            ]
        , describe "CheckStatus"
            [ test "increments pollCount" <|
                \_ ->
                    let
                        ( model, _ ) =
                            Upload.update CheckStatus modelWithImage (Just "tok")
                    in
                    model.pollCount |> Expect.equal 1
            , test "sets result to IdentificationFailed when maxPollCount reached" <|
                \_ ->
                    let
                        base =
                            Upload.init

                        timedOut =
                            { base | uploadState = Success "img-1", pollCount = 150 }

                        ( model, _ ) =
                            Upload.update CheckStatus timedOut (Just "tok")
                    in
                    model.result |> Expect.equal IdentificationFailed
            , test "no-ops when uploadState is not Success" <|
                \_ ->
                    let
                        ( model, _ ) =
                            Upload.update CheckStatus Upload.init (Just "tok")
                    in
                    model.pollCount |> Expect.equal 0
            , test "no-ops when token is absent" <|
                \_ ->
                    let
                        ( model, _ ) =
                            Upload.update CheckStatus modelWithImage Nothing
                    in
                    model.pollCount |> Expect.equal 0
            ]
        , describe "StatusReceived"
            [ test "Pending leaves result unchanged" <|
                \_ ->
                    let
                        ( model, _ ) =
                            Upload.update (StatusReceived (Ok pendingPoll)) modelWithImage (Just "tok")
                    in
                    model.result |> Expect.equal NoResult
            , test "Rejected sets result to IdentificationFailed" <|
                \_ ->
                    let
                        ( model, _ ) =
                            Upload.update (StatusReceived (Ok rejectedPoll)) Upload.init (Just "tok")
                    in
                    model.result |> Expect.equal IdentificationFailed
            , test "Resolved without bookId sets result to NotABook" <|
                \_ ->
                    let
                        ( model, _ ) =
                            Upload.update (StatusReceived (Ok resolvedNotABook)) Upload.init (Just "tok")
                    in
                    model.result |> Expect.equal NotABook
            , test "Resolved with bookId leaves result pending (waits for GotIdentifiedBook)" <|
                \_ ->
                    let
                        ( model, _ ) =
                            Upload.update (StatusReceived (Ok resolvedNewBook)) Upload.init (Just "tok")
                    in
                    -- Model unchanged while getBook request is in-flight.
                    model.result |> Expect.equal NoResult
            , test "Resolved with duplicate flag leaves result pending (waits for GotDuplicateBook)" <|
                \_ ->
                    let
                        ( model, _ ) =
                            Upload.update (StatusReceived (Ok resolvedDuplicate)) Upload.init (Just "tok")
                    in
                    model.result |> Expect.equal NoResult
            , test "Http error on poll sets result to IdentificationFailed" <|
                \_ ->
                    let
                        ( model, _ ) =
                            Upload.update (StatusReceived (Err Http.NetworkError)) Upload.init (Just "tok")
                    in
                    model.result |> Expect.equal IdentificationFailed
            ]
        , describe "GotIdentifiedBook"
            [ test "Ok collects book and shows Identified when no more pending" <|
                \_ ->
                    let
                        base =
                            Upload.init

                        modelPending =
                            { base | pendingBookIds = [ "book-1" ], collectedBooks = [] }

                        ( model, _ ) =
                            Upload.update (GotIdentifiedBook "book-1" (Ok dummyBook)) modelPending Nothing
                    in
                    model.result |> Expect.equal (Identified [ dummyBook ])
            , test "Err sets result to IdentificationFailed when no books collected" <|
                \_ ->
                    let
                        base =
                            Upload.init

                        modelPending =
                            { base | pendingBookIds = [ "book-1" ], collectedBooks = [] }

                        ( model, _ ) =
                            Upload.update (GotIdentifiedBook "book-1" (Err Http.NetworkError)) modelPending Nothing
                    in
                    model.result |> Expect.equal IdentificationFailed
            ]
        , describe "GotDuplicateBook"
            [ test "Ok sets result to DuplicateDetected" <|
                \_ ->
                    let
                        ( model, _ ) =
                            Upload.update (GotDuplicateBook (Ok dummyBook)) Upload.init Nothing
                    in
                    model.result |> Expect.equal (DuplicateDetected dummyBook)
            , test "Err sets result to IdentificationFailed" <|
                \_ ->
                    let
                        ( model, _ ) =
                            Upload.update (GotDuplicateBook (Err Http.NetworkError)) Upload.init Nothing
                    in
                    model.result |> Expect.equal IdentificationFailed
            ]
        ]
