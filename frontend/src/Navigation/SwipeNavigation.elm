module Navigation.SwipeNavigation exposing
    ( swipeLeft
    , swipeRight
    )

import Navigation.Route exposing (Route(..))


bookshelfRoutes : List Route
bookshelfRoutes =
    [ Library
    , AntiLibrary
    , WishList
    , ReadingPile
    , LookingForHome
    ]


swipeLeft : Route -> Maybe Route
swipeLeft currentRoute =
    swipeRoute "left" currentRoute


swipeRight : Route -> Maybe Route
swipeRight currentRoute =
    swipeRoute "right" currentRoute


swipeRoute : String -> Route -> Maybe Route
swipeRoute direction currentRoute =
    let
        maybeIndex =
            findIndex currentRoute bookshelfRoutes 0

        len =
            List.length bookshelfRoutes
    in
    case maybeIndex of
        Nothing ->
            Nothing

        Just idx ->
            let
                nextIdx =
                    if direction == "left" then
                        modBy len (idx + 1)

                    else
                        modBy len (idx - 1 + len)
            in
            getAt nextIdx bookshelfRoutes


findIndex : Route -> List Route -> Int -> Maybe Int
findIndex target routes idx =
    case routes of
        [] ->
            Nothing

        first :: rest ->
            if first == target then
                Just idx

            else
                findIndex target rest (idx + 1)


getAt : Int -> List Route -> Maybe Route
getAt idx routes =
    case routes of
        [] ->
            Nothing

        first :: rest ->
            if idx == 0 then
                Just first

            else
                getAt (idx - 1) rest
