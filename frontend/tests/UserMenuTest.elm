module UserMenuTest exposing (suite)

{-| Unit tests for Components.UserMenu — the authenticated account dropdown.

Covers Toggle (open/close), Close, SignOutClicked → SignOut OutMsg,
SettingsClicked → NavigateToSettings, and the rendered dropdown contents.
The Main.elm SignOut wiring (auth cleared, clearAuth port, navigate to /login)
and the non-blocking LogoutCompleted no-op are exercised at the Main level,
which cannot be unit-tested here because it owns a Browser.Navigation.Key.

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
    , role = "user"
    , countryCode = Nothing
    , city = Nothing
    }


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
        , describe "SettingsClicked"
            [ test "SettingsClicked emits NavigateToSettings" <|
                \() ->
                    Tuple.second (UserMenu.update SettingsClicked UserMenu.init)
                        |> Expect.equal NavigateToSettings
            ]
        , describe "view"
            [ test "closed menu shows the display name trigger" <|
                \() ->
                    UserMenu.view testUser UserMenu.init
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "A Reader" ]
            , test "closed menu does not render the dropdown items" <|
                \() ->
                    UserMenu.view testUser UserMenu.init
                        |> Query.fromHtml
                        |> Query.hasNot [ Selector.text "Sign Out" ]
            , test "open menu renders Settings and Sign Out" <|
                \() ->
                    UserMenu.view testUser openMenu
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.has [ Selector.text "Settings" ]
                            , Query.has [ Selector.text "Sign Out" ]
                            ]
            , test "open menu renders a click-outside backdrop" <|
                \() ->
                    UserMenu.view testUser openMenu
                        |> Query.fromHtml
                        |> Query.has [ Selector.class "user-menu__backdrop" ]
            ]
        ]
