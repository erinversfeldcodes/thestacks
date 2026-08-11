module Page.Settings exposing (view)

import Html exposing (Html, a, div, h1, h2, li, nav, text, ul)
import Html.Attributes exposing (attribute, class, href)
import Navigation.Route as Route exposing (Route(..))
import Util.TestId exposing (testId)


type alias Config msg =
    { currentRoute : Route
    , content : Html msg
    }


view : Config msg -> Html msg
view config =
    div [ class "page page--settings settings-hub", testId "settings-hub" ]
        [ h1 [ class "page__title" ] [ text "Settings" ]
        , div [ class "settings-hub__layout" ]
            [ viewNav config.currentRoute
            , div [ class "settings-hub__content" ]
                [ config.content ]
            ]
        ]


{-| ONE nav idiom for every viewport (TR-4): a grouped list of links that
reflows from a left-hand sidebar to a stacked, wrapping row at the 768px
breakpoint via CSS — the CSS-less mobile `<select>` is gone. The current
sub-page is marked with `aria-current="page"`, which both announces "you are
here" to assistive tech and drives the active styling (`[aria-current="page"]`),
so there is a single source of truth for the active state.
-}
viewNav : Route -> Html msg
viewNav currentRoute =
    nav [ class "settings-hub__nav", testId "settings-sidebar" ]
        (List.map (viewGroup currentRoute) navGroups)


type alias NavGroup =
    { heading : String
    , items : List SidebarItem
    }


type alias SidebarItem =
    { route : Route
    , label : String
    , path : String
    }


item : Route -> String -> SidebarItem
item route label =
    { route = route, label = label, path = Route.toPath route }


{-| The settings destinations grouped into the three families the IA now speaks
in: who you are, your privacy (visibility + consent, since the consent page
folded into Privacy), and the record of your data.
-}
navGroups : List NavGroup
navGroups =
    [ { heading = "You"
      , items =
            [ item SettingsProfile "Profile"
            , item SettingsPassword "Password"
            , item SettingsNotifications "Notifications"
            ]
      }
    , { heading = "Privacy"
      , items =
            [ item SettingsPrivacy "Privacy & consent" ]
      }
    , { heading = "Your data"
      , items =
            [ item SettingsAuditLog "Audit Log"
            , item Insights "Your Data Insights"
            ]
      }
    ]


viewGroup : Route -> NavGroup -> Html msg
viewGroup currentRoute group =
    div [ class "settings-hub__group" ]
        [ h2 [ class "settings-hub__group-heading" ] [ text group.heading ]
        , ul [ class "settings-hub__nav-list" ]
            (List.map (viewSidebarItem currentRoute) group.items)
        ]


viewSidebarItem : Route -> SidebarItem -> Html msg
viewSidebarItem currentRoute navItem =
    let
        isActive =
            currentRoute == navItem.route

        currentAttrs =
            if isActive then
                [ attribute "aria-current" "page" ]

            else
                []
    in
    li [ class "settings-hub__nav-item" ]
        [ a
            (href navItem.path
                :: class "settings-hub__nav-link"
                :: currentAttrs
            )
            [ text navItem.label ]
        ]
