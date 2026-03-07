module Components.RemoveBookModal exposing (removeBookModal)

import Html exposing (Html, button, div, h2, p, text)
import Html.Attributes exposing (class)
import Html.Events exposing (onClick)


removeBookModal :
    { bookTitle : String
    , onConfirm : msg
    , onCancel : msg
    }
    -> Html msg
removeBookModal config =
    div [ class "modal-overlay" ]
        [ div [ class "modal" ]
            [ h2 [ class "modal__title" ] [ text "Remove Book" ]
            , p [ class "modal__message" ]
                [ text
                    ("Are you sure you want to remove \""
                        ++ config.bookTitle
                        ++ "\" from your shelf? This cannot be undone."
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
                    , onClick config.onConfirm
                    ]
                    [ text "Remove" ]
                ]
            ]
        ]
