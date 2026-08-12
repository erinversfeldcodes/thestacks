module String.Extra exposing (isCapitalized)

{-| Some utilities.
-}


{-| Check if the first character of a string is upper case, unicode aware.

Note that `Char.isUpper` returns the correct result only for ASCII characters, even though it can be called with any Unicode character.
See <https://github.com/elm/core/pull/1138>

-}
isCapitalized : String -> Bool
isCapitalized string =
    case String.uncons string of
        Just ( char, _ ) ->
            (char == Char.toUpper char)
                && (char /= Char.toLower char)

        Nothing ->
            False
