module Components.ConsentBanner exposing (consentBanner)

import Html exposing (Html, a, button, div, p, text)
import Html.Attributes exposing (class, href)
import Html.Events exposing (onClick)


consentBanner :
    { onAccept : msg
    , onManage : msg
    }
    -> Html msg
consentBanner config =
    div [ class "consent-banner" ]
        [ p [ class "consent-banner__text" ]
            [ text "We use minimal analytics to improve your experience. "
            , a [ href "/settings/consent", class "consent-banner__link" ]
                [ text "Manage preferences" ]
            , text "."
            ]
        , div [ class "consent-banner__actions" ]
            [ button
                [ class "btn btn--secondary btn--sm"
                , onClick config.onManage
                ]
                [ text "Manage" ]
            , button
                [ class "btn btn--primary btn--sm"
                , onClick config.onAccept
                ]
                [ text "Accept" ]
            ]
        ]
