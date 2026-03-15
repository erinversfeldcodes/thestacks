module Components.BookDetailOverlay exposing (viewBookDetailOverlay)

{-| Shared book detail overlay component.

Renders a modal overlay with book title, author, and a close button.
Used across all shelf pages (Library, AntiLibrary, WishList, ReadingPile).

-}

import Html exposing (Html, button, div, h2, p, text)
import Html.Attributes exposing (attribute, class)
import Html.Events exposing (onClick)
import Types.Book exposing (Book)


{-| Render a book detail overlay with dialog semantics.
Returns empty text when no book is selected.
-}
viewBookDetailOverlay : { onClose : msg } -> Maybe Book -> Html msg
viewBookDetailOverlay config maybeBook =
    case maybeBook of
        Nothing ->
            text ""

        Just bk ->
            div [ class "book-detail" ]
                [ div [ class "book-detail__backdrop", onClick config.onClose ] []
                , div
                    [ class "book-detail__content"
                    , attribute "role" "dialog"
                    , attribute "aria-modal" "true"
                    ]
                    [ h2 [ class "book-detail__title" ] [ text bk.title ]
                    , p [ class "book-detail__author" ] [ text (Types.Book.authorName bk) ]
                    , button [ class "book-detail__close", onClick config.onClose ] [ text "Close" ]
                    ]
                ]
