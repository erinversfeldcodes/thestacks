module MainNavTest exposing (suite)

{-| Tests for Main.elm navigation chrome and flag decoding.

Main.elm uses Browser.application with ports and a Browser.Navigation.Key, so
the full update loop cannot be program-tested. Following the pattern in
NavigationProgramTest, we test the pure surfaces directly:

1.  `viewNav` renders the correct nav for authenticated vs unauthenticated state
2.  `decodeFlags` restores a `Maybe Auth` from localStorage-shaped flags
3.  `shouldShowOnboarding` encodes the onboarding display condition

-}

import Components.UserMenu as UserMenu
import Expect
import Html.Attributes as Attr
import Json.Encode as Encode
import Main
import Navigation.Route exposing (Route(..))
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Types.User exposing (User)


ownerUser : User
ownerUser =
    { id = "u1", email = "owner@stacks.dev", displayName = "The Owner", handle = "the_owner", role = "owner", countryCode = Nothing, city = Nothing, consentAnalytics = False, consentWritingAssistant = False }


readerUser : User
readerUser =
    { id = "u2", email = "reader@stacks.dev", displayName = "A Reader", handle = "a_reader", role = "user", countryCode = Nothing, city = Nothing, consentAnalytics = False, consentWritingAssistant = False }


ownerAuth : Main.Auth
ownerAuth =
    { user = ownerUser, token = "tok" }


readerAuth : Main.Auth
readerAuth =
    { user = readerUser, token = "tok" }


flags : String -> Encode.Value
flags role =
    Encode.object
        [ ( "token", Encode.string "jwt-token" )
        , ( "userId", Encode.string "u2" )
        , ( "email", Encode.string "reader@stacks.dev" )
        , ( "displayName", Encode.string "A Reader" )
        , ( "role", Encode.string role )
        ]


suite : Test
suite =
    describe "Main navigation & flags"
        [ describe "viewNav Nothing (unauthenticated)"
            [ test "shows the Sign In link" <|
                \() ->
                    Main.viewNav Catalogue Nothing UserMenu.init
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "Sign In" ]
            , test "shows Catalogue and Marketplace" <|
                \() ->
                    Main.viewNav Catalogue Nothing UserMenu.init
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.has [ Selector.text "Catalogue" ]
                            , Query.has [ Selector.text "Marketplace" ]
                            ]
            , test "shows a single About entry linking to /about" <|
                \() ->
                    Main.viewNav Catalogue Nothing UserMenu.init
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.has [ Selector.text "About" ]
                            , Query.has
                                [ Selector.attribute (Attr.href "/about") ]
                            ]
            , test "does not show authenticated-only bookshelves" <|
                \() ->
                    Main.viewNav Catalogue Nothing UserMenu.init
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.hasNot [ Selector.text "Antilibrary" ]
                            , Query.hasNot [ Selector.text "Reading Pile" ]
                            ]
            ]
        , describe "viewNav (Just auth) (authenticated)"
            [ test "shows the user's display name" <|
                \() ->
                    Main.viewNav Library (Just readerAuth) UserMenu.init
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "A Reader" ]
            , test "shows the full nav item set" <|
                \() ->
                    Main.viewNav Library (Just readerAuth) UserMenu.init
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.has [ Selector.text "Library" ]
                            , Query.has [ Selector.text "Antilibrary" ]
                            , Query.has [ Selector.text "Wish List" ]
                            , Query.has [ Selector.text "Reading Pile" ]
                            ]
            , test "does not show a Sign In link" <|
                \() ->
                    Main.viewNav Library (Just readerAuth) UserMenu.init
                        |> Query.fromHtml
                        |> Query.hasNot [ Selector.text "Sign In" ]
            , test "marks the current route's nav item active" <|
                \() ->
                    Main.viewNav Library (Just readerAuth) UserMenu.init
                        |> Query.fromHtml
                        |> Query.has [ Selector.class "app-nav__item--active" ]
            , test "owner sees the Admin dropdown" <|
                \() ->
                    Main.viewNav Library (Just ownerAuth) UserMenu.init
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "Admin" ]
            , test "non-owner does not see the Admin dropdown" <|
                \() ->
                    Main.viewNav Library (Just readerAuth) UserMenu.init
                        |> Query.fromHtml
                        |> Query.hasNot [ Selector.text "Admin" ]
            ]
        , describe "decodeFlags"
            [ test "restores an Auth from valid flags" <|
                \() ->
                    Main.decodeFlags (flags "user")
                        |> Maybe.map (.user >> .displayName)
                        |> Expect.equal (Just "A Reader")
            , test "restores the role from flags" <|
                \() ->
                    Main.decodeFlags (flags "owner")
                        |> Maybe.map (.user >> .role)
                        |> Expect.equal (Just "owner")
            , test "returns Nothing when flags are empty" <|
                \() ->
                    Main.decodeFlags (Encode.object [])
                        |> Expect.equal Nothing
            ]
        , describe "decodeConfig (server-config channel — ADR-020)"
            [ test "decodes ageGatingEnabled: true" <|
                \() ->
                    Main.decodeConfig
                        (Encode.object [ ( "ageGatingEnabled", Encode.bool True ) ])
                        |> .ageGatingEnabled
                        |> Expect.equal True
            , test "decodes ageGatingEnabled: false" <|
                \() ->
                    Main.decodeConfig
                        (Encode.object [ ( "ageGatingEnabled", Encode.bool False ) ])
                        |> .ageGatingEnabled
                        |> Expect.equal False
            , test "defaults to False when ageGatingEnabled is absent (fail safe)" <|
                \() ->
                    Main.decodeConfig (Encode.object [])
                        |> .ageGatingEnabled
                        |> Expect.equal False
            , test "defaults to False when flags are malformed (fail safe)" <|
                \() ->
                    Main.decodeConfig (Encode.string "not-an-object")
                        |> .ageGatingEnabled
                        |> Expect.equal False
            ]
        , describe "loginEffects (fresh login mirrors init)"
            [ test "fetches placements so onboarding can trigger for a placement-free user" <|
                \() ->
                    List.member Main.FetchPlacements Main.loginEffects
                        |> Expect.equal True
            , test "initialises the onboarding overlay after login" <|
                \() ->
                    List.member Main.InitOnboarding Main.loginEffects
                        |> Expect.equal True
            , test "still persists the auth and navigates to the page they asked for" <|
                \() ->
                    Main.loginEffects
                        |> Expect.all
                            [ \effects -> Expect.equal True (List.member Main.PersistAuth effects)
                            , \effects -> Expect.equal True (List.member Main.NavigateToRequestedPage effects)
                            ]
            ]
        , describe "shouldShowOnboarding"
            [ test "shows when authed, not completed, and no placements" <|
                \() ->
                    Main.shouldShowOnboarding (Just readerAuth) False False
                        |> Expect.equal True
            , test "hidden when not authenticated" <|
                \() ->
                    Main.shouldShowOnboarding Nothing False False
                        |> Expect.equal False
            , test "hidden when onboarding already completed" <|
                \() ->
                    Main.shouldShowOnboarding (Just readerAuth) True False
                        |> Expect.equal False
            , test "hidden when the user already has placements" <|
                \() ->
                    Main.shouldShowOnboarding (Just readerAuth) False True
                        |> Expect.equal False
            ]
        ]
