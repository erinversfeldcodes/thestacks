module MainNavTest exposing (suite)

{-| Tests for Main.elm navigation chrome and flag decoding.

Main.elm uses Browser.application with ports and a Browser.Navigation.Key, so
the full update loop cannot be program-tested. Following the pattern in
NavigationProgramTest, we test the pure surfaces directly:

1.  `viewNav` renders the correct nav for authenticated vs unauthenticated state
2.  `decodeFlags` restores a `StoredAuth` from localStorage-shaped flags (the
    corrupt and unreadable outcomes have their own suite, `StoredAuthTest`)
3.  `shouldShowOnboarding` encodes the onboarding display condition

-}

import Api
import Components.UserMenu as UserMenu
import Expect
import Html.Attributes as Attr
import Http
import Json.Encode as Encode
import Main
import Navigation.Route exposing (Route(..))
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Types.RemoteData
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


{-| The Add Book badge, found the way a test should find it (Issue #351).
-}
badge : Selector.Selector
badge =
    Selector.attribute (Attr.attribute "data-testid" "nav-upload-badge")


awaitingItem : String -> Api.InboxItem
awaitingItem imageId =
    { imageId = imageId
    , kind = Api.AwaitingConfirmation
    , bookIds = [ "book-" ++ imageId ]
    , rejectionReason = Nothing
    }


failedItem : String -> String -> Api.InboxItem
failedItem imageId reason =
    { imageId = imageId
    , kind = Api.Failed
    , bookIds = []
    , rejectionReason = Just reason
    }


navWithInbox : Types.RemoteData.RemoteData Http.Error (List Api.InboxItem) -> Query.Single Main.Msg
navWithInbox inbox =
    Main.viewNav Library (Just readerAuth) UserMenu.init inbox
        |> Query.fromHtml


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
                    Main.viewNav Catalogue Nothing UserMenu.init Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "Sign In" ]
            , test "shows Catalogue and Marketplace" <|
                \() ->
                    Main.viewNav Catalogue Nothing UserMenu.init Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.has [ Selector.text "Catalogue" ]
                            , Query.has [ Selector.text "Marketplace" ]
                            ]
            , test "shows a single About entry linking to /about" <|
                \() ->
                    Main.viewNav Catalogue Nothing UserMenu.init Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.has [ Selector.text "About" ]
                            , Query.has
                                [ Selector.attribute (Attr.href "/about") ]
                            ]
            , test "does not show authenticated-only bookshelves" <|
                \() ->
                    Main.viewNav Catalogue Nothing UserMenu.init Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.hasNot [ Selector.text "Antilibrary" ]
                            , Query.hasNot [ Selector.text "Reading Pile" ]
                            ]
            ]
        , describe "viewNav (Just auth) (authenticated)"
            [ test "shows the user's display name" <|
                \() ->
                    Main.viewNav Library (Just readerAuth) UserMenu.init Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "A Reader" ]
            , test "shows the full nav item set" <|
                \() ->
                    Main.viewNav Library (Just readerAuth) UserMenu.init Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.has [ Selector.text "Library" ]
                            , Query.has [ Selector.text "Antilibrary" ]
                            , Query.has [ Selector.text "Wish List" ]
                            , Query.has [ Selector.text "Reading Pile" ]
                            ]
            , test "does not show a Sign In link" <|
                \() ->
                    Main.viewNav Library (Just readerAuth) UserMenu.init Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Query.hasNot [ Selector.text "Sign In" ]
            , test "marks the current route's nav item active" <|
                \() ->
                    Main.viewNav Library (Just readerAuth) UserMenu.init Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Query.has [ Selector.class "app-nav__item--active" ]
            , test "owner sees the Admin dropdown" <|
                \() ->
                    Main.viewNav Library (Just ownerAuth) UserMenu.init Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "Admin" ]
            , test "non-owner does not see the Admin dropdown" <|
                \() ->
                    Main.viewNav Library (Just readerAuth) UserMenu.init Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Query.hasNot [ Selector.text "Admin" ]
            ]
        , describe "the Add Book badge (Issue #351)"
            [ test "counts the uploads awaiting confirmation" <|
                \() ->
                    navWithInbox
                        (Types.RemoteData.Success
                            [ awaitingItem "img-1", awaitingItem "img-2" ]
                        )
                        |> Query.find [ badge ]
                        |> Query.has [ Selector.text "2" ]

            -- ⛔ Requirement 4 of the issue, and the reason `pendingConfirmationBadge`
            -- returns a `Maybe Int` rather than an `Int`: "Zero pending renders no
            -- badge, not a `0`." A badge showing nothing to do is a mark that
            -- survives being looked at, and teaches the reader to stop looking.
            , test "renders NO badge when nothing is waiting" <|
                \() ->
                    navWithInbox (Types.RemoteData.Success [])
                        |> Query.hasNot [ badge ]

            -- ⛔ The failure/confirmation split, asserted on the number itself. A
            -- failed upload has nothing to confirm and nothing to place, so a
            -- badge counting it could never be cleared by doing what it asks —
            -- the reader would be left with a permanent 1 and no way to act.
            , test "does not count failures — an inbox of only failures shows no badge" <|
                \() ->
                    navWithInbox
                        (Types.RemoteData.Success
                            [ failedItem "img-1" "vision_unavailable"
                            , failedItem "img-2" "not_a_book"
                            ]
                        )
                        |> Query.hasNot [ badge ]

            -- The anti-vacuity companion to the test above: "no badge" and "no
            -- badge" compare equal for the wrong reason if the badge never
            -- renders at all. A mixed inbox pins the number to the count of
            -- confirmations ALONE — one, out of three items.
            , test "a mixed inbox counts only the confirmations" <|
                \() ->
                    navWithInbox
                        (Types.RemoteData.Success
                            [ failedItem "img-1" "vision_unavailable"
                            , awaitingItem "img-2"
                            , failedItem "img-3" "isbn_not_found"
                            ]
                        )
                        |> Query.find [ badge ]
                        |> Query.has [ Selector.text "1" ]
            , test "an unloaded inbox renders no badge — 'we don't know' is not 'nothing'" <|
                \() ->
                    navWithInbox Types.RemoteData.NotAsked
                        |> Query.hasNot [ badge ]
            , test "a failed inbox fetch renders no badge rather than a cleared one" <|
                \() ->
                    navWithInbox (Types.RemoteData.Failure Http.NetworkError)
                        |> Query.hasNot [ badge ]

            -- The owner ruled the badge stays inside the Catalogue dropdown:
            -- "we don't need to render it outside of the drop down, it can
            -- remain low-but-easy-visibility." The dropdown menu is the only
            -- place it may appear.
            , test "the badge lives inside the Catalogue dropdown menu" <|
                \() ->
                    navWithInbox (Types.RemoteData.Success [ awaitingItem "img-1" ])
                        |> Query.findAll [ Selector.class "app-nav__dropdown-menu" ]
                        |> Query.keep badge
                        |> Query.count (Expect.equal 1)
            , test "the badge is on the Add Book entry, not on Search" <|
                \() ->
                    navWithInbox (Types.RemoteData.Success [ awaitingItem "img-1" ])
                        |> Query.find
                            [ Selector.class "app-nav__dropdown-link"
                            , Selector.attribute (Attr.href "/upload")
                            ]
                        |> Query.has [ badge ]
            ]
        , describe "decodeFlags"
            [ test "restores an Auth from valid flags" <|
                \() ->
                    Main.decodeFlags (flags "user")
                        |> Main.storedSession
                        |> Maybe.map (.user >> .displayName)
                        |> Expect.equal (Just "A Reader")
            , test "restores the role from flags" <|
                \() ->
                    Main.decodeFlags (flags "owner")
                        |> Main.storedSession
                        |> Maybe.map (.user >> .role)
                        |> Expect.equal (Just "owner")
            , test "empty flags are a clean signed-out boot, not a corrupt one" <|
                \() ->
                    Main.decodeFlags (Encode.object [])
                        |> Expect.equal Main.NoStoredAuth
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
