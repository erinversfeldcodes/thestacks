module Page.SettingsHubTest exposing (suite)

{-| The `Page.Settings` hub shell, restyled for #318 TR-4.

`Page.Settings.view` is a stateless layout parameterised by the parent's `msg`.
Since TR-4 it renders ONE grouped nav (no mobile `<select>`): entries are
gathered under the "You" / "Privacy" / "Your data" headings, and the current
sub-page is marked with `aria-current="page"` — the semantic current-page
treatment that both announces "you are here" and drives the active styling.

These tests pin the grouping, the six-item roster (Consent folded into Privacy),
and the active-state semantics. Two of them are ORACLES for the redesign: they
fail against the old flat, un-grouped, `aria-current`-less nav.

-}

import Expect
import Html
import Html.Attributes
import Navigation.Route as Route exposing (Route(..))
import Page.Settings as Settings
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector


{-| The hub emits no messages of its own (the mobile-select `onInput` is gone),
so `()` stands in for the parent's message type.
-}
viewFor : Route -> Query.Single ()
viewFor route =
    Settings.view
        { currentRoute = route
        , content = Html.text ""
        }
        |> Query.fromHtml


{-| The three IA groups, in sidebar order, and their headings.
-}
expectedGroups : List String
expectedGroups =
    [ "You", "Privacy", "Your data" ]


{-| The six hub destinations (Consent folded into Privacy), with canonical paths.
-}
expectedItems : List ( String, String )
expectedItems =
    [ ( "Profile", Route.toPath SettingsProfile )
    , ( "Password", Route.toPath SettingsPassword )
    , ( "Notifications", Route.toPath SettingsNotifications )
    , ( "Privacy & consent", Route.toPath SettingsPrivacy )
    , ( "Audit Log", Route.toPath SettingsAuditLog )
    , ( "Your Data Insights", Route.toPath Insights )
    ]


ariaCurrentPage : Selector.Selector
ariaCurrentPage =
    Selector.attribute (Html.Attributes.attribute "aria-current" "page")


suite : Test
suite =
    describe "Page.Settings — hub shell (#318 TR-4)"
        [ describe "grouped nav (ORACLE: fails on the old flat nav)"
            [ test "renders the three IA group headings" <|
                \_ ->
                    viewFor SettingsProfile
                        |> (\hub ->
                                Expect.all
                                    (List.map
                                        (\heading ->
                                            \_ ->
                                                hub
                                                    |> Query.has
                                                        [ Selector.class "settings-hub__group-heading"
                                                        , Selector.text heading
                                                        ]
                                        )
                                        expectedGroups
                                    )
                                    ()
                           )
            , test "renders exactly three groups" <|
                \_ ->
                    viewFor SettingsProfile
                        |> Query.findAll [ Selector.class "settings-hub__group" ]
                        |> Query.count (Expect.equal 3)
            ]
        , describe "sidebar roster"
            [ test "renders exactly six nav links" <|
                \_ ->
                    viewFor SettingsProfile
                        |> Query.findAll [ Selector.class "settings-hub__nav-link" ]
                        |> Query.count (Expect.equal 6)
            , test "renders each of the six labels" <|
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
        , describe "active-item selection via aria-current (ORACLE: the old nav set no aria-current)"
            [ test "marks exactly one link as the current page" <|
                \_ ->
                    viewFor SettingsPassword
                        |> Query.findAll [ ariaCurrentPage ]
                        |> Query.count (Expect.equal 1)
            , test "the current-page link is the one for the current route" <|
                \_ ->
                    viewFor SettingsNotifications
                        |> Query.find [ ariaCurrentPage ]
                        |> Query.has [ Selector.text "Notifications" ]
            , test "the current-page marker follows the current route" <|
                \_ ->
                    -- A different route moves aria-current off Notifications.
                    viewFor SettingsPrivacy
                        |> Query.find [ ariaCurrentPage ]
                        |> Query.hasNot [ Selector.text "Notifications" ]
            , test "the Privacy link is current on the Privacy route" <|
                \_ ->
                    viewFor SettingsPrivacy
                        |> Query.find [ ariaCurrentPage ]
                        |> Query.has [ Selector.text "Privacy & consent" ]
            ]
        ]
