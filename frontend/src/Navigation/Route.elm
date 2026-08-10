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
    | SettingsProfile
    | SettingsPassword
    | SettingsNotifications
    | SettingsAuditLog
    | Insights
    | CostTransparency
    | Metrics
    | About
    | ListingRemoval
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
    | AdminInvites
    | AdminScraperConfig
    | AdminBookModeration
    | AdminRemovalRequests
    | Groups
    | GroupDetail String
    | Profile String
    | ProfileShelf String String
    | ConfirmEmail ConfirmStatus
    | ForgotPassword
    | ResendConfirmation
    | ResetPassword String
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
        , -- Consent folded into Privacy (#318 TR-4): the legacy path resolves
          -- to the Privacy page so an in-app hit never 404s. A full-page load /
          -- bookmark is 302-redirected server-side to /settings/privacy before
          -- the SPA even boots (CoreWeb.Router + PageController.redirect_consent).
          Parser.map SettingsPrivacy (s "settings" </> s "consent")
        , Parser.map SettingsAuditLog (s "settings" </> s "audit-log")
        , Parser.map Insights (s "me" </> s "insights")
        , Parser.map SettingsProfile (s "settings")
        , Parser.map CostTransparency (s "costs")
        , Parser.map Metrics (s "metrics")
        , Parser.map About (s "about")
        , Parser.map ListingRemoval (s "listing-removal")
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
        , Parser.map AdminInvites (s "admin" </> s "invites")
        , Parser.map AdminScraperConfig (s "admin" </> s "scrapers")
        , Parser.map AdminBookModeration (s "admin" </> s "book-moderation")
        , Parser.map AdminRemovalRequests (s "admin" </> s "removal-requests")
        , Parser.map GroupDetail (s "groups" </> string)
        , Parser.map Groups (s "groups")
        , Parser.map ProfileShelf (s "u" </> string </> string)
        , Parser.map Profile (s "u" </> string)
        , Parser.map (ConfirmEmail EmailConfirmed) (s "confirm-email" </> s "success")
        , Parser.map (ConfirmEmail EmailConfirmFailed) (s "confirm-email" </> s "error")
        , Parser.map ForgotPassword (s "forgot-password")
        , Parser.map ResendConfirmation (s "resend-confirmation")
        , Parser.map ResetPassword (s "reset-password" </> string)
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

        SettingsProfile ->
            "/settings/profile"

        SettingsPassword ->
            "/settings/password"

        SettingsNotifications ->
            "/settings/notifications"

        SettingsAuditLog ->
            "/settings/audit-log"

        Insights ->
            "/me/insights"

        CostTransparency ->
            "/costs"

        Metrics ->
            "/metrics"

        About ->
            "/about"

        ListingRemoval ->
            "/listing-removal"

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

        AdminInvites ->
            "/admin/invites"

        AdminScraperConfig ->
            "/admin/scrapers"

        AdminBookModeration ->
            "/admin/book-moderation"

        AdminRemovalRequests ->
            "/admin/removal-requests"

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

        ForgotPassword ->
            "/forgot-password"

        ResendConfirmation ->
            "/resend-confirmation"

        ResetPassword token ->
            "/reset-password/" ++ token

        NotFound ->
            "/not-found"


isSettingsRoute : Route -> Bool
isSettingsRoute route =
    case route of
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

        SettingsPrivacy ->
            True

        _ ->
            False
