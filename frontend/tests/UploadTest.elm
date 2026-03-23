module UploadTest exposing (suite)

import Api exposing (PollResponse, PollStatus(..))
import Expect
import Http
import Navigation.Route
import Page.Upload as Upload exposing (Msg(..), OutMsg(..), UploadResult(..), UploadStep(..))
import Test exposing (Test, describe, test)
import Types.Book exposing (Book, VisibilityTier(..))
import Types.RemoteData exposing (RemoteData(..))


dummyBook : Book
dummyBook =
    { id = "book-1"
    , title = "Test Book"
    , author = Just { id = "author-1", name = "Test Author", bio = Nothing, website = Nothing }
    , description = Nothing
    , editions = []
    , primaryEdition = Nothing
    , editionCount = 0
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
                        ( model, _, _ ) =
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
                        ( model, _, _ ) =
                            Upload.update (UploadAccepted (Err Http.NetworkError)) Upload.init (Just "tok")
                    in
                    model.uploadState |> Expect.equal (Failure Http.NetworkError)
            ]
        , describe "CheckStatus"
            [ test "increments pollCount" <|
                \_ ->
                    let
                        ( model, _, _ ) =
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

                        ( model, _, _ ) =
                            Upload.update CheckStatus timedOut (Just "tok")
                    in
                    model.result |> Expect.equal IdentificationFailed
            , test "no-ops when uploadState is not Success" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update CheckStatus Upload.init (Just "tok")
                    in
                    model.pollCount |> Expect.equal 0
            , test "no-ops when token is absent" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update CheckStatus modelWithImage Nothing
                    in
                    model.pollCount |> Expect.equal 0
            ]
        , describe "StatusReceived"
            [ test "Pending leaves result unchanged" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (StatusReceived (Ok pendingPoll)) modelWithImage (Just "tok")
                    in
                    model.result |> Expect.equal NoResult
            , test "Rejected sets result to IdentificationFailed" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (StatusReceived (Ok rejectedPoll)) Upload.init (Just "tok")
                    in
                    model.result |> Expect.equal IdentificationFailed
            , test "Resolved without bookId sets result to NotABook" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (StatusReceived (Ok resolvedNotABook)) Upload.init (Just "tok")
                    in
                    model.result |> Expect.equal NotABook
            , test "Resolved with bookId leaves result pending (waits for GotIdentifiedBook)" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (StatusReceived (Ok resolvedNewBook)) Upload.init (Just "tok")
                    in
                    -- Model unchanged while getBook request is in-flight.
                    model.result |> Expect.equal NoResult
            , test "Resolved with duplicate flag leaves result pending (waits for GotDuplicateBook)" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (StatusReceived (Ok resolvedDuplicate)) Upload.init (Just "tok")
                    in
                    model.result |> Expect.equal NoResult
            , test "Http error on poll sets result to IdentificationFailed" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (StatusReceived (Err Http.NetworkError)) Upload.init (Just "tok")
                    in
                    model.result |> Expect.equal IdentificationFailed
            ]
        , describe "GotIdentifiedBook"
            [ test "Ok collects book and enters Verifying step when no more pending" <|
                \_ ->
                    let
                        base =
                            Upload.init

                        modelPending =
                            { base | pendingBookIds = [ "book-1" ], collectedBooks = [] }

                        ( model, _, _ ) =
                            Upload.update (GotIdentifiedBook "book-1" (Ok { book = dummyBook, placement = Nothing })) modelPending Nothing
                    in
                    Expect.all
                        [ \m -> m.result |> Expect.equal (Identified [ dummyBook ])
                        , \m -> m.step |> Expect.equal (Verifying dummyBook)
                        ]
                        model
            , test "Err sets result to IdentificationFailed when no books collected" <|
                \_ ->
                    let
                        base =
                            Upload.init

                        modelPending =
                            { base | pendingBookIds = [ "book-1" ], collectedBooks = [] }

                        ( model, _, _ ) =
                            Upload.update (GotIdentifiedBook "book-1" (Err Http.NetworkError)) modelPending Nothing
                    in
                    model.result |> Expect.equal IdentificationFailed
            ]
        , describe "GotDuplicateBook"
            [ test "Ok sets result to DuplicateDetected" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (GotDuplicateBook (Ok { book = dummyBook, placement = Nothing })) Upload.init Nothing
                    in
                    model.result |> Expect.equal (DuplicateDetected dummyBook)
            , test "Err sets result to IdentificationFailed" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (GotDuplicateBook (Err Http.NetworkError)) Upload.init Nothing
                    in
                    model.result |> Expect.equal IdentificationFailed
            ]
        , describe "Verification step"
            [ test "ConfirmIdentification moves from Verifying to ChoosingShelf" <|
                \_ ->
                    let
                        base =
                            Upload.init

                        verifying =
                            { base | step = Verifying dummyBook }

                        ( model, _, _ ) =
                            Upload.update ConfirmIdentification verifying Nothing
                    in
                    model.step |> Expect.equal (ChoosingShelf dummyBook)
            , test "RejectIdentification resets to init" <|
                \_ ->
                    let
                        base =
                            Upload.init

                        verifying =
                            { base | step = Verifying dummyBook }

                        ( model, _, _ ) =
                            Upload.update RejectIdentification verifying Nothing
                    in
                    model.step |> Expect.equal Uploading
            , test "ShelfSelected updates selectedShelf" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Upload.update (ShelfSelected "antilibrary") Upload.init Nothing
                    in
                    model.selectedShelf |> Expect.equal "antilibrary"
            , test "default selectedShelf is wishlist" <|
                \_ ->
                    Upload.init.selectedShelf |> Expect.equal "wishlist"
            ]
        , describe "GoToShelf"
            [ test "emits NavigateTo with Library route" <|
                \_ ->
                    let
                        ( _, _, outMsg ) =
                            Upload.update (GoToShelf "library") Upload.init Nothing
                    in
                    outMsg |> Expect.equal (NavigateTo Navigation.Route.Library)
            ]
        ]
