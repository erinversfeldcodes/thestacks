module Components.AbandonModal exposing (abandonModal)

import Html exposing (Html, button, div, h2, p, text)
import Html.Attributes exposing (class)
import Html.Events exposing (onClick)


abandonModal :
    { title : String
    , message : String
    , onConfirm : msg
    , onCancel : msg
    }
    -> Html msg
abandonModal config =
    div [ class "modal-overlay" ]
        [ div [ class "modal" ]
            [ h2 [ class "modal__title" ] [ text config.title ]
            , p [ class "modal__message" ] [ text config.message ]
            , div [ class "modal__actions" ]
                [ button
                    [ class "btn btn--secondary"
                    , onClick config.onCancel
                    ]
                    [ text "Cancel" ]
                , button
                    [ class "btn btn--danger"
                    , onClick config.onConfirm
                    ]
                    [ text "Confirm" ]
                ]
            ]
        ]
