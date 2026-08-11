module Components.WritingAssistant exposing (view)

{-| Under-construction writing-assistant widget.

Honest placeholder — the assistant is not built yet. Two states:

  - consent GRANTED → a "coming soon" placeholder.
  - consent OFF → a prompt to enable the assistant in Settings › Privacy.

Rendered on the blog-post page for the post owner. Purely presentational; it
takes no messages of its own (there is nothing to interact with yet).

-}

import Html exposing (Html, a, div, h3, p, text)
import Html.Attributes exposing (class, href)
import Navigation.Route as Route exposing (Route(..))


view : { hasConsent : Bool } -> Html msg
view { hasConsent } =
    if hasConsent then
        div [ class "writing-assistant writing-assistant--coming-soon" ]
            [ h3 [ class "writing-assistant__title" ]
                [ text "Writing assistant — coming soon" ]
            , p [ class "writing-assistant__body" ]
                [ text
                    "The writing assistant is under construction. Once it launches it will use your shelf and writing history to suggest ideas for this post."
                ]
            ]

    else
        div [ class "writing-assistant writing-assistant--disabled" ]
            [ h3 [ class "writing-assistant__title" ]
                [ text "Writing assistant" ]
            , p [ class "writing-assistant__body" ]
                [ text "Enable the writing assistant to get personalised writing suggestions. "
                , a
                    [ class "writing-assistant__settings-link"
                    , href (Route.toPath SettingsPrivacy)
                    ]
                    [ text "Enable it in Settings › Privacy." ]
                ]
            ]
