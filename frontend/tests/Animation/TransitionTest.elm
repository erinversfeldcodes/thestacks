module Animation.TransitionTest exposing (suite)

{-| US-1.2.5 — bookshelf navigation transitions (issue #277, punch #9).

The three bookcase bookshelves are ordered as the nav renders them
(`Main.elm:2594-2598`): Library, AntiLibrary, WishList. Navigating _along_ that
order slides horizontally, in the direction of travel. Navigating into or out of
a room page (Reading Pile, Looking for a Home) fades through darkness.

Note what these tests can and cannot prove. They pin the _class selection_ only.
They cannot see `main.css`, so they cannot detect the original defect that the
selected class had an empty CSS rule (`animation-name: none`). That half of the
story is pinned by `e2e/tests/shelf-transitions.spec.ts`, which asserts the
_computed_ animation values in a real browser.

-}

import Animation.RoomTransition as RoomTransition
import Animation.SlideTransition as SlideTransition
import Animation.Transition exposing (clearOnAnimationEnd, transitionClass)
import Expect
import Navigation.Route exposing (Route(..))
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Animation.Transition"
        [ transitionClassSuite
        , clearOnAnimationEndSuite
        ]


clearOnAnimationEndSuite : Test
clearOnAnimationEndSuite =
    describe "clearOnAnimationEnd"
        [ test "clears the class when its own animation finishes" <|
            \_ ->
                Just SlideTransition.slideInRight
                    |> clearOnAnimationEnd SlideTransition.slideInRight
                    |> Expect.equal Nothing
        , test "clears the fade when the fade finishes" <|
            \_ ->
                Just RoomTransition.fadeThroughDarkIn
                    |> clearOnAnimationEnd RoomTransition.fadeThroughDarkIn
                    |> Expect.equal Nothing
        , test "ignores a bubbled animationend from a descendant" <|
            \_ ->
                Just SlideTransition.slideInRight
                    |> clearOnAnimationEnd "book-hover-lift"
                    |> Expect.equal (Just SlideTransition.slideInRight)
        , test "ignores the wrong transition animation" <|
            \_ ->
                Just SlideTransition.slideInLeft
                    |> clearOnAnimationEnd SlideTransition.slideInRight
                    |> Expect.equal (Just SlideTransition.slideInLeft)
        , test "is a no-op when no transition is applied" <|
            \_ ->
                Nothing
                    |> clearOnAnimationEnd SlideTransition.slideInRight
                    |> Expect.equal Nothing
        , test "a repeat navigation re-triggers because the class is cleared in between" <|
            \_ ->
                let
                    firstNavigation =
                        Just (transitionClass Library AntiLibrary)

                    afterAnimation =
                        clearOnAnimationEnd (transitionClass Library AntiLibrary)
                            firstNavigation

                    secondNavigation =
                        Just (transitionClass Library AntiLibrary)
                in
                ( afterAnimation, secondNavigation )
                    |> Expect.equal ( Nothing, Just SlideTransition.slideInRight )
        ]


transitionClassSuite : Test
transitionClassSuite =
    describe "transitionClass"
        [ describe "adjacent bookshelves slide, in the direction of travel"
            [ test "Library -> AntiLibrary moves right, so the new shelf enters from the right" <|
                \_ ->
                    transitionClass Library AntiLibrary
                        |> Expect.equal SlideTransition.slideInRight
            , test "Library -> WishList moves right" <|
                \_ ->
                    transitionClass Library WishList
                        |> Expect.equal SlideTransition.slideInRight
            , test "AntiLibrary -> WishList moves right" <|
                \_ ->
                    transitionClass AntiLibrary WishList
                        |> Expect.equal SlideTransition.slideInRight
            , test "AntiLibrary -> Library moves left, so the new shelf enters from the left" <|
                \_ ->
                    transitionClass AntiLibrary Library
                        |> Expect.equal SlideTransition.slideInLeft
            , test "WishList -> Library moves left" <|
                \_ ->
                    transitionClass WishList Library
                        |> Expect.equal SlideTransition.slideInLeft
            , test "WishList -> AntiLibrary moves left" <|
                \_ ->
                    transitionClass WishList AntiLibrary
                        |> Expect.equal SlideTransition.slideInLeft
            , test "the slide is directional — the reverse trip is not the same class" <|
                \_ ->
                    transitionClass Library WishList
                        |> Expect.notEqual (transitionClass WishList Library)
            ]
        , describe "room pages fade through darkness in both directions"
            [ test "Library -> ReadingPile fades" <|
                \_ ->
                    transitionClass Library ReadingPile
                        |> Expect.equal RoomTransition.fadeThroughDarkIn
            , test "ReadingPile -> Library fades" <|
                \_ ->
                    transitionClass ReadingPile Library
                        |> Expect.equal RoomTransition.fadeThroughDarkIn
            , test "WishList -> LookingForHome fades" <|
                \_ ->
                    transitionClass WishList LookingForHome
                        |> Expect.equal RoomTransition.fadeThroughDarkIn
            , test "LookingForHome -> AntiLibrary fades" <|
                \_ ->
                    transitionClass LookingForHome AntiLibrary
                        |> Expect.equal RoomTransition.fadeThroughDarkIn
            , test "room to room fades" <|
                \_ ->
                    transitionClass ReadingPile LookingForHome
                        |> Expect.equal RoomTransition.fadeThroughDarkIn
            ]
        , describe "a slide and a fade are distinguishable"
            [ test "an adjacent move and a room move do not yield the same class" <|
                \_ ->
                    transitionClass Library AntiLibrary
                        |> Expect.notEqual (transitionClass Library ReadingPile)
            ]
        , describe "everything else falls through to the fade"
            [ test "navigating to the same bookshelf has no direction, so it fades" <|
                \_ ->
                    transitionClass Library Library
                        |> Expect.equal RoomTransition.fadeThroughDarkIn
            , test "navigating to the same non-bookshelf route fades" <|
                \_ ->
                    transitionClass Home Home
                        |> Expect.equal RoomTransition.fadeThroughDarkIn
            , test "a non-bookshelf route fades" <|
                \_ ->
                    transitionClass Library Search
                        |> Expect.equal RoomTransition.fadeThroughDarkIn
            , test "BookDetail is an overlay (ADR-005), never a UrlChanged route, so it fades" <|
                \_ ->
                    transitionClass Library (BookDetail "book-1")
                        |> Expect.equal RoomTransition.fadeThroughDarkIn
            ]
        ]
