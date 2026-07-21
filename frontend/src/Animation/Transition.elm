module Animation.Transition exposing (transitionClass)

{-| Picks the CSS animation class for a route change.

Book detail is an overlay slid in over the page beneath it (see
`docs/decisions/005-book-detail-overlay-not-route.md`), so entering or leaving
it slides horizontally; every other move between metaphors fades through dark.

-}

import Animation.RoomTransition as RoomTransition
import Animation.SlideTransition as SlideTransition
import Navigation.Route exposing (Route(..))


transitionClass : Route -> Route -> String
transitionClass from to =
    case ( from, to ) of
        ( _, BookDetail _ ) ->
            SlideTransition.slideInRight

        ( BookDetail _, _ ) ->
            SlideTransition.slideOutRight

        _ ->
            RoomTransition.fadeThroughDarkIn
