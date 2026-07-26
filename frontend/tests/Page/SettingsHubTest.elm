module Page.SettingsHubTest exposing (suite)

{-| #126 punch 13 — the `Page.Settings` hub shell.

`Page.Settings.view` is a stateless layout parameterised by the parent's `msg`:
it renders the sidebar (seven links), marks exactly the current route active, and
renders a mobile `<select>` whose `onInput` is wired to the parent-provided
`onMobileNavChange`. These tests pin the seven-item roster, the active-class
selection, and the mobile-nav intent produced when the select changes.

-}

import Expect
import Html
import Html.Attributes
import Navigation.Route as Route exposing (Route(..))
import Page.Settings as Settings
import Test exposing (Test, describe, test)
import Test.Html.Event as Event
import Test.Html.Query as Query
import Test.Html.Selector as Selector


{-| The parent's message type, produced only through `onMobileNavChange`.
-}
type Msg
    = MobileNav String


{-| Render the hub for the given active route. `content` is inert here — these
tests only exercise the sidebar and mobile-nav chrome, not the slotted page.
-}
viewFor : Route -> Query.Single Msg
viewFor route =
    Settings.view
        { currentRoute = route
        , content = Html.text ""
        , onMobileNavChange = MobileNav
        }
        |> Query.fromHtml


{-| The seven hub destinations, in sidebar order, with their canonical paths.
-}
expectedItems : List ( String, String )
expectedItems =
    [ ( "Profile", Route.toPath SettingsProfile )
    , ( "Password", Route.toPath SettingsPassword )
    , ( "Notifications", Route.toPath SettingsNotifications )
    , ( "Consent", Route.toPath SettingsConsent )
    , ( "Privacy", Route.toPath SettingsPrivacy )
    , ( "Audit Log", Route.toPath SettingsAuditLog )
    , ( "Your Data Insights", Route.toPath Insights )
    ]


suite : Test
suite =
    describe "Page.Settings — hub shell (#126 punch 13)"
        [ describe "sidebar roster"
            [ test "renders exactly seven nav links" <|
                \_ ->
                    viewFor SettingsProfile
                        |> Query.findAll [ Selector.class "settings-hub__nav-link" ]
                        |> Query.count (Expect.equal 7)
            , test "renders each of the seven labels" <|
                \_ ->
                    viewFor SettingsProfile
                        |> (\hub ->
                                Expect.all
                                    (List.map
                                        (\( label, _ ) ->
                                            \_ -> hub |> Query.has [ Selector.text label ]
                                        )
                                        expectedItems
                                    )
                                    ()
                           )
            , test "each nav link points at its route's canonical path" <|
                \_ ->
                    viewFor SettingsProfile
                        |> (\hub ->
                                Expect.all
                                    (List.map
                                        (\( _, path ) ->
                                            \_ ->
                                                hub
                                                    |> Query.has
                                                        [ Selector.tag "a"
                                                        , Selector.attribute (Html.Attributes.href path)
                                                        ]
                                        )
                                        expectedItems
                                    )
                                    ()
                           )
            ]
        , describe "active-item selection"
            [ test "marks exactly one nav item active for the current route" <|
                \_ ->
                    viewFor SettingsPassword
                        |> Query.findAll [ Selector.class "settings-hub__nav-item--active" ]
                        |> Query.count (Expect.equal 1)
            , test "the active item is the one for the current route" <|
                \_ ->
                    viewFor SettingsNotifications
                        |> Query.find [ Selector.class "settings-hub__nav-item--active" ]
                        |> Query.has [ Selector.text "Notifications" ]
            , test "the active class follows the current route" <|
                \_ ->
                    -- A different route moves the active marker off Notifications.
                    viewFor SettingsConsent
                        |> Query.find [ Selector.class "settings-hub__nav-item--active" ]
                        |> Query.hasNot [ Selector.text "Notifications" ]
            ]
        , describe "mobile nav select"
            [ test "renders all seven options" <|
                \_ ->
                    viewFor SettingsProfile
                        |> Query.find [ Selector.class "settings-hub__mobile-select" ]
                        |> Query.findAll [ Selector.tag "option" ]
                        |> Query.count (Expect.equal 7)
            , test "changing the select produces the navigation intent for the chosen path" <|
                \_ ->
                    viewFor SettingsProfile
                        |> Query.find [ Selector.class "settings-hub__mobile-select" ]
                        |> Event.simulate (Event.input (Route.toPath SettingsAuditLog))
                        |> Event.toResult
                        |> Result.map (\(MobileNav path) -> path)
                        |> Expect.equal (Ok "/settings/audit-log")
            ]
        ]
