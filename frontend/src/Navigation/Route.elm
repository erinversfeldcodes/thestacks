module Navigation.Route exposing
    ( ConfirmStatus(..)
    , Route(..)
    , fromUrl
    , isSettingsRoute
    , toPath
    , toPattern
    )

import Url exposing (Url)
import Url.Parser as Parser exposing ((</>), Parser, s, string)


{-| Which "you clicked a link in an email" page the reader landed on.

The three `EmailChange*` variants are the email-change flow's landing pages. They
are separate from the registration pair because the reader arrives with a
different question: not "am I in?" but "which address does my account have now?" —
and after a revert, "why was I signed out?".

-}
type ConfirmStatus
    = EmailConfirmed
    | EmailConfirmFailed
    | EmailChangeConfirmed
    | EmailChangeReverted
    | EmailChangeFailed


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
    | Import
    | Search
    | SettingsProfile
    | SettingsPassword
    | SettingsNotifications
    | SettingsAuditLog
    | Insights
    | CostTransparency
    | Metrics
    | About
    | Faq
    | DataTransparency
    | Architecture
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
    | Feedback
    | AdminSourceApproval
    | AdminInvites
    | AdminScraperConfig
    | AdminBookModeration
    | AdminRemovalRequests
    | AdminFeedback
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
        , Parser.map Import (s "import")
        , Parser.map Search (s "search")
        , Parser.map SettingsProfile (s "settings" </> s "profile")
        , Parser.map SettingsPassword (s "settings" </> s "password")
        , Parser.map SettingsNotifications (s "settings" </> s "notifications")
        , -- Consent folded into Privacy (#318 TR-4): the legacy path resolves
          Parser.map SettingsPrivacy (s "settings" </> s "consent")
        , Parser.map SettingsAuditLog (s "settings" </> s "audit-log")
        , Parser.map Insights (s "me" </> s "insights")
        , Parser.map SettingsProfile (s "settings")
        , Parser.map CostTransparency (s "costs")
        , Parser.map Metrics (s "metrics")
        , Parser.map About (s "about")
        , Parser.map Faq (s "faq")
        , Parser.map DataTransparency (s "transparency")
        , Parser.map Architecture (s "architecture")
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
        , Parser.map Feedback (s "feedback")
        , Parser.map AdminSourceApproval (s "admin" </> s "sources")
        , Parser.map AdminFeedback (s "admin" </> s "feedback")
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
        , Parser.map (ConfirmEmail EmailChangeConfirmed) (s "confirm-email" </> s "change-confirmed")
        , Parser.map (ConfirmEmail EmailChangeReverted) (s "confirm-email" </> s "change-reverted")
        , Parser.map (ConfirmEmail EmailChangeFailed) (s "confirm-email" </> s "change-error")
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

        Import ->
            "/import"

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

        Faq ->
            "/faq"

        DataTransparency ->
            "/transparency"

        Architecture ->
            "/architecture"

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

        Feedback ->
            "/feedback"

        AdminSourceApproval ->
            "/admin/sources"

        AdminFeedback ->
            "/admin/feedback"

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

        ConfirmEmail EmailChangeConfirmed ->
            "/confirm-email/change-confirmed"

        ConfirmEmail EmailChangeReverted ->
            "/confirm-email/change-reverted"

        ConfirmEmail EmailChangeFailed ->
            "/confirm-email/change-error"

        ForgotPassword ->
            "/forgot-password"

        ResendConfirmation ->
            "/resend-confirmation"

        ResetPassword token ->
            "/reset-password/" ++ token

        NotFound ->
            "/not-found"


{-| The shape of a route's path, with every argument replaced by its name.

⚠️ **This is not a cosmetic variant of `toPath`.** `toPath (Profile "mara")` is
`/u/mara` — another reader's handle, and a bug report that captured it would be
putting a person who was never involved into a support record. `toPattern`
gives `/u/:handle`, which is everything a bug report actually needs.

The case has **no wildcard**, deliberately. A new route with an argument is a
compile error here until someone writes its pattern, which is the only reliable
way to stop the next parameterised route from quietly leaking its argument.

-}
toPattern : Route -> String
toPattern route =
    case route of
        BookDetail _ ->
            "/books/:id"

        MarketplaceDetail _ ->
            "/marketplace/:id"

        BlogEdit _ ->
            "/blog/:id/edit"

        BlogPost _ ->
            "/blog/:id"

        GroupDetail _ ->
            "/groups/:id"

        Profile _ ->
            "/u/:handle"

        ProfileShelf _ _ ->
            "/u/:handle/:bookshelf"

        ConfirmEmail _ ->
            "/confirm-email"

        ResetPassword _ ->
            "/reset-password/:token"

        Home ->
            toPath Home

        Login ->
            toPath Login

        Library ->
            toPath Library

        AntiLibrary ->
            toPath AntiLibrary

        WishList ->
            toPath WishList

        ReadingPile ->
            toPath ReadingPile

        LookingForHome ->
            toPath LookingForHome

        Upload ->
            toPath Upload

        Import ->
            toPath Import

        Search ->
            toPath Search

        SettingsProfile ->
            toPath SettingsProfile

        SettingsPassword ->
            toPath SettingsPassword

        SettingsNotifications ->
            toPath SettingsNotifications

        SettingsAuditLog ->
            toPath SettingsAuditLog

        Insights ->
            toPath Insights

        CostTransparency ->
            toPath CostTransparency

        Metrics ->
            toPath Metrics

        Faq ->
            toPath Faq

        About ->
            toPath About

        DataTransparency ->
            toPath DataTransparency

        Architecture ->
            toPath Architecture

        ListingRemoval ->
            toPath ListingRemoval

        Catalogue ->
            toPath Catalogue

        MarketplaceBrowse ->
            toPath MarketplaceBrowse

        MarketplaceCreate ->
            toPath MarketplaceCreate

        MarketplaceMyListings ->
            toPath MarketplaceMyListings

        SettingsPrivacy ->
            toPath SettingsPrivacy

        BlogArchive ->
            toPath BlogArchive

        BlogNew ->
            toPath BlogNew

        Feedback ->
            toPath Feedback

        AdminSourceApproval ->
            toPath AdminSourceApproval

        AdminInvites ->
            toPath AdminInvites

        AdminScraperConfig ->
            toPath AdminScraperConfig

        AdminBookModeration ->
            toPath AdminBookModeration

        AdminRemovalRequests ->
            toPath AdminRemovalRequests

        AdminFeedback ->
            toPath AdminFeedback

        Groups ->
            toPath Groups

        ForgotPassword ->
            toPath ForgotPassword

        ResendConfirmation ->
            toPath ResendConfirmation

        NotFound ->
            toPath NotFound


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
