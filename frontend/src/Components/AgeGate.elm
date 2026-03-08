module Components.AgeGate exposing (ageGate)

import Html exposing (Html, button, div, h2, p, text)
import Html.Attributes exposing (class)
import Html.Events exposing (onClick)


ageGate : { onVerify : msg, onDismiss : msg } -> Html msg
ageGate config =
    div [ class "age-gate" ]
        [ div [ class "age-gate__content" ]
            [ h2 [ class "age-gate__heading" ] [ text "Age Verification Required" ]
            , p [ class "age-gate__message" ]
                [ text "This content is restricted to verified adults. Please confirm your age to continue." ]
            , div [ class "age-gate__actions" ]
                [ button
                    [ class "btn btn--primary"
                    , onClick config.onVerify
                    ]
                    [ text "Verify Age" ]
                , button
                    [ class "btn btn--secondary"
                    , onClick config.onDismiss
                    ]
                    [ text "Go Back" ]
                ]
            ]
        ]
