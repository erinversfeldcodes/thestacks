port module Main exposing
    ( AppConfig
    , Auth
    , AuthState(..)
    , CompletedLogin
    , Connectivity(..)
    , ExternalAuthOutcome(..)
    , LoginEffect(..)
    , Msg(..)
    , NavMenu(..)
    , Page(..)
    , PendingLogout
    , StoredAuth(..)
    , StoredAuthResolution(..)
    , adoptExternalAuth
    , applyPendingUndo
    , arrivalForBoot
    , completeLogin
    , connectivityFromOnline
    , consumeArrival
    , currentAuth
    , decodeConfig
    , decodeFlags
    , decodeSwipe
    , initPage
    , loginEffects
    , loginRedirectFor
    , main
    , pageTitle
    , parkPending
    , reconnectShouldRefetch
    , redirectAfterNavigation
    , refreshShelfBehindOverlay
    , renewAuthToken
    , requiresAuth
    , resetPasswordDestination
    , resolveRecheck
    , settleArrival
    , shouldShowOnboarding
    , storedSession
    , toggleNavMenu
    , viewArrivalDoor
    , viewConnectivity
    , viewFooter
    , viewNav
    , viewNotFound
    )

import Animation.Transition as Transition exposing (transitionClass)
import Api
import Browser
import Browser.Dom
import Browser.Events
import Browser.Navigation as Nav
import Components.AdminChrome as AdminChrome
import Components.OnboardingOverlay as OnboardingOverlay
import Components.Syndication as Syndication
import Components.UserMenu as UserMenu
import Components.ViewAsBar as ViewAsBar
import Html exposing (Html, a, button, div, footer, h1, header, li, main_, nav, p, span, text, ul)
import Html.Attributes exposing (attribute, class, href, id, style, tabindex)
import Html.Events
import Http
import Json.Decode as Decode
import Json.Encode
import Navigation.Route as Route exposing (ConfirmStatus(..), Route(..), isSettingsRoute)
import Navigation.SwipeNavigation as SwipeNavigation
import Page.About as AboutPage
import Page.Admin.BookModeration as AdminBookModeration
import Page.Admin.Feedback as AdminFeedback
import Page.Admin.Invites as AdminInvites
import Page.Admin.RemovalRequests as AdminRemovalRequests
import Page.Admin.ScraperConfig as AdminScraperConfig
import Page.Admin.Session as AdminSession
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
import Page.DataTransparency as DataTransparencyPage
import Page.Faq as FaqPage
import Page.Feedback as FeedbackPage
import Page.Groups as Groups
import Page.Groups.Detail as GroupsDetail
import Page.Home as Home
import Page.Import as ImportPage
import Page.Insights as Insights
import Page.ListingRemoval as ListingRemoval
import Page.Login as Login
import Page.Marketplace.Browse as MarketplaceBrowse
import Page.Marketplace.CreateListing as CreateListing
import Page.Marketplace.ListingDetail as ListingDetail
import Page.Marketplace.MyListings as MyListings
import Page.Metrics as MetricsPage
import Page.Profile as ProfilePage
import Page.ResetPassword as ResetPassword
import Page.Search as Search
import Page.Settings as Settings
import Page.Settings.AuditLog as AuditLog
import Page.Settings.Notifications as Notifications
import Page.Settings.Password as Password
import Page.Settings.Privacy as Privacy
import Page.Settings.Profile as Profile
import Page.Upload as Upload
import Process
import Task
import Time
import Types.Placement
import Types.RemoteData exposing (RemoteData(..))
import Types.User exposing (AuthToken, User)
import Url exposing (Url)
import Util.TestId exposing (testId)


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
localStorage. `saveListingDraft` is fired when a session expires
mid-compose; `requestListingDraft` is fired when the create page is (re)built and
its answer arrives on `gotListingDraft` (the parsed value, or `null` when absent).
-}
port saveListingDraft : Json.Encode.Value -> Cmd msg


port clearListingDraft : () -> Cmd msg


port requestListingDraft : () -> Cmd msg


port gotListingDraft : (Decode.Value -> msg) -> Sub msg


{-| Cross-tab token propagation. Fires when ANOTHER tab
writes `stacks-auth` in localStorage: `saveAuth` (a sibling tab just rotated its
token → the raw new JSON string) or `clearAuth` (a sibling logged out → `null`).
The writing tab never receives its own event, so there is no feedback loop. The
payload is the raw string / `null`; it is decoded in Elm via `adoptExternalAuth`.
-}
port authChanged : (Decode.Value -> msg) -> Sub msg


{-| Belt-and-suspenders re-check net. Asks JS to read the
CURRENT `stacks-auth` from localStorage; the answer arrives on `gotStoredAuth`.
Fired just before a 401-driven session expiry so a token another tab refreshed
can be adopted instead of logging everyone out.
-}
port requestStoredAuth : () -> Cmd msg


port gotStoredAuth : (Decode.Value -> msg) -> Sub msg


{-| Server-config channel. Elm boots immediately with age-gating OFF
(the fail-safe production default); `GET /api/config` is fetched in the
background by `app.js` and its result is delivered here a beat after boot, so a
network round-trip never blocks first paint. The payload is the resolved
`ageGatingEnabled` boolean; on fetch failure JS sends nothing and the default
(`False`) stands.
-}
port ageGatingConfig : (Bool -> msg) -> Sub msg


{-| Second server-config flag, same channel shape as
`ageGatingConfig`. app.js sends the resolved `inviteOnly` boolean from the same
`GET /api/config` fetch; on ANY failure it sends nothing and the fail-CLOSED
boot default (`True`) stands — a config blip must not reopen registration.
-}
port inviteOnlyConfig : (Bool -> msg) -> Sub msg


{-| Browser connectivity: `app.js` forwards the window online/offline
events plus one send at boot (a tab opened offline must not be told it is
connected). The shell answers this once, centrally — like session expiry —
rather than each page inferring "probably offline" from its own
`Http.NetworkError`.
-}
port connectivityChanged : (Bool -> msg) -> Sub msg


{-| Clipboard write for the syndication panel — the one place the
project needs a clipboard port, because the Clipboard API has no Elm
equivalent. The JS side MUST answer on `copyResult` whether the write
succeeded or was refused — a port that swallows a rejection produces a copy
button that appears to work and does not, which is exactly the "built but not
wired" shape. The False answer is what makes the textarea fallback reachable.
-}
port copyToClipboard : String -> Cmd msg


port copyResult : (Bool -> msg) -> Sub msg


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


type Page
    = PageHome Home.Model
    | PageLogin Login.Model
    | PageBookshelf Bookshelf.Model
    | PageReadingPile ReadingPile.Model
    | PageLookingForHome LookingForHome.Model
    | PageBookDetail BookDetail.Model
    | PageUpload Upload.Model
    | PageImport ImportPage.Model
    | PageSearch Search.Model
    | PageSettingsAuditLog AuditLog.Model
    | PageInsights Insights.Model
    | PageSettingsProfile Profile.Model
    | PageSettingsPassword Password.Model
    | PageSettingsNotifications Notifications.Model
    | PageCostTransparency CostTransparency.Model
    | PageMetrics MetricsPage.Model
    | PageAbout
    | PageFaq
    | PageDataTransparency
    | PageListingRemoval ListingRemoval.Model
    | PageCatalogue Catalogue.Model
    | PageMarketplaceBrowse MarketplaceBrowse.Model
    | PageMarketplaceCreate CreateListing.Model
    | PageMarketplaceMyListings MyListings.Model
    | PageMarketplaceDetail ListingDetail.Model
    | PageSettingsPrivacy Privacy.Model
    | PageBlogArchive BlogArchive.Model
    | PageBlogEditor BlogEditor.Model
    | PageBlogPost BlogPostPage.Model
    | PageFeedback FeedbackPage.Model
    | PageAdminSourceApproval AdminSourceApproval.Model
    | PageAdminFeedback AdminFeedback.Model
    | PageAdminInvites AdminInvites.Model
    | PageAdminScraperConfig AdminScraperConfig.Model
    | PageAdminBookModeration AdminBookModeration.Model
    | PageAdminRemovalRequests AdminRemovalRequests.Model
    | PageAdminGate Route AdminSession.Model
    | PageGroups Groups.Model
    | PageGroupsDetail GroupsDetail.Model
    | PageProfile ProfilePage.Model
    | PageConfirmEmail ConfirmStatus
    | PageResetPassword ResetPassword.Model
    | PageNotFound


type alias Auth =
    { user : User
    , token : AuthToken
    }


{-| Who the app currently believes is signed in.

⛔ What this type makes impossible: the old `auth: Maybe Auth` let login
set an in-memory credential the app had not yet persisted (parked on the
door animation, which an occluded window never finishes) — authenticated
in memory, anonymous on disk. `Arriving` carries both the auth AND the
proof of persistence; `Authed` is only reachable after the write.

-}
type AuthState
    = Anonymous
    | Arriving Auth
    | Authenticated Auth


{-| Whether the browser currently has a network connection.

A two-constructor type rather than `isOffline: Bool` on the model. The banner
is the only reader today, but a boolean named for one of its two states is how
`not online` and `offline` end up being written in different places and drifting;
this cannot be read backwards.

-}
type Connectivity
    = Online
    | Offline


{-| Read a `navigator.onLine` boolean at the port boundary, so the rest of the
app never sees the boolean at all.
-}
connectivityFromOnline : Bool -> Connectivity
connectivityFromOnline isOnline =
    if isOnline then
        Online

    else
        Offline


{-| The whole refetch decision, pure: refetch exactly when the
connectivity change is the offline→online TRANSITION (not a repeated `online`
event, not going offline) and the routed page lost its content to the network.
-}
reconnectShouldRefetch : Connectivity -> Connectivity -> Page -> Bool
reconnectShouldRefetch before after page =
    before == Offline && after == Online && pageLostToNetwork page


{-| Whether the routed page's PRIMARY content was lost to a `NetworkError` —
the one failure reconnecting actually fixes.

Scope rule, stated: reconnect recovery is a SHARED Main-level behaviour (the
connectivity signal lives here, and re-entering a route is Main's job — a
per-page copy in every module is the duplication collapsed), but pages
opt IN by naming their content field here. Seeded with the shelf/book family
the drive covered. The catch-all is honest: a page not named simply
keeps today's behaviour (its own error copy), it does not break — and
`Timeout`/5xx deliberately never trigger a refetch, because reconnecting is
not what fixes those (split, kept).

-}
pageLostToNetwork : Page -> Bool
pageLostToNetwork page =
    let
        lost : RemoteData Http.Error a -> Bool
        lost remote =
            case remote of
                Failure Http.NetworkError ->
                    True

                _ ->
                    False
    in
    case page of
        PageBookshelf m ->
            lost m.shelves

        PageReadingPile m ->
            lost m.books

        PageLookingForHome m ->
            lost m.books

        PageBookDetail m ->
            lost m.book

        PageCatalogue m ->
            lost m.books

        _ ->
            False


{-| The session, whatever stage of arrival it is in. The ONE accessor — nothing
outside this function may pattern-match `AuthState` to decide whether a request
can be made, or `Arriving` would start meaning "not really signed in".
-}
currentAuth : AuthState -> Maybe Auth
currentAuth authState =
    case authState of
        Anonymous ->
            Nothing

        Arriving auth ->
            Just auth

        Authenticated auth ->
            Just auth


{-| Settle an arrival. Total and idempotent on purpose: it is driven by two
racing sources — the door animation's completion signal from JS, and the
`ArmArrivalBackstop` timer — and either may arrive first, twice, or never.
-}
settleArrival : AuthState -> AuthState
settleArrival authState =
    case authState of
        Arriving auth ->
            Authenticated auth

        settled ->
            settled


{-| A parked session-expiry intent. Raised when an
authenticated 401 wants to log out; the actual clear+redirect is deferred one
port round-trip (`requestStoredAuth` → `gotStoredAuth`) so a token another tab
refreshed can be adopted first.

  - `draftSaved` carries the marketplace-draft-saved notice across that
    round-trip so it still shows on the login page.
  - `fromRenewal` records whether the expiry originated from a CONSUMED proactive
    renewal tick (a failed silent refresh). Only then does adopting a newer token
    on re-check re-arm renewal — a page-origin 401 still has its renewal tick
    armed, so re-arming there would spawn a duplicate timer (a refresh storm).

-}
type alias PendingLogout =
    { draftSaved : Bool, fromRenewal : Bool }


{-| Merge a new parked expiry with any intent already in flight. Both flags are STICKY (OR-ed): a later plain expiry must not erase
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
    , auth : AuthState
    , adminAuth : Maybe String
    , adminChrome : AdminChrome.Model
    , page : Page
    , previousRoute : Maybe Route
    , transition : Maybe String
    , redirectAfterLogin : Maybe Route
    , bookDetailOverlay : Maybe BookDetailOverlay
    , userMenu : UserMenu.Model
    , openNavMenu : Maybe NavMenu
    , onboarding : OnboardingOverlay.Model
    , onboardingCompleted : Bool
    , hasAnyPlacements : Bool
    , pendingUndo : Maybe Bookshelf.Removal
    , arrival : Login.Arrival

    -- A deferred session-expiry intent (Phase 2): set while the
    -- re-check-before-logout port round-trip is in flight, cleared when it
    -- resolves (adopt a newer token, or proceed to `forceSessionExpiry`).
    , pendingLogout : Maybe PendingLogout
    , config : AppConfig
    , connectivity : Connectivity
    , uploadInbox : RemoteData Http.Error (List Api.InboxItem)
    }


{-| Server-provided runtime configuration, delivered in the boot flags from
`GET /api/config`. The frontend's first global config channel —
extend this record as new server-driven flags land.
-}
type alias AppConfig =
    { ageGatingEnabled : Bool
    , inviteOnly : Bool
    }


{-| The fail-safe default config: age-gating OFF (all age UI hidden). Used when
`GET /api/config` fails, times out, or returns a malformed/absent field.
-}
defaultConfig : AppConfig
defaultConfig =
    { ageGatingEnabled = False

    -- Fail CLOSED (): a gate on account creation must not reopen
    -- because a config fetch blipped. The server's real value arrives over
    -- `inviteOnlyConfig` a beat after boot; until then Register shows the
    -- invite panel, which an open-registration deployment replaces almost
    -- immediately.
    , inviteOnly = True
    }


{-| Decode the runtime config out of the boot flags. A missing or malformed
`ageGatingEnabled` never crashes boot — it defaults to `False` (fail safe).
-}
configDecoder : Decode.Decoder AppConfig
configDecoder =
    Decode.map2 AppConfig
        (Decode.oneOf
            [ Decode.field "ageGatingEnabled" Decode.bool
            , Decode.succeed False
            ]
        )
        (Decode.oneOf
            [ Decode.field "inviteOnly" Decode.bool
            , Decode.succeed True
            ]
        )


{-| Read the runtime config from the boot flags, falling back to
`defaultConfig` (age-gating off) on any decode failure. Exposed for tests.
-}
decodeConfig : Decode.Value -> AppConfig
decodeConfig flags =
    Decode.decodeValue configDecoder flags
        |> Result.withDefault defaultConfig


init : Decode.Value -> Url -> Nav.Key -> ( Model, Cmd Msg )
init flags url key =
    let
        stored =
            decodeFlags flags

        maybeAuth =
            storedSession stored

        arrival =
            arrivalForBoot stored

        config =
            decodeConfig flags

        route =
            Route.fromUrl url

        ( page, cmd ) =
            initPage config route (originOf url) maybeAuth Nothing Nothing arrival
    in
    ( { key = key
      , url = url
      , route = route
      , auth =
            maybeAuth |> Maybe.map Authenticated |> Maybe.withDefault Anonymous
      , adminAuth = Nothing
      , adminChrome = AdminChrome.init
      , page = page
      , previousRoute = Nothing
      , transition = Nothing
      , redirectAfterLogin = loginRedirectFor route maybeAuth
      , bookDetailOverlay = Nothing
      , userMenu = UserMenu.init
      , openNavMenu = Nothing
      , onboarding = OnboardingOverlay.init
      , onboardingCompleted = False
      , hasAnyPlacements = True
      , pendingUndo = Nothing
      , arrival = consumeArrival page arrival
      , pendingLogout = Nothing
      , config = config
      , connectivity = Online
      , uploadInbox = NotAsked
      }
    , Cmd.batch
        [ cmd
        , case maybeAuth of
            Just auth ->
                Cmd.batch
                    [ Cmd.map OnboardingMsg (OnboardingOverlay.initCmd auth.token)
                    , Api.getMyPlacements auth.token GotPlacementCheck
                    , scheduleRenewal
                    , Api.getUploadInbox auth.token GotUploadInbox
                    ]

            Nothing ->
                Cmd.none
        ]
    )


{-| Ask the server what is waiting for this reader.

Called at boot, on sign-in, and whenever `Page.Upload` says something changed.
Anonymous is a `Cmd.none` rather than a failure: there is no inbox to have.

-}
fetchUploadInbox : Maybe Auth -> Cmd Msg
fetchUploadInbox maybeAuth =
    case maybeAuth of
        Just auth ->
            Api.getUploadInbox auth.token GotUploadInbox

        Nothing ->
            Cmd.none


{-| Decoder for a stored-auth JSON object (the exact shape `encodeAuth` writes to
localStorage `stacks-auth`). Lifted to the top level so both `decodeFlags` (boot)
and `adoptExternalAuth` (cross-tab propagation,) share one contract.
-}
authDecoder : Decode.Decoder Auth
authDecoder =
    Decode.map6
        (\token userId email displayName handle role ->
            { user =
                { id = userId
                , email = email
                , displayName = displayName
                , handle = handle
                , role = role
                , countryCode = Nothing
                , city = Nothing
                , consentAnalytics = False
                , consentWritingAssistant = False
                }
            , token = token
            }
        )
        (Decode.field "token" Decode.string)
        (Decode.field "userId" Decode.string)
        (Decode.field "email" Decode.string)
        (Decode.field "displayName" Decode.string)
        (Decode.oneOf
            [ Decode.field "handle" Decode.string
            , Decode.succeed ""
            ]
        )
        (Decode.oneOf
            [ Decode.field "role" Decode.string
            , Decode.succeed "user"
            ]
        )


{-| What boot found in localStorage. Three outcomes, three
constructors — the old `Maybe Auth` folded "no stored credential" and
"stored but would not decode" into one `Nothing`. The blob is written by
`saveAuth` and read by the same decoder, so a decode failure means
something rewrote it; treating it as an ordinary signed-out boot hides
that, and `CorruptAuth` lets boot clear the bad blob and say why.
-}
type StoredAuth
    = NoStoredAuth
    | CorruptStoredAuth String
    | ValidStoredAuth Auth


{-| The session a boot recovered, if any. The ONE accessor — mirroring
`currentAuth` for `AuthState` — so no consumer pattern-matches `StoredAuth` to
decide whether a request can be made and accidentally makes `CorruptStoredAuth`
mean something other than "signed out".
-}
storedSession : StoredAuth -> Maybe Auth
storedSession stored =
    case stored of
        ValidStoredAuth auth ->
            Just auth

        NoStoredAuth ->
            Nothing

        CorruptStoredAuth _ ->
            Nothing


{-| What a boot owes the reader an explanation for.

⛔ This is the whole point of `CorruptStoredAuth`: the boot outcome is
turned into something the reader can SEE. Before, `decodeFlags` answered
`Nothing` and `init` simply started anonymous — the app knew a credential had
been found and rejected, and told nobody. A silent sign-out is indistinguishable
from a deliberate one, so the failure could only ever be diagnosed from the
outside, which is exactly what made the private-session auth bug expensive.

Named and exposed rather than inlined in `init`, because `init` needs a
`Nav.Key` and is therefore unreachable from elm-test: the whole chain from raw
boot flags to rendered notice would otherwise have no test that could run.

-}
arrivalForBoot : StoredAuth -> Login.Arrival
arrivalForBoot stored =
    case stored of
        CorruptStoredAuth reason ->
            Login.StoredSessionUnreadable reason

        NoStoredAuth ->
            Login.Fresh

        ValidStoredAuth _ ->
            Login.Fresh


{-| The flag keys that mean "a stored credential was here". `authDecoder`
failing tells us the blob is not a session; these tell us a blob was _attempted_,
which is the difference between a corrupt credential and a clean signed-out boot.

`user` is in the list although no valid blob has it: it is the exact shape of the
nested-blob mistake, and the whole point is to name that case rather than let it
fall through to "never signed in". Every other entry is a field `encodeAuth`
writes, so any partial or truncated write is caught by at least one.

-}
storedAuthMarkers : List String
storedAuthMarkers =
    [ "token", "userId", "user", "email", "displayName" ]


{-| Read the stored credential out of the boot flags.

`storedAuthUnreadable` is checked first: `app.js` cannot hand over a blob it
could not `JSON.parse`, or could not read at all because `localStorage` threw
(private browsing, storage disabled), so it sends the reason under that key
instead of dropping it in a bare `catch`. Those are the two failure modes Elm
cannot see for itself.

-}
decodeFlags : Decode.Value -> StoredAuth
decodeFlags flags =
    case Decode.decodeValue (Decode.field "storedAuthUnreadable" Decode.string) flags of
        Ok reason ->
            CorruptStoredAuth reason

        Err _ ->
            case Decode.decodeValue authDecoder flags of
                Ok auth ->
                    ValidStoredAuth auth

                Err decodeError ->
                    if hasStoredAuthMarker flags then
                        CorruptStoredAuth (Decode.errorToString decodeError)

                    else
                        NoStoredAuth


{-| Whether the flags carry any trace of a stored credential.
-}
hasStoredAuthMarker : Decode.Value -> Bool
hasStoredAuthMarker flags =
    List.any
        (\field ->
            case Decode.decodeValue (Decode.field field Decode.value) flags of
                Ok _ ->
                    True

                Err _ ->
                    False
        )
        storedAuthMarkers


isOwner : Maybe Auth -> Bool
isOwner maybeAuth =
    case maybeAuth of
        Just auth ->
            auth.user.role == "owner"

        Nothing ->
            False


{-| The browser origin (scheme://host[:port]) — what turns a post id into its
canonical absolute address client-side.
-}
originOf : Url -> String
originOf url =
    let
        scheme =
            case url.protocol of
                Url.Http ->
                    "http://"

                Url.Https ->
                    "https://"

        portPart =
            url.port_
                |> Maybe.map (\p -> ":" ++ String.fromInt p)
                |> Maybe.withDefault ""
    in
    scheme ++ url.host ++ portPart


requiresAuth : Route -> Bool
requiresAuth route =
    case route of
        Home ->
            False

        Login ->
            False

        CostTransparency ->
            False

        Metrics ->
            False

        About ->
            False

        Faq ->
            False

        DataTransparency ->
            False

        ListingRemoval ->
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

        Profile _ ->
            False

        ProfileShelf _ _ ->
            False

        Search ->
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

        _ ->
            True


{-| The token for `/api/admin/*` — the ONLY thing any admin call site may
pass. `/api/admin/*` requires the MFA-verified admin session token and
401s the ordinary one; when the five call sites each read a field, two
drifted and every admin action 401'd behind a loaded page. One function,
five callers, zero drift.
-}
adminTokenFor : Model -> Maybe String
adminTokenFor model =
    model.adminAuth


{-| The page the reader asked for but is being bounced off (`Nothing` when
not bounced). Named once and read by BOTH the bounce (`initPage`) and the
remembering site (`Model.redirectAfterLogin`) — a second copy of the
condition is how "capture the asked-for page" drifts from "bounce to the
gate" and starts remembering a page nobody was denied.
-}
loginRedirectFor : Route -> Maybe Auth -> Maybe Route
loginRedirectFor route maybeAuth =
    if requiresAuth route && maybeAuth == Nothing then
        Just route

    else
        Nothing


{-| Where a finished password reset carries the reader, or `Nothing` when the
reset page is not asking to go anywhere.

⛔ Key-free and exposed on purpose. `Model` embeds an unconstructable `Nav.Key`,
so `update`'s `ResetPasswordMsg` branch cannot be driven from a test — and a
wire whose far end is untestable is a wire that gets stubbed and stays stubbed
(the seam /found, where both ends were right and the join between them
was never exercised). `update` **calls** this rather than re-deciding the
destination inline, so the branch a test can reach is the branch that ships:
change the answer here and the running app changes with it.

-}
resetPasswordDestination : ResetPassword.OutMsg -> Maybe Route
resetPasswordDestination outMsg =
    case outMsg of
        ResetPassword.NoOut ->
            Nothing

        ResetPassword.AdvanceToLogin ->
            Just Route.Login


{-| The page to return the reader to after sign-in, recomputed for THIS
navigation — never accumulated; read once from `UrlChanged`.

⛔ An expiry bounce is a bounce too: a bare `loginRedirectFor` is
right for a route-guard bounce and wrong when the session dies underneath
the reader — `/login` requires no auth, so the recompute answered
`Nothing` and dropped the page they were standing on. Expiry stashes the
current route explicitly; this preserves it.

-}
redirectAfterNavigation :
    { arrivingAt : Route
    , leaving : Route
    , sessionExpiring : Bool
    , auth : Maybe Auth
    }
    -> Maybe Route
redirectAfterNavigation navigation =
    if navigation.arrivingAt == Login && navigation.sessionExpiring then
        loginRedirectFor navigation.leaving Nothing

    else
        loginRedirectFor navigation.arrivingAt navigation.auth


{-| Build the page for a route. `arrival` is the reason the reader would be
looking at a login card, threaded IN rather than patched on afterwards:
there is more than one way to reach the card (protected-route bounce,
`/login`, `/forgot-password`), and the notice used to be attached at only
one of them.
-}
initPage : AppConfig -> Route -> String -> Maybe Auth -> Maybe String -> Maybe Route -> Login.Arrival -> ( Page, Cmd Msg )
initPage config route origin maybeAuth adminToken maybePreviousRoute arrival =
    if loginRedirectFor route maybeAuth /= Nothing then
        ( PageLogin (Login.init arrival |> Login.withInviteOnly config.inviteOnly), Cmd.none )

    else if isAdminRoute route && adminToken == Nothing then
        -- ⛔ The gate that makes four surfaces reachable. `/api/admin/*` needs an
        -- MFA-verified admin-session token, NOT the ordinary Guardian one; the pages were handed
        -- the latter and every request 401'd, so all four had never loaded for anyone. Rather than
        -- let a page render and fail, the route resolves to the sign-in gate until a real admin
        -- token exists — so a page never holds a token it cannot use.
        ( PageAdminGate route AdminSession.init, Cmd.none )

    else
        initPageAuthenticated config route origin maybeAuth adminToken maybePreviousRoute arrival


{-| What the feedback form records about where the reader was.

`Route.toPattern`, never `Route.toPath`: the reader may have walked here from
someone else's profile, and `/u/:handle` is all a bug report needs. Empty when
they arrived directly, which is honest — nothing is invented to fill the field.

-}
feedbackContextFor : Maybe Route -> String
feedbackContextFor maybePreviousRoute =
    maybePreviousRoute
        |> Maybe.map Route.toPattern
        |> Maybe.withDefault ""


{-| The routes behind the `:admin` pipeline. Exhaustive on purpose — a `_ -> False` catch-all would
silently leave a newly added admin route ungated, which is the bug this whole change is fixing.
-}
isAdminRoute : Route -> Bool
isAdminRoute route =
    case route of
        Route.AdminSourceApproval ->
            True

        Route.AdminInvites ->
            True

        Route.AdminFeedback ->
            True

        Route.AdminScraperConfig ->
            True

        Route.AdminBookModeration ->
            True

        Route.AdminRemovalRequests ->
            True

        _ ->
            False


{-| Hand a just-built page the removal the reader may still take back. Applied to `initPage`'s result, not threaded through it — only the
`UrlChanged` a removal's `pushUrl` provokes can ever have an undo, and a
seventh parameter would make the other call sites say `Nothing` forever.
The destination is `BookDetail.previousRoute`, i.e. the shelf the reader
was standing on.
-}
applyPendingUndo : Maybe Bookshelf.Removal -> ( Page, Cmd Msg ) -> ( Page, Cmd Msg )
applyPendingUndo maybeRemoval ( page, cmd ) =
    case ( maybeRemoval, page ) of
        ( Just _, PageBookshelf bookshelfModel ) ->
            let
                ( withToast, toastCmd ) =
                    Bookshelf.withPendingUndo maybeRemoval ( bookshelfModel, Cmd.none )
            in
            ( PageBookshelf withToast
            , Cmd.batch [ cmd, Cmd.map BookshelfMsg toastCmd ]
            )

        _ ->
            ( page, cmd )


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


initPageAuthenticated : AppConfig -> Route -> String -> Maybe Auth -> Maybe String -> Maybe Route -> Login.Arrival -> ( Page, Cmd Msg )
initPageAuthenticated config route origin maybeAuth adminToken maybePreviousRoute arrival =
    let
        maybeToken =
            Maybe.map .token maybeAuth
    in
    case route of
        Home ->
            let
                ( subModel, subCmd ) =
                    Home.init maybeToken
            in
            ( PageHome subModel, Cmd.map HomeMsg subCmd )

        Login ->
            ( PageLogin (Login.init arrival |> Login.withInviteOnly config.inviteOnly), Cmd.none )

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
            ( PageBookDetail model
            , Cmd.map BookDetailMsg cmd
            )

        Upload ->
            let
                uploadModel =
                    Upload.init
            in
            ( PageUpload { uploadModel | ageGatingEnabled = config.ageGatingEnabled }, Cmd.none )

        Import ->
            ( PageImport ImportPage.init, Cmd.none )

        Search ->
            ( PageSearch Search.init, Cmd.none )

        SettingsAuditLog ->
            let
                ( model, cmd ) =
                    AuditLog.init maybeToken
            in
            ( PageSettingsAuditLog model, Cmd.map AuditLogMsg cmd )

        Insights ->
            let
                ( model, cmd ) =
                    Insights.init maybeToken
            in
            ( PageInsights model, Cmd.map InsightsMsg cmd )

        CostTransparency ->
            let
                ( model, cmd ) =
                    CostTransparency.init
            in
            ( PageCostTransparency model, Cmd.map CostTransparencyMsg cmd )

        Metrics ->
            let
                ( model, cmd ) =
                    MetricsPage.init
            in
            ( PageMetrics model, Cmd.map MetricsMsg cmd )

        About ->
            ( PageAbout, Cmd.none )

        Faq ->
            ( PageFaq, Cmd.none )

        DataTransparency ->
            ( PageDataTransparency, Cmd.none )

        ListingRemoval ->
            ( PageListingRemoval ListingRemoval.init, Cmd.none )

        Catalogue ->
            let
                ( model, cmd ) =
                    Catalogue.init maybeToken
            in
            ( PageCatalogue model, Cmd.map CatalogueMsg cmd )

        SettingsProfile ->
            let
                ( model, cmd ) =
                    Profile.initWithToken maybeToken
                        (case maybeAuth of
                            Just auth ->
                                auth.user

                            Nothing ->
                                { id = "", email = "", displayName = "", handle = "", role = "user", countryCode = Nothing, city = Nothing, consentAnalytics = False, consentWritingAssistant = False }
                        )
            in
            ( PageSettingsProfile model, Cmd.map ProfileMsg cmd )

        SettingsPassword ->
            ( PageSettingsPassword Password.init, Cmd.none )

        SettingsNotifications ->
            let
                ( model, cmd ) =
                    Notifications.init maybeToken
            in
            ( PageSettingsNotifications model, Cmd.map NotificationsMsg cmd )

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
            let
                consentSeed =
                    case maybeAuth of
                        Just auth ->
                            { analytics = auth.user.consentAnalytics
                            , writingAssistant = auth.user.consentWritingAssistant
                            }

                        Nothing ->
                            { analytics = False, writingAssistant = False }

                ( privacyModel, privacyCmd ) =
                    Privacy.initWithToken maybeToken consentSeed
            in
            ( PageSettingsPrivacy privacyModel, Cmd.map PrivacyMsg privacyCmd )

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
                    BlogPostPage.init postId maybeToken currentUserId writingAssistantConsent origin
            in
            ( PageBlogPost postModel, Cmd.map BlogPostMsg postCmd )

        Route.Feedback ->
            ( PageFeedback (FeedbackPage.init (feedbackContextFor maybePreviousRoute)), Cmd.none )

        Route.AdminSourceApproval ->
            if isOwner maybeAuth then
                let
                    ( subModel, subCmd ) =
                        AdminSourceApproval.init adminToken
                in
                ( PageAdminSourceApproval subModel, Cmd.map AdminSourceApprovalMsg subCmd )

            else
                ( PageNotFound, Cmd.none )

        Route.AdminFeedback ->
            if isOwner maybeAuth then
                let
                    ( subModel, subCmd ) =
                        AdminFeedback.init adminToken
                in
                ( PageAdminFeedback subModel, Cmd.map AdminFeedbackMsg subCmd )

            else
                ( PageNotFound, Cmd.none )

        Route.AdminInvites ->
            if isOwner maybeAuth then
                let
                    ( subModel, subCmd ) =
                        AdminInvites.init adminToken
                in
                ( PageAdminInvites subModel, Cmd.map AdminInvitesMsg subCmd )

            else
                ( PageNotFound, Cmd.none )

        Route.AdminScraperConfig ->
            if isOwner maybeAuth then
                let
                    ( subModel, subCmd ) =
                        AdminScraperConfig.init adminToken
                in
                ( PageAdminScraperConfig subModel, Cmd.map AdminScraperConfigMsg subCmd )

            else
                ( PageNotFound, Cmd.none )

        Route.AdminBookModeration ->
            if isOwner maybeAuth && config.ageGatingEnabled then
                let
                    ( subModel, subCmd ) =
                        AdminBookModeration.init adminToken
                in
                ( PageAdminBookModeration subModel, Cmd.map AdminBookModerationMsg subCmd )

            else
                ( PageNotFound, Cmd.none )

        Route.AdminRemovalRequests ->
            if isOwner maybeAuth then
                let
                    ( subModel, subCmd ) =
                        AdminRemovalRequests.init adminToken
                in
                ( PageAdminRemovalRequests subModel, Cmd.map AdminRemovalRequestsMsg subCmd )

            else
                ( PageNotFound, Cmd.none )

        Groups ->
            let
                auth =
                    Maybe.withDefault { user = { id = "", email = "", displayName = "", handle = "", role = "user", countryCode = Nothing, city = Nothing, consentAnalytics = False, consentWritingAssistant = False }, token = "" } maybeAuth

                ( m, cmd ) =
                    Groups.init auth.user.id auth.token
            in
            ( PageGroups m, Cmd.map GroupsMsg cmd )

        GroupDetail groupId ->
            let
                auth =
                    Maybe.withDefault { user = { id = "", email = "", displayName = "", handle = "", role = "user", countryCode = Nothing, city = Nothing, consentAnalytics = False, consentWritingAssistant = False }, token = "" } maybeAuth

                ( m, cmd ) =
                    GroupsDetail.init groupId auth.user.id auth.token
            in
            ( PageGroupsDetail m, Cmd.map GroupsDetailMsg cmd )

        Profile handle ->
            let
                ( m, cmd ) =
                    ProfilePage.init maybeToken handle
            in
            ( PageProfile m, Cmd.map PublicProfileMsg cmd )

        ProfileShelf handle bookshelfName ->
            initBookshelf (Bookshelf.profileConfig handle bookshelfName) maybeAuth

        ConfirmEmail status ->
            ( PageConfirmEmail status, Cmd.none )

        ForgotPassword ->
            ( PageLogin (Login.init Login.ForgotPassword |> Login.withInviteOnly config.inviteOnly), Cmd.none )

        ResendConfirmation ->
            ( PageLogin (Login.init Login.ConfirmationExpired |> Login.withInviteOnly config.inviteOnly), Cmd.none )

        ResetPassword token ->
            ( PageResetPassword (ResetPassword.init token), Cmd.none )

        NotFound ->
            ( PageNotFound, Cmd.none )


encodeAuth : Auth -> Json.Encode.Value
encodeAuth auth =
    Json.Encode.object
        [ ( "token", Json.Encode.string auth.token )
        , ( "userId", Json.Encode.string auth.user.id )
        , ( "email", Json.Encode.string auth.user.email )
        , ( "displayName", Json.Encode.string auth.user.displayName )
        , ( "handle", Json.Encode.string auth.user.handle )
        , ( "role", Json.Encode.string auth.user.role )
        ]


{-| The single, central deferred session-expiry entry point. EVERY authenticated page routes its `SessionExpired` OutMsg here, and a
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


{-| As `handleSessionExpiry`, but for the marketplace-compose expiry: the
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


{-| The actual, irreversible session-expiry path. Reached only after
the re-check net (`handleSessionExpiry` → `gotStoredAuth`) confirms there is no
newer token to adopt, or from a sibling-tab `clearAuth`. Mirrors sign-out: clears
`model.auth`, drops the `clearAuth` port, and redirects to `/login` — raising
`sessionExpiredNotice` (and `draftSavedNotice` when a draft was parked) so the
login page shows an "expired" message distinct from invalid-credentials. The
notice survives the `Nav.pushUrl`-driven `UrlChanged` re-init via the flag.
-}
forceSessionExpiry : Bool -> Model -> ( Model, Cmd Msg )
forceSessionExpiry draftSaved model =
    ( { model
        | auth = Anonymous
        , adminAuth = Nothing
        , arrival =
            Login.SessionExpired
                { draftSaved = draftSaved || Login.draftWasSaved model.arrival }
        , userMenu = UserMenu.init
        , openNavMenu = Nothing
        , bookDetailOverlay = Nothing
        , pendingLogout = Nothing
      }
    , Cmd.batch
        [ clearAuth ()
        , Nav.pushUrl model.key (Route.toPath Login)
        ]
    )


{-| The farewell/logout path after a successful account-deletion request. The backend has queued the erasure; here we tear down the local
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
        | auth = Anonymous
        , adminAuth = Nothing
        , arrival = Login.AccountDeleted
        , userMenu = UserMenu.init
        , openNavMenu = Nothing
        , bookDetailOverlay = Nothing
        , pendingLogout = Nothing
      }
    , Cmd.batch
        [ clearAuth ()
        , clearListingDraft ()
        , Nav.pushUrl model.key (Route.toPath Login)
        ]
    )


{-| Spend the pending arrival once a login card has actually been built with it.

⛔ The condition is "a login card was rendered", NOT "the route is `/login`".
The three booleans this replaced were each cleared by `… && newRoute /= Login`,
which is the same test written three times and wrong in the same way three
times: the protected-route bounce (`initPage`) shows the login card **without
changing the URL**, so an expiry notice raised on `/library` was never marked as
delivered and would resurface on the reader's next navigation. Asking the page
that was built removes the possibility of the two disagreeing.

-}
consumeArrival : Page -> Login.Arrival -> Login.Arrival
consumeArrival page arrival =
    case page of
        PageLogin _ ->
            Login.Fresh

        _ ->
            arrival


{-| The outcome of interpreting a stored-auth value, used
for BOTH cross-tab propagation and the 401 re-check net.
-}
type ExternalAuthOutcome
    = AdoptAuth Auth
    | LogOutExternally
    | IgnoreExternal


{-| Pure decision for an externally-observed stored-auth value (a sibling
tab's `storage` event, or the re-check response). The port delivers the
RAW localStorage payload. Differing valid token while authed →
`AdoptAuth`; same token → `IgnoreExternal` (echo defence); `null`/corrupt
while authed → `DropAuth` (a sibling signed out or the blob was
clobbered); anything while not authed → adopt-or-ignore without a drop.
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
            case maybeAuth of
                Just _ ->
                    LogOutExternally

                Nothing ->
                    IgnoreExternal

        Err _ ->
            IgnoreExternal


{-| The resolution of a re-check (`gotStoredAuth`) answer against the parked
intent. Pure, so the reschedule decision — opaque as a `Cmd`
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
The access token TTL is 8h (server-side,); we refresh comfortably
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

`PlayDoorAnimation` is in this list rather than in a branch of its own so that
"the animation runs last" is a fact about ONE ordered value a test can read,
instead of an ordering buried in a `Cmd.batch` nobody can inspect.

-}
type LoginEffect
    = PersistAuth
    | FetchPlacements
    | InitOnboarding
    | ScheduleRenewal
    | NavigateToRequestedPage
    | ArmArrivalBackstop
    | PlayDoorAnimation


{-| Effects performed when a login completes. Mirrors what `init` does for a
stored auth, plus the arrival ornament.

⛔ The ORDER is the fix. `PersistAuth` is first and `PlayDoorAnimation` is
last, and every one of them is fired from the single update that decodes the
`200` — nothing here waits for a message from the browser. It used to be the
other way round: the animation was started, and the token was written only when
the browser reported the animation had finished. `requestAnimationFrame` does
not fire while a window is occluded, so on a backgrounded tab the report never
came and the login was discarded in silence. Anything a browser may decline to
run belongs after the credential is durable, never in front of it.

-}
loginEffects : List LoginEffect
loginEffects =
    [ PersistAuth
    , FetchPlacements
    , InitOnboarding
    , ScheduleRenewal
    , NavigateToRequestedPage
    , ArmArrivalBackstop
    , PlayDoorAnimation
    ]


{-| Everything a completed login produces, as one indivisible value: the session
to hold in memory, the state that session puts the app in, and the effects that
make it durable.

⛔ This is the ONLY function that turns an `AuthResponse` into an `AuthState`.
Returning the state and its effects together is what makes "authenticated but
never saved" unwritable: a caller cannot reach `Arriving auth` without also
being handed the `PersistAuth` that backs it.

-}
type alias CompletedLogin =
    { session : Auth
    , authState : AuthState
    , effects : List LoginEffect
    }


{-| Build the completed login for a `200` from `POST /api/auth/login`. Pure and
key-free, so the persist-first guarantee is unit-testable rather than only
observable in a browser.
-}
completeLogin : Api.AuthResponse -> CompletedLogin
completeLogin authResponse =
    let
        session =
            { user =
                { id = authResponse.userId
                , email = authResponse.email
                , displayName = authResponse.displayName
                , handle = authResponse.handle
                , role = authResponse.role
                , countryCode = Nothing
                , city = Nothing
                , consentAnalytics = authResponse.consentAnalytics
                , consentWritingAssistant = authResponse.consentWritingAssistant
                }
            , token = authResponse.token
            }
    in
    { session = session
    , authState = Arriving session
    , effects = loginEffects
    }


{-| How long the app will wait for the door ornament to report itself finished
before settling the arrival anyway. Comfortably past the 4 s animation.
-}
arrivalBackstopMs : Float
arrivalBackstopMs =
    6000


{-| Realise a single `LoginEffect` as a concrete `Cmd` for a completed login.
`redirect` is the page the reader was bounced off, if any.
-}
loginEffectCmd : Nav.Key -> Maybe Route -> Auth -> LoginEffect -> Cmd Msg
loginEffectCmd key redirect auth effect =
    case effect of
        PersistAuth ->
            saveAuth (encodeAuth auth)

        FetchPlacements ->
            Api.getMyPlacements auth.token GotPlacementCheck

        InitOnboarding ->
            Cmd.map OnboardingMsg (OnboardingOverlay.initCmd auth.token)

        ScheduleRenewal ->
            scheduleRenewal

        NavigateToRequestedPage ->
            Nav.pushUrl key (Route.toPath (Maybe.withDefault AntiLibrary redirect))

        ArmArrivalBackstop ->
            Process.sleep arrivalBackstopMs |> Task.perform (\_ -> ArrivalSettled)

        PlayDoorAnimation ->
            playLoginTransition
                (Json.Encode.object [ ( "duration", Json.Encode.int 4000 ) ])


{-| All commands a completed login must fire, given the base command already
produced by the login sub-update.
-}
loginCompletionCmd : Nav.Key -> Maybe Route -> CompletedLogin -> Cmd Msg -> Cmd Msg
loginCompletionCmd key redirect arrival baseCmd =
    Cmd.batch
        (baseCmd
            :: List.map (loginEffectCmd key redirect arrival.session) arrival.effects
        )


{-| The top-level navigation disclosures whose open/closed state Elm owns
(TR-1). Each corresponds to a `<button aria-haspopup aria-expanded>` in the
nav; `Model.openNavMenu` holds the one that is open. Compared with `==`, so it
must stay a plain, argument-free custom type.
-}
type NavMenu
    = BookshelvesMenu
    | MarketplaceMenu
    | AdminMenu


{-| Toggle a nav disclosure: opening the one that is closed, closing the one
that is open, and switching directly from any other. This is the pure core that
both the trigger button (`ToggleNavMenu`) and the keyboard path run through, so
it is the unit-test oracle for "keyboard/click toggles the menu".
-}
toggleNavMenu : NavMenu -> Maybe NavMenu -> Maybe NavMenu
toggleNavMenu menu current =
    if current == Just menu then
        Nothing

    else
        Just menu


type Msg
    = LinkClicked Browser.UrlRequest
    | UrlChanged Url
    | TransitionEnded String
    | LoginMsg Login.Msg
    | ResetPasswordMsg ResetPassword.Msg
    | ArrivalSettled
    | HomeMsg Home.Msg
    | BookshelfMsg Bookshelf.Msg
    | ReadingPileMsg ReadingPile.Msg
    | LookingForHomeMsg LookingForHome.Msg
    | BookDetailMsg BookDetail.Msg
    | UploadMsg Upload.Msg
    | ImportPageMsg ImportPage.Msg
    | SearchMsg Search.Msg
    | AuditLogMsg AuditLog.Msg
    | InsightsMsg Insights.Msg
    | ProfileMsg Profile.Msg
    | PasswordMsg Password.Msg
    | NotificationsMsg Notifications.Msg
    | CostTransparencyMsg CostTransparency.Msg
    | MetricsMsg MetricsPage.Msg
    | CatalogueMsg Catalogue.Msg
    | ListingRemovalMsg ListingRemoval.Msg
    | MarketplaceBrowseMsg MarketplaceBrowse.Msg
    | CreateListingMsg CreateListing.Msg
    | MyListingsMsg MyListings.Msg
    | ListingDetailMsg ListingDetail.Msg
    | PrivacyMsg Privacy.Msg
    | BlogArchiveMsg BlogArchive.Msg
    | BlogEditorMsg BlogEditor.Msg
    | BlogPostMsg BlogPostPage.Msg
    | FeedbackMsg FeedbackPage.Msg
    | AdminSourceApprovalMsg AdminSourceApproval.Msg
    | AdminFeedbackMsg AdminFeedback.Msg
    | AdminInvitesMsg AdminInvites.Msg
    | AdminScraperConfigMsg AdminScraperConfig.Msg
    | AdminBookModerationMsg AdminBookModeration.Msg
    | AdminRemovalRequestsMsg AdminRemovalRequests.Msg
    | AdminSessionMsg AdminSession.Msg
    | GroupsMsg Groups.Msg
    | GroupsDetailMsg GroupsDetail.Msg
    | PublicProfileMsg ProfilePage.Msg
    | UserMenuMsg UserMenu.Msg
    | ToggleNavMenu NavMenu
    | CloseNavMenu
    | SwipeReceived String
    | SwipeIgnored
    | OverlayBookDetailMsg BookDetail.Msg
    | EscapePressed
    | AdminChromeMsg AdminChrome.Msg
    | OnboardingMsg OnboardingOverlay.Msg
    | OnboardingStatusReceived Bool
    | FocusResult
    | GotPlacementCheck (Result Http.Error (List Types.Placement.Placement))
    | GotUploadInbox (Result Http.Error (List Api.InboxItem))
    | RenewToken
    | TokenRefreshed (Result Http.Error Api.AuthResponse)
    | AuthChangedExternally Decode.Value
    | GotStoredAuth Decode.Value
    | AgeGatingConfigReceived Bool
    | InviteOnlyConfigReceived Bool
    | ConnectivityChanged Bool


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

                ( page, cmd ) =
                    initPage model.config
                        newRoute
                        (originOf url)
                        (currentAuth model.auth)
                        (adminTokenFor model)
                        (Just model.route)
                        model.arrival
                        |> applyPendingUndo model.pendingUndo
            in
            ( { model
                | url = url
                , route = newRoute
                , page = page
                , previousRoute = Just model.route
                , pendingUndo = Nothing
                , transition = transition
                , redirectAfterLogin =
                    redirectAfterNavigation
                        { arrivingAt = newRoute
                        , leaving = model.route
                        , sessionExpiring = Login.isSessionExpiry model.arrival
                        , auth = currentAuth model.auth
                        }
                , userMenu = UserMenu.init
                , arrival = consumeArrival page model.arrival
              }
            , cmd
            )

        TransitionEnded animationName ->
            ( { model
                | transition =
                    Transition.clearOnAnimationEnd animationName model.transition
              }
            , Cmd.none
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

                        Login.LoggedIn authResponse ->
                            let
                                arrival =
                                    completeLogin authResponse
                            in
                            ( { baseModel | auth = arrival.authState }
                            , loginCompletionCmd model.key model.redirectAfterLogin arrival baseCmd
                            )

                        Login.RegistrationSucceeded _ ->
                            ( baseModel, baseCmd )

                _ ->
                    ( model, Cmd.none )

        ArrivalSettled ->
            ( { model | auth = settleArrival model.auth }, Cmd.none )

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

        HomeMsg subMsg ->
            case model.page of
                PageHome subModel ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            Home.update subMsg subModel

                        baseModel =
                            { model | page = PageHome newSubModel }

                        baseCmd =
                            Cmd.map HomeMsg subCmd
                    in
                    case outMsg of
                        Home.NoOut ->
                            ( baseModel, baseCmd )

                        Home.SessionExpired ->
                            handleSessionExpiry model

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

                _ ->
                    ( model, Cmd.none )

        BookDetailMsg subMsg ->
            case model.page of
                PageBookDetail subModel ->
                    let
                        maybeToken =
                            Maybe.map .token (currentAuth model.auth)

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

                        -- The routed page fills the window: the mutation signal
                        -- has no covered page to correct.
                        BookDetail.PlacementMutated ->
                            ( baseModel, baseCmd )

                        BookDetail.SessionExpired ->
                            handleSessionExpiry model

                        BookDetail.RequestCloseOverlay ->
                            ( baseModel, baseCmd )

                        BookDetail.NavigateTo route ->
                            ( { baseModel | pendingUndo = newSubModel.undoableRemoval }
                            , Cmd.batch
                                [ baseCmd
                                , Nav.pushUrl model.key (Route.toPath route)
                                , focusMainContent
                                ]
                            )

                _ ->
                    ( model, Cmd.none )

        UploadMsg subMsg ->
            case model.page of
                PageUpload subModel ->
                    let
                        maybeToken =
                            Maybe.map .token (currentAuth model.auth)

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

                        Upload.RefreshInbox ->
                            ( baseModel
                            , Cmd.batch
                                [ baseCmd
                                , fetchUploadInbox (currentAuth model.auth)
                                ]
                            )

                _ ->
                    ( model, Cmd.none )

        ImportPageMsg subMsg ->
            case model.page of
                PageImport subModel ->
                    let
                        maybeToken =
                            Maybe.map .token (currentAuth model.auth)

                        ( newSubModel, subCmd, outMsg ) =
                            ImportPage.update subMsg subModel maybeToken
                    in
                    case outMsg of
                        ImportPage.NoOut ->
                            ( { model | page = PageImport newSubModel }
                            , Cmd.map ImportPageMsg subCmd
                            )

                        ImportPage.SessionExpired ->
                            handleSessionExpiry model

                _ ->
                    ( model, Cmd.none )

        SearchMsg subMsg ->
            case model.page of
                PageSearch subModel ->
                    let
                        maybeToken =
                            Maybe.map .token (currentAuth model.auth)

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

                        Search.OpenOverlay bookId ->
                            let
                                baseModel =
                                    { model | page = PageSearch newSubModel }

                                ( overlayModel, overlayCmd ) =
                                    openOverlayWithTrigger baseModel bookId ("search-result-" ++ bookId)
                            in
                            ( overlayModel
                            , Cmd.batch [ Cmd.map SearchMsg subCmd, overlayCmd ]
                            )

                _ ->
                    ( model, Cmd.none )

        AuditLogMsg subMsg ->
            case model.page of
                PageSettingsAuditLog subModel ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            AuditLog.update subMsg subModel
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

        InsightsMsg subMsg ->
            case model.page of
                PageInsights subModel ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            Insights.update subMsg subModel
                    in
                    case outMsg of
                        Insights.NoOut ->
                            ( { model | page = PageInsights newSubModel }
                            , Cmd.map InsightsMsg subCmd
                            )

                        Insights.SessionExpired ->
                            handleSessionExpiry model

                _ ->
                    ( model, Cmd.none )

        ProfileMsg subMsg ->
            case model.page of
                PageSettingsProfile subModel ->
                    let
                        maybeToken =
                            Maybe.map .token (currentAuth model.auth)

                        ( newSubModel, subCmd, outMsg ) =
                            Profile.update subMsg subModel maybeToken
                    in
                    case outMsg of
                        Profile.NoOut ->
                            ( { model | page = PageSettingsProfile newSubModel }
                            , Cmd.map ProfileMsg subCmd
                            )

                        Profile.SessionExpired ->
                            handleSessionExpiry model

                _ ->
                    ( model, Cmd.none )

        PasswordMsg subMsg ->
            case model.page of
                PageSettingsPassword subModel ->
                    let
                        maybeToken =
                            Maybe.map .token (currentAuth model.auth)

                        ( newSubModel, subCmd, outMsg ) =
                            Password.update subMsg subModel maybeToken
                    in
                    case outMsg of
                        Password.NoOut ->
                            ( { model | page = PageSettingsPassword newSubModel }
                            , Cmd.map PasswordMsg subCmd
                            )

                        Password.SessionExpired ->
                            handleSessionExpiry model

                _ ->
                    ( model, Cmd.none )

        ResetPasswordMsg subMsg ->
            case model.page of
                PageResetPassword subModel ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            ResetPassword.update subMsg subModel

                        advanced =
                            case resetPasswordDestination outMsg of
                                Just route ->
                                    [ Nav.pushUrl model.key (Route.toPath route) ]

                                Nothing ->
                                    []
                    in
                    ( { model | page = PageResetPassword newSubModel }
                    , Cmd.batch (Cmd.map ResetPasswordMsg subCmd :: advanced)
                    )

                _ ->
                    ( model, Cmd.none )

        NotificationsMsg subMsg ->
            case model.page of
                PageSettingsNotifications subModel ->
                    let
                        maybeToken =
                            Maybe.map .token (currentAuth model.auth)

                        ( newSubModel, subCmd, outMsg ) =
                            Notifications.update subMsg subModel maybeToken
                    in
                    case outMsg of
                        Notifications.NoOut ->
                            ( { model | page = PageSettingsNotifications newSubModel }
                            , Cmd.map NotificationsMsg subCmd
                            )

                        Notifications.SessionExpired ->
                            handleSessionExpiry model

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

        MetricsMsg subMsg ->
            case model.page of
                PageMetrics subModel ->
                    let
                        ( newSubModel, subCmd ) =
                            MetricsPage.update subMsg subModel
                    in
                    ( { model | page = PageMetrics newSubModel }
                    , Cmd.map MetricsMsg subCmd
                    )

                _ ->
                    ( model, Cmd.none )

        ListingRemovalMsg subMsg ->
            case model.page of
                PageListingRemoval subModel ->
                    let
                        ( newSubModel, subCmd ) =
                            ListingRemoval.update subMsg subModel
                    in
                    ( { model | page = PageListingRemoval newSubModel }
                    , Cmd.map ListingRemovalMsg subCmd
                    )

                _ ->
                    ( model, Cmd.none )

        CatalogueMsg subMsg ->
            case model.page of
                PageCatalogue subModel ->
                    let
                        maybeToken =
                            Maybe.map .token (currentAuth model.auth)

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
                            Maybe.map .token (currentAuth model.auth)

                        maybeUserId =
                            Maybe.map (.user >> .id) (currentAuth model.auth)

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
                            -- logout.
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
                            Maybe.map .token (currentAuth model.auth)

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
                            Maybe.map .token (currentAuth model.auth)

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
                            Maybe.map .token (currentAuth model.auth)

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
                            Maybe.map .token (currentAuth model.auth)

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

                        BlogPostPage.EscapeUnhandled ->
                            ( { model | page = PageBlogPost newSubModel }
                            , Cmd.map BlogPostMsg subCmd
                            )

                        BlogPostPage.RequestCopy payload ->
                            ( { model | page = PageBlogPost newSubModel }
                            , Cmd.batch
                                [ Cmd.map BlogPostMsg subCmd
                                , copyToClipboard payload
                                ]
                            )

                _ ->
                    ( model, Cmd.none )

        FeedbackMsg subMsg ->
            case model.page of
                PageFeedback subModel ->
                    let
                        maybeToken =
                            Maybe.map .token (currentAuth model.auth)

                        ( newSubModel, subCmd, outMsg ) =
                            FeedbackPage.update subMsg subModel maybeToken
                    in
                    case outMsg of
                        FeedbackPage.NoOut ->
                            ( { model | page = PageFeedback newSubModel }
                            , Cmd.map FeedbackMsg subCmd
                            )

                        FeedbackPage.SessionExpired ->
                            handleSessionExpiry model

                _ ->
                    ( model, Cmd.none )

        AdminFeedbackMsg subMsg ->
            case model.page of
                PageAdminFeedback subModel ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            AdminFeedback.update subMsg subModel
                    in
                    case outMsg of
                        AdminFeedback.NoOut ->
                            ( { model | page = PageAdminFeedback newSubModel }
                            , Cmd.map AdminFeedbackMsg subCmd
                            )

                        AdminFeedback.SessionExpired ->
                            handleAdminSessionExpiry model

                _ ->
                    ( model, Cmd.none )

        AdminSourceApprovalMsg subMsg ->
            case model.page of
                PageAdminSourceApproval subModel ->
                    let
                        adminToken =
                            adminTokenFor model

                        ( newSubModel, subCmd, outMsg ) =
                            AdminSourceApproval.update subMsg subModel adminToken
                    in
                    case outMsg of
                        AdminSourceApproval.NoOut ->
                            ( { model | page = PageAdminSourceApproval newSubModel }
                            , Cmd.map AdminSourceApprovalMsg subCmd
                            )

                        AdminSourceApproval.SessionExpired ->
                            handleAdminSessionExpiry model

                _ ->
                    ( model, Cmd.none )

        AdminInvitesMsg subMsg ->
            case model.page of
                PageAdminInvites subModel ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            AdminInvites.update subMsg subModel (adminTokenFor model)
                    in
                    case outMsg of
                        AdminInvites.NoOut ->
                            ( { model | page = PageAdminInvites newSubModel }
                            , Cmd.map AdminInvitesMsg subCmd
                            )

                        AdminInvites.SessionExpired ->
                            handleAdminSessionExpiry model

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
                            handleAdminSessionExpiry model

                _ ->
                    ( model, Cmd.none )

        AdminBookModerationMsg subMsg ->
            case model.page of
                PageAdminBookModeration subModel ->
                    let
                        adminToken =
                            adminTokenFor model

                        ( newSubModel, subCmd, outMsg ) =
                            AdminBookModeration.update subMsg subModel adminToken
                    in
                    case outMsg of
                        AdminBookModeration.NoOut ->
                            ( { model | page = PageAdminBookModeration newSubModel }
                            , Cmd.map AdminBookModerationMsg subCmd
                            )

                        AdminBookModeration.SessionExpired ->
                            handleAdminSessionExpiry model

                _ ->
                    ( model, Cmd.none )

        AdminSessionMsg subMsg ->
            case model.page of
                PageAdminGate gatedRoute subModel ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            AdminSession.update subMsg subModel (Maybe.map .token (currentAuth model.auth))
                    in
                    case outMsg of
                        AdminSession.NoOut ->
                            ( { model | page = PageAdminGate gatedRoute newSubModel }
                            , Cmd.map AdminSessionMsg subCmd
                            )

                        AdminSession.Authenticated adminToken ->
                            let
                                withToken =
                                    { model | adminAuth = Just adminToken }

                                ( page, pageCmd ) =
                                    initPage model.config
                                        gatedRoute
                                        (originOf model.url)
                                        (currentAuth model.auth)
                                        (adminTokenFor withToken)
                                        (Just model.route)
                                        model.arrival
                            in
                            ( { withToken | page = page, arrival = consumeArrival page model.arrival }
                            , pageCmd
                            )

                _ ->
                    ( model, Cmd.none )

        AdminChromeMsg subMsg ->
            let
                ( newChrome, subCmd, outMsg ) =
                    AdminChrome.update subMsg model.adminChrome (adminTokenFor model)

                withChrome =
                    { model | adminChrome = newChrome }
            in
            case outMsg of
                AdminChrome.NoOut ->
                    ( withChrome, Cmd.map AdminChromeMsg subCmd )

                AdminChrome.SessionEnded ->
                    ( { withChrome
                        | adminAuth = Nothing
                        , page = PageAdminGate model.route (AdminSession.initWithNotice adminSessionEndedNotice)
                      }
                    , Cmd.map AdminChromeMsg subCmd
                    )

        AdminRemovalRequestsMsg subMsg ->
            case model.page of
                PageAdminRemovalRequests subModel ->
                    let
                        adminToken =
                            adminTokenFor model

                        ( newSubModel, subCmd, outMsg ) =
                            AdminRemovalRequests.update subMsg subModel adminToken
                    in
                    case outMsg of
                        AdminRemovalRequests.NoOut ->
                            ( { model | page = PageAdminRemovalRequests newSubModel }
                            , Cmd.map AdminRemovalRequestsMsg subCmd
                            )

                        AdminRemovalRequests.SessionExpired ->
                            handleAdminSessionExpiry model

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

                        GroupsDetail.EscapeUnhandled ->
                            ( { model | page = PageGroupsDetail newSubModel }
                            , Cmd.map GroupsDetailMsg subCmd
                            )

                _ ->
                    ( model, Cmd.none )

        PublicProfileMsg subMsg ->
            case model.page of
                PageProfile subModel ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            ProfilePage.update subMsg subModel
                    in
                    case outMsg of
                        ProfilePage.NoOut ->
                            ( { model | page = PageProfile newSubModel }
                            , Cmd.map PublicProfileMsg subCmd
                            )

                        ProfilePage.SessionExpired ->
                            handleSessionExpiry model

                _ ->
                    ( model, Cmd.none )

        OverlayBookDetailMsg subMsg ->
            case model.bookDetailOverlay of
                Just overlay ->
                    let
                        maybeToken =
                            Maybe.map .token (currentAuth model.auth)

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
                            ( { model
                                | bookDetailOverlay = Nothing
                                , pendingUndo = newDetail.undoableRemoval
                              }
                            , Cmd.batch
                                [ Nav.pushUrl model.key (Route.toPath route)
                                , focusMainContent
                                ]
                            )

                        BookDetail.PlacementMutated ->
                            let
                                ( refreshedPage, refreshCmd ) =
                                    refreshShelfBehindOverlay model.page
                                        |> Maybe.withDefault ( model.page, Cmd.none )
                            in
                            ( { model
                                | bookDetailOverlay = Just updatedOverlay
                                , page = refreshedPage
                              }
                            , Cmd.batch [ Cmd.map OverlayBookDetailMsg subCmd, refreshCmd ]
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
                    ( { model | userMenu = newUserMenu, openNavMenu = Nothing }, Cmd.none )

                UserMenu.NavigateTo path ->
                    ( { model | userMenu = newUserMenu, openNavMenu = Nothing }
                    , Nav.pushUrl model.key path
                    )

                UserMenu.SignOut ->
                    let
                        logoutCmd =
                            case currentAuth model.auth of
                                Just auth ->
                                    Api.logout auth.token (always FocusResult)

                                Nothing ->
                                    Cmd.none
                    in
                    ( { model
                        | userMenu = newUserMenu
                        , auth = Anonymous
                        , adminAuth = Nothing
                        , page = PageLogin (Login.init Login.Fresh |> Login.withInviteOnly model.config.inviteOnly)
                        , arrival = Login.Fresh
                      }
                    , Cmd.batch
                        [ logoutCmd
                        , clearAuth ()
                        , clearListingDraft ()
                        , Nav.pushUrl model.key (Route.toPath Login)
                        ]
                    )

        ToggleNavMenu menu ->
            ( { model
                | openNavMenu = toggleNavMenu menu model.openNavMenu
                , userMenu = UserMenu.init
              }
            , Cmd.none
            )

        CloseNavMenu ->
            ( { model | openNavMenu = Nothing }, Cmd.none )

        EscapePressed ->
            if onboardingShowing model then
                update (OnboardingMsg OnboardingOverlay.EscapePressed) model

            else
                escapeForPage model

        OnboardingMsg subMsg ->
            let
                maybeToken =
                    Maybe.map .token (currentAuth model.auth)

                ( newOnboarding, subCmd, outMsg ) =
                    OnboardingOverlay.update maybeToken subMsg model.onboarding

                baseModel =
                    { model | onboarding = newOnboarding }

                baseCmd =
                    Cmd.map OnboardingMsg subCmd
            in
            case outMsg of
                OnboardingOverlay.OnboardingFinished ->
                    ( { baseModel | onboardingCompleted = True }
                    , Cmd.batch [ baseCmd, saveOnboardingCompleted () ]
                    )

                OnboardingOverlay.UploadOpenStream url ->
                    ( baseModel, Cmd.batch [ baseCmd, openUploadStream { url = url } ] )

                OnboardingOverlay.UploadRefreshInbox ->
                    ( baseModel, Cmd.batch [ baseCmd, fetchUploadInbox (currentAuth model.auth) ] )

                OnboardingOverlay.UploadNavigate route ->
                    ( baseModel, Cmd.batch [ baseCmd, Nav.pushUrl model.key (Route.toPath route) ] )

                OnboardingOverlay.SessionExpired ->
                    handleSessionExpiry model

                OnboardingOverlay.NoOut ->
                    ( baseModel, baseCmd )

        OnboardingStatusReceived completed ->
            ( { model | onboardingCompleted = completed }, Cmd.none )

        InviteOnlyConfigReceived enabled ->
            let
                config =
                    model.config

                page =
                    case model.page of
                        PageLogin loginModel ->
                            PageLogin (Login.withInviteOnly enabled loginModel)

                        other ->
                            other
            in
            ( { model | config = { config | inviteOnly = enabled }, page = page }, Cmd.none )

        AgeGatingConfigReceived enabled ->
            let
                config =
                    model.config
            in
            ( { model | config = { config | ageGatingEnabled = enabled } }, Cmd.none )

        ConnectivityChanged isOnline ->
            let
                connectivity =
                    connectivityFromOnline isOnline
            in
            if reconnectShouldRefetch model.connectivity connectivity model.page then
                let
                    ( page, cmd ) =
                        initPage model.config
                            model.route
                            (originOf model.url)
                            (currentAuth model.auth)
                            (adminTokenFor model)
                            (Just model.route)
                            model.arrival
                in
                ( { model | connectivity = connectivity, page = page }, cmd )

            else
                ( { model | connectivity = connectivity }, Cmd.none )

        FocusResult ->
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

        GotUploadInbox result ->
            case result of
                Ok items ->
                    ( { model | uploadInbox = Success items }, Cmd.none )

                Err err ->
                    if Api.isUnauthorized err then
                        handleSessionExpiry model

                    else
                        ( { model | uploadInbox = Failure err }, Cmd.none )

        RenewToken ->
            case currentAuth model.auth of
                Just auth ->
                    ( model, Api.refresh auth.token TokenRefreshed )

                Nothing ->
                    ( model, Cmd.none )

        TokenRefreshed (Ok authResponse) ->
            case currentAuth model.auth of
                Just auth ->
                    let
                        renewedAuth =
                            renewAuthToken authResponse auth
                    in
                    ( { model | auth = Authenticated renewedAuth }
                    , Cmd.batch [ saveAuth (encodeAuth renewedAuth), scheduleRenewal ]
                    )

                Nothing ->
                    ( model, Cmd.none )

        TokenRefreshed (Err _) ->
            handleSessionExpiryFromRenewal model

        AuthChangedExternally value ->
            case adoptExternalAuth value (currentAuth model.auth) of
                AdoptAuth newAuth ->
                    ( { model | auth = Authenticated newAuth, pendingLogout = Nothing }
                    , Cmd.none
                    )

                LogOutExternally ->
                    forceSessionExpiry False model

                IgnoreExternal ->
                    ( model, Cmd.none )

        GotStoredAuth value ->
            case resolveRecheck model.pendingLogout (adoptExternalAuth value (currentAuth model.auth)) of
                ResolveAdopt newAuth reschedule ->
                    ( { model | auth = Authenticated newAuth, pendingLogout = Nothing }
                    , if reschedule then
                        scheduleRenewal

                      else
                        Cmd.none
                    )

                ResolveForceLogout draftSaved ->
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


{-| Re-read the page the overlay is covering, after a placement write the
overlay reports as done.

The overlay is a layer over a page that is still mounted and still rendering
what it read on arrival, so a successful write leaves a page behind it telling
the reader something untrue — a book on the shelf it just left. The pages named
here are the ones whose content IS placements; a page not named keeps what it
has, which is correct for pages a placement write does not change.

The refetch is asked for as a `Msg` rather than reached for as a `Cmd` so each
page stays the only thing that decides how to re-read itself — the read-only
profile shelf reads from a different endpoint than the reader's own.

`Nothing` is "there is nothing behind this that a placement write makes untrue",
which is a different answer from handing back the page and an empty command:
the caller leaves `model.page` alone rather than rewriting it with itself.

-}
refreshShelfBehindOverlay : Page -> Maybe ( Page, Cmd Msg )
refreshShelfBehindOverlay page =
    case page of
        PageBookshelf shelf ->
            let
                ( refreshed, cmd, _ ) =
                    Bookshelf.update Bookshelf.ReloadRequested shelf
            in
            Just ( PageBookshelf refreshed, Cmd.map BookshelfMsg cmd )

        PageReadingPile pile ->
            let
                ( refreshed, cmd, _ ) =
                    ReadingPile.update ReadingPile.ReloadRequested pile
            in
            Just ( PageReadingPile refreshed, Cmd.map ReadingPileMsg cmd )

        _ ->
            Nothing


{-| Open the book detail overlay for a given book ID.
Initialises a BookDetail.Model and fires the API fetch command.
Stores the triggering spine element ID so focus can return on close.
-}
openOverlay : Model -> String -> ( Model, Cmd Msg )
openOverlay model bookId =
    openOverlayWithTrigger model bookId ("spine-" ++ bookId)


{-| Move focus to the persistent main-content landmark. Used after a book is
removed from its shelf (item b): the remove-success path navigates to the
previous shelf route, and without an explicit target focus would drop to
`<body>`, stranding keyboard and screen-reader users. The landmark carries
`tabindex -1` so this focus lands. It is always in the DOM (the app shell), so
the command can run alongside the route change regardless of ordering.
-}
focusMainContent : Cmd Msg
focusMainContent =
    Task.attempt (always FocusResult) (Browser.Dom.focus "main-content")


{-| The default top-level Escape behaviour when no book overlay is open and the
current page has nothing nested to dismiss: close whichever menu is open — the
account menu and every nav disclosure (TR-1).
-}
closeUserMenuOnEscape : Model -> ( Model, Cmd Msg )
closeUserMenuOnEscape model =
    let
        ( newUserMenu, _ ) =
            UserMenu.update UserMenu.Close model.userMenu
    in
    ( { model | userMenu = newUserMenu, openNavMenu = Nothing }, Cmd.none )


{-| Whether the onboarding overlay is the topmost, interactive surface: the
view-gate (`shouldShowOnboarding`) is satisfied AND the overlay still wants to
render. Used so Escape reaches onboarding before any page-level handler.
-}
onboardingShowing : Model -> Bool
onboardingShowing model =
    shouldShowOnboarding (currentAuth model.auth) model.onboardingCompleted model.hasAnyPlacements
        && OnboardingOverlay.isVisible model.onboarding


{-| The Escape handling for whatever page/overlay is showing when onboarding is
NOT up. Extracted from `update` so the onboarding-first-dibs branch stays a
one-liner (the body is unchanged from before 8b).
-}
escapeForPage : Model -> ( Model, Cmd Msg )
escapeForPage model =
    case model.bookDetailOverlay of
        Just overlay ->
            let
                maybeToken =
                    Maybe.map .token (currentAuth model.auth)

                ( newDetail, subCmd, outMsg ) =
                    BookDetail.update BookDetail.EscapePressed overlay.detail maybeToken

                returnFocusCmd =
                    case overlay.triggerSpineId of
                        Just spineId ->
                            Task.attempt (always FocusResult) (Browser.Dom.focus spineId)

                        Nothing ->
                            Cmd.none
            in
            case outMsg of
                BookDetail.RequestCloseOverlay ->
                    ( { model | bookDetailOverlay = Nothing }, returnFocusCmd )

                _ ->
                    ( { model | bookDetailOverlay = Just { overlay | detail = newDetail } }
                    , Cmd.map OverlayBookDetailMsg subCmd
                    )

        Nothing ->
            case model.page of
                PageBookDetail subModel ->
                    let
                        maybeToken =
                            Maybe.map .token (currentAuth model.auth)

                        ( newSubModel, subCmd, outMsg ) =
                            BookDetail.update BookDetail.EscapePressed subModel maybeToken
                    in
                    case outMsg of
                        BookDetail.RequestCloseOverlay ->
                            closeUserMenuOnEscape model

                        _ ->
                            ( { model | page = PageBookDetail newSubModel }
                            , Cmd.map BookDetailMsg subCmd
                            )

                PageBlogPost subModel ->
                    let
                        maybeToken =
                            Maybe.map .token (currentAuth model.auth)

                        ( newSubModel, subCmd, outMsg ) =
                            BlogPostPage.update BlogPostPage.EscapePressed subModel maybeToken
                    in
                    case outMsg of
                        BlogPostPage.EscapeUnhandled ->
                            closeUserMenuOnEscape model

                        _ ->
                            ( { model | page = PageBlogPost newSubModel }
                            , Cmd.map BlogPostMsg subCmd
                            )

                PageGroupsDetail subModel ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            GroupsDetail.update GroupsDetail.EscapePressed subModel
                    in
                    case outMsg of
                        GroupsDetail.EscapeUnhandled ->
                            closeUserMenuOnEscape model

                        _ ->
                            ( { model | page = PageGroupsDetail newSubModel }
                            , Cmd.map GroupsDetailMsg subCmd
                            )

                _ ->
                    closeUserMenuOnEscape model


{-| Open the book detail overlay, returning focus to an explicit trigger
element id on close. Shelf pages trigger from a `spine-<bookId>` element
(`openOverlay`); the search results list triggers from its own
`search-result-<bookId>` button — both compose with the focus-return mechanism via `triggerSpineId`.
-}
openOverlayWithTrigger : Model -> String -> String -> ( Model, Cmd Msg )
openOverlayWithTrigger model bookId triggerId =
    let
        maybeToken =
            Maybe.map .token (currentAuth model.auth)

        ( detailModel, detailCmd ) =
            BookDetail.init bookId maybeToken (Just model.route)

        overlay =
            { bookId = bookId
            , detail = detailModel
            , triggerSpineId = Just triggerId
            }
    in
    ( { model | bookDetailOverlay = Just overlay }
    , Cmd.batch
        [ Cmd.map OverlayBookDetailMsg detailCmd
        , Task.attempt (always FocusResult) (Browser.Dom.focus BookDetail.cardFocusId)
        ]
    )


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ onSwipe decodeSwipe
        , onLoginTransitionComplete (\_ -> ArrivalSettled)
        , onOnboardingStatus OnboardingStatusReceived
        , authChanged AuthChangedExternally
        , gotStoredAuth GotStoredAuth
        , ageGatingConfig AgeGatingConfigReceived
        , inviteOnlyConfig InviteOnlyConfigReceived
        , connectivityChanged ConnectivityChanged
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
        , if onboardingShowing model && OnboardingOverlay.isOnUploadStep model.onboarding then
            uploadSubscriptions (OnboardingMsg << OnboardingOverlay.UploadMsg)

          else
            case model.page of
                PageUpload _ ->
                    uploadSubscriptions UploadMsg

                PageImport _ ->
                    Time.every (toFloat ImportPage.pollSeconds * 1000)
                        (\_ -> ImportPageMsg ImportPage.PollTick)

                PageBlogPost _ ->
                    copyResult
                        (BlogPostMsg
                            << BlogPostPage.SyndicationMsg
                            << Syndication.CopyOutcome
                        )

                PageMarketplaceCreate _ ->
                    gotListingDraft (CreateListingMsg << CreateListing.DraftLoaded)

                _ ->
                    Sub.none
        ]


{-| The two subscriptions the upload flow needs, parameterised by how
its messages are tagged so they can drive either the standalone upload page
(`UploadMsg`) or the embedded onboarding-step flow
(`OnboardingMsg << OnboardingOverlay.UploadMsg`).
-}
uploadSubscriptions : (Upload.Msg -> Msg) -> Sub Msg
uploadSubscriptions tag =
    Sub.batch
        [ uploadStreamEvent
            (\raw ->
                case Decode.decodeString (Decode.field "type" Decode.string) raw of
                    Ok "error" ->
                        tag Upload.StreamError

                    _ ->
                        tag (Upload.StreamEvent raw)
            )
        , Time.every (toFloat Upload.tickSeconds * 1000)
            (\_ -> tag Upload.WaitTick)
        ]


decodeSwipe : Decode.Value -> Msg
decodeSwipe value =
    case Decode.decodeValue Decode.string value of
        Ok direction ->
            SwipeReceived direction

        Err _ ->
            SwipeIgnored


view : Model -> Browser.Document Msg
view model =
    { title = pageTitle model.page
    , body =
        [ viewOverlay model
        , viewOnboarding model
        , ViewAsBar.view model.url
        , div [ class "app" ]
            [ a [ class "skip-link", href "#main-content" ] [ text "Skip to main content" ]
            , viewConnectivity model.connectivity
            , viewNav model.route (currentAuth model.auth) model.openNavMenu model.userMenu model.uploadInbox
            , main_
                [ id "main-content"
                , tabindex -1
                , class
                    ("app__main"
                        ++ (case model.transition of
                                Just t ->
                                    " " ++ t

                                Nothing ->
                                    ""
                           )
                    )
                , Html.Events.on "animationend"
                    (Decode.map TransitionEnded
                        (Decode.field "animationName" Decode.string)
                    )
                ]
                [ viewPage model ]
            , viewFooter
            ]
        , viewArrivalDoor model.auth
        ]
    }


{-| The login door dolly-shot, rendered from the SHELL over the destination
page for exactly the `Arriving` window. 359 navigates away from the
login scene on the same update that decodes the 200, unmounting
`Page.Login`'s layers before the animation port's rAF callback runs —
zero animations started. The layers live here, in the thing that survives
the navigation; `Arriving` is the render window.
-}
viewArrivalDoor : AuthState -> Html Msg
viewArrivalDoor authState =
    case authState of
        Arriving _ ->
            div
                [ class "arrival-door"
                , attribute "aria-hidden" "true"
                , testId "arrival-door"
                ]
                [ div [ class "layer-arrival" ] []
                , div [ class "layer-passage", id "passage" ] []
                , div [ class "layer-passage-bright", id "passageBright" ] []
                , div [ class "layer-bookshelf", id "bookshelf" ] []
                , div [ class "layer-bookshelf-dim", id "bookshelfDim" ] []
                , div [ class "layer-vignette", id "vignette" ] []
                , div [ class "layer-wash", id "wash" ] []
                ]

        Anonymous ->
            text ""

        Authenticated _ ->
            text ""


{-| The document title, derived from the PAGE actually on screen — not the
route. Route is what the reader asked for; `Page` is what the shell
built, and they differ by design at six sites (protected-route bounce,
admin gate, invalid-route fallback, …): a signed-out reader at `/upload`
was looking at a login card in a tab titled "Add a Book".
-}
pageTitle : Page -> String
pageTitle page =
    case page of
        PageHome _ ->
            "The Stacks"

        PageLogin loginModel ->
            titled (loginCardTitle loginModel.mode)

        PageBookshelf bookshelfModel ->
            titled (bookshelfTitle bookshelfModel)

        PageReadingPile _ ->
            titled "Reading Pile"

        PageLookingForHome _ ->
            titled "Looking for a Home"

        PageBookDetail detailModel ->
            titled (bookDetailTitle detailModel)

        PageUpload _ ->
            titled "Add a Book"

        PageImport _ ->
            titled "Import Your Library"

        PageSearch _ ->
            titled "Search"

        PageSettingsAuditLog _ ->
            titled "Audit Log"

        PageInsights _ ->
            titled "What Your Data Reveals"

        PageSettingsProfile _ ->
            titled "Profile"

        PageSettingsPassword _ ->
            titled "Password"

        PageSettingsNotifications _ ->
            titled "Notifications"

        PageCostTransparency _ ->
            titled "Cost Transparency"

        PageMetrics _ ->
            titled "What We Measure"

        PageAbout ->
            titled "About"

        PageFaq ->
            titled "Questions, Answered"

        PageDataTransparency ->
            titled "On Data Transparency"

        PageListingRemoval _ ->
            titled "Remove a listing"

        PageCatalogue _ ->
            titled "Catalogue"

        PageMarketplaceBrowse _ ->
            titled "Marketplace"

        PageMarketplaceCreate _ ->
            titled "Create Listing"

        PageMarketplaceMyListings _ ->
            titled "My Listings"

        PageMarketplaceDetail _ ->
            titled "Listing"

        PageSettingsPrivacy _ ->
            titled "Privacy"

        PageBlogArchive _ ->
            titled "Blog"

        PageBlogEditor editorModel ->
            case editorModel.mode of
                BlogEditor.New ->
                    titled "New Post"

                BlogEditor.Edit _ ->
                    titled "Edit Post"

        PageBlogPost _ ->
            titled "Blog Post"

        PageAdminSourceApproval _ ->
            titled "Source Approval"

        PageAdminInvites _ ->
            titled "Invitations"

        PageAdminScraperConfig _ ->
            titled "Scraper Health"

        PageAdminBookModeration _ ->
            titled "Book Moderation"

        PageAdminRemovalRequests _ ->
            titled "Removal Requests"

        PageFeedback _ ->
            titled "Tell us"

        PageAdminFeedback _ ->
            titled "Feedback"

        PageAdminGate _ _ ->
            titled "Admin Sign-In"

        PageGroups _ ->
            titled "My Groups"

        PageGroupsDetail _ ->
            titled "Group"

        PageProfile profileModel ->
            titled ("@" ++ profileModel.handle)

        PageConfirmEmail EmailConfirmed ->
            titled "Email Confirmed"

        PageConfirmEmail EmailConfirmFailed ->
            titled "Confirmation Failed"

        PageConfirmEmail EmailChangeConfirmed ->
            titled "Email Address Updated"

        PageConfirmEmail EmailChangeReverted ->
            titled "Change Undone"

        PageConfirmEmail EmailChangeFailed ->
            titled "Link No Longer Valid"

        PageResetPassword _ ->
            titled "Reset Password"

        PageNotFound ->
            titled "Not Found"


{-| Every title but the home page's is the page's own name followed by the
product's. Written once, so a stray dash or a missing suffix cannot appear on
one page out of forty.
-}
titled : String -> String
titled name =
    name ++ " — The Stacks"


{-| The login card names its current mode. Drift sites 1 and 5 — the
protected-route bounce and sign-out both render this card — resolve here.
-}
loginCardTitle : Login.Mode -> String
loginCardTitle mode =
    case mode of
        Login.LoginMode ->
            "Sign In"

        Login.RegisterMode ->
            "Create Account"

        Login.RegistrationPending _ ->
            "Check Your Email"

        Login.ForgotPasswordMode ->
            "Reset Password"

        Login.ResendConfirmationMode ->
            "Confirm Your Email"


{-| Library, Antilibrary and Wish List all render through one `PageBookshelf`,
and so does another reader's shelf — so the route was the only thing that could
tell them apart, and for `/u/:handle/:bookshelf` it gave up and said "Reader".
The page itself knows: its config carries the shelf's label and, when it is
being browsed read-only, whose shelf it is.
-}
bookshelfTitle : Bookshelf.Model -> String
bookshelfTitle bookshelfModel =
    case bookshelfModel.config.profileHandle of
        Just handle ->
            bookshelfModel.config.label ++ " — @" ++ handle

        Nothing ->
            bookshelfModel.config.label


{-| Once the book has loaded, the tab says which book. A route can only say
"Book", which is what every book-detail tab, bookmark and history entry used to
say — indistinguishable from one another.
-}
bookDetailTitle : BookDetail.Model -> String
bookDetailTitle detailModel =
    case detailModel.book of
        Types.RemoteData.Success book ->
            book.title

        _ ->
            "Book"


viewNav : Route -> Maybe Auth -> Maybe NavMenu -> UserMenu.Model -> RemoteData Http.Error (List Api.InboxItem) -> Html Msg
viewNav route maybeAuth openNavMenu userMenu inbox =
    header [ class "app-header" ]
        [ a [ href "/", class "app-header__logo" ] [ text "The Stacks" ]
        , nav [ class "app-nav", attribute "aria-label" "Main navigation" ]
            [ ul [ class "app-nav__list" ]
                (case maybeAuth of
                    Nothing ->
                        [ navItem route Catalogue "Catalogue"
                        , navItem route Search "Search"
                        , navItem route MarketplaceBrowse "Marketplace"
                        , navItem route About "About"
                        , navItem route Login "Sign In"
                        ]

                    Just auth ->
                        [ -- The five bookshelves, grouped under one disclosure
                          navDisclosure
                            { menu = BookshelvesMenu
                            , label = "Bookshelves"
                            , isActive = isBookshelfRoute route
                            , isOpen = openNavMenu == Just BookshelvesMenu
                            , items =
                                List.map viewNavDropdownLink
                                    [ navLink Library "Library"
                                    , navLink AntiLibrary "Antilibrary"
                                    , navLink WishList "Wish List"
                                    , navLink ReadingPile "Reading Pile"
                                    , navLink LookingForHome "Looking for a Home"
                                    ]
                            }
                        , navItem route Search "Search"
                        , viewAddBook route (pendingConfirmationBadge inbox)
                        , navDisclosure
                            { menu = MarketplaceMenu
                            , label = "Marketplace"
                            , isActive = isMarketplaceRoute route
                            , isOpen = openNavMenu == Just MarketplaceMenu
                            , items =
                                List.map viewNavDropdownLink
                                    [ navLink MarketplaceBrowse "Browse"
                                    , navLink MarketplaceCreate "Create Listing"
                                    , navLink MarketplaceMyListings "My Listings"
                                    ]
                            }
                        , navItem route About "About"
                        , if auth.user.role == "owner" then
                            navDisclosure
                                { menu = AdminMenu
                                , label = "Admin"
                                , isActive = isAdminRoute route
                                , isOpen = openNavMenu == Just AdminMenu
                                , items =
                                    List.map viewNavDropdownLink
                                        [ navLink Route.AdminSourceApproval "Sources"
                                        , navLink Route.AdminScraperConfig "Scrapers"
                                        , navLink Route.AdminBookModeration "Book Moderation"
                                        , navLink Route.AdminRemovalRequests "Removal Requests"
                                        , navLink Route.AdminInvites "Invites"
                                        , navLink Route.AdminFeedback "Feedback"
                                        ]
                                }

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
                                (UserMenu.view auth.user settingsLinks userMenu)
                            ]
                        ]
                )
            ]
        ]


{-| The settings family exposed by the account menu (TR-1). Before this,
only the profile page was reachable from nav; the rest of the settings routes
had no nav affordance at all. Paths come from `Route.toPath` so there is one
source of truth for where each item goes.
-}
settingsLinks : List UserMenu.SettingsLink
settingsLinks =
    [ { label = "Profile", path = Route.toPath SettingsProfile }
    , { label = "Privacy", path = Route.toPath SettingsPrivacy }
    , { label = "Notifications", path = Route.toPath SettingsNotifications }
    , { label = "Password", path = Route.toPath SettingsPassword }
    , { label = "Activity Log", path = Route.toPath SettingsAuditLog }
    , { label = "Reading Insights", path = Route.toPath Insights }
    , { label = "Tell us", path = Route.toPath Route.Feedback }
    ]


{-| `True` for the five bookshelf routes AND for a book-detail, which is a child
of the shelves. This is what keeps the Bookshelves nav item highlighted while
you are reading a book you reached from a shelf (TR-1, child-route
highlight).
-}
isBookshelfRoute : Route -> Bool
isBookshelfRoute route =
    case route of
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
            True

        _ ->
            False


isMarketplaceRoute : Route -> Bool
isMarketplaceRoute route =
    case route of
        MarketplaceBrowse ->
            True

        MarketplaceCreate ->
            True

        MarketplaceMyListings ->
            True

        MarketplaceDetail _ ->
            True

        _ ->
            False


{-| A top-level nav disclosure: a real `<button aria-haspopup aria-expanded>`
whose menu is in the DOM ONLY when open (TR-1). This replaced the CSS
`:hover`/`:focus-within` reveal, which put the menu in the DOM always and was
unreachable by touch or keyboard. Open/close is owned by `Model.openNavMenu`;
the backdrop catches an outside click, and Escape is handled in `update`.
-}
navDisclosure :
    { menu : NavMenu
    , label : String
    , isActive : Bool
    , isOpen : Bool
    , items : List (Html Msg)
    }
    -> Html Msg
navDisclosure config =
    li
        [ class
            (if config.isActive then
                "app-nav__item app-nav__item--active app-nav__dropdown"

             else
                "app-nav__item app-nav__dropdown"
            )
        ]
        [ button
            [ class "app-nav__link app-nav__disclosure"
            , Html.Events.onClick (ToggleNavMenu config.menu)
            , attribute "aria-haspopup" "true"
            , attribute "aria-expanded" (boolAttr config.isOpen)
            ]
            [ text config.label
            , span [ class "app-nav__caret", attribute "aria-hidden" "true" ] []
            ]
        , if config.isOpen then
            div []
                [ -- Transparent full-screen layer that turns an outside click
                  div
                    [ class "app-nav__backdrop"
                    , style "position" "fixed"
                    , style "top" "0"
                    , style "left" "0"
                    , style "width" "100vw"
                    , style "height" "100vh"
                    , style "z-index" "999"
                    , Html.Events.onClick CloseNavMenu
                    ]
                    []
                , ul
                    [ class "app-nav__dropdown-menu"
                    , style "z-index" "1000"
                    ]
                    config.items
                ]

          else
            text ""
        ]


{-| The persistent "Add Book" primary action (TR-1). An always-present
`btn btn--primary` link — no hover menu in front of it — so it is reachable on
touch and by keyboard. The pending-confirmation badge rides here now that
the Catalogue dropdown it used to live in is gone.
-}
viewAddBook : Route -> Maybe Int -> Html Msg
viewAddBook route badge =
    li
        [ class
            (if route == Upload then
                "app-nav__item app-nav__item--active"

             else
                "app-nav__item"
            )
        ]
        [ a
            [ href (Route.toPath Upload)
            , class "btn btn--primary btn--sm app-nav__add-book"
            ]
            (text "Add Book"
                :: (case badge of
                        Just count ->
                            [ span
                                [ class "app-nav__badge"
                                , testId "nav-upload-badge"
                                , attribute "aria-label"
                                    (String.fromInt count ++ " waiting to be confirmed")
                                ]
                                [ text (String.fromInt count) ]
                            ]

                        Nothing ->
                            []
                   )
            )
        ]


boolAttr : Bool -> String
boolAttr b =
    if b then
        "true"

    else
        "false"


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


{-| One entry inside a navigation disclosure menu.
-}
type alias NavLink =
    { route : Route
    , label : String
    }


navLink : Route -> String -> NavLink
navLink route label =
    { route = route, label = label }


{-| The number on the `Add Book` marker. `Nothing` when the inbox
has not loaded or failed — a cleared badge asserts nothing is waiting,
which we cannot claim; `Nothing` at zero ("no badge, not a 0");
`Just n` otherwise, from `Api.awaitingConfirmationCount` over the same
list the inbox renders.
-}
pendingConfirmationBadge : RemoteData Http.Error (List Api.InboxItem) -> Maybe Int
pendingConfirmationBadge inbox =
    case inbox of
        Success items ->
            case Api.awaitingConfirmationCount items of
                0 ->
                    Nothing

                count ->
                    Just count

        _ ->
            Nothing


viewNavDropdownLink : NavLink -> Html Msg
viewNavDropdownLink item =
    li []
        [ a [ href (Route.toPath item.route), class "app-nav__dropdown-link" ]
            [ text item.label ]
        ]


viewPage : Model -> Html Msg
viewPage model =
    case model.page of
        PageHome subModel ->
            Html.map HomeMsg (Home.view subModel)

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
            Html.map UploadMsg
                (Upload.view subModel
                    (Maybe.map .token (currentAuth model.auth))
                    model.uploadInbox
                )

        PageImport subModel ->
            Html.map ImportPageMsg (ImportPage.view subModel)

        PageSearch subModel ->
            Html.map SearchMsg (Search.view (currentAuth model.auth /= Nothing) subModel)

        PageSettingsAuditLog subModel ->
            viewSettingsHub model.route
                (Html.map AuditLogMsg (AuditLog.view subModel))

        PageInsights subModel ->
            viewSettingsHub model.route
                (Html.map InsightsMsg (Insights.view subModel))

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

        PageMetrics subModel ->
            Html.map MetricsMsg (MetricsPage.view subModel)

        PageAbout ->
            AboutPage.view

        PageFaq ->
            FaqPage.view { inviteOnly = model.config.inviteOnly }

        PageDataTransparency ->
            DataTransparencyPage.view

        PageListingRemoval subModel ->
            Html.map ListingRemovalMsg (ListingRemoval.view subModel)

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
            viewAdminSurface model
                (Html.map AdminSourceApprovalMsg (AdminSourceApproval.view subModel))

        PageAdminInvites subModel ->
            viewAdminSurface model
                (Html.map AdminInvitesMsg (AdminInvites.view subModel))

        PageAdminScraperConfig subModel ->
            viewAdminSurface model
                (Html.map AdminScraperConfigMsg (AdminScraperConfig.view subModel))

        PageAdminBookModeration subModel ->
            viewAdminSurface model
                (Html.map AdminBookModerationMsg (AdminBookModeration.view subModel))

        PageAdminRemovalRequests subModel ->
            viewAdminSurface model
                (Html.map AdminRemovalRequestsMsg (AdminRemovalRequests.view subModel))

        PageFeedback subModel ->
            Html.map FeedbackMsg (FeedbackPage.view subModel)

        PageAdminFeedback subModel ->
            viewAdminSurface model
                (Html.map AdminFeedbackMsg (AdminFeedback.view subModel))

        PageAdminGate _ subModel ->
            Html.map AdminSessionMsg (AdminSession.view subModel)

        PageGroups subModel ->
            Html.map GroupsMsg (Groups.view subModel)

        PageGroupsDetail subModel ->
            Html.map GroupsDetailMsg (GroupsDetail.view subModel)

        PageProfile subModel ->
            Html.map PublicProfileMsg (ProfilePage.view subModel)

        PageConfirmEmail status ->
            viewConfirmEmail status

        PageResetPassword subModel ->
            Html.map ResetPasswordMsg (ResetPassword.view subModel)

        PageNotFound ->
            viewNotFound


{-| Every admin surface, in its chrome. Applied at the ONE place the admin
pages already have in common — this dispatch — so a new admin page gets the
sign-out affordance by being routed here, not by remembering to add it.
`PageAdminGate` is deliberately not wrapped: there is no session to end on the
page that exists because there isn't one.
-}
viewAdminSurface : Model -> Html Msg -> Html Msg
viewAdminSurface model content =
    AdminChrome.view AdminChromeMsg model.adminChrome content


viewSettingsHub : Route -> Html Msg -> Html Msg
viewSettingsHub currentRoute content =
    Settings.view
        { currentRoute = currentRoute
        , content = content
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
    if shouldShowOnboarding (currentAuth model.auth) model.onboardingCompleted model.hasAnyPlacements then
        Html.map OnboardingMsg
            (OnboardingOverlay.view model.onboarding
                (Maybe.map .token (currentAuth model.auth))
            )

    else
        text ""


viewConfirmEmail : ConfirmStatus -> Html Msg
viewConfirmEmail status =
    div [ class "page page--login" ]
        [ div [ class "layer-arrival" ] []
        , div [ class "layer-bookshelf" ] []
        , div [ class "layer-bookshelf-dim" ] []
        , div [ class "layer-vignette" ] []
        , div [ class "login-overlay" ]
            [ div [ class "login-card" ] (viewConfirmEmailCard status) ]
        ]


viewConfirmEmailCard : ConfirmStatus -> List (Html Msg)
viewConfirmEmailCard status =
    case status of
        EmailConfirmed ->
            [ h1 [ class "login-card__title" ] [ text "Email confirmed" ]
            , p [ class "login-card__subtitle" ]
                [ text "Your email address has been verified. You can now sign in to The Stacks." ]
            , a [ class "btn btn--primary", href (Route.toPath Login) ] [ text "Sign in" ]
            ]

        EmailConfirmFailed ->
            [ h1 [ class "login-card__title" ] [ text "Confirmation failed" ]
            , p [ class "login-card__subtitle" ]
                [ text "This confirmation link is no longer valid — it may have expired, or already been used. If it has already been used, you can simply sign in." ]
            , a
                [ class "btn btn--primary"
                , href (Route.toPath ResendConfirmation)
                ]
                [ text "Send me a new link" ]
            , a [ class "btn btn--secondary", href (Route.toPath Login) ] [ text "Back to sign in" ]
            ]

        EmailChangeConfirmed ->
            [ h1 [ class "login-card__title" ] [ text "Email address updated" ]
            , p [ class "login-card__subtitle" ]
                [ text "This is your account's address from now on — it's what you'll sign in with, and where we'll write. The link we sent to your old address no longer does anything." ]
            , a [ class "btn btn--primary", href (Route.toPath SettingsProfile) ] [ text "Back to settings" ]
            ]

        EmailChangeReverted ->
            [ h1 [ class "login-card__title" ] [ text "Change undone" ]
            , p [ class "login-card__subtitle" ]
                [ text "Your address is unchanged and the confirmation link we sent to the new one no longer works. Every signed-in device has been signed out." ]
            , p [ class "login-card__subtitle" ]
                [ text "If you didn't ask for this change, change your password now — whoever asked for it could sign in as you." ]
            , a [ class "btn btn--primary", href (Route.toPath Login) ] [ text "Sign in" ]
            , a [ class "btn btn--secondary", href (Route.toPath ForgotPassword) ] [ text "Change my password" ]
            ]

        EmailChangeFailed ->
            [ h1 [ class "login-card__title" ] [ text "This link no longer works" ]
            , p [ class "login-card__subtitle" ]
                [ text "Email-change links stop working once the change is settled one way or the other — confirmed, undone, or replaced by a newer request. Sign in and check your profile settings to see where your account stands." ]
            , a [ class "btn btn--primary", href (Route.toPath Login) ] [ text "Sign in" ]
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
            [ text "The Stacks — source-available book management" ]
        ]


{-| The shell's connectivity banner. Losing the connection is a fact
about the app, not a request — the page that most needed to say so
rendered an empty bookcase when its fetch never returned, telling the
reader their library was empty. One banner above every page, driven by
the OS-level signal, able to speak before any request fails.
-}
viewConnectivity : Connectivity -> Html Msg
viewConnectivity connectivity =
    case connectivity of
        Online ->
            text ""

        Offline ->
            div
                [ class "connectivity-banner"
                , testId "connectivity-offline"
                , attribute "role" "status"
                , attribute "aria-live" "polite"
                ]
                [ p [ class "connectivity-banner__text" ]
                    [ text "You are offline. The Stacks can’t reach the library right now — anything already on screen stays put, and this will clear as soon as you reconnect." ]
                ]


{-| What the gate says to an operator who ended their own session. It names the
thing that did NOT happen, because "signed out" on a product where the ordinary
session and the admin session are different things would read as both being
gone.
-}
adminSessionEndedNotice : String
adminSessionEndedNotice =
    "Your admin session has ended. Your ordinary session is untouched — sign in again to reopen the admin surfaces."


{-| An admin API call came back unauthorised. All four admin pages used to
call `handleSessionExpiry`, signing the operator out of the WHOLE product
when only the deliberately short-lived admin session had lapsed.
This drops the admin token alone, keeps the ordinary session, and sends
the operator to the admin login with a notice.
-}
handleAdminSessionExpiry : Model -> ( Model, Cmd Msg )
handleAdminSessionExpiry model =
    ( { model
        | adminAuth = Nothing
        , page = PageAdminGate model.route AdminSession.init
      }
    , Cmd.none
    )
