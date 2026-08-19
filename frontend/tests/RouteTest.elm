module RouteTest exposing (suite)

import Expect
import Navigation.Route as Route exposing (ConfirmStatus(..), Route(..))
import Test exposing (Test, describe, test)
import Url


fromPath : String -> Route
fromPath path =
    let
        urlStr =
            "http://localhost" ++ path

        maybeUrl =
            Url.fromString urlStr
    in
    case maybeUrl of
        Just url ->
            Route.fromUrl url

        Nothing ->
            NotFound


{-| Every `Route` constructor with a sample argument. `routeLabel` below is an
exhaustive case (no wildcard), so adding a constructor to the `Route` union is
a compile error here until it is added to this list and covered by the
round-trip property.
-}
allRoutes : List Route
allRoutes =
    [ Home
    , Login
    , Library
    , AntiLibrary
    , WishList
    , ReadingPile
    , LookingForHome
    , BookDetail "abc123"
    , Upload
    , Import
    , Search
    , SettingsProfile
    , SettingsPassword
    , SettingsNotifications
    , SettingsAuditLog
    , Insights
    , CostTransparency
    , Metrics
    , DataTransparency
    , About
    , Faq
    , Feedback
    , ListingRemoval
    , Catalogue
    , MarketplaceBrowse
    , MarketplaceCreate
    , MarketplaceMyListings
    , MarketplaceDetail "listing-1"
    , SettingsPrivacy
    , BlogArchive
    , BlogNew
    , BlogEdit "post-1"
    , BlogPost "post-1"
    , AdminSourceApproval
    , AdminScraperConfig
    , AdminBookModeration
    , AdminRemovalRequests
    , AdminInvites
    , AdminFeedback
    , Groups
    , GroupDetail "group-1"
    , Profile "handle"
    , ProfileShelf "handle" "library"
    , ConfirmEmail EmailConfirmed
    , ConfirmEmail EmailConfirmFailed
    , ConfirmEmail EmailChangeConfirmed
    , ConfirmEmail EmailChangeReverted
    , ConfirmEmail EmailChangeFailed
    , ForgotPassword
    , ResetPassword "tok-abc123"
    , NotFound
    ]


{-| Exhaustive on purpose — a new `Route` constructor fails to compile here,
forcing it into `allRoutes` (and thus into the round-trip property).
-}
routeLabel : Route -> String
routeLabel route =
    case route of
        Home ->
            "Home"

        Login ->
            "Login"

        Library ->
            "Library"

        AntiLibrary ->
            "AntiLibrary"

        WishList ->
            "WishList"

        ReadingPile ->
            "ReadingPile"

        LookingForHome ->
            "LookingForHome"

        BookDetail _ ->
            "BookDetail"

        Upload ->
            "Upload"

        Import ->
            "Import"

        Search ->
            "Search"

        SettingsProfile ->
            "SettingsProfile"

        SettingsPassword ->
            "SettingsPassword"

        SettingsNotifications ->
            "SettingsNotifications"

        SettingsAuditLog ->
            "SettingsAuditLog"

        Insights ->
            "Insights"

        CostTransparency ->
            "CostTransparency"

        Metrics ->
            "Metrics"

        DataTransparency ->
            "DataTransparency"

        About ->
            "About"

        Faq ->
            "Faq"

        Feedback ->
            "Feedback"

        ListingRemoval ->
            "ListingRemoval"

        Catalogue ->
            "Catalogue"

        MarketplaceBrowse ->
            "MarketplaceBrowse"

        MarketplaceCreate ->
            "MarketplaceCreate"

        MarketplaceMyListings ->
            "MarketplaceMyListings"

        MarketplaceDetail _ ->
            "MarketplaceDetail"

        SettingsPrivacy ->
            "SettingsPrivacy"

        BlogArchive ->
            "BlogArchive"

        BlogNew ->
            "BlogNew"

        BlogEdit _ ->
            "BlogEdit"

        BlogPost _ ->
            "BlogPost"

        AdminSourceApproval ->
            "AdminSourceApproval"

        AdminInvites ->
            "AdminInvites"

        AdminScraperConfig ->
            "AdminScraperConfig"

        AdminBookModeration ->
            "AdminBookModeration"

        AdminRemovalRequests ->
            "AdminRemovalRequests"

        AdminFeedback ->
            "AdminFeedback"

        Groups ->
            "Groups"

        GroupDetail _ ->
            "GroupDetail"

        Profile _ ->
            "Profile"

        ProfileShelf _ _ ->
            "ProfileShelf"

        ConfirmEmail EmailConfirmed ->
            "ConfirmEmail EmailConfirmed"

        ConfirmEmail EmailConfirmFailed ->
            "ConfirmEmail EmailConfirmFailed"

        ConfirmEmail EmailChangeConfirmed ->
            "ConfirmEmail EmailChangeConfirmed"

        ConfirmEmail EmailChangeReverted ->
            "ConfirmEmail EmailChangeReverted"

        ConfirmEmail EmailChangeFailed ->
            "ConfirmEmail EmailChangeFailed"

        ForgotPassword ->
            "ForgotPassword"

        ResendConfirmation ->
            "ResendConfirmation"

        ResetPassword _ ->
            "ResetPassword"

        NotFound ->
            "NotFound"


roundTripTest : Route -> Test
roundTripTest route =
    test (routeLabel route ++ " survives fromUrl (toPath r)") <|
        \_ ->
            fromPath (Route.toPath route)
                |> Expect.equal route


suite : Test
suite =
    describe "Route"
        [ describe "fromUrl (toPath r) == r for every Route constructor"
            (List.map roundTripTest allRoutes)
        , describe "fromUrl / toPath round-trips"
            [ test "bare /settings parses to SettingsProfile" <|
                \_ ->
                    fromPath "/settings"
                        |> Expect.equal SettingsProfile
            , test "Home" <|
                \_ ->
                    fromPath "/"
                        |> Expect.equal Home
            , test "Library" <|
                \_ ->
                    fromPath "/library"
                        |> Expect.equal Library
            , test "AntiLibrary" <|
                \_ ->
                    fromPath "/antilibrary"
                        |> Expect.equal AntiLibrary
            , test "WishList" <|
                \_ ->
                    fromPath "/wishlist"
                        |> Expect.equal WishList
            , test "ReadingPile" <|
                \_ ->
                    fromPath "/reading-pile"
                        |> Expect.equal ReadingPile
            , test "LookingForHome" <|
                \_ ->
                    fromPath "/looking-for-home"
                        |> Expect.equal LookingForHome
            , test "BookDetail" <|
                \_ ->
                    fromPath "/books/abc123"
                        |> Expect.equal (BookDetail "abc123")
            , test "ForgotPassword" <|
                \_ ->
                    fromPath "/forgot-password"
                        |> Expect.equal ForgotPassword
            , test "ResetPassword carries the token" <|
                \_ ->
                    fromPath "/reset-password/tok-abc123"
                        |> Expect.equal (ResetPassword "tok-abc123")
            , test "ResendConfirmation" <|
                \_ ->
                    fromPath "/resend-confirmation"
                        |> Expect.equal ResendConfirmation
            , test "ForgotPassword toPath round-trips" <|
                \_ ->
                    Route.toPath ForgotPassword
                        |> Expect.equal "/forgot-password"
            , test "ResendConfirmation toPath round-trips" <|
                \_ ->
                    Route.toPath ResendConfirmation
                        |> Expect.equal "/resend-confirmation"
            , test "ResetPassword toPath round-trips" <|
                \_ ->
                    Route.toPath (ResetPassword "tok-abc123")
                        |> Expect.equal "/reset-password/tok-abc123"
            , test "Upload" <|
                \_ ->
                    fromPath "/upload"
                        |> Expect.equal Upload
            , test "Search" <|
                \_ ->
                    fromPath "/search"
                        |> Expect.equal Search
            , -- #318 TR-4: the consent page folded into Privacy. The legacy path
              test "legacy /settings/consent resolves to Privacy" <|
                \_ ->
                    fromPath "/settings/consent"
                        |> Expect.equal SettingsPrivacy
            , test "Catalogue" <|
                \_ ->
                    fromPath "/catalogue"
                        |> Expect.equal Catalogue
            , test "Metrics" <|
                \_ ->
                    fromPath "/metrics"
                        |> Expect.equal Metrics
            , test "DataTransparency" <|
                \_ ->
                    fromPath "/transparency"
                        |> Expect.equal DataTransparency
            , test "About" <|
                \_ ->
                    fromPath "/about"
                        |> Expect.equal About
            , test "Faq" <|
                \_ ->
                    fromPath "/faq"
                        |> Expect.equal Faq
            , test "a /faq fragment still parses to Faq" <|
                \_ ->
                    fromPath "/faq#erasure"
                        |> Expect.equal Faq
            , test "Insights" <|
                \_ ->
                    fromPath "/me/insights"
                        |> Expect.equal Insights
            , test "AdminBookModeration" <|
                \_ ->
                    fromPath "/admin/book-moderation"
                        |> Expect.equal AdminBookModeration
            , test "Feedback" <|
                \_ ->
                    fromPath "/feedback"
                        |> Expect.equal Feedback
            , test "AdminFeedback" <|
                \_ ->
                    fromPath "/admin/feedback"
                        |> Expect.equal AdminFeedback
            , test "unknown path returns NotFound" <|
                \_ ->
                    fromPath "/does-not-exist"
                        |> Expect.equal NotFound
            ]
        , describe "toPath"
            [ test "Home path" <|
                \_ ->
                    Route.toPath Home
                        |> Expect.equal "/"
            , test "Library path" <|
                \_ ->
                    Route.toPath Library
                        |> Expect.equal "/library"
            , test "AntiLibrary path" <|
                \_ ->
                    Route.toPath AntiLibrary
                        |> Expect.equal "/antilibrary"
            , test "WishList path" <|
                \_ ->
                    Route.toPath WishList
                        |> Expect.equal "/wishlist"
            , test "ReadingPile path" <|
                \_ ->
                    Route.toPath ReadingPile
                        |> Expect.equal "/reading-pile"
            , test "LookingForHome path" <|
                \_ ->
                    Route.toPath LookingForHome
                        |> Expect.equal "/looking-for-home"
            , test "BookDetail path" <|
                \_ ->
                    Route.toPath (BookDetail "xyz")
                        |> Expect.equal "/books/xyz"
            , test "Upload path" <|
                \_ ->
                    Route.toPath Upload
                        |> Expect.equal "/upload"
            , test "Search path" <|
                \_ ->
                    Route.toPath Search
                        |> Expect.equal "/search"
            , test "Catalogue path" <|
                \_ ->
                    Route.toPath Catalogue
                        |> Expect.equal "/catalogue"
            , test "Metrics path" <|
                \_ ->
                    Route.toPath Metrics
                        |> Expect.equal "/metrics"
            , test "About path" <|
                \_ ->
                    Route.toPath About
                        |> Expect.equal "/about"
            , test "Faq path" <|
                \_ ->
                    Route.toPath Faq
                        |> Expect.equal "/faq"
            , test "Insights path" <|
                \_ ->
                    Route.toPath Insights
                        |> Expect.equal "/me/insights"
            , test "AdminBookModeration path" <|
                \_ ->
                    Route.toPath AdminBookModeration
                        |> Expect.equal "/admin/book-moderation"
            ]
        ]
