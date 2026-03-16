module UpdateTest exposing (..)

import Expect
import Http
import Navigation.Route exposing (Route(..))
import Page.BookDetail as BookDetail
import Page.Bookshelf as Bookshelf
import Test exposing (Test, describe, test)
import Types.Book exposing (Author, Book, VisibilityTier(..))
import Types.RemoteData exposing (RemoteData(..))



-- Helpers


libraryInit : Bookshelf.Model
libraryInit =
    { books = Loading
    , showAgeGate = False
    , config = Bookshelf.libraryConfig
    }


bookDetailInit : BookDetail.Model
bookDetailInit =
    { book = Loading
    , placement = Nothing
    , bookshelfMoverOpen = False
    , removeModalOpen = False
    , formatPickerOpen = False
    , currentBookshelf = ""
    , selectedBookshelf = "antilibrary"
    , selectedFormats = []
    , moveState = NotAsked
    , removeState = NotAsked
    , previousRoute = Nothing
    , showAgeGate = False
    , entryAnimationActive = False
    }


sampleAuthor : Author
sampleAuthor =
    { id = "author-1"
    , name = "Test Author"
    , bio = Nothing
    }


sampleBook : Book
sampleBook =
    { id = "book-1"
    , isbn = "9780000000000"
    , title = "Test Book"
    , author = Just sampleAuthor
    , description = Nothing
    , coverImageUrl = Nothing
    , pageCount = Nothing
    , publisher = Nothing
    , publicationYear = Nothing
    , subjects = []
    , visibilityTier = Public
    }



-- Library update tests


suite : Test
suite =
    describe "Update"
        [ describe "Library"
            [ test "BooksLoaded 403 sets showAgeGate = True and books = Failure" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Bookshelf.update
                                (Bookshelf.BooksLoaded (Err (Http.BadStatus 403)))
                                libraryInit
                    in
                    Expect.all
                        [ \m -> Expect.equal True m.showAgeGate
                        , \m -> Expect.equal (Failure (Http.BadStatus 403)) m.books
                        ]
                        model
            , test "BooksLoaded NetworkError sets showAgeGate = False and books = Failure" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Bookshelf.update
                                (Bookshelf.BooksLoaded (Err Http.NetworkError))
                                libraryInit
                    in
                    Expect.all
                        [ \m -> Expect.equal False m.showAgeGate
                        , \m -> Expect.equal (Failure Http.NetworkError) m.books
                        ]
                        model
            , test "BooksLoaded Ok sets showAgeGate = False and books = Success" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Bookshelf.update
                                (Bookshelf.BooksLoaded (Ok []))
                                libraryInit
                    in
                    Expect.all
                        [ \m -> Expect.equal False m.showAgeGate
                        , \m -> Expect.equal (Success []) m.books
                        ]
                        model
            , test "VerifyAge produces NavigateTo SettingsAgeVerification" <|
                \_ ->
                    let
                        ( _, _, outMsg ) =
                            Bookshelf.update Bookshelf.VerifyAge libraryInit
                    in
                    Expect.equal (Bookshelf.NavigateTo SettingsAgeVerification) outMsg
            , test "DismissAgeGate sets showAgeGate = False" <|
                \_ ->
                    let
                        modelWithGate =
                            { libraryInit | showAgeGate = True }

                        ( model, _, _ ) =
                            Bookshelf.update Bookshelf.DismissAgeGate modelWithGate
                    in
                    Expect.equal False model.showAgeGate
            ]
        , describe "BookDetail"
            [ test "BookLoaded 403 sets showAgeGate = True and book = Failure" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            BookDetail.update
                                (BookDetail.BookLoaded (Err (Http.BadStatus 403)))
                                bookDetailInit
                                Nothing
                    in
                    Expect.all
                        [ \m -> Expect.equal True m.showAgeGate
                        , \m -> Expect.equal (Failure (Http.BadStatus 403)) m.book
                        ]
                        model
            , test "BookLoaded NetworkError sets showAgeGate = False and book = Failure" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            BookDetail.update
                                (BookDetail.BookLoaded (Err Http.NetworkError))
                                bookDetailInit
                                Nothing
                    in
                    Expect.all
                        [ \m -> Expect.equal False m.showAgeGate
                        , \m -> Expect.equal (Failure Http.NetworkError) m.book
                        ]
                        model
            , test "BookLoaded Ok sets showAgeGate = False and book = Success" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            BookDetail.update
                                (BookDetail.BookLoaded (Ok sampleBook))
                                bookDetailInit
                                Nothing
                    in
                    Expect.all
                        [ \m -> Expect.equal False m.showAgeGate
                        , \m -> Expect.equal (Success sampleBook) m.book
                        ]
                        model
            , test "DismissAgeGate sets showAgeGate = False" <|
                \_ ->
                    let
                        modelWithGate =
                            { bookDetailInit | showAgeGate = True }

                        ( model, _, _ ) =
                            BookDetail.update BookDetail.DismissAgeGate modelWithGate Nothing
                    in
                    Expect.equal False model.showAgeGate
            , test "VerifyAge produces NavigateTo SettingsAgeVerification" <|
                \_ ->
                    let
                        ( _, _, outMsg ) =
                            BookDetail.update BookDetail.VerifyAge bookDetailInit Nothing
                    in
                    Expect.equal (BookDetail.NavigateTo SettingsAgeVerification) outMsg
            ]
        ]
