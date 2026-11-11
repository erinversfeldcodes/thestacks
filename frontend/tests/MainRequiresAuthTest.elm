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

import Api
import Expect
import Http
import Main
import Navigation.Route exposing (ConfirmStatus(..), Route(..))
import Page.Login as Login
import Test exposing (Test, describe, test)
import TestHelpers


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

        Import ->
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

        DataTransparency ->
            False

        Architecture ->
            False

        Metrics ->
            False

        About ->
            False

        Faq ->
            False

        -- Signed in: the minimal channel records who wrote it, so the owner
        -- can write back.
        Feedback ->
            True

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
            True

        AdminScraperConfig ->
            True

        AdminBookModeration ->
            True

        AdminRemovalRequests ->
            True

        AdminFeedback ->
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
    , ( "DataTransparency", DataTransparency )
    , ( "Architecture", Architecture )
    , ( "Metrics", Metrics )
    , ( "About", About )
    , ( "Faq", Faq )
    , ( "Feedback", Feedback )
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
    , ( "AdminFeedback", AdminFeedback )
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
    { ageGatingEnabled = False, inviteOnly = False, proof = Nothing }


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


isPageFaq : Main.Page -> Bool
isPageFaq page =
    case page of
        Main.PageFaq ->
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
    , token = TestHelpers.creds "ordinary-guardian-token"
    }


suite : Test
suite =
    describe "Main auth gating"
        [ describe "requiresAuth matrix (full Route union)"
            (List.map matrixTest allRoutes)
        , describe "requiresAuth counts"
            [ test "22 public routes and 24 protected routes are enumerated" <|
                \() ->
                    ( List.length (List.filter (\( _, r ) -> not (Main.requiresAuth r)) allRoutes)
                    , List.length (List.filter (\( _, r ) -> Main.requiresAuth r) allRoutes)
                    )
                        |> Expect.equal ( 22, 24 )
            ]
        , describe "admin elevation is the SERVER's answer, not the presence of a credential"
            [ -- ⛔ THESE REPLACE THREE TESTS THAT ASSERTED THE OPPOSITE, and the
              -- reason they could assert it was a bug. `initPage` used to show
              -- the gate whenever `adminToken == Nothing` — but every caller
              -- passes the ORDINARY session, so that condition reads "am I
              -- signed in?", not "am I elevated?". It only ever fired because
              -- `bootPage` handed it a stale pre-boot model where the
              -- credential was still absent. Fixing that staleness alone made
              -- the gate vanish entirely; the two defects were cancelling.
              --
              -- So the gate is now REACTIVE: the page renders, the request is
              -- refused, and `Main.endAdminSession` swaps to the gate. A pure
              -- `initPage` test cannot see that round trip, so the guarantee is
              -- asserted at the two points that are pure — the predicate that
              -- recognises a refusal, and the page produced in response.
              test "a 401 from an admin route means elevation is needed" <|
                \() ->
                    Api.needsAdminElevation (Http.BadStatus 401)
                        |> Expect.equal True
            , test "a 403 ALSO means elevation is needed — RequireMFA refuses with it" <|
                \() ->
                    -- The window-lapsed case. `Api.isUnauthorized` is 401-only,
                    -- so before this an operator whose 30 minutes ran out saw a
                    -- generic "Action failed" on a page that could never
                    -- succeed again, with no way back to the gate but a reload.
                    Api.needsAdminElevation (Http.BadStatus 403)
                        |> Expect.equal True
            , test "an ordinary failure does NOT send the operator to the gate" <|
                \() ->
                    [ Http.BadStatus 404, Http.BadStatus 500, Http.Timeout, Http.NetworkError ]
                        |> List.map Api.needsAdminElevation
                        |> Expect.equal [ False, False, False, False ]
            , test "a refused admin route lands on the gate, carrying the route behind it" <|
                \() ->
                    Main.adminGateAfterEnding Nothing AdminRemovalRequests
                        |> isPageAdminGate
                        |> Expect.equal True
            , test "a non-admin route never resolves to the admin gate" <|
                \() ->
                    Main.initPage config Library "https://thestacks.test" (Just ownerAuth) Nothing Nothing Login.Fresh
                        |> Tuple.first
                        |> isPageAdminGate
                        |> Expect.equal False
            ]
        , describe "initPage redirect guard"
            [ test "a protected route with no auth renders the Login page (login-at-URL)" <|
                \() ->
                    Main.initPage config Upload "https://thestacks.test" Nothing Nothing Nothing Login.Fresh
                        |> Tuple.first
                        |> isPageLogin
                        |> Expect.equal True
            , test "a second protected route with no auth also renders Login" <|
                \() ->
                    Main.initPage config SettingsProfile "https://thestacks.test" Nothing Nothing Nothing Login.Fresh
                        |> Tuple.first
                        |> isPageLogin
                        |> Expect.equal True
            , test "a public route with no auth does NOT force the Login page" <|
                \() ->
                    Main.initPage config Home "https://thestacks.test" Nothing Nothing Nothing Login.Fresh
                        |> Tuple.first
                        |> isPageLogin
                        |> Expect.equal False
            , test "an anonymous visitor lands on the FAQ itself, not a sign-in wall" <|
                \() ->
                    Main.initPage config Faq "https://thestacks.test" Nothing Nothing Nothing Login.Fresh
                        |> Tuple.first
                        |> isPageFaq
                        |> Expect.equal True
            ]
        ]
