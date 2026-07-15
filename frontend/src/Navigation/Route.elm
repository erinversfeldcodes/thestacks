module Navigation.Route exposing
    ( ConfirmStatus(..)
    , Route(..)
    , fromUrl
    , isSettingsRoute
    , toPath
    )

import Url exposing (Url)
import Url.Parser as Parser exposing ((</>), Parser, s, string)


type ConfirmStatus
    = EmailConfirmed
    | EmailConfirmFailed


type Route
    = Home
    | Login
    | Library
    | AntiLibrary
    | WishList
    | ReadingPile
    | LookingForHome
    | BookDetail String
    | Upload
    | Search
    | Settings
    | SettingsProfile
    | SettingsPassword
    | SettingsNotifications
    | SettingsConsent
    | SettingsAgeVerification
    | SettingsAuditLog
    | CostTransparency
    | Metrics
    | About
    | Catalogue
    | MarketplaceBrowse
    | MarketplaceCreate
    | MarketplaceMyListings
    | MarketplaceDetail String
    | SettingsPrivacy
    | BlogArchive
    | BlogNew
    | BlogEdit String
    | BlogPost String
    | AdminSourceApproval
    | AdminScraperConfig
    | AdminMetrics
    | Groups
    | GroupDetail String
    | Profile String
    | ProfileShelf String String
    | ConfirmEmail ConfirmStatus
    | NotFound


parser : Parser (Route -> a) a
parser =
    Parser.oneOf
        [ Parser.map Home Parser.top
        , Parser.map Login (s "login")
        , Parser.map Library (s "library")
        , Parser.map AntiLibrary (s "antilibrary")
        , Parser.map WishList (s "wishlist")
        , Parser.map ReadingPile (s "reading-pile")
        , Parser.map LookingForHome (s "looking-for-home")
        , Parser.map BookDetail (s "books" </> string)
        , Parser.map Upload (s "upload")
        , Parser.map Search (s "search")
        , Parser.map SettingsProfile (s "settings" </> s "profile")
        , Parser.map SettingsPassword (s "settings" </> s "password")
        , Parser.map SettingsNotifications (s "settings" </> s "notifications")
        , Parser.map SettingsConsent (s "settings" </> s "consent")
        , Parser.map SettingsAgeVerification (s "settings" </> s "age-verification")
        , Parser.map SettingsAuditLog (s "settings" </> s "audit-log")
        , Parser.map Settings (s "settings")
        , Parser.map CostTransparency (s "costs")
        , Parser.map Metrics (s "metrics")
        , Parser.map About (s "about")
        , Parser.map Catalogue (s "catalogue")
        , Parser.map MarketplaceCreate (s "marketplace" </> s "create")
        , Parser.map MarketplaceMyListings (s "marketplace" </> s "mine")
        , Parser.map MarketplaceDetail (s "marketplace" </> string)
        , Parser.map MarketplaceBrowse (s "marketplace")
        , Parser.map SettingsPrivacy (s "settings" </> s "privacy")
        , Parser.map BlogNew (s "blog" </> s "new")
        , Parser.map BlogEdit (s "blog" </> string </> s "edit")
        , Parser.map BlogPost (s "blog" </> string)
        , Parser.map BlogArchive (s "blog")
        , Parser.map AdminSourceApproval (s "admin" </> s "sources")
        , Parser.map AdminScraperConfig (s "admin" </> s "scrapers")
        , Parser.map AdminMetrics (s "admin" </> s "metrics")
        , Parser.map GroupDetail (s "groups" </> string)
        , Parser.map Groups (s "groups")
        , Parser.map ProfileShelf (s "u" </> string </> string)
        , Parser.map Profile (s "u" </> string)
        , Parser.map (ConfirmEmail EmailConfirmed) (s "confirm-email" </> s "success")
        , Parser.map (ConfirmEmail EmailConfirmFailed) (s "confirm-email" </> s "error")
        ]


fromUrl : Url -> Route
fromUrl url =
    Parser.parse parser url
        |> Maybe.withDefault NotFound


toPath : Route -> String
toPath route =
    case route of
        Home ->
            "/"

        Login ->
            "/login"

        Library ->
            "/library"

        AntiLibrary ->
            "/antilibrary"

        WishList ->
            "/wishlist"

        ReadingPile ->
            "/reading-pile"

        LookingForHome ->
            "/looking-for-home"

        BookDetail bookId ->
            "/books/" ++ bookId

        Upload ->
            "/upload"

        Search ->
            "/search"

        Settings ->
            "/settings/profile"

        SettingsProfile ->
            "/settings/profile"

        SettingsPassword ->
            "/settings/password"

        SettingsNotifications ->
            "/settings/notifications"

        SettingsConsent ->
            "/settings/consent"

        SettingsAgeVerification ->
            "/settings/age-verification"

        SettingsAuditLog ->
            "/settings/audit-log"

        CostTransparency ->
            "/costs"

        Metrics ->
            "/metrics"

        About ->
            "/about"

        Catalogue ->
            "/catalogue"

        MarketplaceBrowse ->
            "/marketplace"

        MarketplaceCreate ->
            "/marketplace/create"

        MarketplaceMyListings ->
            "/marketplace/mine"

        MarketplaceDetail listingId ->
            "/marketplace/" ++ listingId

        SettingsPrivacy ->
            "/settings/privacy"

        BlogArchive ->
            "/blog"

        BlogNew ->
            "/blog/new"

        BlogEdit postId ->
            "/blog/" ++ postId ++ "/edit"

        BlogPost postId ->
            "/blog/" ++ postId

        AdminSourceApproval ->
            "/admin/sources"

        AdminScraperConfig ->
            "/admin/scrapers"

        AdminMetrics ->
            "/admin/metrics"

        Groups ->
            "/groups"

        GroupDetail groupId ->
            "/groups/" ++ groupId

        Profile handle ->
            "/u/" ++ handle

        ProfileShelf handle shelfName ->
            "/u/" ++ handle ++ "/" ++ shelfName

        ConfirmEmail EmailConfirmed ->
            "/confirm-email/success"

        ConfirmEmail EmailConfirmFailed ->
            "/confirm-email/error"

        NotFound ->
            "/not-found"


isSettingsRoute : Route -> Bool
isSettingsRoute route =
    case route of
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

        SettingsAgeVerification ->
            True

        SettingsAuditLog ->
            True

        SettingsPrivacy ->
            True

        _ ->
            False
