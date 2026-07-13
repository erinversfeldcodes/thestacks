port module Main exposing
    ( Auth
    , ExternalAuthOutcome(..)
    , LoginEffect(..)
    , PendingLogout
    , StoredAuthResolution(..)
    , adoptExternalAuth
    , decodeFlags
    , loginEffects
    , main
    , parkPending
    , renewAuthToken
    , resolveRecheck
    , shouldShowOnboarding
    , viewNav
    )

import Animation.RoomTransition as RoomTransition
import Animation.SlideTransition as SlideTransition
import Api
import Browser
import Browser.Dom
import Browser.Events
import Browser.Navigation as Nav
import Components.OnboardingOverlay as OnboardingOverlay
import Components.UserMenu as UserMenu
import Components.ViewAsBar as ViewAsBar
import Html exposing (Html, a, div, footer, h1, header, li, main_, nav, p, text, ul)
import Html.Attributes exposing (attribute, class, href, id)
import Http
import Json.Decode as Decode
import Json.Encode
import Navigation.Route as Route exposing (ConfirmStatus(..), Route(..), isSettingsRoute)
import Navigation.SwipeNavigation as SwipeNavigation
import Page.Admin.Metrics as AdminMetrics
import Page.Admin.ScraperConfig as AdminScraperConfig
import Page.Admin.SourceApproval as AdminSourceApproval
import Page.Blog.Archive as BlogArchive
import Page.Blog.Editor as BlogEditor
import Page.Blog.Post as BlogPostPage
import Page.BookDetail as BookDetail
import Page.Bookshelf as Bookshelf
import Page.Bookshelf.LookingForHome as LookingForHome
import Page.Bookshelf.ReadingPile as ReadingPile
import Page.Catalogue as Catalogue
import Page.CostTransparency as CostTransparency
import Page.Groups as Groups
import Page.Groups.Detail as GroupsDetail
import Page.Login as Login
import Page.Marketplace.Browse as MarketplaceBrowse
import Page.Marketplace.CreateListing as CreateListing
import Page.Marketplace.ListingDetail as ListingDetail
import Page.Marketplace.MyListings as MyListings
import Page.Search as Search
import Page.Settings as Settings
import Page.Settings.AgeVerification as AgeVerification
import Page.Settings.AuditLog as AuditLog
import Page.Settings.Consent as Consent
import Page.Settings.Notifications as Notifications
import Page.Settings.Password as Password
import Page.Settings.Privacy as Privacy
import Page.Settings.Profile as Profile
import Page.Upload as Upload
import Process
import Task
import Types.Placement
import Types.RemoteData
import Types.User exposing (AuthToken, User)
import Url exposing (Url)


port onSwipe : (Decode.Value -> msg) -> Sub msg


port playLoginTransition : Json.Encode.Value -> Cmd msg


port onLoginTransitionComplete : (Decode.Value -> msg) -> Sub msg


port saveAuth : Json.Encode.Value -> Cmd msg


port clearAuth : () -> Cmd msg


port saveOnboardingCompleted : () -> Cmd msg


port onOnboardingStatus : (Bool -> msg) -> Sub msg


port openUploadStream : { url : String } -> Cmd msg


port uploadStreamEvent : (String -> msg) -> Sub msg


{-| Persist / clear / request an in-progress marketplace listing draft in
localStorage (Issue #182). `saveListingDraft` is fired when a session expires
mid-compose; `requestListingDraft` is fired when the create page is (re)built and
its answer arrives on `gotListingDraft` (the parsed value, or `null` when absent).
-}
port saveListingDraft : Json.Encode.Value -> Cmd msg


port clearListingDraft : () -> Cmd msg


port requestListingDraft : () -> Cmd msg


port gotListingDraft : (Decode.Value -> msg) -> Sub msg


{-| Cross-tab token propagation (Issue #180 Phase 2). Fires when ANOTHER tab
writes `stacks-auth` in localStorage: `saveAuth` (a sibling tab just rotated its
token → the raw new JSON string) or `clearAuth` (a sibling logged out → `null`).
The writing tab never receives its own event, so there is no feedback loop. The
payload is the raw string / `null`; it is decoded in Elm via `adoptExternalAuth`.
-}
port authChanged : (Decode.Value -> msg) -> Sub msg


{-| Belt-and-suspenders re-check net (Issue #180 Phase 2). Asks JS to read the
CURRENT `stacks-auth` from localStorage; the answer arrives on `gotStoredAuth`.
Fired just before a 401-driven session expiry so a token another tab refreshed
can be adopted instead of logging everyone out.
-}
port requestStoredAuth : () -> Cmd msg


port gotStoredAuth : (Decode.Value -> msg) -> Sub msg


main : Program Decode.Value Model Msg
main =
    Browser.application
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        , onUrlChange = UrlChanged
        , onUrlRequest = LinkClicked
        }



-- MODEL


type Page
    = PageHome
    | PageLogin Login.Model
    | PageBookshelf Bookshelf.Model
    | PageReadingPile ReadingPile.Model
    | PageLookingForHome LookingForHome.Model
    | PageBookDetail BookDetail.Model
    | PageUpload Upload.Model
    | PageSearch Search.Model
    | PageSettingsConsent Consent.Model
    | PageSettingsAgeVerification AgeVerification.Model
    | PageSettingsAuditLog AuditLog.Model
    | PageSettingsProfile Profile.Model
    | PageSettingsPassword Password.Model
    | PageSettingsNotifications Notifications.Model
    | PageCostTransparency CostTransparency.Model
    | PageCatalogue Catalogue.Model
    | PageMarketplaceBrowse MarketplaceBrowse.Model
    | PageMarketplaceCreate CreateListing.Model
    | PageMarketplaceMyListings MyListings.Model
    | PageMarketplaceDetail ListingDetail.Model
    | PageSettingsPrivacy Privacy.Model
    | PageBlogArchive BlogArchive.Model
    | PageBlogEditor BlogEditor.Model
    | PageBlogPost BlogPostPage.Model
    | PageAdminSourceApproval AdminSourceApproval.Model
    | PageAdminScraperConfig AdminScraperConfig.Model
    | PageAdminMetrics AdminMetrics.Model
    | PageGroups Groups.Model
    | PageGroupsDetail GroupsDetail.Model
    | PageConfirmEmail ConfirmStatus
    | PageNotFound


type alias Auth =
    { user : User
    , token : AuthToken
    }


{-| A parked session-expiry intent (Issue #180 Phase 2). Raised when an
authenticated 401 wants to log out; the actual clear+redirect is deferred one
port round-trip (`requestStoredAuth` → `gotStoredAuth`) so a token another tab
refreshed can be adopted first.

  - `draftSaved` carries the marketplace-draft-saved notice (#182) across that
    round-trip so it still shows on the login page.
  - `fromRenewal` records whether the expiry originated from a CONSUMED proactive
    renewal tick (a failed silent refresh). Only then does adopting a newer token
    on re-check re-arm renewal — a page-origin 401 still has its renewal tick
    armed, so re-arming there would spawn a duplicate timer (a refresh storm).

-}
type alias PendingLogout =
    { draftSaved : Bool, fromRenewal : Bool }


{-| Merge a new parked expiry with any intent already in flight (Issue #180
Phase 2, P2). Both flags are STICKY (OR-ed): a later plain expiry must not erase
a `draftSaved` reassurance a draft-expiry parked, and if any origin consumed a
renewal tick the eventual adopt must still re-arm renewal. Pure + testable.
-}
parkPending : Bool -> Bool -> Maybe PendingLogout -> PendingLogout
parkPending draftSaved fromRenewal existing =
    { draftSaved = draftSaved || (existing |> Maybe.map .draftSaved |> Maybe.withDefault False)
    , fromRenewal = fromRenewal || (existing |> Maybe.map .fromRenewal |> Maybe.withDefault False)
    }


type alias BookDetailOverlay =
    { bookId : String
    , detail : BookDetail.Model
    , triggerSpineId : Maybe String
    }


type alias Model =
    { key : Nav.Key
    , url : Url
    , route : Route
    , auth : Maybe Auth
    , page : Page
    , previousRoute : Maybe Route
    , transition : Maybe String
    , pendingAuthResponse : Maybe Api.AuthResponse
    , bookDetailOverlay : Maybe BookDetailOverlay
    , userMenu : UserMenu.Model
    , onboarding : OnboardingOverlay.Model
    , onboardingCompleted : Bool
    , hasAnyPlacements : Bool

    -- Raised by `sessionExpired`; consumed when the Login page is (re)built so the
    -- global session-expiry notice survives the redirect's `UrlChanged`.
    , sessionExpiredNotice : Bool

    -- Raised alongside `sessionExpiredNotice` when the expiry happened while
    -- composing a marketplace listing (Issue #182), so the login notice can
    -- reassure the user their draft was saved.
    , draftSavedNotice : Bool

    -- Raised after a successful account-deletion request (Issue #188); consumed
    -- when the Login page is (re)built so a warm farewell survives the redirect's
    -- `UrlChanged`, mirroring `sessionExpiredNotice`.
    , accountDeletedNotice : Bool

    -- A deferred session-expiry intent (Issue #180 Phase 2): set while the
    -- re-check-before-logout port round-trip is in flight, cleared when it
    -- resolves (adopt a newer token, or proceed to `forceSessionExpiry`).
    , pendingLogout : Maybe PendingLogout
    }


init : Decode.Value -> Url -> Nav.Key -> ( Model, Cmd Msg )
init flags url key =
    let
        maybeAuth =
            decodeFlags flags

        route =
            Route.fromUrl url

        ( page, cmd ) =
            initPage route maybeAuth Nothing
    in
    ( { key = key
      , url = url
      , route = route
      , auth = maybeAuth
      , page = page
      , previousRoute = Nothing
      , transition = Nothing
      , pendingAuthResponse = Nothing
      , bookDetailOverlay = Nothing
      , userMenu = UserMenu.init
      , onboarding = OnboardingOverlay.init
      , onboardingCompleted = False
      , hasAnyPlacements = True
      , sessionExpiredNotice = False
      , draftSavedNotice = False
      , accountDeletedNotice = False
      , pendingLogout = Nothing
      }
    , Cmd.batch
        [ cmd
        , case maybeAuth of
            Just auth ->
                Cmd.batch
                    [ Cmd.map OnboardingMsg (OnboardingOverlay.initCmd auth.token)
                    , Api.getMyPlacements auth.token GotPlacementCheck
                    , scheduleRenewal
                    ]

            Nothing ->
                Cmd.none
        ]
    )


{-| Decoder for a stored-auth JSON object (the exact shape `encodeAuth` writes to
localStorage `stacks-auth`). Lifted to the top level so both `decodeFlags` (boot)
and `adoptExternalAuth` (cross-tab propagation, Issue #180) share one contract.
-}
authDecoder : Decode.Decoder Auth
authDecoder =
    Decode.map7
        (\token userId email displayName role consentAnalytics consentWritingAssistant ->
            { user =
                { id = userId
                , email = email
                , displayName = displayName
                , role = role
                , countryCode = Nothing
                , city = Nothing
                , consentAnalytics = consentAnalytics
                , consentWritingAssistant = consentWritingAssistant
                }
            , token = token
            }
        )
        (Decode.field "token" Decode.string)
        (Decode.field "userId" Decode.string)
        (Decode.field "email" Decode.string)
        (Decode.field "displayName" Decode.string)
        (Decode.oneOf
            [ Decode.field "role" Decode.string
            , Decode.succeed "user"
            ]
        )
        (Decode.oneOf
            [ Decode.field "consentAnalytics" Decode.bool
            , Decode.succeed False
            ]
        )
        (Decode.oneOf
            [ Decode.field "consentWritingAssistant" Decode.bool
            , Decode.succeed False
            ]
        )


decodeFlags : Decode.Value -> Maybe Auth
decodeFlags flags =
    Decode.decodeValue authDecoder flags
        |> Result.toMaybe


isOwner : Maybe Auth -> Bool
isOwner maybeAuth =
    case maybeAuth of
        Just auth ->
            auth.user.role == "owner"

        Nothing ->
            False


requiresAuth : Route -> Bool
requiresAuth route =
    case route of
        Home ->
            False

        Login ->
            False

        CostTransparency ->
            False

        Catalogue ->
            False

        BookDetail _ ->
            False

        MarketplaceBrowse ->
            False

        MarketplaceDetail _ ->
            False

        BlogArchive ->
            False

        BlogPost _ ->
            False

        ConfirmEmail _ ->
            False

        NotFound ->
            False

        _ ->
            True


initPage : Route -> Maybe Auth -> Maybe Route -> ( Page, Cmd Msg )
initPage route maybeAuth maybePreviousRoute =
    if requiresAuth route && maybeAuth == Nothing then
        ( PageLogin Login.init, Cmd.none )

    else
        initPageAuthenticated route maybeAuth maybePreviousRoute


initBookshelf : Bookshelf.Config -> Maybe Auth -> ( Page, Cmd Msg )
initBookshelf config maybeAuth =
    let
        maybeToken =
            Maybe.map .token maybeAuth

        userId =
            maybeAuth |> Maybe.map (.user >> .id) |> Maybe.withDefault ""

        ( model, cmd ) =
            Bookshelf.init config maybeToken userId
    in
    ( PageBookshelf model, Cmd.map BookshelfMsg cmd )


initPageAuthenticated : Route -> Maybe Auth -> Maybe Route -> ( Page, Cmd Msg )
initPageAuthenticated route maybeAuth maybePreviousRoute =
    let
        maybeToken =
            Maybe.map .token maybeAuth
    in
    case route of
        Home ->
            ( PageHome, Cmd.none )

        Login ->
            ( PageLogin Login.init, Cmd.none )

        Library ->
            initBookshelf Bookshelf.libraryConfig maybeAuth

        AntiLibrary ->
            initBookshelf Bookshelf.antiLibraryConfig maybeAuth

        WishList ->
            initBookshelf Bookshelf.wishListConfig maybeAuth

        ReadingPile ->
            let
                ( model, cmd ) =
                    ReadingPile.init maybeToken
            in
            ( PageReadingPile model, Cmd.map ReadingPileMsg cmd )

        LookingForHome ->
            let
                ( subModel, subCmd ) =
                    LookingForHome.init maybeToken
            in
            ( PageLookingForHome subModel, Cmd.map LookingForHomeMsg subCmd )

        BookDetail bookId ->
            let
                ( model, cmd ) =
                    BookDetail.init bookId maybeToken maybePreviousRoute
            in
            ( PageBookDetail model, Cmd.map BookDetailMsg cmd )

        Upload ->
            ( PageUpload Upload.init, Cmd.none )

        Search ->
            ( PageSearch Search.init, Cmd.none )

        SettingsConsent ->
            let
                consentSeed =
                    case maybeAuth of
                        Just auth ->
                            { analytics = auth.user.consentAnalytics
                            , writingAssistant = auth.user.consentWritingAssistant
                            }

                        Nothing ->
                            { analytics = False, writingAssistant = False }
            in
            ( PageSettingsConsent (Consent.init consentSeed), Cmd.none )

        SettingsAgeVerification ->
            ( PageSettingsAgeVerification AgeVerification.init, Cmd.none )

        SettingsAuditLog ->
            let
                ( model, cmd ) =
                    AuditLog.init maybeToken
            in
            ( PageSettingsAuditLog model, Cmd.map AuditLogMsg cmd )

        CostTransparency ->
            let
                ( model, cmd ) =
                    CostTransparency.init
            in
            ( PageCostTransparency model, Cmd.map CostTransparencyMsg cmd )

        Catalogue ->
            let
                ( model, cmd ) =
                    Catalogue.init maybeToken
            in
            ( PageCatalogue model, Cmd.map CatalogueMsg cmd )

        Settings ->
            let
                profileModel =
                    case maybeAuth of
                        Just auth ->
                            Profile.init auth.user

                        Nothing ->
                            Profile.init { id = "", email = "", displayName = "", role = "user", countryCode = Nothing, city = Nothing, consentAnalytics = False, consentWritingAssistant = False }
            in
            ( PageSettingsProfile profileModel, Cmd.none )

        SettingsProfile ->
            let
                profileModel =
                    case maybeAuth of
                        Just auth ->
                            Profile.init auth.user

                        Nothing ->
                            Profile.init { id = "", email = "", displayName = "", role = "user", countryCode = Nothing, city = Nothing, consentAnalytics = False, consentWritingAssistant = False }
            in
            ( PageSettingsProfile profileModel, Cmd.none )

        SettingsPassword ->
            ( PageSettingsPassword Password.init, Cmd.none )

        SettingsNotifications ->
            ( PageSettingsNotifications Notifications.init, Cmd.none )

        MarketplaceBrowse ->
            let
                ( model, cmd ) =
                    MarketplaceBrowse.init maybeToken
            in
            ( PageMarketplaceBrowse model, Cmd.map MarketplaceBrowseMsg cmd )

        MarketplaceCreate ->
            let
                ( model, cmd ) =
                    CreateListing.init maybeToken
            in
            -- Ask JS for any persisted draft; the answer arrives on
            -- `gotListingDraft` and is routed to CreateListing.DraftLoaded (#182).
            ( PageMarketplaceCreate model
            , Cmd.batch
                [ Cmd.map CreateListingMsg cmd
                , requestListingDraft ()
                ]
            )

        MarketplaceMyListings ->
            let
                ( model, cmd ) =
                    MyListings.init maybeToken
            in
            ( PageMarketplaceMyListings model, Cmd.map MyListingsMsg cmd )

        MarketplaceDetail listingId ->
            let
                ( model, cmd ) =
                    ListingDetail.init listingId maybeToken
            in
            ( PageMarketplaceDetail model, Cmd.map ListingDetailMsg cmd )

        SettingsPrivacy ->
            ( PageSettingsPrivacy Privacy.init, Cmd.none )

        BlogArchive ->
            let
                ( blogModel, blogCmd ) =
                    BlogArchive.init maybeToken
            in
            ( PageBlogArchive blogModel, Cmd.map BlogArchiveMsg blogCmd )

        BlogNew ->
            let
                ( editorModel, editorCmd ) =
                    BlogEditor.init BlogEditor.New maybeToken
            in
            ( PageBlogEditor editorModel, Cmd.map BlogEditorMsg editorCmd )

        BlogEdit postId ->
            let
                ( editorModel, editorCmd ) =
                    BlogEditor.init (BlogEditor.Edit postId) maybeToken
            in
            ( PageBlogEditor editorModel, Cmd.map BlogEditorMsg editorCmd )

        Route.BlogPost postId ->
            let
                currentUserId =
                    Maybe.map (.user >> .id) maybeAuth

                writingAssistantConsent =
                    maybeAuth
                        |> Maybe.map (.user >> .consentWritingAssistant)
                        |> Maybe.withDefault False

                ( postModel, postCmd ) =
                    BlogPostPage.init postId maybeToken currentUserId writingAssistantConsent
            in
            ( PageBlogPost postModel, Cmd.map BlogPostMsg postCmd )

        Route.AdminSourceApproval ->
            if isOwner maybeAuth then
                let
                    ( subModel, subCmd ) =
                        AdminSourceApproval.init maybeToken
                in
                ( PageAdminSourceApproval subModel, Cmd.map AdminSourceApprovalMsg subCmd )

            else
                ( PageNotFound, Cmd.none )

        Route.AdminScraperConfig ->
            if isOwner maybeAuth then
                let
                    ( subModel, subCmd ) =
                        AdminScraperConfig.init maybeToken
                in
                ( PageAdminScraperConfig subModel, Cmd.map AdminScraperConfigMsg subCmd )

            else
                ( PageNotFound, Cmd.none )

        Route.AdminMetrics ->
            if isOwner maybeAuth then
                let
                    ( subModel, subCmd ) =
                        AdminMetrics.init maybeToken
                in
                ( PageAdminMetrics subModel, Cmd.map AdminMetricsMsg subCmd )

            else
                ( PageNotFound, Cmd.none )

        Groups ->
            let
                auth =
                    Maybe.withDefault { user = { id = "", email = "", displayName = "", role = "user", countryCode = Nothing, city = Nothing, consentAnalytics = False, consentWritingAssistant = False }, token = "" } maybeAuth

                ( m, cmd ) =
                    Groups.init auth.user.id auth.token
            in
            ( PageGroups m, Cmd.map GroupsMsg cmd )

        GroupDetail groupId ->
            let
                auth =
                    Maybe.withDefault { user = { id = "", email = "", displayName = "", role = "user", countryCode = Nothing, city = Nothing, consentAnalytics = False, consentWritingAssistant = False }, token = "" } maybeAuth

                ( m, cmd ) =
                    GroupsDetail.init groupId auth.user.id auth.token
            in
            ( PageGroupsDetail m, Cmd.map GroupsDetailMsg cmd )

        ConfirmEmail status ->
            ( PageConfirmEmail status, Cmd.none )

        NotFound ->
            ( PageNotFound, Cmd.none )


encodeAuth : Auth -> Json.Encode.Value
encodeAuth auth =
    Json.Encode.object
        [ ( "token", Json.Encode.string auth.token )
        , ( "userId", Json.Encode.string auth.user.id )
        , ( "email", Json.Encode.string auth.user.email )
        , ( "displayName", Json.Encode.string auth.user.displayName )
        , ( "role", Json.Encode.string auth.user.role )
        , ( "consentAnalytics", Json.Encode.bool auth.user.consentAnalytics )
        , ( "consentWritingAssistant", Json.Encode.bool auth.user.consentWritingAssistant )
        ]


{-| The single, central deferred session-expiry entry point (Issue #173 + #180
Phase 2). EVERY authenticated page routes its `SessionExpired` OutMsg here, and a
failed silent renewal falls through here too — so the re-check net lives in ONE
place, not scattered across the ~25 call sites.

Rather than logging out immediately, it parks a `pendingLogout` intent and asks
JS for the CURRENT stored auth (`requestStoredAuth`). The answer arrives on
`gotStoredAuth`, where `adoptExternalAuth` decides: if another tab has stored a
newer token, adopt it (cancel the logout); otherwise fall through to
`forceSessionExpiry`. The round-trip is a single JS tick, so there is no visible
flash. In-memory `auth` is intentionally left intact during the round-trip.

-}
handleSessionExpiry : Model -> ( Model, Cmd Msg )
handleSessionExpiry model =
    ( { model | pendingLogout = Just (parkPending False False model.pendingLogout) }
    , requestStoredAuth ()
    )


{-| As `handleSessionExpiry`, but for a CONSUMED renewal tick (a failed silent
refresh). `fromRenewal = True` so a re-check that adopts a newer token re-arms
renewal — the proactive tick that would have kept the session alive is gone.
-}
handleSessionExpiryFromRenewal : Model -> ( Model, Cmd Msg )
handleSessionExpiryFromRenewal model =
    ( { model | pendingLogout = Just (parkPending False True model.pendingLogout) }
    , requestStoredAuth ()
    )


{-| As `handleSessionExpiry`, but for the marketplace-compose expiry (#182): the
in-progress draft is persisted immediately, and the parked intent remembers to
raise the draft-saved notice if the round-trip does end in a logout.
-}
handleSessionExpiryWithDraft : Json.Encode.Value -> Model -> ( Model, Cmd Msg )
handleSessionExpiryWithDraft draft model =
    ( { model | pendingLogout = Just (parkPending True False model.pendingLogout) }
    , Cmd.batch
        [ saveListingDraft draft
        , requestStoredAuth ()
        ]
    )


{-| The actual, irreversible session-expiry path (Issue #173). Reached only after
the re-check net (`handleSessionExpiry` → `gotStoredAuth`) confirms there is no
newer token to adopt, or from a sibling-tab `clearAuth`. Mirrors sign-out: clears
`model.auth`, drops the `clearAuth ()` port, and redirects to `/login` — raising
`sessionExpiredNotice` (and `draftSavedNotice` when a draft was parked) so the
login page shows an "expired" message distinct from invalid-credentials. The
notice survives the `Nav.pushUrl`-driven `UrlChanged` re-init via the flag.
-}
forceSessionExpiry : Bool -> Model -> ( Model, Cmd Msg )
forceSessionExpiry draftSaved model =
    ( { model
        | auth = Nothing
        , sessionExpiredNotice = True
        , draftSavedNotice = model.draftSavedNotice || draftSaved
        , userMenu = UserMenu.init
        , bookDetailOverlay = Nothing
        , pendingLogout = Nothing
      }
    , Cmd.batch
        [ clearAuth ()
        , Nav.pushUrl model.key (Route.toPath Login)
        ]
    )


{-| The farewell/logout path after a successful account-deletion request
(Issue #188). The backend has queued the erasure; here we tear down the local
session the same way a deliberate sign-out does — clear `model.auth`, reset the
user menu, wipe any persisted listing draft (it carries PII), and redirect to
`/login`. Rather than a bare login page, we raise `accountDeletedNotice` so the
redirect's `UrlChanged` builds the Login page in its farewell state (mirroring
`forceSessionExpiry` → `sessionExpiredNotice`), giving the user a warm goodbye
distinct from an expiry. No `sessionExpiredNotice`: this was a deliberate,
successful action.
-}
handleAccountDeleted : Model -> ( Model, Cmd Msg )
handleAccountDeleted model =
    ( { model
        | auth = Nothing
        , accountDeletedNotice = True
        , userMenu = UserMenu.init
        , bookDetailOverlay = Nothing
        , pendingLogout = Nothing
      }
    , Cmd.batch
        [ clearAuth ()
        , clearListingDraft ()
        , Nav.pushUrl model.key (Route.toPath Login)
        ]
    )


{-| The outcome of interpreting a stored-auth value (Issue #180 Phase 2), used
for BOTH cross-tab propagation and the 401 re-check net.
-}
type ExternalAuthOutcome
    = AdoptAuth Auth
    | LogOutExternally
    | IgnoreExternal


{-| Pure, key-free decision for an externally-observed stored-auth value — a
sibling tab's `storage` event (`AuthChangedExternally`) or the re-check response
(`GotStoredAuth`). The port delivers the RAW localStorage payload: a JSON string
(a `saveAuth` write), JSON `null` (a `clearAuth`), or something unexpected.

  - a valid stored auth whose token DIFFERS from the in-memory token, while
    authed → `AdoptAuth` the stored auth (new token, its user).
  - the SAME token → `IgnoreExternal` (nothing changed; also the writer's own
    echo defence).
  - a valid stored auth while signed out → `IgnoreExternal` (a signed-out tab
    does not spontaneously log in from a sibling).
  - JSON `null` while authed → `LogOutExternally` (a sibling logged out).
  - JSON `null` while signed out, or any garbage → `IgnoreExternal` (never crash
    or log out on undecodable input).

-}
adoptExternalAuth : Decode.Value -> Maybe Auth -> ExternalAuthOutcome
adoptExternalAuth value maybeAuth =
    case Decode.decodeValue (Decode.nullable Decode.string) value of
        Ok (Just raw) ->
            case ( Decode.decodeString authDecoder raw, maybeAuth ) of
                ( Ok incoming, Just current ) ->
                    if incoming.token == current.token then
                        IgnoreExternal

                    else
                        AdoptAuth incoming

                ( Ok _, Nothing ) ->
                    IgnoreExternal

                ( Err _, _ ) ->
                    IgnoreExternal

        Ok Nothing ->
            -- JSON null: a sibling `clearAuth`. Log this tab out too, but only if
            -- it is currently authed (a signed-out tab has nothing to clear).
            case maybeAuth of
                Just _ ->
                    LogOutExternally

                Nothing ->
                    IgnoreExternal

        Err _ ->
            -- Not a string and not null (unexpected shape): ignore, never log out.
            IgnoreExternal


{-| The resolution of a re-check (`gotStoredAuth`) answer against the parked
intent (Issue #180 Phase 2). Pure, so the reschedule decision — opaque as a `Cmd`
— is unit-testable.

  - `ResolveAdopt auth reschedule` — adopt `auth`, cancel the logout; `reschedule`
    is `True` only for a renewal-origin expiry (P1b: a page-origin 401 still has
    its renewal tick armed, so re-arming would duplicate the timer).
  - `ResolveForceLogout draftSaved` — nothing newer to adopt; proceed to logout.
  - `ResolveNoop` — no parked intent (e.g. a cross-tab adopt already cancelled it,
    P1a): a late answer must NOT log out.

-}
type StoredAuthResolution
    = ResolveAdopt Auth Bool
    | ResolveForceLogout Bool
    | ResolveNoop


{-| Decide what a re-check answer means, given the parked intent and the decoded
outcome. See `StoredAuthResolution`. Pure and key-free.
-}
resolveRecheck : Maybe PendingLogout -> ExternalAuthOutcome -> StoredAuthResolution
resolveRecheck maybePending outcome =
    case maybePending of
        Nothing ->
            ResolveNoop

        Just pending ->
            case outcome of
                AdoptAuth newAuth ->
                    ResolveAdopt newAuth pending.fromRenewal

                LogOutExternally ->
                    ResolveForceLogout pending.draftSaved

                IgnoreExternal ->
                    ResolveForceLogout pending.draftSaved


{-| Adopt a freshly-refreshed access token, keeping the same authenticated user.
A token refresh only rotates the credential — identity, role, and location are
unchanged — so the refresh response's user fields are ignored in favour of the
current ones. Pure and key-free, so the renewal-success path is unit-testable.
-}
renewAuthToken : Api.AuthResponse -> Auth -> Auth
renewAuthToken authResponse auth =
    { auth | token = authResponse.token }


{-| How long to wait after receiving an access token before silently renewing it.
The access token TTL is 8h (server-side, Issue #124); we refresh comfortably
before that so an active session never hits a hard 401. A single fixed delay is
used rather than decoding the JWT `exp` claim (the token is opaque to the SPA).
-}
renewalDelayMs : Float
renewalDelayMs =
    7 * 60 * 60 * 1000


{-| Schedule one proactive silent-renewal tick. Fired on every token receipt
(stored-auth `init`, fresh login, and after each successful renewal) so renewal
keeps rolling for the life of the session without a busy loop.
-}
scheduleRenewal : Cmd Msg
scheduleRenewal =
    Process.sleep renewalDelayMs
        |> Task.perform (\_ -> RenewToken)


{-| The side-effects a completed form login must fire.

A stored-auth reload runs the placements + onboarding check in `init`; a fresh
login must run the _same_ effects, otherwise `hasAnyPlacements` never leaves its
optimistic init value (`True`) and the onboarding overlay can never appear for a
brand-new, placement-free user. Exposed so tests can assert the fetch happens.

-}
type LoginEffect
    = PersistAuth
    | NavigateHome
    | FetchPlacements
    | InitOnboarding
    | ScheduleRenewal


{-| Effects performed when a login completes (form login, both the immediate and
post-transition paths). Mirrors what `init` does for a stored auth.
-}
loginEffects : List LoginEffect
loginEffects =
    [ PersistAuth
    , NavigateHome
    , FetchPlacements
    , InitOnboarding
    , ScheduleRenewal
    ]


{-| Realise a single `LoginEffect` as a concrete `Cmd` for a completed login.
-}
loginEffectCmd : Nav.Key -> Auth -> LoginEffect -> Cmd Msg
loginEffectCmd key auth effect =
    case effect of
        PersistAuth ->
            saveAuth (encodeAuth auth)

        NavigateHome ->
            Nav.pushUrl key (Route.toPath AntiLibrary)

        FetchPlacements ->
            Api.getMyPlacements auth.token GotPlacementCheck

        InitOnboarding ->
            Cmd.map OnboardingMsg (OnboardingOverlay.initCmd auth.token)

        ScheduleRenewal ->
            scheduleRenewal


{-| All commands a completed login must fire, given the base command already
produced by the login sub-update.
-}
loginCompletionCmd : Nav.Key -> Auth -> Cmd Msg -> Cmd Msg
loginCompletionCmd key auth baseCmd =
    Cmd.batch (baseCmd :: List.map (loginEffectCmd key auth) loginEffects)



-- UPDATE


type Msg
    = LinkClicked Browser.UrlRequest
    | UrlChanged Url
    | LoginMsg Login.Msg
    | LoginTransitionCompleted
    | BookshelfMsg Bookshelf.Msg
    | ReadingPileMsg ReadingPile.Msg
    | LookingForHomeMsg LookingForHome.Msg
    | BookDetailMsg BookDetail.Msg
    | UploadMsg Upload.Msg
    | SearchMsg Search.Msg
    | ConsentMsg Consent.Msg
    | AgeVerificationMsg AgeVerification.Msg
    | AuditLogMsg AuditLog.Msg
    | ProfileMsg Profile.Msg
    | PasswordMsg Password.Msg
    | NotificationsMsg Notifications.Msg
    | CostTransparencyMsg CostTransparency.Msg
    | CatalogueMsg Catalogue.Msg
    | MarketplaceBrowseMsg MarketplaceBrowse.Msg
    | CreateListingMsg CreateListing.Msg
    | MyListingsMsg MyListings.Msg
    | ListingDetailMsg ListingDetail.Msg
    | PrivacyMsg Privacy.Msg
    | BlogArchiveMsg BlogArchive.Msg
    | BlogEditorMsg BlogEditor.Msg
    | BlogPostMsg BlogPostPage.Msg
    | AdminSourceApprovalMsg AdminSourceApproval.Msg
    | AdminScraperConfigMsg AdminScraperConfig.Msg
    | AdminMetricsMsg AdminMetrics.Msg
    | GroupsMsg Groups.Msg
    | GroupsDetailMsg GroupsDetail.Msg
    | UserMenuMsg UserMenu.Msg
    | LogoutCompleted
    | SettingsMobileNavChanged String
    | SwipeReceived String
    | SwipeIgnored
    | OverlayBookDetailMsg BookDetail.Msg
    | EscapePressed
    | OnboardingMsg OnboardingOverlay.Msg
    | OnboardingStatusReceived Bool
    | FocusResult
    | GotPlacementCheck (Result Http.Error (List Types.Placement.Placement))
    | RenewToken
    | TokenRefreshed (Result Http.Error Api.AuthResponse)
    | AuthChangedExternally Decode.Value
    | GotStoredAuth Decode.Value


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        LinkClicked urlRequest ->
            case urlRequest of
                Browser.Internal url ->
                    case Route.fromUrl url of
                        BookDetail bookId ->
                            let
                                ( overlayModel, overlayCmd ) =
                                    openOverlay model bookId
                            in
                            ( overlayModel, overlayCmd )

                        _ ->
                            ( model, Nav.pushUrl model.key (Url.toString url) )

                Browser.External url ->
                    ( model, Nav.load url )

        UrlChanged url ->
            let
                newRoute =
                    Route.fromUrl url

                transition =
                    Just (transitionClass model.route newRoute)

                ( initialisedPage, cmd ) =
                    initPage newRoute model.auth (Just model.route)

                -- Consume a pending session-expiry notice: when the redirect lands
                -- on /login, build the Login page in its expired-notice state so the
                -- message survives this `UrlChanged` re-init.
                page =
                    if newRoute == Login && model.accountDeletedNotice then
                        PageLogin Login.farewellInit

                    else if newRoute == Login && model.sessionExpiredNotice then
                        if model.draftSavedNotice then
                            PageLogin Login.expiredDraftInit

                        else
                            PageLogin Login.expiredInit

                    else
                        initialisedPage
            in
            ( { model
                | url = url
                , route = newRoute
                , page = page
                , previousRoute = Just model.route
                , transition = transition
                , userMenu = UserMenu.init
                , sessionExpiredNotice =
                    model.sessionExpiredNotice && newRoute /= Login
                , draftSavedNotice =
                    model.draftSavedNotice && newRoute /= Login
                , accountDeletedNotice =
                    model.accountDeletedNotice && newRoute /= Login
              }
            , cmd
            )

        LoginMsg subMsg ->
            case model.page of
                PageLogin subModel ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            Login.update subMsg subModel

                        baseModel =
                            { model | page = PageLogin newSubModel }

                        baseCmd =
                            Cmd.map LoginMsg subCmd
                    in
                    case outMsg of
                        Login.NoOut ->
                            ( baseModel, baseCmd )

                        Login.StartTransition authResponse ->
                            ( { baseModel | pendingAuthResponse = Just authResponse }
                            , Cmd.batch
                                [ baseCmd
                                , playLoginTransition
                                    (Json.Encode.object
                                        [ ( "duration", Json.Encode.int 4000 ) ]
                                    )
                                ]
                            )

                        Login.LoggedIn authResponse ->
                            let
                                auth =
                                    { user =
                                        { id = authResponse.userId
                                        , email = authResponse.email
                                        , displayName = authResponse.displayName
                                        , role = authResponse.role
                                        , countryCode = Nothing
                                        , city = Nothing
                                        , consentAnalytics = authResponse.consentAnalytics
                                        , consentWritingAssistant = authResponse.consentWritingAssistant
                                        }
                                    , token = authResponse.token
                                    }
                            in
                            ( { baseModel | auth = Just auth, pendingAuthResponse = Nothing }
                            , loginCompletionCmd model.key auth baseCmd
                            )

                        Login.RegistrationSucceeded _ ->
                            -- Registration only sends a confirmation email; no JWT is
                            -- issued and no navigation happens. The Login page has already
                            -- switched itself to the pending state via its own model.
                            ( baseModel, baseCmd )

                _ ->
                    ( model, Cmd.none )

        LoginTransitionCompleted ->
            case ( model.page, model.pendingAuthResponse ) of
                ( PageLogin subModel, Just authResponse ) ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            Login.update (Login.TransitionCompleted authResponse) subModel

                        baseModel =
                            { model | page = PageLogin newSubModel }

                        baseCmd =
                            Cmd.map LoginMsg subCmd
                    in
                    case outMsg of
                        Login.LoggedIn ar ->
                            let
                                auth =
                                    { user =
                                        { id = ar.userId
                                        , email = ar.email
                                        , displayName = ar.displayName
                                        , role = ar.role
                                        , countryCode = Nothing
                                        , city = Nothing
                                        , consentAnalytics = ar.consentAnalytics
                                        , consentWritingAssistant = ar.consentWritingAssistant
                                        }
                                    , token = ar.token
                                    }
                            in
                            ( { baseModel | auth = Just auth, pendingAuthResponse = Nothing }
                            , loginCompletionCmd model.key auth baseCmd
                            )

                        _ ->
                            ( baseModel, baseCmd )

                _ ->
                    ( model, Cmd.none )

        BookshelfMsg subMsg ->
            case model.page of
                PageBookshelf subModel ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            Bookshelf.update subMsg subModel

                        hasPlacements =
                            case newSubModel.shelves of
                                Types.RemoteData.Success shelves ->
                                    List.any (\s -> not (List.isEmpty s.placements)) shelves

                                _ ->
                                    model.hasAnyPlacements

                        baseModel =
                            { model
                                | page = PageBookshelf newSubModel
                                , hasAnyPlacements = model.hasAnyPlacements || hasPlacements
                            }

                        baseCmd =
                            Cmd.map BookshelfMsg subCmd
                    in
                    case outMsg of
                        Bookshelf.NoOut ->
                            ( baseModel, baseCmd )

                        Bookshelf.SessionExpired ->
                            handleSessionExpiry model

                        Bookshelf.NavigateTo (BookDetail bookId) ->
                            let
                                ( overlayModel, overlayCmd ) =
                                    openOverlay baseModel bookId
                            in
                            ( overlayModel
                            , Cmd.batch [ baseCmd, overlayCmd ]
                            )

                        Bookshelf.NavigateTo route ->
                            ( baseModel
                            , Cmd.batch
                                [ baseCmd
                                , Nav.pushUrl model.key (Route.toPath route)
                                ]
                            )

                _ ->
                    ( model, Cmd.none )

        ReadingPileMsg subMsg ->
            case model.page of
                PageReadingPile subModel ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            ReadingPile.update subMsg subModel

                        baseModel =
                            { model | page = PageReadingPile newSubModel }

                        baseCmd =
                            Cmd.map ReadingPileMsg subCmd
                    in
                    case outMsg of
                        ReadingPile.NoOut ->
                            ( baseModel, baseCmd )

                        ReadingPile.SessionExpired ->
                            handleSessionExpiry model

                        ReadingPile.NavigateTo (BookDetail bookId) ->
                            let
                                ( overlayModel, overlayCmd ) =
                                    openOverlay baseModel bookId
                            in
                            ( overlayModel
                            , Cmd.batch [ baseCmd, overlayCmd ]
                            )

                        ReadingPile.NavigateTo route ->
                            ( baseModel
                            , Cmd.batch
                                [ baseCmd
                                , Nav.pushUrl model.key (Route.toPath route)
                                ]
                            )

                _ ->
                    ( model, Cmd.none )

        LookingForHomeMsg subMsg ->
            case model.page of
                PageLookingForHome subModel ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            LookingForHome.update subMsg subModel

                        baseModel =
                            { model | page = PageLookingForHome newSubModel }

                        baseCmd =
                            Cmd.map LookingForHomeMsg subCmd
                    in
                    case outMsg of
                        LookingForHome.NoOut ->
                            ( baseModel, baseCmd )

                        LookingForHome.SessionExpired ->
                            handleSessionExpiry model

                        LookingForHome.NavigateTo (Route.BookDetail bookId) ->
                            openOverlay baseModel bookId

                        LookingForHome.NavigateTo route ->
                            ( baseModel
                            , Cmd.batch
                                [ baseCmd
                                , Nav.pushUrl model.key (Route.toPath route)
                                ]
                            )

                _ ->
                    ( model, Cmd.none )

        BookDetailMsg subMsg ->
            case model.page of
                PageBookDetail subModel ->
                    let
                        maybeToken =
                            Maybe.map .token model.auth

                        ( newSubModel, subCmd, outMsg ) =
                            BookDetail.update subMsg subModel maybeToken

                        baseModel =
                            { model | page = PageBookDetail newSubModel }

                        baseCmd =
                            Cmd.map BookDetailMsg subCmd
                    in
                    case outMsg of
                        BookDetail.NoOut ->
                            ( baseModel, baseCmd )

                        BookDetail.SessionExpired ->
                            handleSessionExpiry model

                        BookDetail.RequestCloseOverlay ->
                            ( baseModel, baseCmd )

                        BookDetail.NavigateTo route ->
                            ( baseModel
                            , Cmd.batch
                                [ baseCmd
                                , Nav.pushUrl model.key (Route.toPath route)
                                ]
                            )

                _ ->
                    ( model, Cmd.none )

        UploadMsg subMsg ->
            case model.page of
                PageUpload subModel ->
                    let
                        maybeToken =
                            Maybe.map .token model.auth

                        ( newSubModel, subCmd, outMsg ) =
                            Upload.update subMsg subModel maybeToken

                        baseModel =
                            { model | page = PageUpload newSubModel }

                        baseCmd =
                            Cmd.map UploadMsg subCmd
                    in
                    case outMsg of
                        Upload.NoOut ->
                            ( baseModel, baseCmd )

                        Upload.SessionExpired ->
                            handleSessionExpiry model

                        Upload.NavigateTo route ->
                            ( baseModel
                            , Cmd.batch
                                [ baseCmd
                                , Nav.pushUrl model.key (Route.toPath route)
                                ]
                            )

                        Upload.OpenStream url ->
                            ( baseModel
                            , Cmd.batch
                                [ baseCmd
                                , openUploadStream { url = url }
                                ]
                            )

                _ ->
                    ( model, Cmd.none )

        SearchMsg subMsg ->
            case model.page of
                PageSearch subModel ->
                    let
                        maybeToken =
                            Maybe.map .token model.auth

                        ( newSubModel, subCmd, outMsg ) =
                            Search.update subMsg subModel maybeToken
                    in
                    case outMsg of
                        Search.NoOut ->
                            ( { model | page = PageSearch newSubModel }
                            , Cmd.map SearchMsg subCmd
                            )

                        Search.SessionExpired ->
                            handleSessionExpiry model

                _ ->
                    ( model, Cmd.none )

        ConsentMsg subMsg ->
            case model.page of
                PageSettingsConsent subModel ->
                    let
                        maybeToken =
                            Maybe.map .token model.auth

                        ( newSubModel, subCmd, outMsg ) =
                            Consent.update subMsg subModel maybeToken
                    in
                    case outMsg of
                        Consent.NoOut ->
                            ( { model | page = PageSettingsConsent newSubModel }
                            , Cmd.map ConsentMsg subCmd
                            )

                        Consent.SessionExpired ->
                            handleSessionExpiry model

                _ ->
                    ( model, Cmd.none )

        AuditLogMsg subMsg ->
            case model.page of
                PageSettingsAuditLog subModel ->
                    let
                        maybeToken =
                            Maybe.map .token model.auth

                        ( newSubModel, subCmd, outMsg ) =
                            AuditLog.update subMsg subModel maybeToken
                    in
                    case outMsg of
                        AuditLog.NoOut ->
                            ( { model | page = PageSettingsAuditLog newSubModel }
                            , Cmd.map AuditLogMsg subCmd
                            )

                        AuditLog.SessionExpired ->
                            handleSessionExpiry model

                _ ->
                    ( model, Cmd.none )

        AgeVerificationMsg subMsg ->
            case model.page of
                PageSettingsAgeVerification subModel ->
                    let
                        maybeToken =
                            Maybe.map .token model.auth

                        ( newSubModel, subCmd, outMsg ) =
                            AgeVerification.update subMsg subModel maybeToken
                    in
                    case outMsg of
                        AgeVerification.NoOut ->
                            ( { model | page = PageSettingsAgeVerification newSubModel }
                            , Cmd.map AgeVerificationMsg subCmd
                            )

                        AgeVerification.SessionExpired ->
                            handleSessionExpiry model

                _ ->
                    ( model, Cmd.none )

        ProfileMsg subMsg ->
            case model.page of
                PageSettingsProfile subModel ->
                    let
                        maybeToken =
                            Maybe.map .token model.auth

                        ( newSubModel, subCmd ) =
                            Profile.update subMsg subModel maybeToken
                    in
                    ( { model | page = PageSettingsProfile newSubModel }
                    , Cmd.map ProfileMsg subCmd
                    )

                _ ->
                    ( model, Cmd.none )

        PasswordMsg subMsg ->
            case model.page of
                PageSettingsPassword subModel ->
                    let
                        maybeToken =
                            Maybe.map .token model.auth

                        ( newSubModel, subCmd ) =
                            Password.update subMsg subModel maybeToken
                    in
                    ( { model | page = PageSettingsPassword newSubModel }
                    , Cmd.map PasswordMsg subCmd
                    )

                _ ->
                    ( model, Cmd.none )

        NotificationsMsg subMsg ->
            case model.page of
                PageSettingsNotifications subModel ->
                    let
                        maybeToken =
                            Maybe.map .token model.auth

                        ( newSubModel, subCmd ) =
                            Notifications.update subMsg subModel maybeToken
                    in
                    ( { model | page = PageSettingsNotifications newSubModel }
                    , Cmd.map NotificationsMsg subCmd
                    )

                _ ->
                    ( model, Cmd.none )

        CostTransparencyMsg subMsg ->
            case model.page of
                PageCostTransparency subModel ->
                    let
                        ( newSubModel, subCmd ) =
                            CostTransparency.update subMsg subModel
                    in
                    ( { model | page = PageCostTransparency newSubModel }
                    , Cmd.map CostTransparencyMsg subCmd
                    )

                _ ->
                    ( model, Cmd.none )

        CatalogueMsg subMsg ->
            case model.page of
                PageCatalogue subModel ->
                    let
                        maybeToken =
                            Maybe.map .token model.auth

                        ( newSubModel, subCmd, outMsg ) =
                            Catalogue.update subMsg subModel maybeToken
                    in
                    case outMsg of
                        Catalogue.NoOut ->
                            ( { model | page = PageCatalogue newSubModel }
                            , Cmd.map CatalogueMsg subCmd
                            )

                        Catalogue.SessionExpired ->
                            handleSessionExpiry model

                _ ->
                    ( model, Cmd.none )

        MarketplaceBrowseMsg subMsg ->
            case model.page of
                PageMarketplaceBrowse subModel ->
                    let
                        ( newSubModel, subCmd ) =
                            MarketplaceBrowse.update subMsg subModel
                    in
                    ( { model | page = PageMarketplaceBrowse newSubModel }
                    , Cmd.map MarketplaceBrowseMsg subCmd
                    )

                _ ->
                    ( model, Cmd.none )

        CreateListingMsg subMsg ->
            case model.page of
                PageMarketplaceCreate subModel ->
                    let
                        maybeToken =
                            Maybe.map .token model.auth

                        maybeUserId =
                            Maybe.map (.user >> .id) model.auth

                        ( newSubModel, subCmd, outMsg ) =
                            CreateListing.update subMsg subModel maybeToken maybeUserId

                        baseModel =
                            { model | page = PageMarketplaceCreate newSubModel }

                        baseCmd =
                            Cmd.map CreateListingMsg subCmd
                    in
                    case outMsg of
                        CreateListing.NoOut ->
                            ( baseModel, baseCmd )

                        CreateListing.SessionExpired ->
                            handleSessionExpiry model

                        CreateListing.SessionExpiredWithDraft draft ->
                            -- Persist the draft and run the deferred expiry path,
                            -- remembering (via the parked intent) to raise the
                            -- draft-saved login notice IF the re-check ends in a
                            -- logout (#182 + #180 Phase 2).
                            handleSessionExpiryWithDraft draft model

                        CreateListing.ClearDraft ->
                            ( baseModel
                            , Cmd.batch
                                [ baseCmd
                                , clearListingDraft ()
                                ]
                            )

                        CreateListing.NavigateTo route ->
                            ( baseModel
                            , Cmd.batch
                                [ baseCmd
                                , Nav.pushUrl model.key (Route.toPath route)
                                ]
                            )

                _ ->
                    ( model, Cmd.none )

        MyListingsMsg subMsg ->
            case model.page of
                PageMarketplaceMyListings subModel ->
                    let
                        maybeToken =
                            Maybe.map .token model.auth

                        ( newSubModel, subCmd, outMsg ) =
                            MyListings.update subMsg subModel maybeToken
                    in
                    case outMsg of
                        MyListings.NoOut ->
                            ( { model | page = PageMarketplaceMyListings newSubModel }
                            , Cmd.map MyListingsMsg subCmd
                            )

                        MyListings.SessionExpired ->
                            handleSessionExpiry model

                _ ->
                    ( model, Cmd.none )

        ListingDetailMsg subMsg ->
            case model.page of
                PageMarketplaceDetail subModel ->
                    let
                        ( newSubModel, subCmd ) =
                            ListingDetail.update subMsg subModel
                    in
                    ( { model | page = PageMarketplaceDetail newSubModel }
                    , Cmd.map ListingDetailMsg subCmd
                    )

                _ ->
                    ( model, Cmd.none )

        PrivacyMsg subMsg ->
            case model.page of
                PageSettingsPrivacy subModel ->
                    let
                        maybeToken =
                            Maybe.map .token model.auth

                        ( newSubModel, subCmd, outMsg ) =
                            Privacy.update subMsg subModel maybeToken
                    in
                    case outMsg of
                        Privacy.NoOut ->
                            ( { model | page = PageSettingsPrivacy newSubModel }
                            , Cmd.map PrivacyMsg subCmd
                            )

                        Privacy.SessionExpired ->
                            handleSessionExpiry model

                        Privacy.AccountDeleted ->
                            handleAccountDeleted model

                _ ->
                    ( model, Cmd.none )

        BlogArchiveMsg subMsg ->
            case model.page of
                PageBlogArchive subModel ->
                    let
                        ( newSubModel, subCmd ) =
                            BlogArchive.update subMsg subModel
                    in
                    ( { model | page = PageBlogArchive newSubModel }
                    , Cmd.map BlogArchiveMsg subCmd
                    )

                _ ->
                    ( model, Cmd.none )

        BlogEditorMsg subMsg ->
            case model.page of
                PageBlogEditor subModel ->
                    let
                        maybeToken =
                            Maybe.map .token model.auth

                        ( newSubModel, subCmd, outMsg ) =
                            BlogEditor.update subMsg subModel maybeToken
                    in
                    case outMsg of
                        BlogEditor.NoOut ->
                            ( { model | page = PageBlogEditor newSubModel }
                            , Cmd.map BlogEditorMsg subCmd
                            )

                        BlogEditor.SessionExpired ->
                            handleSessionExpiry model

                _ ->
                    ( model, Cmd.none )

        BlogPostMsg subMsg ->
            case model.page of
                PageBlogPost subModel ->
                    let
                        maybeToken =
                            Maybe.map .token model.auth

                        ( newSubModel, subCmd, outMsg ) =
                            BlogPostPage.update subMsg subModel maybeToken
                    in
                    case outMsg of
                        BlogPostPage.NoOut ->
                            ( { model | page = PageBlogPost newSubModel }
                            , Cmd.map BlogPostMsg subCmd
                            )

                        BlogPostPage.SessionExpired ->
                            handleSessionExpiry model

                _ ->
                    ( model, Cmd.none )

        AdminSourceApprovalMsg subMsg ->
            case model.page of
                PageAdminSourceApproval subModel ->
                    let
                        maybeToken =
                            Maybe.map .token model.auth

                        ( newSubModel, subCmd, outMsg ) =
                            AdminSourceApproval.update subMsg subModel maybeToken
                    in
                    case outMsg of
                        AdminSourceApproval.NoOut ->
                            ( { model | page = PageAdminSourceApproval newSubModel }
                            , Cmd.map AdminSourceApprovalMsg subCmd
                            )

                        AdminSourceApproval.SessionExpired ->
                            handleSessionExpiry model

                _ ->
                    ( model, Cmd.none )

        AdminScraperConfigMsg subMsg ->
            case model.page of
                PageAdminScraperConfig subModel ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            AdminScraperConfig.update subMsg subModel
                    in
                    case outMsg of
                        AdminScraperConfig.NoOut ->
                            ( { model | page = PageAdminScraperConfig newSubModel }
                            , Cmd.map AdminScraperConfigMsg subCmd
                            )

                        AdminScraperConfig.SessionExpired ->
                            handleSessionExpiry model

                _ ->
                    ( model, Cmd.none )

        AdminMetricsMsg subMsg ->
            case model.page of
                PageAdminMetrics subModel ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            AdminMetrics.update subMsg subModel
                    in
                    case outMsg of
                        AdminMetrics.NoOut ->
                            ( { model | page = PageAdminMetrics newSubModel }
                            , Cmd.map AdminMetricsMsg subCmd
                            )

                        AdminMetrics.SessionExpired ->
                            handleSessionExpiry model

                _ ->
                    ( model, Cmd.none )

        GroupsMsg subMsg ->
            case model.page of
                PageGroups subModel ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            Groups.update subMsg subModel
                    in
                    case outMsg of
                        Groups.NoOut ->
                            ( { model | page = PageGroups newSubModel }
                            , Cmd.map GroupsMsg subCmd
                            )

                        Groups.SessionExpired ->
                            handleSessionExpiry model

                        Groups.NavigateTo route ->
                            ( { model | page = PageGroups newSubModel }
                            , Cmd.batch
                                [ Cmd.map GroupsMsg subCmd
                                , Nav.pushUrl model.key (Route.toPath route)
                                ]
                            )

                _ ->
                    ( model, Cmd.none )

        GroupsDetailMsg subMsg ->
            case model.page of
                PageGroupsDetail subModel ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            GroupsDetail.update subMsg subModel
                    in
                    case outMsg of
                        GroupsDetail.NoOut ->
                            ( { model | page = PageGroupsDetail newSubModel }
                            , Cmd.map GroupsDetailMsg subCmd
                            )

                        GroupsDetail.SessionExpired ->
                            handleSessionExpiry model

                        GroupsDetail.NavigateTo route ->
                            ( { model | page = PageGroupsDetail newSubModel }
                            , Cmd.batch
                                [ Cmd.map GroupsDetailMsg subCmd
                                , Nav.pushUrl model.key (Route.toPath route)
                                ]
                            )

                _ ->
                    ( model, Cmd.none )

        OverlayBookDetailMsg subMsg ->
            case model.bookDetailOverlay of
                Just overlay ->
                    let
                        maybeToken =
                            Maybe.map .token model.auth

                        ( newDetail, subCmd, outMsg ) =
                            BookDetail.update subMsg overlay.detail maybeToken

                        updatedOverlay =
                            { overlay | detail = newDetail }

                        returnFocusCmd =
                            case overlay.triggerSpineId of
                                Just spineId ->
                                    Task.attempt (always FocusResult) (Browser.Dom.focus spineId)

                                Nothing ->
                                    Cmd.none
                    in
                    case outMsg of
                        BookDetail.RequestCloseOverlay ->
                            ( { model | bookDetailOverlay = Nothing }
                            , returnFocusCmd
                            )

                        BookDetail.NavigateTo route ->
                            ( { model | bookDetailOverlay = Nothing }
                            , Nav.pushUrl model.key (Route.toPath route)
                            )

                        BookDetail.NoOut ->
                            ( { model | bookDetailOverlay = Just updatedOverlay }
                            , Cmd.map OverlayBookDetailMsg subCmd
                            )

                        BookDetail.SessionExpired ->
                            handleSessionExpiry model

                Nothing ->
                    ( model, Cmd.none )

        UserMenuMsg subMsg ->
            let
                ( newUserMenu, outMsg ) =
                    UserMenu.update subMsg model.userMenu
            in
            case outMsg of
                UserMenu.NoOut ->
                    ( { model | userMenu = newUserMenu }, Cmd.none )

                UserMenu.NavigateToSettings ->
                    ( { model | userMenu = newUserMenu }
                    , Nav.pushUrl model.key (Route.toPath SettingsProfile)
                    )

                UserMenu.SignOut ->
                    let
                        logoutCmd =
                            case model.auth of
                                Just auth ->
                                    Api.logout auth.token (always LogoutCompleted)

                                Nothing ->
                                    Cmd.none
                    in
                    ( { model | userMenu = newUserMenu, auth = Nothing, page = PageLogin Login.init }
                    , Cmd.batch
                        [ logoutCmd
                        , clearAuth ()

                        -- Defense-in-depth (#182): a deliberate sign-out also
                        -- wipes any persisted listing draft (it carries PII).
                        -- NB: the session-expiry path deliberately does NOT do
                        -- this — it must preserve the draft across the redirect.
                        , clearListingDraft ()
                        , Nav.pushUrl model.key (Route.toPath Login)
                        ]
                    )

        LogoutCompleted ->
            ( model, Cmd.none )

        SettingsMobileNavChanged path ->
            ( model, Nav.pushUrl model.key path )

        EscapePressed ->
            case model.bookDetailOverlay of
                Just overlay ->
                    let
                        focusCmd =
                            case overlay.triggerSpineId of
                                Just spineId ->
                                    Task.attempt (always FocusResult) (Browser.Dom.focus spineId)

                                Nothing ->
                                    Cmd.none
                    in
                    ( { model | bookDetailOverlay = Nothing }, focusCmd )

                Nothing ->
                    let
                        ( newUserMenu, _ ) =
                            UserMenu.update UserMenu.Close model.userMenu
                    in
                    ( { model | userMenu = newUserMenu }, Cmd.none )

        OnboardingMsg subMsg ->
            let
                ( newOnboarding, subCmd, outMsg ) =
                    OnboardingOverlay.update subMsg model.onboarding

                -- When the user clicks Next, record the completed step via the API
                apiCmd =
                    case ( subMsg, model.auth ) of
                        ( OnboardingOverlay.NextStep, Just auth ) ->
                            Cmd.map OnboardingMsg
                                (OnboardingOverlay.completeStep auth.token model.onboarding.step)

                        _ ->
                            Cmd.none
            in
            case outMsg of
                OnboardingOverlay.SkipCompleted ->
                    ( { model | onboarding = newOnboarding, onboardingCompleted = True }
                    , Cmd.batch [ Cmd.map OnboardingMsg subCmd, saveOnboardingCompleted () ]
                    )

                OnboardingOverlay.FinishCompleted ->
                    ( { model | onboarding = newOnboarding, onboardingCompleted = True }
                    , Cmd.batch [ Cmd.map OnboardingMsg subCmd, saveOnboardingCompleted () ]
                    )

                OnboardingOverlay.NoOut ->
                    ( { model | onboarding = newOnboarding }
                    , Cmd.batch [ Cmd.map OnboardingMsg subCmd, apiCmd ]
                    )

        OnboardingStatusReceived completed ->
            ( { model | onboardingCompleted = completed }, Cmd.none )

        FocusResult ->
            -- Focus attempt completed (success or failure); nothing to do.
            ( model, Cmd.none )

        GotPlacementCheck result ->
            case result of
                Ok placements ->
                    ( { model | hasAnyPlacements = not (List.isEmpty placements) }, Cmd.none )

                Err err ->
                    if Api.isUnauthorized err then
                        handleSessionExpiry model

                    else
                        ( model, Cmd.none )

        RenewToken ->
            -- Proactive silent renewal tick. Only meaningful while authenticated;
            -- a signed-out session simply drops the tick.
            case model.auth of
                Just auth ->
                    ( model, Api.refresh auth.token TokenRefreshed )

                Nothing ->
                    ( model, Cmd.none )

        TokenRefreshed (Ok authResponse) ->
            -- Renewal succeeded: adopt the fresh token (keeping the same user),
            -- persist it, and roll the next renewal. No navigation, no logout.
            case model.auth of
                Just auth ->
                    let
                        renewedAuth =
                            renewAuthToken authResponse auth
                    in
                    ( { model | auth = Just renewedAuth }
                    , Cmd.batch [ saveAuth (encodeAuth renewedAuth), scheduleRenewal ]
                    )

                Nothing ->
                    ( model, Cmd.none )

        TokenRefreshed (Err _) ->
            -- Renewal failed (token already expired/revoked, or the service is
            -- down): fall through to the session-expiry path, tagged as
            -- renewal-origin so a re-check adopt re-arms the consumed tick (P1b).
            handleSessionExpiryFromRenewal model

        AuthChangedExternally value ->
            -- A sibling tab wrote `stacks-auth` (Issue #180 Phase 2).
            case adoptExternalAuth value model.auth of
                AdoptAuth newAuth ->
                    -- Adopt the token another tab rotated in. No `saveAuth` (that
                    -- tab already persisted it) and NO reschedule: this tab still
                    -- has its own renewal tick armed, so re-arming here would let
                    -- every rotation spawn an extra timer per tab (a growing
                    -- refresh storm — exactly what #180 fights).
                    --
                    -- P1a: adopting a VALID token also cancels any parked expiry —
                    -- otherwise an in-flight `gotStoredAuth` (whose stored value now
                    -- equals this adopted token → IgnoreExternal) would force a
                    -- logout on a tab that just adopted a live credential.
                    ( { model | auth = Just newAuth, pendingLogout = Nothing }
                    , Cmd.none
                    )

                LogOutExternally ->
                    -- A sibling `clearAuth`: a logout in one tab logs out all.
                    forceSessionExpiry False model

                IgnoreExternal ->
                    ( model, Cmd.none )

        GotStoredAuth value ->
            -- The re-check-before-logout answer (Issue #180 Phase 2). The pure
            -- resolver folds in the parked intent (origin + draft flags); a stray
            -- answer with no parked intent is a no-op (P1a).
            case resolveRecheck model.pendingLogout (adoptExternalAuth value model.auth) of
                ResolveAdopt newAuth reschedule ->
                    -- localStorage holds a newer token than the one that 401'd —
                    -- adopt it and cancel the logout. Re-arm renewal ONLY for a
                    -- renewal-origin expiry, whose proactive tick was consumed (P1b).
                    ( { model | auth = Just newAuth, pendingLogout = Nothing }
                    , if reschedule then
                        scheduleRenewal

                      else
                        Cmd.none
                    )

                ResolveForceLogout draftSaved ->
                    -- Nothing newer stored (same token / cleared / garbage):
                    -- proceed to the real logout, carrying the draft notice.
                    forceSessionExpiry draftSaved model

                ResolveNoop ->
                    ( model, Cmd.none )

        SwipeReceived direction ->
            let
                maybeNext =
                    if direction == "left" then
                        SwipeNavigation.swipeLeft model.route

                    else
                        SwipeNavigation.swipeRight model.route
            in
            case maybeNext of
                Just nextRoute ->
                    ( model, Nav.pushUrl model.key (Route.toPath nextRoute) )

                Nothing ->
                    ( model, Cmd.none )

        SwipeIgnored ->
            ( model, Cmd.none )


{-| Open the book detail overlay for a given book ID.
Initialises a BookDetail.Model and fires the API fetch command.
Stores the triggering spine element ID so focus can return on close.
-}
openOverlay : Model -> String -> ( Model, Cmd Msg )
openOverlay model bookId =
    let
        maybeToken =
            Maybe.map .token model.auth

        ( detailModel, detailCmd ) =
            BookDetail.init bookId maybeToken (Just model.route)

        overlay =
            { bookId = bookId
            , detail = detailModel
            , triggerSpineId = Just ("spine-" ++ bookId)
            }
    in
    ( { model | bookDetailOverlay = Just overlay }
    , Cmd.batch
        [ Cmd.map OverlayBookDetailMsg detailCmd
        , Task.attempt (always FocusResult) (Browser.Dom.focus "book-overlay-close")
        ]
    )


transitionClass : Route -> Route -> String
transitionClass from to =
    case ( from, to ) of
        ( _, BookDetail _ ) ->
            SlideTransition.slideInRight

        ( BookDetail _, _ ) ->
            SlideTransition.slideOutRight

        _ ->
            RoomTransition.fadeThroughDarkIn



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ onSwipe decodeSwipe
        , onLoginTransitionComplete (\_ -> LoginTransitionCompleted)
        , onOnboardingStatus OnboardingStatusReceived
        , authChanged AuthChangedExternally
        , gotStoredAuth GotStoredAuth
        , Browser.Events.onKeyDown
            (Decode.field "key" Decode.string
                |> Decode.andThen
                    (\key ->
                        if key == "Escape" then
                            Decode.succeed EscapePressed

                        else
                            Decode.fail "not handled"
                    )
            )
        , case model.page of
            PageUpload _ ->
                uploadStreamEvent
                    (\raw ->
                        case Decode.decodeString (Decode.field "type" Decode.string) raw of
                            Ok "error" ->
                                UploadMsg Upload.StreamError

                            _ ->
                                UploadMsg (Upload.StreamEvent raw)
                    )

            PageMarketplaceCreate _ ->
                gotListingDraft (CreateListingMsg << CreateListing.DraftLoaded)

            _ ->
                Sub.none
        ]


decodeSwipe : Decode.Value -> Msg
decodeSwipe value =
    case Decode.decodeValue Decode.string value of
        Ok direction ->
            SwipeReceived direction

        Err _ ->
            SwipeIgnored



-- VIEW


view : Model -> Browser.Document Msg
view model =
    { title = pageTitle model.route
    , body =
        [ viewOverlay model
        , viewOnboarding model
        , ViewAsBar.view model.url
        , div [ class "app" ]
            [ a [ class "skip-link", href "#main-content" ] [ text "Skip to main content" ]
            , viewNav model.route model.auth model.userMenu
            , main_
                [ id "main-content"
                , class
                    ("app__main"
                        ++ (case model.transition of
                                Just t ->
                                    " " ++ t

                                Nothing ->
                                    ""
                           )
                    )
                ]
                [ viewPage model ]
            , viewFooter
            ]
        ]
    }


pageTitle : Route -> String
pageTitle route =
    case route of
        Home ->
            "The Stacks"

        Login ->
            "Sign In — The Stacks"

        Library ->
            "Library — The Stacks"

        AntiLibrary ->
            "Antilibrary — The Stacks"

        WishList ->
            "Wish List — The Stacks"

        ReadingPile ->
            "Reading Pile — The Stacks"

        LookingForHome ->
            "Looking for a Home — The Stacks"

        BookDetail _ ->
            "Book — The Stacks"

        Upload ->
            "Add a Book — The Stacks"

        Search ->
            "Search — The Stacks"

        Settings ->
            "Settings — The Stacks"

        SettingsProfile ->
            "Profile — The Stacks"

        SettingsPassword ->
            "Password — The Stacks"

        SettingsNotifications ->
            "Notifications — The Stacks"

        SettingsConsent ->
            "Privacy Settings — The Stacks"

        SettingsAgeVerification ->
            "Age Verification — The Stacks"

        SettingsAuditLog ->
            "Audit Log — The Stacks"

        CostTransparency ->
            "Cost Transparency — The Stacks"

        Catalogue ->
            "Catalogue — The Stacks"

        MarketplaceBrowse ->
            "Marketplace — The Stacks"

        MarketplaceCreate ->
            "Create Listing — The Stacks"

        MarketplaceMyListings ->
            "My Listings — The Stacks"

        MarketplaceDetail _ ->
            "Listing — The Stacks"

        SettingsPrivacy ->
            "Privacy — The Stacks"

        BlogArchive ->
            "Blog — The Stacks"

        BlogNew ->
            "New Post — The Stacks"

        BlogEdit _ ->
            "Edit Post — The Stacks"

        BlogPost _ ->
            "Blog Post — The Stacks"

        Route.AdminSourceApproval ->
            "Source Approval — The Stacks"

        Route.AdminScraperConfig ->
            "Scraper Health — The Stacks"

        Route.AdminMetrics ->
            "Metrics — The Stacks"

        Groups ->
            "My Groups — The Stacks"

        GroupDetail _ ->
            "Group — The Stacks"

        ConfirmEmail EmailConfirmed ->
            "Email Confirmed — The Stacks"

        ConfirmEmail EmailConfirmFailed ->
            "Confirmation Failed — The Stacks"

        NotFound ->
            "Not Found — The Stacks"


viewNav : Route -> Maybe Auth -> UserMenu.Model -> Html Msg
viewNav route maybeAuth userMenu =
    header [ class "app-header" ]
        [ div [ class "app-header__brand app-nav__dropdown" ]
            [ a [ href "/", class "app-header__logo" ] [ text "The Stacks" ]
            , ul [ class "app-nav__dropdown-menu" ]
                [ li []
                    [ a [ href (Route.toPath CostTransparency), class "app-nav__dropdown-link" ]
                        [ text "Costs" ]
                    ]
                ]
            ]
        , nav [ class "app-nav", attribute "aria-label" "Main navigation" ]
            [ ul [ class "app-nav__list" ]
                (case maybeAuth of
                    Nothing ->
                        [ navItem route Catalogue "Catalogue"
                        , navItem route MarketplaceBrowse "Marketplace"
                        , navItem route Login "Sign In"
                        ]

                    Just auth ->
                        [ navItem route Library "Library"
                        , navItem route AntiLibrary "Antilibrary"
                        , navItem route WishList "Wish List"
                        , navItem route ReadingPile "Reading Pile"
                        , navItem route LookingForHome "Looking for a Home"
                        , navDropdown route
                            Catalogue
                            "Catalogue"
                            [ ( Search, "Search" )
                            , ( Upload, "Add Book" )
                            ]
                        , navDropdown route
                            MarketplaceBrowse
                            "Marketplace"
                            [ ( MarketplaceCreate, "Create Listing" )
                            , ( MarketplaceMyListings, "My Listings" )
                            ]
                        , if auth.user.role == "owner" then
                            navDropdown route
                                Route.AdminMetrics
                                "Admin"
                                [ ( Route.AdminSourceApproval, "Sources" )
                                , ( Route.AdminScraperConfig, "Scrapers" )
                                ]

                          else
                            text ""
                        , li
                            [ class
                                (if isSettingsRoute route then
                                    "app-nav__item app-nav__item--active app-nav__dropdown"

                                 else
                                    "app-nav__item app-nav__dropdown"
                                )
                            ]
                            [ Html.map UserMenuMsg
                                (UserMenu.view auth.user userMenu)
                            ]
                        ]
                )
            ]
        ]


navItem : Route -> Route -> String -> Html Msg
navItem currentRoute targetRoute label =
    let
        isActive =
            currentRoute == targetRoute

        activeClass =
            if isActive then
                "app-nav__item app-nav__item--active"

            else
                "app-nav__item"
    in
    li [ class activeClass ]
        [ a [ href (Route.toPath targetRoute), class "app-nav__link" ]
            [ text label ]
        ]


navDropdown : Route -> Route -> String -> List ( Route, String ) -> Html Msg
navDropdown currentRoute primaryRoute primaryLabel subItems =
    let
        isActive =
            (currentRoute == primaryRoute)
                || List.any (\( r, _ ) -> currentRoute == r) subItems

        activeClass =
            if isActive then
                "app-nav__item app-nav__item--active app-nav__dropdown"

            else
                "app-nav__item app-nav__dropdown"
    in
    li [ class activeClass ]
        [ a [ href (Route.toPath primaryRoute), class "app-nav__link" ]
            [ text primaryLabel ]
        , ul [ class "app-nav__dropdown-menu" ]
            (List.map
                (\( route, label ) ->
                    li []
                        [ a [ href (Route.toPath route), class "app-nav__dropdown-link" ]
                            [ text label ]
                        ]
                )
                subItems
            )
        ]


viewPage : Model -> Html Msg
viewPage model =
    case model.page of
        PageHome ->
            viewHome

        PageLogin subModel ->
            Html.map LoginMsg (Login.view subModel)

        PageBookshelf subModel ->
            Html.map BookshelfMsg (Bookshelf.view subModel)

        PageReadingPile subModel ->
            Html.map ReadingPileMsg (ReadingPile.view subModel)

        PageLookingForHome subModel ->
            Html.map LookingForHomeMsg (LookingForHome.view subModel)

        PageBookDetail subModel ->
            Html.map BookDetailMsg (BookDetail.view subModel)

        PageUpload subModel ->
            Html.map UploadMsg (Upload.view subModel (Maybe.map .token model.auth))

        PageSearch subModel ->
            Html.map SearchMsg (Search.view subModel)

        PageSettingsConsent subModel ->
            viewSettingsHub model.route
                (Html.map ConsentMsg (Consent.view subModel))

        PageSettingsAgeVerification subModel ->
            viewSettingsHub model.route
                (Html.map AgeVerificationMsg (AgeVerification.view subModel))

        PageSettingsAuditLog subModel ->
            viewSettingsHub model.route
                (Html.map AuditLogMsg (AuditLog.view subModel))

        PageSettingsProfile subModel ->
            viewSettingsHub model.route
                (Html.map ProfileMsg (Profile.view subModel))

        PageSettingsPassword subModel ->
            viewSettingsHub model.route
                (Html.map PasswordMsg (Password.view subModel))

        PageSettingsNotifications subModel ->
            viewSettingsHub model.route
                (Html.map NotificationsMsg (Notifications.view subModel))

        PageCostTransparency subModel ->
            Html.map CostTransparencyMsg (CostTransparency.view subModel)

        PageCatalogue subModel ->
            Html.map CatalogueMsg (Catalogue.view subModel)

        PageMarketplaceBrowse subModel ->
            Html.map MarketplaceBrowseMsg (MarketplaceBrowse.view subModel)

        PageMarketplaceCreate subModel ->
            Html.map CreateListingMsg (CreateListing.view subModel)

        PageMarketplaceMyListings subModel ->
            Html.map MyListingsMsg (MyListings.view subModel)

        PageMarketplaceDetail subModel ->
            Html.map ListingDetailMsg (ListingDetail.view subModel)

        PageSettingsPrivacy subModel ->
            viewSettingsHub model.route
                (Html.map PrivacyMsg (Privacy.view subModel))

        PageBlogArchive subModel ->
            Html.map BlogArchiveMsg (BlogArchive.view subModel)

        PageBlogEditor subModel ->
            Html.map BlogEditorMsg (BlogEditor.view subModel)

        PageBlogPost subModel ->
            Html.map BlogPostMsg (BlogPostPage.view subModel)

        PageAdminSourceApproval subModel ->
            Html.map AdminSourceApprovalMsg (AdminSourceApproval.view subModel)

        PageAdminScraperConfig subModel ->
            Html.map AdminScraperConfigMsg (AdminScraperConfig.view subModel)

        PageAdminMetrics subModel ->
            Html.map AdminMetricsMsg (AdminMetrics.view subModel)

        PageGroups subModel ->
            Html.map GroupsMsg (Groups.view subModel)

        PageGroupsDetail subModel ->
            Html.map GroupsDetailMsg (GroupsDetail.view subModel)

        PageConfirmEmail status ->
            viewConfirmEmail status

        PageNotFound ->
            viewNotFound


viewSettingsHub : Route -> Html Msg -> Html Msg
viewSettingsHub currentRoute content =
    Settings.view
        { currentRoute = currentRoute
        , content = content
        , onMobileNavChange = SettingsMobileNavChanged
        }


viewOverlay : Model -> Html Msg
viewOverlay model =
    case model.bookDetailOverlay of
        Just overlay ->
            Html.map OverlayBookDetailMsg (BookDetail.overlayView overlay.detail)

        Nothing ->
            text ""


{-| The onboarding overlay is shown for an authenticated user who has not yet
completed onboarding and has no placements on any bookshelf.
-}
shouldShowOnboarding : Maybe Auth -> Bool -> Bool -> Bool
shouldShowOnboarding maybeAuth onboardingCompleted hasAnyPlacements =
    case maybeAuth of
        Just _ ->
            not onboardingCompleted && not hasAnyPlacements

        Nothing ->
            False


{-| Show onboarding overlay for authenticated users with no placements
who haven't completed onboarding yet.
-}
viewOnboarding : Model -> Html Msg
viewOnboarding model =
    if shouldShowOnboarding model.auth model.onboardingCompleted model.hasAnyPlacements then
        Html.map OnboardingMsg (OnboardingOverlay.view model.onboarding)

    else
        text ""


viewHome : Html Msg
viewHome =
    div [ class "page page--home" ]
        [ h1 [ class "home__title" ] [ text "The Stacks" ]
        , p [ class "home__subtitle" ]
            [ text "Your personal collection, beautifully organised." ]
        , div [ class "home__actions" ]
            [ a [ href (Route.toPath AntiLibrary), class "btn btn--primary" ]
                [ text "View Antilibrary" ]
            , a [ href (Route.toPath Upload), class "btn btn--secondary" ]
                [ text "Add a Book" ]
            ]
        ]


viewConfirmEmail : ConfirmStatus -> Html Msg
viewConfirmEmail status =
    case status of
        EmailConfirmed ->
            div [ class "page page--confirm-email" ]
                [ h1 [] [ text "Email confirmed" ]
                , p [] [ text "Your email address has been verified. You can now use The Stacks." ]
                , a [ href (Route.toPath Login), class "btn btn--primary" ] [ text "Sign in" ]
                ]

        EmailConfirmFailed ->
            div [ class "page page--confirm-email page--confirm-email--error" ]
                [ h1 [] [ text "Confirmation failed" ]
                , p [] [ text "This link has expired or is no longer valid. Please register again to receive a new confirmation email." ]
                , a [ href "/", class "btn btn--primary" ] [ text "Go home" ]
                ]


viewNotFound : Html Msg
viewNotFound =
    div [ class "page page--not-found" ]
        [ h1 [] [ text "Page Not Found" ]
        , p [] [ text "The page you're looking for doesn't exist." ]
        , a [ href "/", class "btn btn--primary" ] [ text "Go Home" ]
        ]


viewFooter : Html Msg
viewFooter =
    footer [ class "app-footer" ]
        [ p [ class "app-footer__text" ]
            [ text "The Stacks — open source book management" ]
        ]
