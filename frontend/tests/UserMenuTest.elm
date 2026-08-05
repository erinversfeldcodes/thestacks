module UserMenuTest exposing (suite)

{-| Unit tests for Components.UserMenu — the authenticated account dropdown.

Covers Toggle (open/close), Close, SignOutClicked → SignOut OutMsg,
NavigateClicked → NavigateTo OutMsg, and the rendered dropdown contents (the
settings family + Sign Out, #318 TR-1). The Main.elm SignOut wiring (auth
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
        , describe "NavigateClicked (settings family, #318 TR-1)"
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
        , describe "view"
            [ test "closed menu shows the display name trigger" <|
                \() ->
                    UserMenu.view testUser sampleLinks UserMenu.init
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "A Reader" ]
            , test "closed menu does not render the dropdown items" <|
                \() ->
                    UserMenu.view testUser sampleLinks UserMenu.init
                        |> Query.fromHtml
                        |> Query.hasNot [ Selector.text "Sign Out" ]
            , test "open menu renders the settings family and Sign Out" <|
                \() ->
                    UserMenu.view testUser sampleLinks openMenu
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.has [ Selector.text "Profile" ]
                            , Query.has [ Selector.text "Privacy" ]
                            , Query.has [ Selector.text "Notifications" ]
                            , Query.has [ Selector.text "Sign Out" ]
                            ]
            , test "open menu renders a click-outside backdrop" <|
                \() ->
                    UserMenu.view testUser sampleLinks openMenu
                        |> Query.fromHtml
                        |> Query.has [ Selector.class "user-menu__backdrop" ]
            ]
        ]
