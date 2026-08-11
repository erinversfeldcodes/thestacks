module Animation.Transition exposing (clearOnAnimationEnd, transitionClass)

{-| Picks the CSS animation class for a route change. The three
bookcase bookshelves sit in fixed nav order (Library, AntiLibrary,
WishList); moving between them slides horizontally IN THE DIRECTION OF
TRAVEL — the direction is the spatial information. Everything else
(room pages, unrelated routes) uses the neutral fade.
-}

import Animation.RoomTransition as RoomTransition
import Animation.SlideTransition as SlideTransition
import Navigation.Route exposing (Route(..))


transitionClass : Route -> Route -> String
transitionClass from to =
    case ( bookcasePosition from, bookcasePosition to ) of
        ( Just fromPosition, Just toPosition ) ->
            if toPosition > fromPosition then
                SlideTransition.slideInRight

            else if toPosition < fromPosition then
                SlideTransition.slideInLeft

            else
                RoomTransition.fadeThroughDarkIn

        _ ->
            RoomTransition.fadeThroughDarkIn


{-| Decide what the applied transition class should become when an
`animationend` event arrives naming `animationName`.

The class must be cleared once its animation finishes, so that the _next_
navigation genuinely re-adds it to the DOM and the browser restarts the
animation — a re-render carrying an identical class string does not.

`animationend` bubbles, though, so animations on descendants of
`main.app__main` (book hovers, spine effects) surface here too. Clearing on
those would cut the page transition short. We therefore clear only when the
event names the animation we actually applied, which works because every
transition class name is identical to the `@keyframes` name it triggers.

-}
clearOnAnimationEnd : String -> Maybe String -> Maybe String
clearOnAnimationEnd animationName applied =
    if applied == Just animationName then
        Nothing

    else
        applied


{-| Where a route sits along the bookcase, or `Nothing` if it is not one of the
three adjacent bookshelves.
-}
bookcasePosition : Route -> Maybe Int
bookcasePosition route =
    case route of
        Library ->
            Just 0

        AntiLibrary ->
            Just 1

        WishList ->
            Just 2

        _ ->
            Nothing
