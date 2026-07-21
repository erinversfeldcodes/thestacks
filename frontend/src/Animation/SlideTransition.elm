module Animation.SlideTransition exposing
    ( slideInLeft
    , slideInRight
    )

{-| CSS class names for the horizontal slide animations.

Each constant is deliberately identical to the `@keyframes` name it triggers in
`frontend/css/main.css`. `Main.elm` clears the transition class when an
`animationend` event reports a matching `animationName`, so the two must not
drift apart.

-}


{-| The incoming page enters from the left — used when navigating _backwards_
along the bookshelf order (WishList -> Library).
-}
slideInLeft : String
slideInLeft =
    "slide-in-left"


{-| The incoming page enters from the right — used when navigating _forwards_
along the bookshelf order (Library -> WishList).
-}
slideInRight : String
slideInRight =
    "slide-in-right"
