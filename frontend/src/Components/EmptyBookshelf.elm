module Components.EmptyBookshelf exposing (emptyBookshelf)

import Html exposing (Html, div, p, text)
import Html.Attributes exposing (class)


emptyBookshelf : { bookshelf : String, message : String } -> Html msg
emptyBookshelf config =
    let
        shelfClass =
            "empty-shelf--" ++ String.replace "_" "-" config.bookshelf
    in
    div [ class ("empty-shelf " ++ shelfClass) ]
        [ div [ class "empty-shelf__scene" ]
            [ div [ class "empty-shelf__shelf-unit" ]
                [ div [ class "empty-shelf__shelf-plank" ] []
                , div [ class "empty-shelf__dust-motes" ] []
                ]
            ]
        , p [ class "empty-shelf__message" ] [ text config.message ]
        , p [ class "empty-shelf__hint" ] [ text (hintText config.bookshelf) ]
        ]


hintText : String -> String
hintText bookshelf =
    case bookshelf of
        "library" ->
            "A subtle outline of a book spine suggests where books will appear."

        "antilibrary" ->
            "Add a Book"

        "wishlist" ->
            ""

        "reading_pile" ->
            ""

        _ ->
            ""
