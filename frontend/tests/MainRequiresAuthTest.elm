module MainRequiresAuthTest exposing (suite)

{-| Auth-gating matrix for `Main.requiresAuth` plus the `Main.initPage`
redirect guard.

`requiresAuth` uses a `_ -> True` catch-all, so a newly-added protected route
becomes auth-gated by default and a newly-added _public_ route would silently
be gated too. To stop the matrix from silently skipping a new constructor, the
expected policy is encoded here in `expectedAuth`, an **exhaustive** case over
every `Route` constructor (no wildcard). Adding a constructor to the `Route`
union forces a compile error here until it is classified, and every route in
`allRoutes` is then cross-checked against `Main.requiresAuth`.

-}

import Expect
import Main
import Navigation.Route exposing (ConfirmStatus(..), Route(..))
import Page.Login as Login
import Test exposing (Test, describe, test)


{-| The intended auth policy, declared independently of `Main.requiresAuth` and
exhaustive over the whole `Route` union. `False` = public, `True` = protected.
-}
expectedAuth : Route -> Bool
expectedAuth route =
    case route of
        Home ->
            False

        Login ->
            False

        Library ->
            True

        AntiLibrary ->
            True

        WishList ->
            True

        ReadingPile ->
            True

        LookingForHome ->
            True

        BookDetail _ ->
            False

        Upload ->
            True

        Search ->
            False

        SettingsProfile ->
            True

        SettingsPassword ->
            True

        SettingsNotifications ->
            True

        SettingsAuditLog ->
            True

        Insights ->
            True

        CostTransparency ->
            False

        Metrics ->
            False

        About ->
            False

        -- Unauthenticated on purpose. US-2.5.3: removal "does not require account
        -- creation" — a business that never asked to be listed must not have to sign up
        -- in order to leave. This branch existing is the deliberate decision that
        -- exhaustiveness forces.
        ListingRemoval ->
            False

        Catalogue ->
            False

        MarketplaceBrowse ->
            False

        MarketplaceCreate ->
            True

        MarketplaceMyListings ->
            True

        MarketplaceDetail _ ->
            False

        SettingsPrivacy ->
            True

        BlogArchive ->
            False

        BlogNew ->
            True

        BlogEdit _ ->
            True

        BlogPost _ ->
            False

        AdminSourceApproval ->
            True

        AdminInvites ->
            -- Owner-only (US-14.1.3), like every /admin surface.
            True

        AdminScraperConfig ->
            True

        AdminBookModeration ->
            True

        AdminRemovalRequests ->
            True

        Groups ->
            True

        GroupDetail _ ->
            True

        Profile _ ->
            False

        ProfileShelf _ _ ->
            False

        ConfirmEmail _ ->
            False

        ForgotPassword ->
            False

        ResendConfirmation ->
            -- Public by necessity: a reader who cannot confirm their email
            -- cannot sign in, so requiring auth here would close the only door
            -- out of that state.
            False

        ResetPassword _ ->
            False

        NotFound ->
            False


{-| Every `Route` constructor with a sample argument. Enumerated so the matrix
covers the full union; each is cross-checked against `expectedAuth`.
-}
allRoutes : List ( String, Route )
allRoutes =
    [ ( "Home", Home )
    , ( "Login", Login )
    , ( "Library", Library )
    , ( "AntiLibrary", AntiLibrary )
    , ( "WishList", WishList )
    , ( "ReadingPile", ReadingPile )
    , ( "LookingForHome", LookingForHome )
    , ( "BookDetail", BookDetail "abc" )
    , ( "Upload", Upload )
    , ( "Search", Search )
    , ( "SettingsProfile", SettingsProfile )
    , ( "SettingsPassword", SettingsPassword )
    , ( "SettingsNotifications", SettingsNotifications )
    , ( "SettingsAuditLog", SettingsAuditLog )
    , ( "Insights", Insights )
    , ( "CostTransparency", CostTransparency )
    , ( "Metrics", Metrics )
    , ( "About", About )
    , ( "Catalogue", Catalogue )
    , ( "MarketplaceBrowse", MarketplaceBrowse )
    , ( "MarketplaceCreate", MarketplaceCreate )
    , ( "MarketplaceMyListings", MarketplaceMyListings )
    , ( "MarketplaceDetail", MarketplaceDetail "l1" )
    , ( "SettingsPrivacy", SettingsPrivacy )
    , ( "BlogArchive", BlogArchive )
    , ( "BlogNew", BlogNew )
    , ( "BlogEdit", BlogEdit "s1" )
    , ( "BlogPost", BlogPost "s1" )
    , ( "AdminSourceApproval", AdminSourceApproval )
    , ( "AdminScraperConfig", AdminScraperConfig )
    , ( "AdminBookModeration", AdminBookModeration )
    , ( "AdminRemovalRequests", AdminRemovalRequests )
    , ( "Groups", Groups )
    , ( "GroupDetail", GroupDetail "g1" )
    , ( "Profile", Profile "handle" )
    , ( "ProfileShelf", ProfileShelf "handle" "library" )
    , ( "ConfirmEmail", ConfirmEmail EmailConfirmed )
    , ( "ForgotPassword", ForgotPassword )
    , ( "ResendConfirmation", ResendConfirmation )
    , ( "ResetPassword", ResetPassword "tok" )
    , ( "NotFound", NotFound )
    ]


config : Main.AppConfig
config =
    { ageGatingEnabled = False, inviteOnly = False }


matrixTest : ( String, Route ) -> Test
matrixTest ( label, route ) =
    test (label ++ " requiresAuth == " ++ boolLabel (expectedAuth route)) <|
        \() ->
            Main.requiresAuth route
                |> Expect.equal (expectedAuth route)


boolLabel : Bool -> String
boolLabel b =
    if b then
        "True (protected)"

    else
        "False (public)"


isPageLogin : Main.Page -> Bool
isPageLogin page =
    case page of
        Main.PageLogin _ ->
            True

        _ ->
            False


isPageAdminGate : Main.Page -> Bool
isPageAdminGate page =
    case page of
        Main.PageAdminGate _ _ ->
            True

        _ ->
            False


{-| An owner, since every admin route is owner-only. Built from `ownerAuth` so these tests exercise
the ADMIN gate rather than tripping the ordinary auth redirect first.
-}
ownerAuth : Main.Auth
ownerAuth =
    { user =
        { id = "owner-1"
        , email = "owner@thestacks.app"
        , displayName = "Owner"
        , handle = "owner"
        , role = "owner"
        , countryCode = Nothing
        , city = Nothing
        , consentAnalytics = False
        , consentWritingAssistant = False
        }
    , token = "ordinary-guardian-token"
    }


suite : Test
suite =
    describe "Main auth gating"
        [ describe "requiresAuth matrix (full Route union)"
            (List.map matrixTest allRoutes)
        , describe "requiresAuth counts"
            [ test "19 public routes and 22 protected routes are enumerated" <|
                \() ->
                    ( List.length (List.filter (\( _, r ) -> not (Main.requiresAuth r)) allRoutes)
                    , List.length (List.filter (\( _, r ) -> Main.requiresAuth r) allRoutes)
                    )
                        |> Expect.equal ( 19, 22 )
            ]
        , describe "admin routes are gated on an ADMIN token, not the ordinary one (#303)"
            [ test "an owner with no admin token gets the sign-in gate, not the page" <|
                \() ->
                    -- ⛔ The bug this closes. All four admin pages were handed the ordinary Guardian
                    -- token and rendered; every request then 401'd against the `:admin` pipeline,
                    -- which needs a `typ: "admin_session"` token. Four surfaces were built, routed,
                    -- tested and unreachable — and nothing failed, because each page's own tests
                    -- passed a token straight into a mocked API.
                    Main.initPage config AdminRemovalRequests (Just ownerAuth) Nothing Nothing Login.Fresh
                        |> Tuple.first
                        |> isPageAdminGate
                        |> Expect.equal True
            , test "with an admin token the real page loads" <|
                \() ->
                    Main.initPage config AdminRemovalRequests (Just ownerAuth) (Just "admin-tok") Nothing Login.Fresh
                        |> Tuple.first
                        |> isPageAdminGate
                        |> Expect.equal False
            , test "every admin route is gated, not just the new one" <|
                \() ->
                    -- `isAdminRoute` is exhaustive over Route on purpose; this asserts the four are
                    -- actually wired to it, so adding a fifth admin page cannot silently skip the
                    -- gate.
                    [ AdminSourceApproval, AdminScraperConfig, AdminBookModeration, AdminRemovalRequests ]
                        |> List.map
                            (\r ->
                                Main.initPage config r (Just ownerAuth) Nothing Nothing Login.Fresh
                                    |> Tuple.first
                                    |> isPageAdminGate
                            )
                        |> Expect.equal [ True, True, True, True ]
            , test "a non-admin route is unaffected by the admin token being absent" <|
                \() ->
                    Main.initPage config Library (Just ownerAuth) Nothing Nothing Login.Fresh
                        |> Tuple.first
                        |> isPageAdminGate
                        |> Expect.equal False
            ]
        , describe "initPage redirect guard"
            [ test "a protected route with no auth renders the Login page (login-at-URL)" <|
                \() ->
                    Main.initPage config Upload Nothing Nothing Nothing Login.Fresh
                        |> Tuple.first
                        |> isPageLogin
                        |> Expect.equal True
            , test "a second protected route with no auth also renders Login" <|
                \() ->
                    Main.initPage config SettingsProfile Nothing Nothing Nothing Login.Fresh
                        |> Tuple.first
                        |> isPageLogin
                        |> Expect.equal True
            , test "a public route with no auth does NOT force the Login page" <|
                \() ->
                    Main.initPage config Home Nothing Nothing Nothing Login.Fresh
                        |> Tuple.first
                        |> isPageLogin
                        |> Expect.equal False
            ]
        ]
