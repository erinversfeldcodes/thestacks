module Page.Bookshelf.Helpers exposing
    ( groupIntoRows
    , pickTexture
    , viewShelfLabel
    , viewShelfRow
    , viewSpine
    )

import Components.Spine exposing (SpineTexture(..), WearLevel(..), spine)
import Html exposing (Html, div, span, text)
import Html.Attributes exposing (attribute, class)
import Types.Book
import Types.Placement exposing (Placement)


{-| Pick a texture deterministically from the title.
-}
pickTexture : String -> SpineTexture
pickTexture s =
    let
        hash =
            List.foldl (\c acc -> acc + Char.toCode c) 0 (String.toList s)
    in
    if modBy 3 hash == 0 then
        Leather

    else
        Cloth


{-| Split a list into sublists of at most n elements.
-}
groupIntoRows : Int -> List a -> List (List a)
groupIntoRows n items =
    if List.isEmpty items then
        []

    else
        List.take n items :: groupIntoRows n (List.drop n items)


{-| Render a shelf label with an aria-label for accessibility.
-}
viewShelfLabel : String -> Html msg
viewShelfLabel label =
    div [ class "shelf-label", attribute "aria-label" label ]
        [ div [ class "shelf-label__plate" ]
            [ span [ class "shelf-label__text" ] [ text label ] ]
        ]


{-| Render a single shelf row with role="list" for accessibility.
-}
viewShelfRow : WearLevel -> List Placement -> Html msg
viewShelfRow wearLevel placements =
    div [ class "bookshelf__shelf" ]
        [ div [ class "bookshelf__back-panel" ] []
        , div [ class "bookshelf__row", attribute "role" "list" ]
            (List.map (viewSpine wearLevel) placements)
        , div [ class "bookshelf__plank" ]
            [ div [ class "bookshelf__plank-front" ] []
            , div [ class "bookshelf__plank-edge" ] []
            ]
        ]


{-| Render a book spine with role="listitem" for accessibility.
-}
viewSpine : WearLevel -> Placement -> Html msg
viewSpine wearLevel placement =
    let
        ( bookTitle, author, pageCount ) =
            case placement.book of
                Just book ->
                    ( book.title, Types.Book.authorName book, Maybe.withDefault 200 book.pageCount )

                Nothing ->
                    ( "Unknown Title", "Unknown Author", 200 )

        texture =
            pickTexture bookTitle
    in
    div [ class "bookshelf__book", attribute "role" "listitem" ]
        [ spine
            { pageCount = pageCount
            , wearLevel = wearLevel
            , texture = texture
            , title = bookTitle
            , author = author
            }
        ]
