module Components.RemoveBookModal exposing (removeBookModal)

import Html exposing (Html, button, div, h2, p, text)
import Html.Attributes exposing (class)
import Html.Events exposing (onClick)
import Util.TestId exposing (testId)


removeBookModal :
    { bookTitle : String
    , onConfirm : msg
    , onCancel : msg
    }
    -> Html msg
removeBookModal config =
    div [ class "modal-overlay", testId "remove-book-modal" ]
        [ div [ class "modal" ]
            [ h2 [ class "modal__title" ] [ text "Remove Book" ]
            , p [ class "modal__message" ]
                [ text
                    ("Are you sure you want to remove \""
                        ++ config.bookTitle
                        ++ "\" from your collection? This cannot be undone."
                    )
                ]
            , div [ class "modal__actions" ]
                [ button
                    [ class "btn btn--secondary"
                    , onClick config.onCancel
                    ]
                    [ text "Keep It" ]
                , button
                    [ class "btn btn--danger"
                    , testId "remove-book-confirm"
                    , onClick config.onConfirm
                    ]
                    [ text "Remove" ]
                ]
            ]
        ]
