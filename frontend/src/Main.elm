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
    , redirectAfterNavigation
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
import Components.OnboardingOverlay as OnboardingOverlay
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
import Page.Groups as Groups
import Page.Groups.Detail as GroupsDetail
import Page.Home as Home
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


{-| Server-config channel (ADR-020). Elm boots immediately with age-gating OFF
(the fail-safe production default); `GET /api/config` is fetched in the
background by `app.js` and its result is delivered here a beat after boot, so a
network round-trip never blocks first paint. The payload is the resolved
`ageGatingEnabled` boolean; on fetch failure JS sends nothing and the default
(`False`) stands.
-}
port ageGatingConfig : (Bool -> msg) -> Sub msg


{-| Browser connectivity (Issue #362). `app.js` subscribes to the `online` and
`offline` window events and sends `navigator.onLine` here, plus one send at boot
so a tab opened while already offline is not told it is connected.

⛔ **The shell, not the page.** This is the same shape as `handleSessionExpiry`:
a condition that is true of the whole app rather than of any one request, so it
is answered once, centrally, and every page inherits the answer. The alternative
— each page inferring "probably offline" from its own `Http.NetworkError` — is a
decision copied N times, arrives only after a request has already failed, and
says nothing at all on a page that happens not to be fetching anything.

`Bool` on the wire because that is exactly what `navigator.onLine` is; it
becomes a `Connectivity` the moment it crosses into Elm, so nothing downstream
has to remember which way round the boolean goes.

-}
port connectivityChanged : (Bool -> msg) -> Sub msg


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
    = PageHome Home.Model
    | PageLogin Login.Model
    | PageBookshelf Bookshelf.Model
    | PageReadingPile ReadingPile.Model
    | PageLookingForHome LookingForHome.Model
    | PageBookDetail BookDetail.Model
    | PageUpload Upload.Model
    | PageSearch Search.Model
    | PageSettingsAuditLog AuditLog.Model
    | PageInsights Insights.Model
    | PageSettingsProfile Profile.Model
    | PageSettingsPassword Password.Model
    | PageSettingsNotifications Notifications.Model
    | PageCostTransparency CostTransparency.Model
    | PageMetrics MetricsPage.Model
    | PageAbout
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
    | PageAdminSourceApproval AdminSourceApproval.Model
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

⛔ The point of this type is what it makes impossible. The old field was
`auth : Maybe Auth`, and a login could set it from a value the app had NOT yet
persisted: `Main` parked the response in `pendingAuthResponse`, fired the door
animation, and only wrote the token to localStorage when the browser reported
the animation finished. On an occluded window that report never came, so the
reader was authenticated in memory and anonymous on disk — a state that looked
fine until the tab reloaded and the session was simply gone (#359, three logins
returning `200` with nothing stored, driven live 2026-07-30).

Now the ONLY way an `AuthResponse` becomes either authenticated constructor is
`completeLogin`, which returns the state and the effects that make it durable as
one value. There is no half-authenticated variant to put a not-yet-saved
credential into, because there is no variant that means "we have a token but
have not written it".

`Arriving` and `Authenticated` are deliberately indistinguishable to every
consumer — `currentAuth` answers `Just` for both, and it is the only accessor.
`Arriving` names the seconds while the door ornament is still owed a completion
signal; if that signal never comes (occluded window, sleeping machine) nothing
about the session degrades. That is the guarantee: the animation cannot reach
the credential, in either direction.

-}
type AuthState
    = Anonymous
    | Arriving Auth
    | Authenticated Auth


{-| Whether the browser currently has a network connection (Issue #362).

A two-constructor type rather than `isOffline : Bool` on the model. The banner
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
    , auth : AuthState

    -- The MFA-verified admin-session token (#303). Held IN MEMORY and deliberately never
    -- persisted: it needs no port, it is the highest-value credential here, and MFA expires after
    -- 30 minutes anyway. Losing it on reload is the honest cost of that. Separate from `auth`
    -- because an expiring admin session must NOT eject the operator from the ordinary app.
    , adminAuth : Maybe String
    , page : Page
    , previousRoute : Maybe Route
    , transition : Maybe String

    -- The page the reader actually asked for and was bounced off, captured the
    -- moment `initPage` swaps it for the sign-in gate (see `loginRedirectFor`).
    -- Without it, a deep link to /upload sent them to their antilibrary after
    -- signing in and the page they wanted was simply lost. Recomputed on every
    -- `UrlChanged`, so it cannot outlive the bounce that raised it.
    , redirectAfterLogin : Maybe Route
    , bookDetailOverlay : Maybe BookDetailOverlay
    , userMenu : UserMenu.Model

    -- Which top-level nav disclosure (Bookshelves / Marketplace / Admin) is
    -- currently open, if any (#318 TR-1). At most one is open at a time —
    -- opening a second closes the first — so a single `Maybe` is the whole of
    -- the state. The account menu keeps its own `open` flag in `userMenu`; the
    -- two are held mutually exclusive in `update`. This field is what replaced
    -- the CSS `:hover`/`:focus-within` reveal, which was unreachable on touch.
    , openNavMenu : Maybe NavMenu
    , onboarding : OnboardingOverlay.Model
    , onboardingCompleted : Bool
    , hasAnyPlacements : Bool

    -- A removal the reader may still take back (US-1.6.4 extension, #375).
    --
    -- It has to live here, rather than on either page, because it spans the gap
    -- between them: `Page.BookDetail` records it and immediately asks to
    -- navigate, and `Nav.pushUrl` re-runs `initPage`, so the shelf that will
    -- show the toast does not exist yet at the moment the removal is known.
    -- Raised in the `BookDetail.NavigateTo` branches and consumed by the very
    -- next `UrlChanged` — the same "survives exactly one navigation" shape as
    -- `arrival` above, and cleared there for the same reason: an undo offer that
    -- outlived its navigation would reappear on a shelf the reader browsed to
    -- minutes later, pointing at a removal they had forgotten making.
    , pendingUndo : Maybe Bookshelf.Removal

    -- Why the reader will be standing at the login door when they next get
    -- there (Issue #360). Raised by whatever ended the session — expiry,
    -- account deletion, an unreadable stored credential — and consumed the
    -- moment a login card is built, so the reason survives the redirect's
    -- `UrlChanged` and no further.
    --
    -- ⛔ This ONE field replaced three booleans here, which shadowed three more
    -- on `Login.Model`. Six independently-settable flags for four mutually
    -- exclusive facts: see `Login.Arrival`.
    , arrival : Login.Arrival

    -- A deferred session-expiry intent (Issue #180 Phase 2): set while the
    -- re-check-before-logout port round-trip is in flight, cleared when it
    -- resolves (adopt a newer token, or proceed to `forceSessionExpiry`).
    , pendingLogout : Maybe PendingLogout

    -- Server-provided runtime config (ADR-020), fetched via `GET /api/config`
    -- and merged into the boot flags. The app's first global config channel;
    -- keep it minimal and extensible. Currently just the age-gating flag.
    , config : AppConfig

    -- Whether the browser has a network connection (Issue #362). Fed by the
    -- `connectivityChanged` port; read only by the shell's banner, so no page
    -- has to work this out from its own failed request.
    , connectivity : Connectivity

    -- Uploads this reader started and has not finished with (Issue #351).
    --
    -- It lives on the shell, not on `Page.Upload`, because two surfaces read it
    -- and they must not be able to disagree: the inbox listing on the upload
    -- page, and the count on the `Add Book` navigation marker — which has to be
    -- right on every page, including the ones where `Page.Upload` does not
    -- exist. One value, fetched once, rendered twice.
    --
    -- Refetched, never adjusted in place. When a placement or a manual add
    -- finishes, `Page.Upload` raises `RefreshInbox` and this is asked for
    -- again: the server owns the "is this still awaiting attention" predicate,
    -- and a client that decremented a number here would be a second, quieter
    -- implementation of it.
    , uploadInbox : RemoteData Http.Error (List Api.InboxItem)
    }


{-| Server-provided runtime configuration, delivered in the boot flags from
`GET /api/config` (ADR-020). The frontend's first global config channel —
extend this record as new server-driven flags land.
-}
type alias AppConfig =
    { ageGatingEnabled : Bool }


{-| The fail-safe default config: age-gating OFF (all age UI hidden). Used when
`GET /api/config` fails, times out, or returns a malformed/absent field.
-}
defaultConfig : AppConfig
defaultConfig =
    { ageGatingEnabled = False }


{-| Decode the runtime config out of the boot flags. A missing or malformed
`ageGatingEnabled` never crashes boot — it defaults to `False` (fail safe).
-}
configDecoder : Decode.Decoder AppConfig
configDecoder =
    Decode.map AppConfig
        (Decode.oneOf
            [ Decode.field "ageGatingEnabled" Decode.bool
            , Decode.succeed False
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
            initPage config route maybeAuth Nothing Nothing arrival
    in
    ( { key = key
      , url = url
      , route = route
      , auth =
            -- A token read back from localStorage is durable by definition, so it
            -- boots straight into the settled state — nothing is owed a completion
            -- signal.
            maybeAuth |> Maybe.map Authenticated |> Maybe.withDefault Anonymous
      , adminAuth = Nothing
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

      -- Fail-safe: boot as connected. `app.js` sends the real
      -- `navigator.onLine` immediately, so an offline tab corrects itself
      -- within a tick — whereas booting `Offline` would flash a banner at
      -- every reader whose browser happens to answer a moment late.
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


{-| Ask the server what is waiting for this reader (Issue #351).

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
and `adoptExternalAuth` (cross-tab propagation, Issue #180) share one contract.
-}
authDecoder : Decode.Decoder Auth
authDecoder =
    Decode.map8
        (\token userId email displayName handle role consentAnalytics consentWritingAssistant ->
            { user =
                { id = userId
                , email = email
                , displayName = displayName
                , handle = handle
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
            [ Decode.field "handle" Decode.string
            , Decode.succeed ""
            ]
        )
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


{-| What boot found in localStorage (Issue #360).

⛔ Three outcomes, three constructors. `decodeFlags` used to answer
`Maybe Auth`, which has room for only two — so "there was no stored credential"
and "there was one and it would not decode" arrived as the same `Nothing`, and
the app treated both as an ordinary signed-out boot.

That is not a cosmetic loss. The blob is written by `saveAuth` and read back
through the same `authDecoder`, so a mismatch means something rewrote it: a
half-written record, a shape from an older release, or the flat-vs-nested blob
that the SPA auth-injection recipe warns about — _"`stacks-auth` must be a FLAT
blob; nesting under `user` fails silently and looks exactly like logged-out"_.
Looking exactly like logged-out is the defect. The reader is put back at the
door with no explanation, and the one artefact that would have explained it —
the decoder's error — was thrown away by `Result.toMaybe` at the moment of
maximum information.

`CorruptStoredAuth` keeps that error and `Main.init` turns it into an `Arrival`
the login card renders, so the failure is told to the person it happened to
instead of being inferred later from a bug report.

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

⛔ This is the whole point of `CorruptStoredAuth` (#360): the boot outcome is
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

        -- Unauthenticated by design: US-2.5.3 says removal "does not require account
        -- creation". A shop owner who never asked to be listed must not have to sign up
        -- in order to leave.
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
            -- People-search is optional-auth (US-10.5.4): an anonymous visitor can
            -- discover readers even though book search still needs a token. Keeping
            -- /search open exercises the optional-auth backend anonymously.
            False

        ConfirmEmail _ ->
            False

        ForgotPassword ->
            False

        -- Public by necessity (#373): the reader asking for a new confirmation
        -- link is unconfirmed, so they CANNOT sign in — gating this route would
        -- bounce them to the very door they cannot open. Caught by
        -- `route_is_wired`: the `_ -> True` fallthrough below had quietly made
        -- this route protected, and the resend form was unreachable.
        ResendConfirmation ->
            False

        ResetPassword _ ->
            False

        NotFound ->
            False

        _ ->
            True


{-| The token for `/api/admin/*` — and the ONLY thing any admin call site may pass.

⛔ This exists because the entry points disagreed. `/api/admin/*` sits behind an MFA-verified admin
session (`typ: "admin_session"`, IP- and boot\_id-bound) and 401s anything else, so the four admin
surfaces were built, routed, unit-tested and unreachable. Repointing `initPage` fixed the page load
and left the `update` handlers on the ordinary token — the list loaded and every action 401'd.

Five call sites, not two. A field read repeated at five sites is five chances to read the wrong one,
and every page-level admin test is blind to it because the token arrives as an argument: a probe
setting one site to `Nothing` reintroduced the defect verbatim with **all 1285 Elm tests green**
(#309). So the read is named once, and `scripts/check-admin-token-routing.sh` fails the build if any
admin call site passes anything else — measured to catch the probe that elm-test does not.

Deliberately takes the whole `Model`: that is what makes it impossible to hand this function the
ordinary session by mistake.

-}
adminTokenFor : Model -> Maybe String
adminTokenFor model =
    model.adminAuth


{-| The page the reader asked for but is being bounced off, or `Nothing` when
they are not being bounced.

⛔ Named once, and read by BOTH the bounce itself (`initPage`, immediately below)
and the model field that has to remember it (`Model.redirectAfterLogin`). The
condition is the bounce: a second copy of `requiresAuth route && …` at the
remembering site is how "capture the asked-for page" drifts out of step with
"bounce to the sign-in gate" and starts remembering a page nobody was denied —
the #309 lesson, applied before it can happen.

Note the URL does NOT change on this bounce: `initPage` swaps the _page_ for the
sign-in gate and leaves the reader standing at `/upload`. That is what makes the
capture possible at all — the asked-for route is still `model.route`.

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
(the seam #360/#361 found, where both ends were right and the join between them
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


{-| The page to return the reader to after they sign in, recomputed for THIS
navigation — never accumulated. Read once, from `UrlChanged`.

⛔ **An expiry bounce is a bounce too** (#361, found while building #359). This
used to be a bare `loginRedirectFor newRoute auth`, which is right when a route
guard turns someone away at the door and wrong when a session dies underneath
them. `forceSessionExpiry` pushes `/login`; `/login` requires no auth; so the
recompute answered `Nothing` and the page the reader was standing on was dropped
on the floor. They signed back in and landed on the home page instead of the
settings form they were half-way through — the one case where returning them
matters most, because they did not choose to leave it.

`leaving` is the route being navigated AWAY from, which on an expiry bounce is
that page: `forceSessionExpiry` only pushed the URL, and this is the update that
consumes the push. `auth` is pinned to `Nothing` in that branch because the
expiry has already cleared it — asking `loginRedirectFor` about a session that
no longer exists is the whole point.

Key-free and pure so it can be unit-tested: `Main.Model` embeds an
unconstructable `Nav.Key` (the seam documented in `SessionExpiryTest`), so a
decision left inline inside `update` cannot be tested at all.

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


{-| Build the page for a route.

`arrival` is the reason the reader would be looking at a login card if this
route produces one — see `Login.Arrival`. It is threaded in rather than applied
afterwards because there is more than one way to end up at the card (the
protected-route bounce below, `/login` itself, `/forgot-password`), and the
notice used to be attached at only one of them: `UrlChanged` re-built the page
and then overwrote it with an `expiredInit`/`farewellInit` variant when the new
route happened to be `Login`. A reader bounced off `/library` by an expired
session therefore got the plain card with no explanation, because the bounce
does not change the URL to `/login`.

⚠️ Note how this composes with `redirectAfterNavigation` immediately above:
#361 makes the expiry bounce remember the page it is leaving, and #360 makes the
card it lands on say WHY. Same bounce, two independent things the reader was
previously not told.

-}
initPage : AppConfig -> Route -> Maybe Auth -> Maybe String -> Maybe Route -> Login.Arrival -> ( Page, Cmd Msg )
initPage config route maybeAuth adminToken maybePreviousRoute arrival =
    if loginRedirectFor route maybeAuth /= Nothing then
        ( PageLogin (Login.init arrival), Cmd.none )

    else if isAdminRoute route && adminToken == Nothing then
        -- ⛔ The gate that makes #303's four surfaces reachable. `/api/admin/*` needs an
        -- MFA-verified admin-session token, NOT the ordinary Guardian one; the pages were handed
        -- the latter and every request 401'd, so all four had never loaded for anyone. Rather than
        -- let a page render and fail, the route resolves to the sign-in gate until a real admin
        -- token exists — so a page never holds a token it cannot use.
        ( PageAdminGate route AdminSession.init, Cmd.none )

    else
        initPageAuthenticated config route maybeAuth adminToken maybePreviousRoute arrival


{-| The routes behind the `:admin` pipeline. Exhaustive on purpose — a `_ -> False` catch-all would
silently leave a newly added admin route ungated, which is the bug this whole change is fixing.
-}
isAdminRoute : Route -> Bool
isAdminRoute route =
    case route of
        Route.AdminSourceApproval ->
            True

        Route.AdminScraperConfig ->
            True

        Route.AdminBookModeration ->
            True

        Route.AdminRemovalRequests ->
            True

        _ ->
            False


{-| Hand a just-built page the removal the reader may still take back (#375).

Applied to `initPage`'s result rather than threaded through it: `initPage`
already carries six arguments and three call sites, and only ONE of those sites
— the `UrlChanged` that a removal's `Nav.pushUrl` provokes — can ever have an
undo to hand over. A seventh parameter would have made the other two say
`Nothing` forever.

A removal always navigates to `BookDetail.previousRoute`, so the page below is
the shelf the reader was standing on. When that shelf is the Reading Pile or
Looking for a Home the match falls through and no toast is offered: those two
are separate page modules with their own `Model`, and #375's scope is
`Page.Bookshelf` (Library / Antilibrary / Wish List). The removal still
succeeded — nothing is lost but the offer.

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


initPageAuthenticated : AppConfig -> Route -> Maybe Auth -> Maybe String -> Maybe Route -> Login.Arrival -> ( Page, Cmd Msg )
initPageAuthenticated config route maybeAuth adminToken maybePreviousRoute arrival =
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
            ( PageLogin (Login.init arrival), Cmd.none )

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
                profileModel =
                    case maybeAuth of
                        Just auth ->
                            Profile.init auth.user

                        Nothing ->
                            Profile.init { id = "", email = "", displayName = "", handle = "", role = "user", countryCode = Nothing, city = Nothing, consentAnalytics = False, consentWritingAssistant = False }
            in
            ( PageSettingsProfile profileModel, Cmd.none )

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
            let
                -- Seed the folded-in consent toggles from the signed-in user's
                -- current consent (#318 TR-4), exactly as the standalone consent
                -- page used to. `/settings/consent` now redirects here.
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
                    BlogPostPage.init postId maybeToken currentUserId writingAssistantConsent
            in
            ( PageBlogPost postModel, Cmd.map BlogPostMsg postCmd )

        Route.AdminSourceApproval ->
            if isOwner maybeAuth then
                let
                    ( subModel, subCmd ) =
                        AdminSourceApproval.init adminToken
                in
                ( PageAdminSourceApproval subModel, Cmd.map AdminSourceApprovalMsg subCmd )

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
            -- Owner-only AND gated behind the age-gating flag (ADR-020). While
            -- age-gating ships dark the moderation surface is unavailable — a
            -- flag-off route resolves to NotFound, exactly like an unauthorised
            -- owner-guarded route.
            if isOwner maybeAuth && config.ageGatingEnabled then
                let
                    ( subModel, subCmd ) =
                        AdminBookModeration.init adminToken
                in
                ( PageAdminBookModeration subModel, Cmd.map AdminBookModerationMsg subCmd )

            else
                ( PageNotFound, Cmd.none )

        Route.AdminRemovalRequests ->
            -- Owner-only, and NOT flag-gated: a business waiting to be delisted is waiting
            -- now, whatever else ships dark.
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
            -- Browse another reader's shelf read-only (#215 / US-10.5.3): the
            -- Bookshelf module in its profile config fetches the profile endpoint
            -- and strips every mutating affordance.
            initBookshelf (Bookshelf.profileConfig handle bookshelfName) maybeAuth

        ConfirmEmail status ->
            ( PageConfirmEmail status, Cmd.none )

        ForgotPassword ->
            -- The forgot-password form is a mode of the login card, not a
            -- standalone page — deep-linking /forgot-password opens the login
            -- card straight onto that mode. Asking to reset a password is
            -- itself an arrival reason, which is why it is a constructor of the
            -- same type and not a fourth boolean (#360).
            ( PageLogin (Login.init Login.ForgotPassword), Cmd.none )

        ResendConfirmation ->
            -- Where a dead confirmation link sends the reader (#373). Same shape
            -- as ForgotPassword directly above: a mode of the login card, opened
            -- by an arrival, not a page of its own.
            ( PageLogin (Login.init Login.ConfirmationExpired), Cmd.none )

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
        | auth = Anonymous
        , adminAuth = Nothing

        -- `draftSaved` is STICKY: a second, plain expiry arriving on top of a
        -- draft expiry must not withdraw the reassurance that the listing was
        -- saved. It was two fields OR-ed independently; now the OR is inside the
        -- one constructor that gives the flag any meaning.
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

⛔ The ORDER is the fix (#359). `PersistAuth` is first and `PlayDoorAnimation` is
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
            -- Back to the page they asked for, or the antilibrary if they simply
            -- signed in. Note this fires even when the target equals the current
            -- URL (the bounce leaves the URL alone), which is what re-runs
            -- `initPage` with a token in hand and swaps the gate for the real page.
            Nav.pushUrl key (Route.toPath (Maybe.withDefault AntiLibrary redirect))

        ArmArrivalBackstop ->
            -- The sleep race (#359, requirement 3). The ornament's completion
            -- signal comes from JS and can be lost outright: an occluded window
            -- never runs `requestAnimationFrame`, and a machine that suspends
            -- mid-animation may never settle the promise at all. A timer is the
            -- backstop because timers are throttled in a background tab, not
            -- cancelled, and fire on wake. Belt and braces, though: the arrival
            -- settling late — or never — costs nothing, because `Arriving` and
            -- `Authenticated` answer `currentAuth` identically.
            Process.sleep arrivalBackstopMs |> Task.perform (\_ -> ArrivalSettled)

        PlayDoorAnimation ->
            -- Decoration, fired last, gating nothing. See `loginEffects`.
            --
            -- ⚠️ Measured 2026-07-31: with the navigation above firing in the same
            -- update, the login scene is unmounted before the port's frame
            -- callback runs, so the dolly-shot starts ZERO animations. The
            -- ornament is not merely ungating — it no longer plays. That is the
            -- direct cost of "the animation cannot gate anything", and it is a
            -- design decision to take rather than a bug to fix here: bringing the
            -- flourish back means rendering the door layers from the SHELL while
            -- `AuthState` is `Arriving`, over the destination page, which is what
            -- `Arriving` is shaped for and is its own issue. Reported as a
            -- finding on #359 rather than smuggled in.
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



-- UPDATE


{-| The top-level navigation disclosures whose open/closed state Elm owns
(#318 TR-1). Each corresponds to a `<button aria-haspopup aria-expanded>` in the
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
      -- The door ornament finished, or the backstop timer gave up waiting for it.
      -- Both mean the same thing and neither touches the credential (#359).
    | ArrivalSettled
    | HomeMsg Home.Msg
    | BookshelfMsg Bookshelf.Msg
    | ReadingPileMsg ReadingPile.Msg
    | LookingForHomeMsg LookingForHome.Msg
    | BookDetailMsg BookDetail.Msg
    | UploadMsg Upload.Msg
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
    | AdminSourceApprovalMsg AdminSourceApproval.Msg
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

                -- The pending arrival goes IN, so whichever branch of `initPage`
                -- produces a login card produces it already carrying its reason.
                -- This replaced a three-branch `if newRoute == Login && …` ladder
                -- that re-built the page and then threw it away — and which only
                -- fired for the literal `/login` route, so the notice was lost on
                -- every bounce that leaves the URL alone.
                ( page, cmd ) =
                    initPage model.config
                        newRoute
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

                -- Spent. See the field's own note: one navigation, no further.
                , pendingUndo = Nothing
                , transition = transition
                , redirectAfterLogin =
                    redirectAfterNavigation
                        { arrivingAt = newRoute
                        , leaving = model.route

                        -- #361's question, answered by #360's value. Read
                        -- BEFORE `consumeArrival` spends it, just as the boolean
                        -- this replaced was read before `UrlChanged` cleared it.
                        , sessionExpiring = Login.isSessionExpiry model.arrival
                        , auth = currentAuth model.auth
                        }
                , userMenu = UserMenu.init
                , arrival = consumeArrival page model.arrival
              }
            , cmd
            )

        TransitionEnded animationName ->
            -- Clear the navigation transition class once its own animation has
            -- finished, so the next navigation re-adds it and the browser
            -- restarts the animation (US-1.2.5, issue #277). The bubbling
            -- filter lives in Animation.Transition, where it is unit-tested.
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
                            -- The whole login lands here, in the update that decoded
                            -- the 200: the session goes into the model and the token
                            -- goes to localStorage in the same breath. Nothing waits
                            -- on the browser, so an occluded window signs in exactly
                            -- like a focused one (#359).
                            let
                                arrival =
                                    completeLogin authResponse
                            in
                            ( { baseModel | auth = arrival.authState }
                            , loginCompletionCmd model.key model.redirectAfterLogin arrival baseCmd
                            )

                        Login.RegistrationSucceeded _ ->
                            -- Registration only sends a confirmation email; no JWT is
                            -- issued and no navigation happens. The Login page has already
                            -- switched itself to the pending state via its own model.
                            ( baseModel, baseCmd )

                _ ->
                    ( model, Cmd.none )

        ArrivalSettled ->
            -- ⛔ Cosmetic by design. This used to be `LoginTransitionCompleted`, and
            -- it was where the token got written — the browser telling us an
            -- animation had finished was the app's only cue to persist a credential
            -- it had been holding since the 200. Now the credential is long since
            -- durable and there is nothing left for this message to do but retire
            -- the arrival state. Losing it entirely changes nothing observable.
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

                        BookDetail.SessionExpired ->
                            handleSessionExpiry model

                        BookDetail.RequestCloseOverlay ->
                            ( baseModel, baseCmd )

                        BookDetail.NavigateTo route ->
                            ( { baseModel | pendingUndo = newSubModel.undoableRemoval }
                            , Cmd.batch
                                [ baseCmd
                                , Nav.pushUrl model.key (Route.toPath route)

                                -- Match the overlay path: after a remove on the
                                -- full-page route, focus the main landmark so it
                                -- is not lost to <body> (#295 item b).
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

                _ ->
                    ( model, Cmd.none )

        AdminSourceApprovalMsg subMsg ->
            case model.page of
                PageAdminSourceApproval subModel ->
                    let
                        -- ⛔ The ADMIN token, not the ordinary one. `init` was repointed and
                        -- `update` was not, so the first load worked (admin token) and every
                        -- subsequent action 401'd (ordinary token). Driven on a preview
                        -- 2026-07-29: GET /api/admin/sources -> 200, then
                        -- PUT /api/admin/sources/:id/approve -> 401 unauthorized.
                        --
                        -- Same half-wiring shape as the bug this whole change fixes — fixing one
                        -- entry point and not the other leaves a page that loads and cannot act.
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
                        -- ⛔ The ADMIN token, not the ordinary one. `init` was repointed and
                        -- `update` was not, so the first load worked (admin token) and every
                        -- subsequent action 401'd (ordinary token). Driven on a preview
                        -- 2026-07-29: GET /api/admin/sources -> 200, then
                        -- PUT /api/admin/sources/:id/approve -> 401 unauthorized.
                        --
                        -- Same half-wiring shape as the bug this whole change fixes — fixing one
                        -- entry point and not the other leaves a page that loads and cannot act.
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
                            -- Hold the token in memory and re-resolve the route the operator was
                            -- actually going to, so signing in lands them on that page rather than
                            -- on a "now navigate again" screen.
                            let
                                withToken =
                                    { model | adminAuth = Just adminToken }

                                ( page, pageCmd ) =
                                    -- `adminTokenFor withToken`, not `Just adminToken`: the same value
                                    -- by two different routes is exactly what the resolver exists to
                                    -- remove. One way to obtain the admin token, everywhere.
                                    initPage model.config
                                        gatedRoute
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

        AdminRemovalRequestsMsg subMsg ->
            case model.page of
                PageAdminRemovalRequests subModel ->
                    let
                        -- ⛔ The ADMIN token, not the ordinary one. `init` was repointed and
                        -- `update` was not, so the first load worked (admin token) and every
                        -- subsequent action 401'd (ordinary token). Driven on a preview
                        -- 2026-07-29: GET /api/admin/sources -> 200, then
                        -- PUT /api/admin/sources/:id/approve -> 401 unauthorized.
                        --
                        -- Same half-wiring shape as the bug this whole change fixes — fixing one
                        -- entry point and not the other leaves a page that loads and cannot act.
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
                            -- Remove-success path: tear down the overlay, land on
                            -- the previous shelf, and move focus to the main
                            -- landmark so it is not lost to <body> (#295 item b).
                            --
                            -- `newDetail.undoableRemoval` rides along so the shelf
                            -- can offer to put the book back (#375). It is read
                            -- HERE and not in the `NoOut` branch because this is
                            -- the branch a completed removal takes — the overlay
                            -- is about to cease to exist, taking the only record
                            -- of what was removed with it.
                            ( { model
                                | bookDetailOverlay = Nothing
                                , pendingUndo = newDetail.undoableRemoval
                              }
                            , Cmd.batch
                                [ Nav.pushUrl model.key (Route.toPath route)
                                , focusMainContent
                                ]
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
                    -- Opening the account menu closes any open nav disclosure:
                    -- at most one menu is ever open (#318 TR-1).
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

                        -- A deliberate sign-out needs no explanation, so the
                        -- card is built `Fresh` — and any arrival left pending
                        -- from an earlier session goes with it.
                        , page = PageLogin (Login.init Login.Fresh)
                        , arrival = Login.Fresh
                      }
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

        ToggleNavMenu menu ->
            -- Opening a nav disclosure closes the account menu, keeping the
            -- "at most one open" invariant (#318 TR-1).
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
                -- The onboarding overlay is the topmost surface; Escape dismisses
                -- it via the same finish path as Skip (US-14.1.2 §2 sad path).
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
                -- Skip, Escape, and advancing off the last step share ONE finish
                -- path (US-14.1.2 §12): flip the client-side re-trigger guard and
                -- mirror it to localStorage. The overlay's own Cmd has already
                -- recorded the server step being left (#149).
                OnboardingOverlay.OnboardingFinished ->
                    ( { baseModel | onboardingCompleted = True }
                    , Cmd.batch [ baseCmd, saveOnboardingCompleted () ]
                    )

                -- The embedded US-1.1.1 upload flow's effects, relayed to the
                -- shell exactly as the standalone upload page wires them.
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

        AgeGatingConfigReceived enabled ->
            -- The background `GET /api/config` fetch resolved (ADR-020). Adopt the
            -- server-provided flag; in production it is `False` (no-op vs. the
            -- boot default), and only flips age UI on where the flag is set.
            let
                config =
                    model.config
            in
            ( { model | config = { config | ageGatingEnabled = enabled } }, Cmd.none )

        ConnectivityChanged isOnline ->
            -- The browser's own `online`/`offline` event (Issue #362). No
            -- effect: the banner is the whole response. Deliberately NOT a
            -- retry trigger — a page that refetches on reconnect is a separate
            -- decision, and quietly re-issuing a request the reader has since
            -- navigated away from is how stale data lands on the wrong page.
            ( { model | connectivity = connectivityFromOnline isOnline }, Cmd.none )

        FocusResult ->
            -- Shared fire-and-forget no-op: absorbs focus-attempt results and
            -- the logout request's result (best-effort server-side revocation).
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
                        -- The badge renders nothing in this state, and the
                        -- upload page says it could not check. Neither pretends
                        -- the inbox is empty: "we don't know" and "nothing is
                        -- waiting" are different answers, and only one of them
                        -- is safe to show as a cleared badge.
                        ( { model | uploadInbox = Failure err }, Cmd.none )

        RenewToken ->
            -- Proactive silent renewal tick. Only meaningful while authenticated;
            -- a signed-out session simply drops the tick.
            case currentAuth model.auth of
                Just auth ->
                    ( model, Api.refresh auth.token TokenRefreshed )

                Nothing ->
                    ( model, Cmd.none )

        TokenRefreshed (Ok authResponse) ->
            -- Renewal succeeded: adopt the fresh token (keeping the same user),
            -- persist it, and roll the next renewal. No navigation, no logout.
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
            -- Renewal failed (token already expired/revoked, or the service is
            -- down): fall through to the session-expiry path, tagged as
            -- renewal-origin so a re-check adopt re-arms the consumed tick (P1b).
            handleSessionExpiryFromRenewal model

        AuthChangedExternally value ->
            -- A sibling tab wrote `stacks-auth` (Issue #180 Phase 2).
            case adoptExternalAuth value (currentAuth model.auth) of
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
                    ( { model | auth = Authenticated newAuth, pendingLogout = Nothing }
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
            case resolveRecheck model.pendingLogout (adoptExternalAuth value (currentAuth model.auth)) of
                ResolveAdopt newAuth reschedule ->
                    -- localStorage holds a newer token than the one that 401'd —
                    -- adopt it and cancel the logout. Re-arm renewal ONLY for a
                    -- renewal-origin expiry, whose proactive tick was consumed (P1b).
                    ( { model | auth = Authenticated newAuth, pendingLogout = Nothing }
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
    openOverlayWithTrigger model bookId ("spine-" ++ bookId)


{-| Move focus to the persistent main-content landmark. Used after a book is
removed from its shelf (#295 item b): the remove-success path navigates to the
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
account menu and every nav disclosure (#318 TR-1).
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
one-liner (the body is unchanged from before #318 8b).
-}
escapeForPage : Model -> ( Model, Cmd Msg )
escapeForPage model =
    case model.bookDetailOverlay of
        Just overlay ->
            let
                maybeToken =
                    Maybe.map .token (currentAuth model.auth)

                -- Give the overlay first dibs on Escape: it dismisses a
                -- nested surface (remove modal / progress-edit form) if
                -- one is open, else returns RequestCloseOverlay.
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
                    -- No nested surface consumed it: close the overlay and
                    -- return focus to the triggering spine.
                    ( { model | bookDetailOverlay = Nothing }, returnFocusCmd )

                _ ->
                    -- The overlay closed a nested surface and stays open;
                    -- run its (focus-return) command.
                    ( { model | bookDetailOverlay = Just { overlay | detail = newDetail } }
                    , Cmd.map OverlayBookDetailMsg subCmd
                    )

        Nothing ->
            -- No overlay is open. On the full-page BookDetail route,
            -- give the page first dibs on Escape so its nested surfaces
            -- (remove modal / progress-edit form) dismiss too (#295 item
            -- e) — the same consumed/not-consumed pattern as the overlay.
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
                            -- No nested surface consumed it; there is no
                            -- overlay to close on the page route, so fall
                            -- back to the default (close the user menu).
                            closeUserMenuOnEscape model

                        _ ->
                            -- The page dismissed a nested surface and
                            -- stays put; run its (focus-return) command.
                            ( { model | page = PageBookDetail newSubModel }
                            , Cmd.map BookDetailMsg subCmd
                            )

                PageBlogPost subModel ->
                    -- Give the blog post's block affordance (⋯ menu / block
                    -- confirm) first dibs on Escape (#389); fall through to the
                    -- default when nothing was open to consume it.
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
                    -- Same, for the group feed's per-member block affordances (#389).
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
`search-result-<bookId>` button (#289) — both compose with the #114
focus-return mechanism via `triggerSpineId`.
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

        -- #295 item a: focus the labelled dialog card on open (not the close
        -- button), so a screen reader announces the book first. The card is
        -- `tabindex -1`, so the first forward Tab still lands on the close
        -- button and the focus trap is unaffected.
        , Task.attempt (always FocusResult) (Browser.Dom.focus BookDetail.cardFocusId)
        ]
    )



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ onSwipe decodeSwipe
        , onLoginTransitionComplete (\_ -> ArrivalSettled)
        , onOnboardingStatus OnboardingStatusReceived
        , authChanged AuthChangedExternally
        , gotStoredAuth GotStoredAuth
        , ageGatingConfig AgeGatingConfigReceived
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
            -- The onboarding Upload step embeds the real US-1.1.1 flow, so the
            -- SSE stream and wait-clock must reach the overlay's upload sub-model
            -- (routed through `OnboardingMsg`) rather than a `PageUpload` that is
            -- not the current page. Same two subscriptions, one hop deeper.
            uploadSubscriptions (OnboardingMsg << OnboardingOverlay.UploadMsg)

          else
            case model.page of
                PageUpload _ ->
                    uploadSubscriptions UploadMsg

                PageMarketplaceCreate _ ->
                    gotListingDraft (CreateListingMsg << CreateListing.DraftLoaded)

                _ ->
                    Sub.none
        ]


{-| The two subscriptions the US-1.1.1 upload flow needs, parameterised by how
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

        -- The only clock `Page.Upload` has (Issue #351). It drives the "you may
        -- leave" copy and the silent-stream watchdog, both of which are
        -- elapsed-time facts the client genuinely owns — unlike the retry count
        -- it deliberately never claims. The interval MUST match
        -- `Upload.tickSeconds`; `WaitTick` is a no-op whenever the flow is not
        -- waiting, so an idle upload surface costs one discarded message every
        -- five seconds and nothing else.
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



-- VIEW


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

                -- `tabindex -1` makes the main landmark programmatically
                -- focusable: it is both the skip-link target and where focus
                -- lands after a book is removed from its shelf (#295 item b).
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


{-| The login door dolly-shot, rendered from the SHELL over the destination page
for exactly the `Arriving` window (#364).

⛔ This is the observable job `Arriving` was carved for. #359 moved the
credential off the animation frame by navigating away from the login scene on
the SAME update that decodes the `200`; that unmounts `Page.Login`'s scene
layers before the `playLoginTransition` port's `requestAnimationFrame` callback
runs, so the dolly-shot started **zero** animations (`animationsStarted=0`,
driven live 2026-07-31). The layers live here instead, keyed on `AuthState`, so
the exact element ids the port animates are present over the destination page
while the arrival settles and gone the instant it does.

The animation still cannot gate anything: rendering is downstream of `auth`,
which `completeLogin` already put in `Arriving` with the token persisted, and
`Arriving` answers `currentAuth` identically to `Authenticated`. If
`ArrivalSettled` never comes (occluded window, sleeping machine) the door simply
lingers behind a session that is already durable — it is `pointer-events: none`
so it cannot even intercept a click while it does — and the backstop timer
retires it regardless.

The ids and `layer-*` classes mirror `Page.Login.view`'s scene because
`app.js`'s port targets them by id; the login card/overlay is deliberately NOT
rendered — the reader has already stepped through the door, so there is nothing
left to fade. `Anonymous` and `Authenticated` render nothing, which is what
removes the door at both ends of the arrival.

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


{-| The document title, derived from the page that is actually on screen.

⛔ It used to be `pageTitle : Route -> String`, and a route is not a page. The
route is what the reader ASKED for; `Page` is what the shell BUILT, and the two
differ by design at six sites:

1.  `initPage`'s protected-route bounce swaps the page for the sign-in gate and
    deliberately leaves the URL alone — so a signed-out reader at `/upload` was
    looking at a login card in a tab titled "Add a Book".
2.  `initPage`'s admin gate does the same for `/admin/*`, titling the MFA
    challenge "Source Approval".
3.  An owner-guard failure resolves those routes to `PageNotFound`, still titled
    with the admin surface a non-owner was just refused.
4.  `AdminBookModeration` does likewise when age-gating is off (ADR-020).
5.  Signing out replaces the page immediately, so the login card wore the title
    of whatever page the reader signed out from.
6.  `handleAdminSessionExpiry` puts the admin gate back **without touching the
    URL at all**, so that title stayed wrong for as long as the operator did.

Deriving from `Page` closes all six by construction — there is no longer a
second value that could disagree. It also lets a title say what a route cannot
know: which bookshelf, whose shelf, which book, which mode the card is in.

This is not decoration. `Browser.Document.title` is what a screen reader
announces on navigation, and the only page identity a tab, a bookmark and a
history entry keep.

⚠️ Exhaustive over `Page`, with no `_ ->` fallback. A catch-all is how the next
page constructor would silently inherit a title belonging to something else,
which is the defect being fixed.

-}
pageTitle : Page -> String
pageTitle page =
    case page of
        PageHome _ ->
            "The Stacks"

        PageLogin loginModel ->
            -- Derived from the card's CURRENT mode, not from the route that
            -- opened it: switching to Register or to the reset form now
            -- retitles the document, which a route-derived title structurally
            -- could not do — the URL does not change when the card does.
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

        PageAdminScraperConfig _ ->
            titled "Scraper Health"

        PageAdminBookModeration _ ->
            titled "Book Moderation"

        PageAdminRemovalRequests _ ->
            titled "Removal Requests"

        PageAdminGate _ _ ->
            -- Drift sites 2 and 6. The operator is looking at an MFA challenge,
            -- not at the surface behind it. The gated route IS carried by this
            -- constructor and is deliberately not read here: naming the surface
            -- is precisely the claim that was false.
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

        PageResetPassword _ ->
            titled "Reset Password"

        PageNotFound ->
            -- Drift sites 3 and 4. A refused admin route renders this page; it
            -- must not keep announcing the surface it refused.
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
                          -- (#318 TR-1). A book-detail is a child of the shelves,
                          -- so `isBookshelfRoute` keeps this item active there too.
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

                        -- Search is a top-level destination, not buried in a
                        -- menu (#318 TR-1).
                        , navItem route Search "Search"

                        -- Add Book is a PERSISTENT primary action: always in the
                        -- DOM, reachable on touch, never behind a hover reveal
                        -- (#318 TR-1). The #351 pending badge rides on it.
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


{-| The settings family exposed by the account menu (#318 TR-1). Before this,
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
    ]


{-| `True` for the five bookshelf routes AND for a book-detail, which is a child
of the shelves. This is what keeps the Bookshelves nav item highlighted while
you are reading a book you reached from a shelf (#318 TR-1, child-route
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
whose menu is in the DOM ONLY when open (#318 TR-1). This replaced the CSS
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
                  -- into `CloseNavMenu` — the same click-away shape as the
                  -- account menu's backdrop.
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


{-| The persistent "Add Book" primary action (#318 TR-1). An always-present
`btn btn--primary` link — no hover menu in front of it — so it is reachable on
touch and by keyboard. The #351 pending-confirmation badge rides here now that
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

                                -- The visible number is a glyph; this is what it
                                -- means. A screen reader hearing "Add Book 2"
                                -- would be told a quantity of nothing in
                                -- particular.
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


{-| The number on the `Add Book` marker (Issue #351).

⛔ Three states, and they are three different things:

  - `Nothing` when the inbox has not loaded, or failed to load. We do not know
    what is waiting, and a cleared badge is an assertion that nothing is —
    which we cannot make.
  - `Nothing` when the count is zero. Requirement 4 of the issue, spelled out:
    "Zero pending renders no badge, not a `0`."
  - `Just n` otherwise.

The number comes from `Api.awaitingConfirmationCount` over the very list the
inbox surface renders — the same value in the same model field, not a second
query. Failures are in that list and are deliberately not in this number: a
failed upload has nothing to confirm, so a badge counting it could never be
cleared by doing what the badge asks.

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

        PageSearch subModel ->
            Html.map SearchMsg (Search.view subModel)

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
            Html.map AdminSourceApprovalMsg (AdminSourceApproval.view subModel)

        PageAdminScraperConfig subModel ->
            Html.map AdminScraperConfigMsg (AdminScraperConfig.view subModel)

        PageAdminBookModeration subModel ->
            Html.map AdminBookModerationMsg (AdminBookModeration.view subModel)

        PageAdminRemovalRequests subModel ->
            Html.map AdminRemovalRequestsMsg (AdminRemovalRequests.view subModel)

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
    -- Reuse the login page's static scene (library background + dim + vignette)
    -- so the email-confirmation result matches the login and reset-password cards.
    -- The animated door layers are login-only; this renders the background
    -- statically — no animation.
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
            -- ⛔ This used to end "Please register again to receive a fresh
            -- confirmation email" (#373). That was advice the app could not
            -- honour: registering again with the same address fails on the
            -- unique-email constraint, which is the state every reader who
            -- reaches this page is in. The instruction sent them into a wall.
            -- There is now a real way out, so the copy points at it.
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


{-| The shell's connectivity banner (Issue #362).

⛔ **The reason this is in the shell.** Losing your connection is a fact about
the app, not about a request, and the page that most needed to say so was the
one saying least: a shelf whose fetch never returned rendered an empty bookcase,
so the reader was told their library was empty. Answering that per-page means
copying the same inference N times, and it can only ever speak AFTER a request
has failed — it has nothing to say on a page that is simply sitting there.
Here it is one banner, above everything, correct the instant the browser knows.

Rendered above the nav rather than fixed over it: it pushes the page down, which
is honest — something has changed about the whole app — where an overlay would
cover a control the reader may be reaching for.

`role="status"` + `aria-live="polite"` so it is announced without stealing focus
mid-task. It says what is true (nothing is reaching the library) and what will
happen (it comes back on its own), so nobody is left hunting for a retry button
that would not help.

Nothing renders when online. An "everything is fine" banner is noise, and it
would push the page down on every reader, forever, to say nothing.

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


{-| An admin API call came back unauthorised.

⛔ **All four admin pages used to call `handleSessionExpiry` here, which clears the ordinary session
and drops the operator on the Login page.** So honouring a removal request — or any admin action
whose token had lapsed — signed them out of the whole product. Driven on a preview 2026-07-29:
confirming a removal ejected me to "The library closed your session for safekeeping".

That directly contradicted the design this feature was built to (#303): the admin session is
deliberately separate and short-lived — MFA expires after 30 minutes, and the session is bound to the
client IP and the node's `boot_id`, so a network change or a deploy ends it. Those are _routine_, and
none of them is a reason to end the ordinary session, which is untouched and still valid.

So: drop only `adminAuth` and put the gate back on the current route. The operator re-verifies and
carries on, rather than being told they were signed out of something they were not.

⚠️ **Verified by driving, not by a unit test, and that is a deliberate choice.** Asserting on this
needs a whole `Main.Model`, whose `Nav.Key` is opaque and unconstructable in a test — the only routes
in are a `ProgramTest` harness at Main level (which does not exist here) or exporting a `testModel`
seam from production code purely for the assertion. Neither is worth it for a four-line function
whose failure is glaring the moment anyone uses the page. It was found live and it is confirmed live.
The `e2e/` suite is the right home if this ever needs automating.

-}
handleAdminSessionExpiry : Model -> ( Model, Cmd Msg )
handleAdminSessionExpiry model =
    ( { model
        | adminAuth = Nothing
        , page = PageAdminGate model.route AdminSession.init
      }
    , Cmd.none
    )
