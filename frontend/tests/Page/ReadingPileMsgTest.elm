module Page.ReadingPileMsgTest exposing (suite)

{-| Drives `Page.Bookshelf.ReadingPile.update` directly through its `Msg`
constructors. Exists to prove the constructors are reachable from `tests/`;
the full happy-path and sad-path program tests are Issue #112 punch #7/#8.
-}

import Expect
import Http
import Navigation.Route exposing (Route(..))
import Page.Bookshelf.ReadingPile as ReadingPile exposing (Msg(..), OutMsg(..))
import Test exposing (Test, describe, test)
import TestHelpers exposing (testBook, testPlacement)
import Types.RemoteData exposing (RemoteData(..))
import Types.Shelf exposing (Shelf)


loadingModel : ReadingPile.Model
loadingModel =
    { books = Loading
    , showAgeGate = False
    , selectedBookId = Nothing
    }


shelfWithOneBook : Shelf
shelfWithOneBook =
    { id = "shelf-1"
    , position = 0
    , placements = [ testPlacement ]
    }


suite : Test
suite =
    describe "Page.Bookshelf.ReadingPile update"
        [ test "BooksLoaded Ok flattens shelf placements into the pile" <|
            \_ ->
                let
                    ( model, _, out ) =
                        ReadingPile.update (BooksLoaded (Ok [ shelfWithOneBook ])) loadingModel
                in
                ( model.books, out )
                    |> Expect.equal ( Success [ testPlacement ], NoOut )
        , test "BooksLoaded 403 raises the age gate" <|
            \_ ->
                let
                    ( model, _, _ ) =
                        ReadingPile.update (BooksLoaded (Err (Http.BadStatus 403))) loadingModel
                in
                model.showAgeGate
                    |> Expect.equal True
        , test "BooksLoaded 401 reports the session as expired" <|
            \_ ->
                let
                    ( _, _, out ) =
                        ReadingPile.update (BooksLoaded (Err (Http.BadStatus 401))) loadingModel
                in
                out
                    |> Expect.equal SessionExpired
        , test "BooksLoaded network error surfaces as Failure" <|
            \_ ->
                let
                    ( model, _, _ ) =
                        ReadingPile.update (BooksLoaded (Err Http.NetworkError)) loadingModel
                in
                model.books
                    |> Expect.equal (Failure Http.NetworkError)
        , test "DismissAgeGate lowers the age gate" <|
            \_ ->
                let
                    ( model, _, _ ) =
                        ReadingPile.update DismissAgeGate { loadingModel | showAgeGate = True }
                in
                model.showAgeGate
                    |> Expect.equal False
        , test "BookHovered selects the hovered book id" <|
            \_ ->
                let
                    ( model, _, _ ) =
                        ReadingPile.update (BookHovered "book-9") loadingModel
                in
                model.selectedBookId
                    |> Expect.equal (Just "book-9")
        , test "BookClicked on an unselected book selects it rather than navigating" <|
            \_ ->
                let
                    ( model, _, out ) =
                        ReadingPile.update (BookClicked testBook) loadingModel
                in
                ( model.selectedBookId, out )
                    |> Expect.equal ( Just testBook.id, NoOut )
        , test "BookClicked on the already-selected book navigates to its detail" <|
            \_ ->
                let
                    ( _, _, out ) =
                        ReadingPile.update (BookClicked testBook)
                            { loadingModel | selectedBookId = Just testBook.id }
                in
                out
                    |> Expect.equal (NavigateTo (BookDetail testBook.id))
        , test "Deselect clears the selection" <|
            \_ ->
                let
                    ( model, _, _ ) =
                        ReadingPile.update Deselect
                            { loadingModel | selectedBookId = Just "book-9" }
                in
                model.selectedBookId
                    |> Expect.equal Nothing
        ]
