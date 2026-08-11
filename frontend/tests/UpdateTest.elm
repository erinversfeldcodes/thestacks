module UpdateTest exposing (..)

import Components.BookList as BookList
import Components.ViewModeToggle exposing (ShelfViewMode(..))
import Expect
import Http
import Page.BookDetail as BookDetail
import Page.Bookshelf as Bookshelf
import Test exposing (Test, describe, test)
import Types.Book exposing (Author, Book, VisibilityTier(..))
import Types.RemoteData exposing (RemoteData(..))
import Types.Visibility


libraryInit : Bookshelf.Model
libraryInit =
    { shelves = Loading
    , showAgeGate = False
    , config = Bookshelf.libraryConfig
    , userId = "test-user-id"
    , visibility = "owner"
    , rssLink = { showUrl = False }
    , viewMode = SpineView
    , sortState = { column = BookList.Title, direction = BookList.Asc }
    , token = Nothing
    , organiser = { dragging = Nothing }
    , organiserBusy = False
    , organiserError = Nothing
    , undoToast = Bookshelf.ToastHidden
    , focusedSpine = Nothing
    }


bookDetailInit : BookDetail.Model
bookDetailInit =
    { book = Loading
    , prices = NotAsked
    , placement = Nothing
    , placements = []
    , removingPlacementId = Nothing
    , bookshelfMoverOpen = False
    , removeModalOpen = False
    , formatPickerOpen = False
    , currentBookshelf = ""
    , selectedBookshelf = "antilibrary"
    , selectedFormats = []
    , moveState = NotAsked
    , removeState = NotAsked
    , selectedEdition = Nothing
    , previousRoute = Nothing
    , authorEvents = NotAsked
    , showAgeGate = False
    , entryAnimationActive = False
    , isAuthenticated = True
    , availability = NotAsked
    , placementVisibility = Types.Visibility.Platform
    , previousVisibility = Types.Visibility.Platform
    , shelfCeiling = Types.Visibility.Public
    , visibilityState = NotAsked
    , progressCard = Nothing
    , progressSaveState = NotAsked
    , finishedReadPrompt = False
    , undoableRemoval = Nothing
    }


sampleAuthor : Author
sampleAuthor =
    { id = "author-1"
    , name = "Test Author"
    , bio = Nothing
    , website = Nothing
    }


sampleBook : Book
sampleBook =
    { id = "book-1"
    , title = "Test Book"
    , author = Just sampleAuthor
    , description = Nothing
    , editions = []
    , primaryEdition = Nothing
    , editionCount = 0
    , subjects = []
    , visibilityTier = Public
    }


suite : Test
suite =
    describe "Update"
        [ describe "Library"
            [ test "ShelvesLoaded 403 sets showAgeGate = True and shelves = Failure" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Bookshelf.update
                                (Bookshelf.ShelvesLoaded (Bookshelf.requestKey Bookshelf.libraryConfig) (Err (Http.BadStatus 403)))
                                libraryInit
                    in
                    Expect.all
                        [ \m -> Expect.equal True m.showAgeGate
                        , \m -> Expect.equal (Failure (Http.BadStatus 403)) m.shelves
                        ]
                        model
            , test "ShelvesLoaded NetworkError sets showAgeGate = False and shelves = Failure" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Bookshelf.update
                                (Bookshelf.ShelvesLoaded (Bookshelf.requestKey Bookshelf.libraryConfig) (Err Http.NetworkError))
                                libraryInit
                    in
                    Expect.all
                        [ \m -> Expect.equal False m.showAgeGate
                        , \m -> Expect.equal (Failure Http.NetworkError) m.shelves
                        ]
                        model
            , test "ShelvesLoaded Ok sets showAgeGate = False and shelves = Success" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Bookshelf.update
                                (Bookshelf.ShelvesLoaded (Bookshelf.requestKey Bookshelf.libraryConfig) (Ok { shelves = [], visibility = "owner" }))
                                libraryInit
                    in
                    Expect.all
                        [ \m -> Expect.equal False m.showAgeGate
                        , \m -> Expect.equal (Success []) m.shelves
                        ]
                        model
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
                                (BookDetail.BookLoaded (Ok { book = sampleBook, placement = Nothing, bookshelfVisibility = Nothing, placements = [] }))
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
            ]
        ]
