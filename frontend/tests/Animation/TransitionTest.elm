module Animation.TransitionTest exposing (suite)

import Animation.RoomTransition as RoomTransition
import Animation.SlideTransition as SlideTransition
import Animation.Transition exposing (transitionClass)
import Expect
import Navigation.Route exposing (Route(..))
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Animation.Transition.transitionClass"
        [ test "entering a book detail slides in from the right" <|
            \_ ->
                transitionClass Library (BookDetail "book-1")
                    |> Expect.equal SlideTransition.slideInRight
        , test "leaving a book detail slides out to the right" <|
            \_ ->
                transitionClass (BookDetail "book-1") Library
                    |> Expect.equal SlideTransition.slideOutRight
        , test "book detail to book detail slides in (entry wins)" <|
            \_ ->
                transitionClass (BookDetail "book-1") (BookDetail "book-2")
                    |> Expect.equal SlideTransition.slideInRight
        , test "any other route change fades through dark" <|
            \_ ->
                transitionClass Library ReadingPile
                    |> Expect.equal RoomTransition.fadeThroughDarkIn
        , test "navigating to the same non-detail route still fades through dark" <|
            \_ ->
                transitionClass Home Home
                    |> Expect.equal RoomTransition.fadeThroughDarkIn
        ]
