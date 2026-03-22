module Components.VisibilityBadge exposing (view)

import Html exposing (Html, span, text)
import Html.Attributes exposing (class, title)


type alias Visibility =
    String


view : Visibility -> Html msg
view visibility =
    let
        ( icon, tooltip, badgeClass ) =
            case visibility of
                "owner" ->
                    ( "lock", "Only you can see this", "visibility-badge visibility-badge--owner" )

                "group" ->
                    ( "group", "Visible to your groups", "visibility-badge visibility-badge--group" )

                "platform" ->
                    ( "globe", "Visible to everyone on the platform", "visibility-badge visibility-badge--platform" )

                _ ->
                    ( "help", "Unknown visibility", "visibility-badge" )
    in
    span [ class badgeClass, title tooltip ]
        [ text (iconForLevel icon) ]


iconForLevel : String -> String
iconForLevel level =
    case level of
        "lock" ->
            "🔒"

        "group" ->
            "👥"

        "globe" ->
            "🌐"

        _ ->
            "?"
