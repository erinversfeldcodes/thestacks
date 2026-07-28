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

        Settings ->
            True

        SettingsProfile ->
            True

        SettingsPassword ->
            True

        SettingsNotifications ->
            True

        SettingsConsent ->
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

        AdminScraperConfig ->
            True

        AdminBookModeration ->
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
    , ( "Settings", Settings )
    , ( "SettingsProfile", SettingsProfile )
    , ( "SettingsPassword", SettingsPassword )
    , ( "SettingsNotifications", SettingsNotifications )
    , ( "SettingsConsent", SettingsConsent )
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
    , ( "Groups", Groups )
    , ( "GroupDetail", GroupDetail "g1" )
    , ( "Profile", Profile "handle" )
    , ( "ProfileShelf", ProfileShelf "handle" "library" )
    , ( "ConfirmEmail", ConfirmEmail EmailConfirmed )
    , ( "ForgotPassword", ForgotPassword )
    , ( "ResetPassword", ResetPassword "tok" )
    , ( "NotFound", NotFound )
    ]


config : Main.AppConfig
config =
    { ageGatingEnabled = False }


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


suite : Test
suite =
    describe "Main auth gating"
        [ describe "requiresAuth matrix (full Route union)"
            (List.map matrixTest allRoutes)
        , describe "requiresAuth counts"
            [ test "18 public routes and 23 protected routes are enumerated" <|
                \() ->
                    ( List.length (List.filter (\( _, r ) -> not (Main.requiresAuth r)) allRoutes)
                    , List.length (List.filter (\( _, r ) -> Main.requiresAuth r) allRoutes)
                    )
                        |> Expect.equal ( 18, 23 )
            ]
        , describe "initPage redirect guard"
            [ test "a protected route with no auth renders the Login page (login-at-URL)" <|
                \() ->
                    Main.initPage config Upload Nothing Nothing
                        |> Tuple.first
                        |> isPageLogin
                        |> Expect.equal True
            , test "a second protected route with no auth also renders Login" <|
                \() ->
                    Main.initPage config SettingsProfile Nothing Nothing
                        |> Tuple.first
                        |> isPageLogin
                        |> Expect.equal True
            , test "a public route with no auth does NOT force the Login page" <|
                \() ->
                    Main.initPage config Home Nothing Nothing
                        |> Tuple.first
                        |> isPageLogin
                        |> Expect.equal False
            ]
        ]
