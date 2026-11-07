module UserMenuTest exposing (suite)

{-| Unit tests for Components.UserMenu — the authenticated account dropdown.

Covers Toggle (open/close), Close, SignOutClicked → SignOut OutMsg,
NavigateClicked → NavigateTo OutMsg, and the rendered dropdown contents (the
settings family + Sign Out, TR-1). The Main.elm SignOut wiring (auth
cleared, clearAuth port, navigate to /login) and the non-blocking logout result
no-op (FocusResult) are exercised at the Main level, which cannot be
unit-tested here because it owns a Browser.Navigation.Key.

-}

import Components.UserMenu as UserMenu exposing (Msg(..), OutMsg(..))
import Expect
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Types.User exposing (User)


testUser : User
testUser =
    { id = "user-1"
    , email = "reader@stacks.dev"
    , displayName = "A Reader"
    , handle = "a_reader"
    , role = "user"
    , countryCode = Nothing
    , city = Nothing
    , consentAnalytics = False
    , consentWritingAssistant = False
    }


{-| A representative settings family, the way Main passes it in.
-}
sampleLinks : List UserMenu.SettingsLink
sampleLinks =
    [ { label = "Profile", path = "/settings/profile" }
    , { label = "Privacy", path = "/settings/privacy" }
    , { label = "Notifications", path = "/settings/notifications" }
    ]


openMenu : UserMenu.Model
openMenu =
    Tuple.first (UserMenu.update Toggle UserMenu.init)


suite : Test
suite =
    describe "Components.UserMenu"
        [ describe "Toggle"
            [ test "Toggle from closed opens the menu" <|
                \() ->
                    openMenu.open |> Expect.equal True
            , test "Toggle from open closes the menu" <|
                \() ->
                    let
                        ( closed, _ ) =
                            UserMenu.update Toggle openMenu
                    in
                    closed.open |> Expect.equal False
            , test "Toggle produces NoOut" <|
                \() ->
                    Tuple.second (UserMenu.update Toggle UserMenu.init)
                        |> Expect.equal NoOut
            ]
        , describe "Close"
            [ test "Close sets open to False (click-outside / Escape handling)" <|
                \() ->
                    let
                        ( closed, _ ) =
                            UserMenu.update Close openMenu
                    in
                    closed.open |> Expect.equal False
            ]
        , describe "SignOutClicked"
            [ test "SignOutClicked emits the SignOut OutMsg" <|
                \() ->
                    Tuple.second (UserMenu.update SignOutClicked UserMenu.init)
                        |> Expect.equal SignOut
            , test "SignOutClicked also closes the menu" <|
                \() ->
                    let
                        ( model, _ ) =
                            UserMenu.update SignOutClicked openMenu
                    in
                    model.open |> Expect.equal False
            ]
        , describe "NavigateClicked (settings family, TR-1)"
            [ test "NavigateClicked emits NavigateTo carrying the clicked path" <|
                \() ->
                    Tuple.second (UserMenu.update (NavigateClicked "/settings/privacy") UserMenu.init)
                        |> Expect.equal (NavigateTo "/settings/privacy")
            , test "NavigateClicked closes the menu" <|
                \() ->
                    let
                        ( model, _ ) =
                            UserMenu.update (NavigateClicked "/settings/privacy") openMenu
                    in
                    model.open |> Expect.equal False
            ]
        , describe "an unconfirmed sign-out is discoverable from the chrome"
            -- ⛔ WHAT THIS IS FOR. The banner reporting a stalled sign-out was
            -- `position: relative`, so a reader who scrolled — or who navigated,
            -- since this is an SPA — lost the only indication their session was
            -- never closed. The banner is `sticky` now, and this is the other
            -- half: the account menu is where a reader looks for anything about
            -- their account, and it survives navigation by construction because
            -- the chrome is not re-rendered per route.
            --
            -- ⚠️ A stalled sign-out does NOT resolve itself. It persists until a
            -- later sign-out reaches the server or the session's own max_age
            -- expires, which is why one missable notice was not enough.
            [ test "the closed trigger carries a marker, so it is visible without opening the menu" <|
                \() ->
                    UserMenu.view testUser sampleLinks True UserMenu.init
                        |> Query.fromHtml
                        |> Query.has [ Selector.class "user-menu__trigger--session-live" ]

            -- ⛔ THE MARKER IS NOT A BARE DOT. A coloured dot says "something" and
            -- says nothing at all to a screen reader, so the meaning travels in
            -- text that is visually hidden and announced.
            , test "the marker's meaning is announced, not only coloured" <|
                \() ->
                    UserMenu.view testUser sampleLinks True UserMenu.init
                        |> Query.fromHtml
                        |> Query.has [ Selector.text " — still signed in on this device" ]
            , test "the open menu states it in words, at the top" <|
                \() ->
                    UserMenu.view testUser sampleLinks True openMenu
                        |> Query.fromHtml
                        |> Query.has
                            [ Selector.text
                                "Still signed in on this device — your last sign-out did not reach us."
                            ]

            -- ⛔ ANTI-VACUITY, and it is the half that makes the three above mean
            -- anything: none of this may appear when the session is NOT stalled.
            -- Without it an implementation that always rendered the notice would
            -- satisfy every case, while telling every reader their sign-out had
            -- failed.
            , test "none of it appears when there is nothing wrong" <|
                \() ->
                    UserMenu.view testUser sampleLinks False openMenu
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.hasNot [ Selector.class "user-menu__trigger--session-live" ]
                            , Query.hasNot [ Selector.text " — still signed in on this device" ]
                            , Query.hasNot
                                [ Selector.text
                                    "Still signed in on this device — your last sign-out did not reach us."
                                ]
                            ]
            ]
        , describe "view"
            [ test "closed menu shows the display name trigger" <|
                \() ->
                    UserMenu.view testUser sampleLinks False UserMenu.init
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "A Reader" ]
            , test "closed menu does not render the dropdown items" <|
                \() ->
                    UserMenu.view testUser sampleLinks False UserMenu.init
                        |> Query.fromHtml
                        |> Query.hasNot [ Selector.text "Sign Out" ]
            , test "open menu renders the settings family and Sign Out" <|
                \() ->
                    UserMenu.view testUser sampleLinks False openMenu
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.has [ Selector.text "Profile" ]
                            , Query.has [ Selector.text "Privacy" ]
                            , Query.has [ Selector.text "Notifications" ]
                            , Query.has [ Selector.text "Sign Out" ]
                            ]
            , test "open menu renders a click-outside backdrop" <|
                \() ->
                    UserMenu.view testUser sampleLinks False openMenu
                        |> Query.fromHtml
                        |> Query.has [ Selector.class "user-menu__backdrop" ]
            ]
        ]
