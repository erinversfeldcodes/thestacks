module Types.Bookshelf exposing
    ( Bookshelf(..)
    , bookshelfFromString
    , bookshelfToString
    )


type Bookshelf
    = Library
    | AntiLibrary
    | WishList
    | ReadingPile
    | LookingForHome


bookshelfFromString : String -> Maybe Bookshelf
bookshelfFromString s =
    case s of
        "library" ->
            Just Library

        "antilibrary" ->
            Just AntiLibrary

        "wishlist" ->
            Just WishList

        "reading_pile" ->
            Just ReadingPile

        "looking_for_home" ->
            Just LookingForHome

        _ ->
            Nothing


bookshelfToString : Bookshelf -> String
bookshelfToString bookshelf =
    case bookshelf of
        Library ->
            "library"

        AntiLibrary ->
            "antilibrary"

        WishList ->
            "wishlist"

        ReadingPile ->
            "reading_pile"

        LookingForHome ->
            "looking_for_home"
