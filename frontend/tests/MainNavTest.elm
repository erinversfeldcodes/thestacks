module MainNavTest exposing (suite)

{-| Tests for Main.elm navigation chrome and flag decoding. Main is a
`Browser.application` with ports and a real `Nav.Key`, so the full
update loop cannot be program-tested; the pure surfaces are tested
directly — `viewNav` per auth state, active-route marking, and
`decodeFlags` outcomes.
-}

import Api
import Components.UserMenu as UserMenu
import Expect
import Html.Attributes as Attr
import Http
import Json.Encode as Encode
import Main exposing (NavMenu(..))
import Navigation.Route exposing (Route(..))
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import TestHelpers
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
    { user = ownerUser, token = TestHelpers.creds "tok" }


readerAuth : Main.Auth
readerAuth =
    { user = readerUser, token = TestHelpers.creds "tok" }


{-| The Add Book badge, found the way a test should find it.
-}
badge : Selector.Selector
badge =
    Selector.attribute (Attr.attribute "data-testid" "nav-upload-badge")


{-| The persistent Add Book primary action (TR-1) — a `btn btn--primary`
link, NOT a dropdown entry.
-}
addBook : List Selector.Selector
addBook =
    [ Selector.class "app-nav__add-book", Selector.attribute (Attr.href "/upload") ]


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


{-| Authed nav with a given inbox and every disclosure CLOSED.
-}
navWithInbox : Types.RemoteData.RemoteData Http.Error (List Api.InboxItem) -> Query.Single Main.Msg
navWithInbox inbox =
    Main.viewNav Library (Main.Authenticated readerAuth) Nothing UserMenu.init inbox
        |> Query.fromHtml


{-| Authed nav with all disclosures closed.
-}
navClosed : Query.Single Main.Msg
navClosed =
    Main.viewNav Library (Main.Authenticated readerAuth) Nothing UserMenu.init Types.RemoteData.NotAsked
        |> Query.fromHtml


{-| Authed nav with one disclosure open.
-}
navOpen : NavMenu -> Query.Single Main.Msg
navOpen menu =
    Main.viewNav Library (Main.Authenticated readerAuth) (Just menu) UserMenu.init Types.RemoteData.NotAsked
        |> Query.fromHtml


{-| Owner nav on a given route — the Admin disclosure is rendered for the
owner alone, so its tests cannot reuse the reader helpers.
-}
ownerNav : Route -> Maybe NavMenu -> Query.Single Main.Msg
ownerNav route menu =
    Main.viewNav route (Main.Authenticated ownerAuth) menu UserMenu.init Types.RemoteData.NotAsked
        |> Query.fromHtml


suite : Test
suite =
    describe "Main navigation & flags"
        [ describe "viewNav while the server has not yet said who this is"
            [ -- ⛔ THE regression this wave's most likely silent one. `Resolving`
              -- and `Anonymous` both answer `currentAuth = Nothing`, so a nav
              -- written against that `Maybe` draws the signed-out chrome on
              -- every boot — and for a signed-in reader that is the app stating
              -- the opposite of the truth until the round-trip lands.
              test "withholds the Sign In link — it is not known that they are signed out" <|
                \() ->
                    Main.viewNav Catalogue Main.Resolving Nothing UserMenu.init Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Query.hasNot [ Selector.text "Sign In" ]
            , test "withholds the signed-in chrome too — it is not known that they are signed in" <|
                \() ->
                    Main.viewNav Catalogue Main.Resolving Nothing UserMenu.init Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.hasNot [ Selector.text "Bookshelves" ]
                            , Query.hasNot
                                [ Selector.attribute (Attr.attribute "data-testid" "user-menu") ]
                            ]
            , -- The paired control: everything a visitor could already reach is
              -- still there, so the header does not jump when the answer lands.
              test "still offers everything a visitor can reach" <|
                \() ->
                    Main.viewNav Catalogue Main.Resolving Nothing UserMenu.init Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.has [ Selector.text "Catalogue" ]
                            , Query.has [ Selector.text "Marketplace" ]
                            , Query.has [ Selector.text "About" ]
                            ]
            , -- ⛔ The anti-vacuity pair. Without these two, the three
              -- assertions above would pass just as well on a nav that rendered
              -- nothing at all.
              test "a RESOLVED signed-out boot does offer the Sign In link" <|
                \() ->
                    Main.viewNav Catalogue Main.Anonymous Nothing UserMenu.init Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "Sign In" ]
            , test "a RESOLVED signed-in boot does offer the bookshelves" <|
                \() ->
                    Main.viewNav Catalogue (Main.Authenticated readerAuth) Nothing UserMenu.init Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "Bookshelves" ]
            , test "a boot whose check FAILED is resolved, and says so rather than spinning" <|
                \() ->
                    Main.viewNav Catalogue (Main.Unresolved Http.NetworkError) Nothing UserMenu.init Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "Sign In" ]
            ]
        , describe "viewNav Anonymous (unauthenticated)"
            [ test "shows the Sign In link" <|
                \() ->
                    Main.viewNav Catalogue Main.Anonymous Nothing UserMenu.init Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "Sign In" ]
            , test "shows Catalogue and Marketplace" <|
                \() ->
                    Main.viewNav Catalogue Main.Anonymous Nothing UserMenu.init Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.has [ Selector.text "Catalogue" ]
                            , Query.has [ Selector.text "Marketplace" ]
                            ]
            , test "shows a single About entry linking to /about" <|
                \() ->
                    Main.viewNav Catalogue Main.Anonymous Nothing UserMenu.init Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.has [ Selector.text "About" ]
                            , Query.has
                                [ Selector.attribute (Attr.href "/about") ]
                            ]
            , test "does not show authenticated-only bookshelves" <|
                \() ->
                    Main.viewNav Catalogue Main.Anonymous Nothing UserMenu.init Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.hasNot [ Selector.text "Antilibrary" ]
                            , Query.hasNot [ Selector.text "Reading Pile" ]
                            ]
            ]
        , describe "viewNav (Just auth) (authenticated)"
            [ test "shows the user's display name" <|
                \() ->
                    navClosed
                        |> Query.has [ Selector.text "A Reader" ]
            , test "groups the five bookshelves under a Bookshelves disclosure" <|
                \() ->
                    navClosed
                        |> Query.has [ Selector.text "Bookshelves" ]
            , test "promotes Search to a top-level nav item" <|
                \() ->
                    navClosed
                        |> Query.has
                            [ Selector.class "app-nav__link"
                            , Selector.attribute (Attr.href "/search")
                            ]
            , test "does not show a Sign In link" <|
                \() ->
                    navClosed
                        |> Query.hasNot [ Selector.text "Sign In" ]
            , test "marks the current route's nav item active" <|
                \() ->
                    navClosed
                        |> Query.has [ Selector.class "app-nav__item--active" ]
            , test "owner sees the Admin disclosure" <|
                \() ->
                    Main.viewNav Library (Main.Authenticated ownerAuth) Nothing UserMenu.init Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "Admin" ]
            , test "non-owner does not see the Admin disclosure" <|
                \() ->
                    navClosed
                        |> Query.hasNot [ Selector.text "Admin" ]
            ]
        , describe "Elm-owned disclosure"
            [ -- ⛔ THE assertion that fails on the OLD hover-only nav. There the
              -- five bookshelves were top-level `navItem`s, in the DOM always
              -- (the CSS `:hover` reveal only changed `display`), so this
              -- `hasNot` would have FAILED — "Reading Pile" was present with the
              -- menu closed. It passes now only because the menu's contents are
              -- absent from the DOM until `openNavMenu == Just BookshelvesMenu`.
              test "closed: the Bookshelves menu contents are NOT in the DOM" <|
                \() ->
                    navClosed
                        |> Query.hasNot [ Selector.text "Reading Pile" ]
            , test "open: the Bookshelves menu contents appear" <|
                \() ->
                    navOpen BookshelvesMenu
                        |> Expect.all
                            [ Query.has [ Selector.text "Library" ]
                            , Query.has [ Selector.text "Antilibrary" ]
                            , Query.has [ Selector.text "Wish List" ]
                            , Query.has [ Selector.text "Reading Pile" ]
                            , Query.has [ Selector.text "Looking for a Home" ]
                            ]
            , test "closed: no disclosure reports aria-expanded=true" <|
                \() ->
                    navClosed
                        |> Query.hasNot
                            [ Selector.attribute (Attr.attribute "aria-expanded" "true") ]
            , test "open: the open disclosure reports aria-expanded=true" <|
                \() ->
                    navOpen BookshelvesMenu
                        |> Query.has
                            [ Selector.attribute (Attr.attribute "aria-expanded" "true") ]
            , test "the disclosure trigger is a real button with aria-haspopup" <|
                \() ->
                    navClosed
                        |> Query.has
                            [ Selector.tag "button"
                            , Selector.class "app-nav__disclosure"
                            , Selector.attribute (Attr.attribute "aria-haspopup" "true")
                            ]
            , test "closed: no click-outside backdrop is rendered" <|
                \() ->
                    navClosed
                        |> Query.hasNot [ Selector.class "app-nav__backdrop" ]
            , test "open: a click-outside backdrop is rendered" <|
                \() ->
                    navOpen MarketplaceMenu
                        |> Query.has [ Selector.class "app-nav__backdrop" ]
            , test "opening one disclosure does not open another" <|
                \() ->
                    navOpen MarketplaceMenu
                        |> Expect.all
                            [ Query.has [ Selector.text "Create Listing" ]
                            , Query.hasNot [ Selector.text "Reading Pile" ]
                            ]
            ]
        , describe "toggleNavMenu (the click/keyboard toggle oracle)"
            [ test "opens a closed menu" <|
                \() ->
                    Main.toggleNavMenu BookshelvesMenu Nothing
                        |> Expect.equal (Just BookshelvesMenu)
            , test "closes the menu that is already open" <|
                \() ->
                    Main.toggleNavMenu BookshelvesMenu (Just BookshelvesMenu)
                        |> Expect.equal Nothing
            , test "switches directly from one open menu to another" <|
                \() ->
                    Main.toggleNavMenu MarketplaceMenu (Just BookshelvesMenu)
                        |> Expect.equal (Just MarketplaceMenu)
            ]
        , describe "Add Book — persistent primary action"
            [ -- Reachable on touch and keyboard because it is ALWAYS rendered and
              test "is present with all menus closed (no hover/open needed)" <|
                \() ->
                    navClosed
                        |> Query.has addBook
            , test "is present while a different menu is open" <|
                \() ->
                    navOpen MarketplaceMenu
                        |> Query.has addBook
            , -- ⛔ The old Add Book was an `app-nav__dropdown-link` INSIDE the
              test "is styled as the primary action, not a dropdown link" <|
                \() ->
                    navClosed
                        |> Query.find addBook
                        |> Query.has [ Selector.class "btn", Selector.class "btn--primary" ]
            ]
        , describe "the Admin disclosure"
            [ test "open: every admin surface is one click away" <|
                \() ->
                    ownerNav Library (Just AdminMenu)
                        |> Query.find [ Selector.class "app-nav__dropdown-menu" ]
                        |> Query.findAll [ Selector.class "app-nav__dropdown-link" ]
                        |> Query.count (Expect.equal 6)
            , test "open: the invitations surface is one of them" <|
                \() ->
                    ownerNav Library (Just AdminMenu)
                        |> Query.find [ Selector.class "app-nav__dropdown-menu" ]
                        |> Query.findAll [ Selector.attribute (Attr.href "/admin/invites") ]
                        |> Query.count (Expect.equal 1)
            , test "the invitations route keeps the Admin item active" <|
                \() ->
                    ownerNav AdminInvites Nothing
                        |> Query.find [ Selector.class "app-nav__item--active" ]
                        |> Query.has [ Selector.text "Admin" ]
            , test "the invitations route lights exactly one nav item" <|
                \() ->
                    ownerNav AdminInvites Nothing
                        |> Query.findAll [ Selector.class "app-nav__item--active" ]
                        |> Query.count (Expect.equal 1)
            ]
        , describe "active-route highlight on child routes"
            [ test "a book-detail keeps the Bookshelves item active" <|
                \() ->
                    Main.viewNav (BookDetail "b1") (Main.Authenticated readerAuth) Nothing UserMenu.init Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Query.find [ Selector.class "app-nav__item--active" ]
                        |> Query.has [ Selector.text "Bookshelves" ]
            , test "a marketplace listing detail keeps Marketplace active" <|
                \() ->
                    Main.viewNav (MarketplaceDetail "l1") (Main.Authenticated readerAuth) Nothing UserMenu.init Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Query.find [ Selector.class "app-nav__item--active" ]
                        |> Query.has [ Selector.text "Marketplace" ]
            ]
        , describe "the Add Book badge"
            [ test "counts the uploads awaiting confirmation" <|
                \() ->
                    navWithInbox
                        (Types.RemoteData.Success
                            [ awaitingItem "img-1", awaitingItem "img-2" ]
                        )
                        |> Query.find [ badge ]
                        |> Query.has [ Selector.text "2" ]
            , test "renders NO badge when nothing is waiting" <|
                \() ->
                    navWithInbox (Types.RemoteData.Success [])
                        |> Query.hasNot [ badge ]
            , test "does not count failures — an inbox of only failures shows no badge" <|
                \() ->
                    navWithInbox
                        (Types.RemoteData.Success
                            [ failedItem "img-1" "vision_unavailable"
                            , failedItem "img-2" "not_a_book"
                            ]
                        )
                        |> Query.hasNot [ badge ]
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
            , test "the badge rides on the persistent Add Book action" <|
                \() ->
                    navWithInbox (Types.RemoteData.Success [ awaitingItem "img-1" ])
                        |> Query.find addBook
                        |> Query.has [ badge ]
            , test "the badge is not rendered inside any disclosure menu" <|
                \() ->
                    navWithInbox (Types.RemoteData.Success [ awaitingItem "img-1" ])
                        |> Query.findAll [ Selector.class "app-nav__dropdown-menu" ]
                        |> Query.keep badge
                        |> Query.count (Expect.equal 0)
            ]
        , describe "decodeConfig (server-config channel"
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
            , -- ⚠️ `PersistAuth` used to be asserted here too. It is gone with
              -- the stored session: the browser holds the cookie, so a login has
              -- nothing to make durable.
              test "navigates to the page they asked for" <|
                \() ->
                    Main.loginEffects
                        |> Expect.all
                            [ \effects -> Expect.equal True (List.member Main.NavigateToRequestedPage effects)
                            , \effects -> Expect.equal True (List.member Main.ScheduleRenewal effects)
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
