module Page.Settings exposing (view)

import Html exposing (Html, a, div, h1, li, nav, option, select, text, ul)
import Html.Attributes exposing (class, href, selected, value)
import Html.Events exposing (onInput)
import Navigation.Route as Route exposing (Route(..))
import Util.TestId exposing (testId)


type alias Config msg =
    { currentRoute : Route
    , content : Html msg
    , onMobileNavChange : String -> msg
    }


view : Config msg -> Html msg
view config =
    div [ class "page page--settings settings-hub", testId "settings-hub" ]
        [ h1 [ class "page__title" ] [ text "Settings" ]
        , div [ class "settings-hub__layout" ]
            [ viewSidebar config
            , viewMobileNav config
            , div [ class "settings-hub__content" ]
                [ config.content ]
            ]
        ]


viewSidebar : Config msg -> Html msg
viewSidebar config =
    nav [ class "settings-hub__sidebar", testId "settings-sidebar" ]
        [ ul [ class "settings-hub__nav" ]
            (List.map (viewSidebarItem config.currentRoute) sidebarItems)
        ]


viewMobileNav : Config msg -> Html msg
viewMobileNav config =
    div [ class "settings-hub__mobile-nav" ]
        [ select
            [ class "settings-hub__mobile-select"
            , onInput config.onMobileNavChange
            ]
            (List.map (viewMobileOption config.currentRoute) sidebarItems)
        ]


type alias SidebarItem =
    { route : Route
    , label : String
    , path : String
    }


sidebarItems : List SidebarItem
sidebarItems =
    [ { route = SettingsProfile, label = "Profile", path = Route.toPath SettingsProfile }
    , { route = SettingsPassword, label = "Password", path = Route.toPath SettingsPassword }
    , { route = SettingsNotifications, label = "Notifications", path = Route.toPath SettingsNotifications }
    , { route = SettingsConsent, label = "Consent", path = Route.toPath SettingsConsent }
    , { route = SettingsAgeVerification, label = "Age Verification", path = Route.toPath SettingsAgeVerification }
    , { route = SettingsPrivacy, label = "Privacy", path = Route.toPath SettingsPrivacy }
    ]


viewSidebarItem : Route -> SidebarItem -> Html msg
viewSidebarItem currentRoute item =
    let
        isActive =
            currentRoute == item.route

        activeClass =
            if isActive then
                "settings-hub__nav-item settings-hub__nav-item--active"

            else
                "settings-hub__nav-item"
    in
    li [ class activeClass ]
        [ a [ href item.path, class "settings-hub__nav-link" ]
            [ text item.label ]
        ]


viewMobileOption : Route -> SidebarItem -> Html msg
viewMobileOption currentRoute item =
    option
        [ value item.path
        , selected (currentRoute == item.route)
        ]
        [ text item.label ]
