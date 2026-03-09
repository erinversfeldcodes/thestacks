module SwipeTest exposing (..)

import Expect
import Navigation.Route exposing (Route(..))
import Navigation.SwipeNavigation exposing (swipeLeft, swipeRight)
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "SwipeNavigation"
        [ describe "swipeLeft (forward through bookshelves)"
            [ test "Library -> AntiLibrary" <|
                \_ ->
                    swipeLeft Library
                        |> Expect.equal (Just AntiLibrary)
            , test "AntiLibrary -> WishList" <|
                \_ ->
                    swipeLeft AntiLibrary
                        |> Expect.equal (Just WishList)
            , test "WishList -> ReadingPile" <|
                \_ ->
                    swipeLeft WishList
                        |> Expect.equal (Just ReadingPile)
            , test "ReadingPile -> LookingForHome" <|
                \_ ->
                    swipeLeft ReadingPile
                        |> Expect.equal (Just LookingForHome)
            , test "LookingForHome -> Library (wrap-around)" <|
                \_ ->
                    swipeLeft LookingForHome
                        |> Expect.equal (Just Library)
            ]
        , describe "swipeRight (backward through bookshelves)"
            [ test "Library -> LookingForHome (wrap-around)" <|
                \_ ->
                    swipeRight Library
                        |> Expect.equal (Just LookingForHome)
            , test "LookingForHome -> ReadingPile" <|
                \_ ->
                    swipeRight LookingForHome
                        |> Expect.equal (Just ReadingPile)
            , test "ReadingPile -> WishList" <|
                \_ ->
                    swipeRight ReadingPile
                        |> Expect.equal (Just WishList)
            , test "WishList -> AntiLibrary" <|
                \_ ->
                    swipeRight WishList
                        |> Expect.equal (Just AntiLibrary)
            , test "AntiLibrary -> Library" <|
                \_ ->
                    swipeRight AntiLibrary
                        |> Expect.equal (Just Library)
            ]
        , describe "non-bookshelf routes return Nothing"
            [ test "swipeLeft from Search -> Nothing" <|
                \_ ->
                    swipeLeft Search
                        |> Expect.equal Nothing
            , test "swipeLeft from Upload -> Nothing" <|
                \_ ->
                    swipeLeft Upload
                        |> Expect.equal Nothing
            , test "swipeRight from Upload -> Nothing" <|
                \_ ->
                    swipeRight Upload
                        |> Expect.equal Nothing
            , test "swipeRight from Search -> Nothing" <|
                \_ ->
                    swipeRight Search
                        |> Expect.equal Nothing
            , test "swipeLeft from BookDetail -> Nothing" <|
                \_ ->
                    swipeLeft (BookDetail "abc")
                        |> Expect.equal Nothing
            , test "swipeLeft from Home -> Nothing" <|
                \_ ->
                    swipeLeft Home
                        |> Expect.equal Nothing
            ]
        , describe "full swipe-left cycle"
            [ test "5 left swipes from Library returns to Library" <|
                \_ ->
                    let
                        step maybeRoute =
                            Maybe.andThen swipeLeft maybeRoute

                        result =
                            step (Just Library)
                                |> step
                                |> step
                                |> step
                                |> step
                    in
                    Expect.equal (Just Library) result
            ]
        , describe "full swipe-right cycle"
            [ test "5 right swipes from Library returns to Library" <|
                \_ ->
                    let
                        step maybeRoute =
                            Maybe.andThen swipeRight maybeRoute

                        result =
                            step (Just Library)
                                |> step
                                |> step
                                |> step
                                |> step
                    in
                    Expect.equal (Just Library) result
            ]
        ]
