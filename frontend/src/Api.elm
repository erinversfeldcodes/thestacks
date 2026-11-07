module Api exposing
    ( Account
    , AdminAuthError(..)
    , AdminBook
    , AdminBooksResponse
    , AdminFeedbackEntry
    , AdminFeedbackPage
    , AdminInvite
    , AdminMfaEnrolment
    , AdminSession
    , AdminSource
    , AdminSourcesResponse
    , AssociationVerdict(..)
    , AuditLogEntry
    , AuditLogResponse
    , AuthResponse
    , Authed
    , AuthorEvent
    , Behaviour
    , BisacCount
    , BlockAction(..)
    , BlockError(..)
    , BlockedUser
    , BlockedUsersResponse
    , BlogPostPage
    , BookDetailResponse
    , BootFailure(..)
    , CatalogueResponse
    , CollectionHit
    , ConfirmError(..)
    , ConfirmOutcome(..)
    , ConfirmResponse
    , Credential(..)
    , Credentials
    , Deanonymisation
    , GroupMember
    , Identity
    , IdentityOutcome(..)
    , ImportError(..)
    , ImportRow
    , InboxItem
    , InboxKind(..)
    , InterestProfile
    , InvitationAnswer(..)
    , InviteStatus
    , LibraryImport
    , ListingParams
    , ListingTransition(..)
    , LiveSignals(..)
    , MergeFormatResponse
    , MoveError(..)
    , MyWriting
    , NotificationPreferences
    , OnboardingStatus
    , PersonalInferences
    , PlaceError(..)
    , PlacementSummary
    , PlatformHit
    , PollResponse
    , PollStatus(..)
    , PrivacySettings
    , ProfileError(..)
    , ProfileSaved
    , ProfileShelfSummary
    , Progress
    , ProgressError(..)
    , PublicProfile
    , PublicProfileSummary
    , PublicationState(..)
    , Refusal(..)
    , RegisterError(..)
    , RemovalDecision(..)
    , RemovalOutcome(..)
    , RemovalRequest
    , RequestError(..)
    , RequestSpec
    , RiskInference
    , SearchSections
    , ShelfMoveError(..)
    , ShelfVisibilitySetting
    , SourceHealth
    , SubjectCount
    , Syndication
    , SyndicationExport
    , TransparencyEntry
    , TransparencyMetrics
    , UploadInit
    , accountDecoder
    , adminBookDecoder
    , adminBookEnvelopeDecoder
    , adminBooksResponseDecoder
    , adminFeedbackPageDecoder
    , adminFeedbackRequest
    , adminInviteDecoder
    , adminInvitesRequest
    , adminListBooksRequest
    , adminLogin
    , adminLogoutRequest
    , adminMfaConfirm
    , adminMfaSetup
    , adminSetBookAgeGateRequest
    , adminSourceDecoder
    , adminSourcesRequest
    , adminSourcesResponseDecoder
    , adminVerifyMfa
    , approveSourceRequest
    , associationVerdictRequest
    , auditLogResponseDecoder
    , authHeaders
    , authResponseDecoder
    , authed
    , authorEventDecoder
    , authorEventsDecoder
    , awaitingConfirmationCount
    , blockRequest
    , blockResponseToResult
    , blockedUserDecoder
    , blockedUsersRequest
    , blockedUsersResponseDecoder
    , blogPostPageDecoder
    , blogPostRequest
    , bookDetailResponseDecoder
    , catalogueResponseDecoder
    , checkInviteRequest
    , commitUploadDecoder
    , commitUploadRequest
    , completeOnboardingStepRequest
    , confirmBookRequest
    , confirmResponseDecoder
    , confirmResponseToResult
    , cookieSession
    , createAdminInviteRequest
    , createBlogPostRequest
    , createCommentRequest
    , createGoodreadsImport
    , createGroupRequest
    , createListingRequest
    , createShelfRequest
    , credentials
    , decodeUploadInit
    , deleteAccountRequest
    , deleteCommentRequest
    , deleteShelfRequest
    , encodeProfileBody
    , foldProgress
    , forgotPasswordRequest
    , getAccountRequest
    , getAuditLogRequest
    , getAuthorEventsRequest
    , getBlogPostsRequest
    , getBookRequest
    , getBookshelfRequest
    , getCatalogueRequest
    , getInferencesRequest
    , getListingsRequest
    , getProfileRequest
    , getProfileShelfRequest
    , getTransparencyMetricsRequest
    , getUserPlacementsRequest
    , groupFeedRequest
    , groupMemberDecoder
    , groupMembersRequest
    , groupRequest
    , identityDecoder
    , identityOutcome
    , identityRequest
    , importRefusal
    , importRequest
    , importRowDecoder
    , importRowsRequest
    , inboxItemDecoder
    , inboxKindDecoder
    , initUploadRequest
    , interceptExpiry
    , interpretAuthed
    , invitationAnswerRequest
    , inviteErrorDecoder
    , inviteStatusDecoder
    , inviteToGroupRequest
    , isNotFound
    , isUnauthorized
    , leaveGroupRequest
    , libraryImportDecoder
    , listingTransitionRequest
    , loginRequest
    , logoutRequest
    , mergeFormatRequest
    , mergeFormatResponseDecoder
    , moveBookRequest
    , movePlacementToShelfRequest
    , moveResponseToResult
    , myListingsRequest
    , myPlacementsRequest
    , needsAdminElevation
    , needsAdminElevationOf
    , notificationPreferencesDecoder
    , notificationsRequest
    , onboardingStatusDecoder
    , onboardingStatusRequest
    , peopleSearchDecoder
    , personalInferencesDecoder
    , placeBookRequest
    , placeResponseToResult
    , placementFormatsDecoder
    , placementShelfDecoder
    , placementsMineDecoder
    , planHeaders
    , postCommentsRequest
    , privacySettingsDecoder
    , privacySettingsRequest
    , profileSavedDecoder
    , progressDecoder
    , progressErrorMessage
    , progressResponseToResult
    , publicProfileDecoder
    , publicProfileSummaryDecoder
    , publishBlogPostRequest
    , putUploadBytes
    , recordSyndicationRequest
    , refreshRequest
    , refusalFrom
    , refusalToken
    , registerErrorsDecoder
    , registerRequest
    , registrationResponseDecoder
    , rejectIdentificationRequest
    , rejectSourceRequest
    , removalDecisionRequest
    , removalOutcomeDecoder
    , removalRequestDecoder
    , removalRequestsRequest
    , removeBookRequest
    , removeGroupMemberRequest
    , reorderShelvesRequest
    , requestExportRequest
    , requestHeaders
    , requestListingRemovalRequest
    , resendConfirmationRequest
    , resetPasswordRequest
    , resolveAuthResponse
    , resolveJson
    , resolveNoContent
    , resolveProfile
    , resolveRegister
    , resolveWhatever
    , restoreBookRequest
    , retryAfterSeconds
    , revokeAdminInviteRequest
    , saveConsentRequest
    , saveWritingAssistantConsentRequest
    , searchBooksRequest
    , searchResponseDecoder
    , searchUsersRequest
    , sendFeedbackRequest
    , setBookAgeGateRequest
    , setPostSyndicatedRequest
    , shelfMoveErrorMessage
    , shelfMoveResponseToResult
    , shelfVisibilitySettingDecoder
    , sourceHealthDecoder
    , sourceHealthListDecoder
    , sourceHealthRequest
    , specHttpBody
    , standardTimeout
    , storedVisibilityDecoder
    , streamEventDecoder
    , syndicationDecoder
    , syndicationExportDecoder
    , syndicationExportRequest
    , syndicationsRequest
    , transparencyMetricsDecoder
    , updateBlogPostRequest
    , updateLocationRequest
    , updateNotificationsRequest
    , updatePasswordRequest
    , updatePlacementFormatsRequest
    , updatePlacementVisibilityRequest
    , updateProfile
    , updateProfileVisibilityRequest
    , updateProgressRequest
    , updateShelfVisibilityRequest
    , updateSyndicationUrlRequest
    , uploadInboxDecoder
    , uploadInboxRequest
    , uploadTimeout
    , withBearer
    )

{-| Every HTTP call the SPA makes, and every decoder that reads a server
response. The large `exposing` list is deliberate: decoders are exported
so tests wire the REAL decoder into simulated effects — a hand-written
test mirror is what let the upload SSE wire format drift for months.
-}

import Api.Url
import Dict
import File exposing (File)
import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Stacks.Api.V1.AuthResponses as ProtoAuth
import Stacks.Api.V1.BookResponses as ProtoBookResp
import Stacks.Api.V1.BookshelfResponses as ProtoBookshelfResp
import Stacks.Api.V1.Requests as Requests
import Stacks.Api.V1.SourceResponses as ProtoSourceResp
import Stacks.Common.V1.Placement as ProtoPlacement
import Types.BlogPost exposing (BlogPostSummary, blogPostSummaryDecoder)
import Types.Book exposing (Book, Edition, bookDecoder)
import Types.Placement exposing (Placement, ReadingStatus, bookPlacementDecoder, parseReadingStatus, placementRefDecoder)
import Types.ProtoHelpers exposing (emptyToNothing)
import Url.Builder


baseUrl : String
baseUrl =
    ""


{-| WHICH credential a request carries, named rather than implied.

⛔ A NAMED CONSTRUCTOR AND NOT A `Bool`, AND THE REASON IS A GATE. Read the chain
before simplifying this:

1.  `scripts/check-session-expiry-coverage.sh` decides which endpoints are
    mandatorily authenticated by **matching a name** in each definition's body.
2.  A name is only matchable if it **appears at the call site** — the gate reads
    this file as text, so whatever carries the distinction has to be written out
    where the request is built.
3.  `True` and `False` have **no name to match**, and a call site passing a
    variable or a record field has no literal at all. So the first such site
    drops out of the gate's classification with nothing reporting the drop.

⚠️ The failure is silent and partial: the gate does not error, it classifies
fewer endpoints and keeps passing — and its own floor is an emptiness check, so
it stays green down to one remaining endpoint.

⚖️ `Session` is the mandatory marker the gate greps for and `Optional` the
maybe-authenticated one, which is the distinction the gate's two classes need.

⛔ **THREE CONSTRUCTORS, AND THE REASON IS NOT THE GATE — corrected 2026-10-26.**
An earlier version of this comment said `Optional Nothing` and `NoCredential`
must stay separate so the gate can tell them apart. **That is disprovable and
was disproved:** the gate computes `MANDATORY and not OPTIONAL`, a two-class
decision, so both are simply non-mandatory and it never needs to distinguish
them.

⚠️ Why a wrong reason here is worse than no reason: collapsing the two is
**behaviourally invisible**, so no test catches it — which makes this comment the
only guard. A guard carrying a disprovable reason invites the next reader to
check it, find it false, and collapse the constructors **with this comment as
licence.**

⚖️ **The reason that survives checking is a domain one.** `Optional` means _this
endpoint accepts a credential when the reader holds one_ — the 15
optionally-authenticated routes. `NoCredential` means _this endpoint never takes
one_. Collapsing them makes an endpoint that **refuses** credentials
indistinguishable from one that merely **lacks** one, which is this project's
absent-versus-declared-none distinction: a declared "none" can be checked
against intent, an absence cannot.

⚠️ And `Optional Nothing` is not even writable at most of those call sites: it
needs a `Maybe` in scope, and an unauthenticated endpoint has no token argument
to pass. The distinction is forced by the call sites, not just preferred.

**The four `NoCredential` requests, and they are now one kind:**

  - `resetPassword`, `requestListingRemoval`, `adminLogin`, `adminVerifyMfa` —
    `SameOrigin`, and unauthenticated: a state-changing POST at our own origin
    carrying no session. They are not CSRF targets, because there is no ambient
    authority for a cross-site request to borrow — each one carries its own
    capability token in the body, or IS the step that authenticates. ⚠️ They do
    still carry a PROOF, which is what `NoCredential (Maybe String)` holds the
    `Maybe` for.

⛔ **There was a fifth, and it was the example this comment led with — corrected
2026-10-28.** It was the upload byte PUT, described here as "`CrossOrigin`, a
`PUT` at third-party object storage", and that description was false: the server
had been returning a path on OUR origin since July, so the request was
same-origin, state-changing, and sending nothing. Enforcement then refused every
photo upload.

⚠️ The lesson is not "check the comments". The claim was _consistent_ — a
third-party destination with no credential is a coherent, safe-sounding design,
and three separate pieces of prose agreed on it while the code twenty lines
above the decoder said the opposite. What makes a destination claim checkable is
a URL the compiler can see, which is why the byte PUT now builds its own.

-}
type Credential
    = Session Credentials
    | Optional (Maybe Credentials)
    | NoCredential (Maybe String)


{-| What a signed-in reader carries: the bearer token, and the CSRF token the
double-submit scheme requires.

⛔ **OPAQUE, and the reason is that these two must travel together.** A CSRF
token is only a same-origin proof if it accompanies the credential it protects;
a call site that could hold one without the other would be able to send a
state-changing request with a session and no proof, which is the exact hole
being closed. Making it one value means there is no call site at which they can
come apart.

⚖️ **Why this is one value rather than a second parameter**, measured: either
shape costs the same today — about 45 signatures and 45 call sites. The
difference is the second touch. The work that moves sessions onto a cookie
removes the `Authorization` header entirely and deletes stored-token handling, at
which point a second parameter has to be removed from all 45 again — while this
record's SHAPE changes in one place and every call site keeps passing the single
value it already passes.

⚠️ The CSRF token is a `Maybe` because it is read from a cookie that may not be
there yet — a page loaded before the cookie was issued, or a test harness that
mints a session directly. An absent token is a request that will be REFUSED once
enforcement lands, which is the correct outcome and is why it is not defaulted
to `""`.

-}
type Credentials
    = Credentials { bearer : Maybe String, csrf : Maybe String }


{-| Build a reader's credentials. The only constructor, so the pairing above
cannot be bypassed.
-}
credentials : String -> Maybe String -> Credentials
credentials bearer csrf =
    Credentials { bearer = Just bearer, csrf = csrf }


{-| A session the SPA holds no bearer for, because the cookie carries it.

⛔ **THIS IS THE NORMAL STATE AFTER A RELOAD, and it was previously
unrepresentable.** The session cookie is `HttpOnly`, so JavaScript cannot read
it, and `GET /api/auth/me` answers with the account rather than a token. So a
reader who reloads is genuinely signed in while the SPA has no bearer to show
for it — and `Credentials` used to require one, which meant the only way to
survive a reload was to keep a copy of the token in `localStorage`.

⚖️ The proof is still carried, and must be: it is a property of the DOCUMENT,
not of the session, so it comes from the boot flags and is present whether or
not a bearer is. A write from this credential sends `x-csrf-token` and no
`Authorization`, and the cookie authenticates it — which is exactly the header
set `NoCredential` already produced for the signed-out login POST.

⚠️ Deliberately a separate constructor rather than widening `credentials/2`.
Twenty-two call sites pass a real bearer and should go on saying so in their
types; only the boot path has no bearer, and it should have to name that.

-}
cookieSession : Maybe String -> Credentials
cookieSession csrf =
    Credentials { bearer = Nothing, csrf = csrf }


{-| Replace the bearer token, keeping the same-origin proof.

⚖️ This is what a token REFRESH is: the credential that proves who you are gets
a new value, and the proof that the request came from a document on our origin
is unchanged — it is a property of the browsing context, not of the session.
Rebuilding the whole value from the refresh response would drop the CSRF token
and silently stop every subsequent write from proving itself.

-}
withBearer : String -> Credentials -> Credentials
withBearer bearer (Credentials creds) =
    Credentials { creds | bearer = Just bearer }



-- ⛔ `Destination` WAS HERE, AND DELETING IT IS THE POINT.
--
-- Its own docs called it "WHERE a request is going, as a decision rather than a
-- default", and "REQUIRED AT EVERY CALL SITE, so a new request cannot inherit
-- 'attach the credential' by saying nothing". The requirement was real; what it
-- bought was not. A decision every call site must state, where one answer is
-- always correct, is a ritual — and the ritual is what made the wrong answer
-- expressible.
--
--     type Destination = SameOrigin | CrossOrigin
--
-- It was DECLARED by the caller rather than derived from the URL, so
-- `requestHeaders SameOrigin (Session token)` at a foreign URL attached the
-- reader's bearer token. Two script gates related the declaration to the URL
-- text beside it, and both were sound only for the unlikely direction: nothing
-- could catch `SameOrigin` written beside an off-origin URL, because
-- `SameOrigin` is the ordinary-looking value every correct call site also uses.
--
-- ⚖️ It is gone rather than guarded because it had no `CrossOrigin` inhabitant
-- left. `putFileToR2` was the one, and it was replaced by `putUploadBytes` when
-- the upload PUT turned out to be same-origin all along — the destination was a
-- path on our own origin, so declaring it cross-origin sent no CSRF header and
-- every upload was refused. After that there was nothing in the codebase the
-- distinction described, and a type with one reachable value is a parameter
-- every call site must get right for no benefit.
--
-- What stops a credential reaching another origin now is `Api.Url`, whose
-- constructor cannot build a URL that leaves it. A compile error, not a gate.


{-| The one derivation of a request's headers, as DATA rather than as
`Http.Header`.

⛔ DATA, because `Http.Header` and `SimulatedEffect.Http.Header` are different
opaque types — the same constraint `Effect.elm` records about `Http.Expect`. So
production and the program-test harness each convert this list with a one-line
`List.map`, and there is **one** derivation rather than two that can disagree.

⚠️ A `CrossOrigin` destination yields NO credential header regardless of the
credential. The origin decision wins over the credential.

⛔ **WHAT THAT DOES NOT PROTECT, corrected 2026-10-26 because the earlier
wording overclaimed it.** `Destination` is **declared by the caller, not derived
from the URL** — so `requestHeaders SameOrigin (Session token)` against an
external URL still attaches the token. The precedence above defends
`CrossOrigin` + `Session`, which is the _unlikely_ mistake; it does nothing
against the likelier one, because `SameOrigin` is the ordinary-looking value a
hurried caller reaches for.

⚖️ So the real guard is not in this module: it is the assertion that **no request
whose URL is not `baseUrl`-derived carries an `Authorization` header** — URL
against destination, not destination alone. ⚠️ An assertion that only checks
`CrossOrigin ⇒ []` is this blind spot restated as coverage, and would pass while
the gap stands.

-}
requestHeaders : String -> Credential -> List ( String, String )
requestHeaders method credential =
    -- ⚠️ The scheme literal appears ONCE. It used to appear twice — the
    -- `Session` and `Optional (Just _)` arms each spelled `"Bearer " ++ token`
    -- — and Elm has no or-patterns, so collapsing them means mapping the
    -- credential to its token first. `scripts/check-one-credential-derivation.sh`
    -- counts the spellings, and two identical ones make its "there is one
    -- place" report read as a number to be interpreted rather than a fact.
    bearerHeader (tokenFor credential) ++ csrfHeader method (proofFor credential)


{-| The credential header, if there is a credential.

⚠️ Separated from the proof so the scheme literal stays in ONE place. Elm has no
or-patterns, so a `case` that handled bearer and proof together would spell
`"Bearer "` once per arm — and `scripts/check-one-credential-derivation.sh`
counts those spellings precisely so "there is one place" stays a fact.

-}
bearerHeader : Maybe Credentials -> List ( String, String )
bearerHeader maybeCreds =
    case maybeCreds of
        Nothing ->
            []

        Just (Credentials creds) ->
            case creds.bearer of
                -- ⛔ No bearer is not an error: the session cookie carries the
                -- session, and omitting the header is what lets it. An empty
                -- `Bearer ` would be a credential that cannot work, sent as
                -- though it could.
                Nothing ->
                    []

                Just bearer ->
                    [ ( "Authorization", "Bearer " ++ bearer ) ]


{-| The same-origin proof a credential carries, from whichever constructor holds
it.

⛔ **THIS IS THE FUNCTION WHOSE ABSENCE BROKE THE ADMIN GATE.** The proof used
to be reachable only through `Credentials`, so `NoCredential` — an endpoint that
takes no session — had none. That is right for a READ and wrong for a WRITE:
`adminLogin`, `adminVerifyMfa`, `resetPassword` and `requestListingRemoval` are
state-changing requests performed without a session, and enforcement refused
every one of them with `absent_header`.

⚖️ Found by the E2E suite against an enforcing stack, having already been found
once in the PLAN path and fixed only there. ⚠️ The reason it was missed twice is
the same both times: I measured which `Effect.public` sites were writes and
never asked the same question of the direct `Http.request` sites. A proof is a
property of the DOCUMENT, so every constructor has to be able to carry one.

-}
proofFor : Credential -> Maybe String
proofFor credential =
    case credential of
        Session (Credentials creds) ->
            creds.csrf

        Optional (Just (Credentials creds)) ->
            creds.csrf

        Optional Nothing ->
            Nothing

        NoCredential proof ->
            proof


{-| The double-submit proof, on state-changing requests only.

⛔ **ONLY ON UNSAFE METHODS, and the omission is as load-bearing as the
inclusion.** A token sent on every `GET` trains the server to see the header
everywhere, and the first thing anyone does with a header that is always present
is stop checking it where it matters. `safeMethod` below is the whole decision.

⚠️ **An absent token sends no header**, rather than an empty one. The server must
be able to tell "this client has no proof" from "this client proved nothing" —
the first is a request that should be refused once enforcement lands, and an
empty-string header would compare equal to an empty cookie and pass a careless
check.

⚖️ The value is NOT a secret. It is a cookie the page can read, echoed back to
prove the request came from a document on our origin rather than from a
cross-site form — which is why the cookie carrying it is deliberately readable.

-}
csrfHeader : String -> Maybe String -> List ( String, String )
csrfHeader method maybeCsrf =
    case ( safeMethod method, maybeCsrf ) of
        ( True, _ ) ->
            []

        ( False, Nothing ) ->
            []

        ( False, Just csrf ) ->
            [ ( "X-CSRF-Token", csrf ) ]


{-| Methods that do not change state, and so need no proof.

⚠️ `HEAD` and `OPTIONS` are listed with `GET` because the rule is about EFFECT,
not about which verbs this client happens to send today. A list that enumerated
only what `Api.elm` currently uses would silently start demanding a token the
first time someone added one of the others.

-}
safeMethod : String -> Bool
safeMethod method =
    List.member (String.toUpper method) [ "GET", "HEAD", "OPTIONS" ]


{-| Headers for a request whose proof does NOT come from a session credential.

⛔ **WHY THIS EXISTS, and it is a design error of mine that only a drive found.**
The proof began life as a field of `Credentials`, which exists only when there is
a bearer token. A logged-OUT visitor therefore had no proof — and
`POST /api/auth/login` is a state-changing request. Driven against the deployed
preview, the SPA's real login POST sent `content-type` and nothing else.

⚖️ The type error underneath: a credential is a property of the **session**, a
double-submit proof is a property of the **document**. Nesting the second inside
the first makes it unreachable exactly when there is no session, which is the
one case that matters for login fixation.

⚠️ 2208 unit tests passed throughout, because every one of them constructs a
`Credentials` in order to ask its question. The case with no credential at all is
the case no test thought to build.

-}
proofHeaders : String -> Maybe String -> List Http.Header
proofHeaders method maybeProof =
    csrfHeader method maybeProof
        |> List.map (\( name, value ) -> Http.header name value)


{-| The token a credential carries, if any.

⚠️ This is NOT the place to decide whether to send it — that is the destination's
call, above. This only answers "is there a token", so the three constructors
collapse to a `Maybe` for the one arm that needs it. `Optional Nothing` and
`NoCredential` answer the same way here and stay distinct at the call site,
which is where the distinction means something.

-}
tokenFor : Credential -> Maybe Credentials
tokenFor credential =
    case credential of
        Session creds ->
            Just creds

        Optional maybeCreds ->
            maybeCreds

        NoCredential _ ->
            Nothing


{-| `requestHeaders` converted to `elm/http`'s own header type.

⚠️ The conversion is one line and lives here so each call site is a declaration
rather than a declaration plus plumbing. The DATA form stays the shared thing —
`Http.Header` and `SimulatedEffect.Http.Header` are different opaque types, so
the program-test harness converts the same list into its own.

-}
httpHeaders : String -> Credential -> List Http.Header
httpHeaders method credential =
    requestHeaders method credential
        |> List.map (\( name, value ) -> Http.header name value)


{-| A request's data — method, url, JSON body — apart from the
`Http.request` that sends it. `elm-program-test` cannot run real
requests, so test translators build `SimulatedEffect`s; before this seam
they hand-copied url/method/body, and a drifted copy was invisible to
the whole suite. Both production and tests now consume the same spec.
-}
type alias RequestSpec =
    { method : String

    -- ⛔ A `SameOriginUrl`, NOT A `String`, AND THAT IS WHAT MAKES THE
    -- GUARANTEE LOAD-BEARING. `Api.Url.path` is the only way to build one and
    -- it cannot produce a URL that leaves our origin, so "the credential never
    -- reaches another origin" is a fact about this field's type rather than a
    -- property a script re-derives by parsing every builder.
    , url : Api.Url.SameOriginUrl
    , body : Maybe Encode.Value
    }


{-| Send a `RequestSpec` to an authenticated endpoint.

The production twin of the program-test harness's `authedRequestFromSpec`. A page
that decides WHICH request a Msg fires — as data, in a function its tests can
call — dispatches the answer through this, so the decision and the sending are
not two descriptions that can disagree.

-}
specHttpBody : RequestSpec -> Http.Body
specHttpBody spec =
    case spec.body of
        Just value ->
            Http.jsonBody value

        Nothing ->
            Http.emptyBody


{-| How long a request may hang before `elm/http` reports `Http.Timeout`.

⛔ `timeout = Nothing` means "wait forever", not "no timeout": a stalled
connection (sleeping machine, captive portal) never resolves, so
`RemoteData` never leaves `Loading` and the page's `Failure` branch —
where connectivity copy lives — is unreachable. Every request in this
file carries this value.

-}
standardTimeout : Maybe Float
standardTimeout =
    Just 15000


{-| The bound for a request whose body is a file.

Two minutes, not fifteen seconds, because this clock is measuring something
else. `standardTimeout` bounds _waiting for an answer_; an upload's elapsed time
is mostly **bytes crossing the wire**, and a phone photo on a weak connection can
legitimately take a minute. Cancelling that would turn a slow success into a
failure — the timeout would be the bug.

It is still bounded. A stalled upload that will never finish is exactly as
useless as a stalled read, and "wait forever" is not the alternative on offer.

-}
uploadTimeout : Maybe Float
uploadTimeout =
    Just 120000


type alias AuthResponse =
    { token : String
    , userId : String
    , email : String
    , displayName : String
    , handle : String
    , role : String
    , consentAnalytics : Bool
    , consentWritingAssistant : Bool
    }


{-| Adapter: proto AuthResponse (nested user) -> app AuthResponse (flat fields).
-}
fromProtoAuthResponse : ProtoAuth.AuthResponse -> AuthResponse
fromProtoAuthResponse proto =
    { token = proto.token
    , userId = proto.user.id
    , email = proto.user.email
    , displayName = proto.user.displayName
    , handle = proto.user.handle
    , role =
        if proto.user.role == "" then
            "user"

        else
            proto.user.role
    , consentAnalytics = proto.user.consentAnalytics
    , consentWritingAssistant = proto.user.consentWritingAssistant
    }


authResponseDecoder : Decoder AuthResponse
authResponseDecoder =
    Decode.map fromProtoAuthResponse ProtoAuth.decodeAuthResponse


{-| Decoder for the registration response.

The backend returns `{"message": "confirmation_email_sent"}` on HTTP 201 — it
does NOT return an auth token. We deliberately require the `"message"` key so a
missing/unexpected body fails loudly (Err BadBody) rather than silently
succeeding the way the lenient proto AuthResponse decoder would.

-}
registrationResponseDecoder : Decoder ()
registrationResponseDecoder =
    Decode.map (\_ -> ()) (Decode.field "message" Decode.string)


{-| The identification status of an uploaded image. Wire statuses:
`"pending"`, `"resolved"`, `"rejected"`, plus the SSE loop's synthetic
`"timeout"`; unknown strings read as `Pending` (still in flight), never
guessed terminal.

⛔ `"timeout"` is not a rejection: it used to decode to `Rejected`
with a null reason, so the reader was told their photo was refused when
the pipeline had simply not answered yet. `TimedOut` is its own state.

-}
type PollStatus
    = Pending
    | Resolved
    | Rejected
    | TimedOut


{-| The SSE frame from `GET /api/upload/:image_id/stream`.

`bookId` is present only when the status is Resolved and a single book was
identified; `isDuplicate` is True when the identified book is already on one of
the user's bookshelves.

-}
type alias PollResponse =
    { imageId : String
    , status : PollStatus
    , bookId : Maybe String
    , bookIds : List String
    , rejectionReason : Maybe String
    , isDuplicate : Bool
    }


{-| Decoder for SSE frames from `GET /api/upload/:image_id/stream`. There
is exactly ONE wire shape and the server owns it
(`ProtoJSON.poll_response/1`, mirrored by upload.proto): snake\_case, all
six keys always present (`book_ids` defaults `[]`, `is_duplicate`
`false`; `book_id`/`rejection_reason` arrive as JSON null). The decoder
matches that shape exactly — no defensive `oneOf` fallbacks that would
mask a server-side contract break.
-}
streamEventDecoder : Decoder PollResponse
streamEventDecoder =
    Decode.map6
        (\imageId status bookId bookIds rejectionReason isDuplicate ->
            { imageId = imageId
            , status =
                case status of
                    "resolved" ->
                        Resolved

                    "rejected" ->
                        Rejected

                    "timeout" ->
                        TimedOut

                    _ ->
                        Pending
            , bookId = Maybe.andThen emptyToNothing bookId
            , bookIds = bookIds
            , rejectionReason = Maybe.andThen emptyToNothing rejectionReason
            , isDuplicate = isDuplicate
            }
        )
        (Decode.field "image_id" Decode.string)
        (Decode.field "status" Decode.string)
        (Decode.field "book_id" (Decode.nullable Decode.string))
        (Decode.field "book_ids" (Decode.list Decode.string))
        (Decode.field "rejection_reason" (Decode.nullable Decode.string))
        (Decode.field "is_duplicate" Decode.bool)


{-| What an upload in the inbox is waiting for.

⛔ Not a scale from good to bad; never sum them. `AwaitingConfirmation`
is a job the reader can finish; `Failed` is news they were never given.
The navigation badge counts the first kind ONLY — a number no action can
clear is worse than no badge.

-}
type InboxKind
    = AwaitingConfirmation
    | Failed


{-| One unfinished upload — `stacks.common.v1.UploadInboxItem`.

`bookIds` are the candidates the reader has NOT already shelved by some other
route; the server does that filtering, because it is the only party that can
see the reader's bookshelves and the upload row at the same moment. Empty for a
`Failed` item, which has nothing to confirm.

`rejectionReason` is the same token vocabulary the SSE frame carries, so
`Page.Upload.failureFromRejection` maps it with no second table. That is the
whole reason the field is a token and not a sentence.

-}
type alias InboxItem =
    { imageId : String
    , kind : InboxKind
    , bookIds : List String
    , rejectionReason : Maybe String
    , retryable : Bool
    }


{-| The badge number, derived from the inbox itself.

⛔ This function is the ONLY definition of the count, and the list it is given
is the same list the inbox surface renders. The server deliberately ships no
count field alongside the items (see `stacks.common.v1.UploadInbox`): two
separately-derived numbers are two things that can disagree, and a badge that
disagrees with the page it points at teaches the reader to ignore it.

-}
awaitingConfirmationCount : List InboxItem -> Int
awaitingConfirmationCount items =
    List.length (List.filter (\item -> item.kind == AwaitingConfirmation) items)


inboxKindDecoder : Decoder InboxKind
inboxKindDecoder =
    Decode.string
        |> Decode.andThen
            (\raw ->
                case raw of
                    "awaiting_confirmation" ->
                        Decode.succeed AwaitingConfirmation

                    "failed" ->
                        Decode.succeed Failed

                    other ->
                        Decode.fail ("Unknown upload inbox kind: " ++ other)
            )


inboxItemDecoder : Decoder InboxItem
inboxItemDecoder =
    Decode.map5 InboxItem
        (Decode.field "image_id" Decode.string)
        (Decode.field "kind" inboxKindDecoder)
        (Decode.field "book_ids" (Decode.list Decode.string))
        (Decode.field "rejection_reason" (Decode.nullable Decode.string))
        (Decode.field "retryable" Decode.bool)


{-| `GET /api/uploads/inbox` — every upload this reader has not finished with.

Every field is required, for the same reason `streamEventDecoder`'s are: `StacksWeb.ProtoJSON.upload_inbox_item/1` emits all five on every
branch, `book_ids` defaulting to `[]`, `rejection_reason` arriving as JSON
`null` and `retryable` as a bare boolean. A `Decode.succeed` fallback here would
mean a wire rename could never redden a test — and `retryable` is the field
where that would hurt most, because its safe default is `False` and a decoder
that quietly supplied one would hide the button rather than the bug.

-}
uploadInboxDecoder : Decoder (List InboxItem)
uploadInboxDecoder =
    Decode.field "items" (Decode.list inboxItemDecoder)


{-| `GET /api/uploads/inbox` — what is waiting for this reader, as data.
-}
uploadInboxRequest : RequestSpec
uploadInboxRequest =
    { method = "GET"
    , url = Api.Url.path [ "api", "uploads", "inbox" ] []
    , body = Nothing
    }


{-| One bookstore event for an author, scraped from the shop's own page.
`eventDate` is Nothing when the page states none — the shop's page has the
details, and the card must not pretend to a date it doesn't hold.
-}
type alias AuthorEvent =
    { id : String
    , title : String
    , eventDate : Maybe String
    , location : Maybe String
    , url : Maybe String
    , storeName : Maybe String
    }


authorEventDecoder : Decoder AuthorEvent
authorEventDecoder =
    Decode.map6 AuthorEvent
        (Decode.field "id" Decode.string)
        (Decode.field "title" Decode.string)
        (Decode.field "event_date" (Decode.nullable Decode.string))
        (Decode.field "location" (Decode.nullable Decode.string))
        (Decode.field "url" (Decode.nullable Decode.string))
        (Decode.field "store_name" (Decode.nullable Decode.string))


{-| `GET /api/authors/:id/events` — an author's readings and signings. Public:
no token, and none is sent even when the viewer has one.
-}
getAuthorEventsRequest : String -> RequestSpec
getAuthorEventsRequest authorId =
    { method = "GET"
    , url = Api.Url.path [ "api", "authors", authorId, "events" ] []
    , body = Nothing
    }


{-| The `{events: [...]}` envelope an author's event list arrives in.
-}
authorEventsDecoder : Decoder (List AuthorEvent)
authorEventsDecoder =
    Decode.field "events" (Decode.list authorEventDecoder)


{-| An import's summary — the progress counters the reader watches while the
job works through their library, and the durable record afterwards.
-}
type alias LibraryImport =
    { id : String
    , status : String
    , filename : String
    , rowCount : Int
    , processedCount : Int
    , shelvedCount : Int
    , duplicateCount : Int
    , unverifiedCount : Int
    , unreadableCount : Int
    }


{-| One row of the per-row report. `outcome` is `Nothing` until the job
reaches the row.
-}
type alias ImportRow =
    { rowNumber : Int
    , title : String
    , author : String
    , isbn13 : String
    , goodreadsShelf : String
    , outcome : Maybe String
    , reason : Maybe String
    }


{-| Upload refusals the page owes distinct copy for.

⚠️ The status is NOT the discriminant, which this type previously assumed. 409
and 413 are one refusal each, but **four** different refusals arrive as 422, and
collapsing them told a reader with a perfectly good Goodreads export that it
wasn't one:

  - `no_rows` — a real export, correctly recognised, with nothing under the
    header. Nothing is wrong with the file's format; there is nothing in it.
  - `unrecognised_format` — the headers aren't Goodreads'. The server also sends
    the headers it DID find, which is the one piece of information that lets a
    reader work out they exported the wrong thing, and which was thrown away.
  - `missing_file` / `unreadable_upload: …` — the multipart part never arrived,
    or the temp file could not be read. Nothing about the reader's file is
    known to be wrong, so blaming it is a guess, and it sends them to re-export
    from Goodreads for no reason.

So the body's `error` field is read. It is a small, stable vocabulary, and the
`_` branch below keeps an unknown token from becoming a decode failure.

-}
type ImportError
    = ImportInProgress
    | ImportFileTooLarge
    | ImportUnrecognisedFormat (List String)
    | ImportNoRows
    | ImportUploadIncomplete
    | ImportRequestFailed Http.Error


libraryImportDecoder : Decoder LibraryImport
libraryImportDecoder =
    Decode.succeed LibraryImport
        |> andMap (Decode.field "id" Decode.string)
        |> andMap (Decode.field "status" Decode.string)
        |> andMap (textOrBlank "filename")
        |> andMap (Decode.field "row_count" Decode.int)
        |> andMap (Decode.field "processed_count" Decode.int)
        |> andMap (Decode.field "shelved_count" Decode.int)
        |> andMap (Decode.field "duplicate_count" Decode.int)
        |> andMap (Decode.field "unverified_count" Decode.int)
        |> andMap (Decode.field "unreadable_count" Decode.int)


{-| A string field that may be absent, null, or not a string at all, as blank.

The same shape the generated proto decoders use, so a server that stops sending a
field degrades the one cell rather than the whole response. Note the third case:
`oneOf` falls through on a type mismatch too, so `"title": 42` becomes `""`
rather than failing. That is the same tolerance the generated decoders have and
it is deliberate here, but it is wider than "absent or null" and worth naming.

-}
textOrBlank : String -> Decoder String
textOrBlank name =
    Decode.oneOf
        [ Decode.field name Decode.string
        , Decode.succeed ""
        ]


importRowDecoder : Decoder ImportRow
importRowDecoder =
    -- `outcome` and `reason` were already nullable here; these four were not, and an
    -- unreadable row nulls exactly these four. Because the report decodes as a
    -- `Decode.list`, one such row failed the whole response and the page showed "the
    -- report didn't load" forever. Tolerating absent-or-null matches what this
    -- project's GENERATED decoders already do (`oneOf [field, succeed ""]`), which the
    -- hand-written one dropped.
    Decode.map7 ImportRow
        (Decode.field "row_number" Decode.int)
        (textOrBlank "title")
        (textOrBlank "author")
        (textOrBlank "isbn13")
        (textOrBlank "goodreads_shelf")
        (Decode.field "outcome" (Decode.nullable Decode.string))
        (Decode.field "reason" (Decode.nullable Decode.string))


{-| `POST /api/imports/goodreads` — the export CSV as a multipart `file`.
The parse happens synchronously server-side, so a refusal (wrong file, one
already running, too large) arrives on THIS response, not minutes later.
-}
createGoodreadsImport : Credentials -> File -> (Result ImportError LibraryImport -> msg) -> Cmd msg
createGoodreadsImport token file toMsg =
    Http.request
        { method = "POST"
        , headers = httpHeaders "POST" (Session token)
        , url = baseUrl ++ "/api/imports/goodreads"
        , body = Http.multipartBody [ Http.filePart "file" file ]
        , expect = expectImport toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }


expectImport : (Result ImportError LibraryImport -> msg) -> Http.Expect msg
expectImport toMsg =
    Http.expectStringResponse toMsg <|
        \response ->
            case response of
                Http.GoodStatus_ _ body ->
                    Decode.decodeString (Decode.field "import" libraryImportDecoder) body
                        |> Result.mapError
                            (\err -> ImportRequestFailed (Http.BadBody (Decode.errorToString err)))

                Http.BadStatus_ metadata body ->
                    case metadata.statusCode of
                        409 ->
                            Err ImportInProgress

                        413 ->
                            Err ImportFileTooLarge

                        422 ->
                            Err (importRefusal body)

                        status ->
                            Err (ImportRequestFailed (Http.BadStatus status))

                Http.BadUrl_ url ->
                    Err (ImportRequestFailed (Http.BadUrl url))

                Http.Timeout_ ->
                    Err (ImportRequestFailed Http.Timeout)

                Http.NetworkError_ ->
                    Err (ImportRequestFailed Http.NetworkError)


{-| Which of the four 422s came back.

An unparseable body, or a token this build has never heard of, falls to
`ImportUploadIncomplete` — the one whose copy makes no claim about the reader's
file. Guessing "wrong format" on an unknown token is how the collapsed version
misled people in the first place.

-}
importRefusal : String -> ImportError
importRefusal body =
    let
        token =
            Decode.decodeString (Decode.field "error" Decode.string) body
                |> Result.withDefault ""

        headers =
            Decode.decodeString
                (Decode.field "found_headers" (Decode.list Decode.string))
                body
                |> Result.withDefault []
    in
    case token of
        "no_rows" ->
            ImportNoRows

        "unrecognised_format" ->
            ImportUnrecognisedFormat headers

        _ ->
            ImportUploadIncomplete


{-| `GET /api/imports/:id` — one import's progress, as data.

⚠️ The id is percent-encoded, where the old builder concatenated it.

-}
importRequest : String -> RequestSpec
importRequest importId =
    { method = "GET"
    , url = Api.Url.path [ "api", "imports", importId ] []
    , body = Nothing
    }


{-| `GET /api/imports/:id/rows` — one import's per-row outcomes, as data.
-}
importRowsRequest : String -> RequestSpec
importRowsRequest importId =
    { method = "GET"
    , url = Api.Url.path [ "api", "imports", importId, "rows" ] []
    , body = Nothing
    }


{-| A request failure that may carry the server-named wait. Exists
because `Http.Error` structurally cannot: `expectJson` collapses non-2xx
into `BadStatus Int` — the status survives, the headers do not, and
`retry-after` is a header. Built with `expectStringResponse` so the 429
branch can read it; everything else maps onto the ordinary `Http.Error`.
-}
type RequestError
    = RateLimited (Maybe Int)
    | RequestFailed Http.Error


{-| The wait a 429 named, in seconds — `Nothing` when it named none, or named
something that is not a positive whole number of seconds.

RFC 9110 permits `retry-after` to be an HTTP-date as well as a delay in seconds,
and this deliberately does **not** parse the date form. Turning a date into a
delay needs the current time, which is not available where a response is
resolved, and guessing is worse than not knowing: the copy that falls back to
`Nothing` is true, and a wrong number is not. `StacksWeb.Plugs.RateLimiter`
sends the delay form.

`Http.Metadata.headers` is keyed by lower-cased header name, so this looks up
one spelling and there is no second one to get wrong.

-}
retryAfterSeconds : Http.Metadata -> Maybe Int
retryAfterSeconds metadata =
    Dict.get "retry-after" metadata.headers
        |> Maybe.map String.trim
        |> Maybe.andThen String.toInt
        |> Maybe.andThen
            (\seconds ->
                if seconds > 0 then
                    Just seconds

                else
                    Nothing
            )


{-| Classify a `Http.BadStatus_` as either the rate limiter or something else.

One place decides what "throttled" means, so every `:auth` endpoint agrees.

-}
badStatusToRequestError : Http.Metadata -> RequestError
badStatusToRequestError metadata =
    if metadata.statusCode == 429 then
        RateLimited (retryAfterSeconds metadata)

    else
        RequestFailed (Http.BadStatus metadata.statusCode)


{-| The `Http.Response` → `Result RequestError a` translation, given a decoder
for the 2xx body.

Exported (via `resolveAuthResponse` / `resolveNoContent`) so `TestHelpers`'
simulated effects run the **real** resolver rather than a hand-written mirror of
it. `registerResponseResult` used to be such a mirror, and is the record of
what mirrors cost: the copy and the fixtures agree with each other while both
disagree with the server, and the suite stays green through a wire rename.

-}
resolveRequest : (String -> Result String a) -> Http.Response String -> Result RequestError a
resolveRequest decode response =
    case response of
        Http.BadUrl_ url ->
            Err (RequestFailed (Http.BadUrl url))

        Http.Timeout_ ->
            Err (RequestFailed Http.Timeout)

        Http.NetworkError_ ->
            Err (RequestFailed Http.NetworkError)

        Http.BadStatus_ metadata _ ->
            Err (badStatusToRequestError metadata)

        Http.GoodStatus_ _ bodyText ->
            decode bodyText |> Result.mapError (Http.BadBody >> RequestFailed)


{-| Resolver for a sign-in response. Shared with the program-test harness.
-}
resolveAuthResponse : Http.Response String -> Result RequestError AuthResponse
resolveAuthResponse =
    resolveRequest
        (Decode.decodeString authResponseDecoder >> Result.mapError Decode.errorToString)


{-| Resolver for an endpoint whose success body carries nothing the caller may
act on — `forgot-password` and `resend-confirmation`, both of which answer
identically for every address on purpose. Shared with the program-test harness.
-}
resolveNoContent : Http.Response String -> Result RequestError ()
resolveNoContent =
    resolveRequest (\_ -> Ok ())


{-| A registration failure.

A 422 carries per-field validation errors (keyed by field name — `email`,
`password`, `display_name`) so the UI can explain the _actual_ problem rather
than guessing. A 429 carries the rate limiter's wait. Every other
failure (network, timeout, unexpected status, or a 422 whose body we could not
parse) is a `RegisterRequestFailed`.

-}
type RegisterError
    = RegisterValidationFailed (List ( String, List String ))
    | RegisterRateLimited (Maybe Int)
    | RegisterInviteRefused String
    | RegisterRequestFailed Http.Error


{-| Decode the backend's `{"errors": {field: [msg,...]}}` 422 body. See
`format_errors/1` in the Elixir `StacksWeb.ChangesetHelpers`.
-}
registerErrorsDecoder : Decoder (List ( String, List String ))
registerErrorsDecoder =
    Decode.field "errors" (Decode.keyValuePairs (Decode.list Decode.string))


{-| The invite gate's refusal body — only `invite_*` reasons qualify, so an
unrelated `{"error":...}` still reads as its plain HTTP status.
-}
inviteErrorDecoder : Decoder String
inviteErrorDecoder =
    Decode.field "error" Decode.string
        |> Decode.andThen
            (\reason ->
                if String.startsWith "invite_" reason then
                    Decode.succeed reason

                else
                    Decode.fail "not an invite refusal"
            )


{-| What `POST /api/auth/invite/check` says about a redeemable code.
Deliberately tiny: the server never reveals the note, the bound address, or a
redeemer — `emailBound` is a boolean so the form can say "written for a
specific address" without naming it.
-}
type alias InviteStatus =
    { expiresAt : Maybe String
    , emailBound : Bool
    }


inviteStatusDecoder : Decoder InviteStatus
inviteStatusDecoder =
    Decode.map2 InviteStatus
        (Decode.field "expires_at" (Decode.nullable Decode.string))
        (Decode.field "email_bound" Decode.bool)


{-| `POST /api/auth/invite/check` — look an invitation code up before offering
the Register form.

The four refusals arrive as plain `BadStatus`; the status alone tells them
apart, so the card maps status to copy and never reads the body.

A POST for what reads like a lookup, because the code is a credential and the
server logs every request path: in the path it would be written into the
application log on every attempt. In the body it is filterable, and the server
filters it.

-}
checkInviteRequest : String -> RequestSpec
checkInviteRequest code =
    { method = "POST"
    , url = Api.Url.path [ "api", "auth", "invite", "check" ] []
    , body = Just (Encode.object [ ( "code", Encode.string code ) ])
    }


{-| `POST /api/auth/register`. The invite code travels with the credentials —
registration is invite-only, and a code checked but not sent is a code not
enforced.
-}
registerRequest :
    { email : String, password : String, displayName : String, inviteCode : String }
    -> RequestSpec
registerRequest body =
    { method = "POST"
    , url = Api.Url.path [ "api", "auth", "register" ] []
    , body =
        Just
            (Requests.encodeRegisterRequest
                { email = body.email
                , password = body.password
                , displayName = body.displayName
                , inviteCode = body.inviteCode
                }
            )
    }


{-| Resolver for a registration response. Shared with the program-test harness.
-}
resolveRegister : Http.Response String -> Result RegisterError ()
resolveRegister response =
    case response of
        Http.BadUrl_ url ->
            Err (RegisterRequestFailed (Http.BadUrl url))

        Http.Timeout_ ->
            Err (RegisterRequestFailed Http.Timeout)

        Http.NetworkError_ ->
            Err (RegisterRequestFailed Http.NetworkError)

        Http.BadStatus_ metadata bodyText ->
            if metadata.statusCode == 422 then
                case Decode.decodeString registerErrorsDecoder bodyText of
                    Ok errors ->
                        Err (RegisterValidationFailed errors)

                    Err _ ->
                        Err (RegisterRequestFailed (Http.BadStatus metadata.statusCode))

            else if metadata.statusCode == 429 then
                Err (RegisterRateLimited (retryAfterSeconds metadata))

            else
                case Decode.decodeString inviteErrorDecoder bodyText of
                    Ok reason ->
                        Err (RegisterInviteRefused reason)

                    Err _ ->
                        Err (RegisterRequestFailed (Http.BadStatus metadata.statusCode))

        Http.GoodStatus_ _ bodyText ->
            case Decode.decodeString registrationResponseDecoder bodyText of
                Ok value ->
                    Ok value

                Err err ->
                    Err (RegisterRequestFailed (Http.BadBody (Decode.errorToString err)))


{-| `POST /api/auth/login`. Answered with `RequestError` rather than
`Http.Error` so a 429 arrives carrying the wait the server named: this endpoint
is in the `:auth` rate-limit bucket, the tightest in the app, and a mistyped
password is the commonest way a reader reaches it.
-}
loginRequest : { email : String, password : String } -> RequestSpec
loginRequest body =
    { method = "POST"
    , url = Api.Url.path [ "api", "auth", "login" ] []
    , body =
        Just
            (Requests.encodeLoginRequest
                { email = body.email
                , password = body.password
                }
            )
    }


{-| `POST /api/auth/forgot-password` — request a password-reset email.

The backend always answers 200 (no user enumeration), so a caller can tell a
throttle from a transport failure and never one address from another.

-}
forgotPasswordRequest : String -> RequestSpec
forgotPasswordRequest email =
    { method = "POST"
    , url = Api.Url.path [ "api", "auth", "forgot-password" ] []
    , body = Just (Encode.object [ ( "email", Encode.string email ) ])
    }


{-| `POST /api/auth/resend-confirmation` — ask for a fresh confirmation link.

Same shape as `forgotPasswordRequest` and for the same reason: the backend
answers identically for an address awaiting confirmation, one already
confirmed, and one with no account at all.

-}
resendConfirmationRequest : String -> RequestSpec
resendConfirmationRequest email =
    { method = "POST"
    , url = Api.Url.path [ "api", "auth", "resend-confirmation" ] []
    , body = Just (Encode.object [ ( "email", Encode.string email ) ])
    }


{-| `POST /api/auth/reset-password` — completing a password reset, as data.

⛔ NO CREDENTIAL, DECLARED, as in the builder this replaces: the reset token in
the body IS the authentication, and the asker has no session to carry. The proof
goes to `Effect.public`, which is what this endpoint checks.

-}
resetPasswordRequest : { token : String, password : String } -> RequestSpec
resetPasswordRequest body =
    { method = "POST"
    , url = Api.Url.path [ "api", "auth", "reset-password" ] []
    , body =
        Just
            (Encode.object
                [ ( "token", Encode.string body.token )
                , ( "password", Encode.string body.password )
                ]
            )
    }


{-| The outcome of a listing-removal request.

Two outcomes, kept distinct on purpose. A request from an address on the listing's own
domain is applied immediately; anything else is recorded and waits for a human. Telling a
business their listing is gone when it is still live would be worse than telling them it
is pending, so the caller must not be able to collapse these into "success".

-}
type RemovalOutcome
    = Removed
    | PendingReview


{-| `POST /api/listings/removal` — a business owner asking to be delisted, as data.

⛔ NO CREDENTIAL, DECLARED — and the declaration is the point, as it was in the
builder this replaces. The asker is not a reader: they have no session, so there
is no ambient authority for a cross-site request to borrow and this is not a CSRF
target. `Effect.public` takes the proof token instead, which is what this
endpoint actually authenticates against.

-}
requestListingRemovalRequest : { url : String, email : String, reason : String } -> RequestSpec
requestListingRemovalRequest body =
    { method = "POST"
    , url = Api.Url.path [ "api", "listings", "removal" ] []
    , body =
        Just
            (Encode.object
                [ ( "url", Encode.string body.url )
                , ( "email", Encode.string body.email )
                , ( "reason", Encode.string body.reason )
                ]
            )
    }


removalOutcomeDecoder : Decoder RemovalOutcome
removalOutcomeDecoder =
    Decode.field "status" Decode.string
        |> Decode.andThen
            (\status ->
                case status of
                    "removed" ->
                        Decode.succeed Removed

                    "pending_review" ->
                        Decode.succeed PendingReview

                    other ->
                        Decode.fail ("unknown removal status: " ++ other)
            )


{-| True when an `Http.Error` is an authentication failure (HTTP 401) from an
authenticated request — the signal the global session-expiry interceptor uses to
distinguish an expired/revoked token from any other load failure. A 403 is NOT
unauthorized here: it is used for the age-gate and stays local to the page.
-}
isUnauthorized : Http.Error -> Bool
isUnauthorized err =
    case err of
        Http.BadStatus 401 ->
            True

        _ ->
            False


{-| True when an admin request was refused for want of a live, MFA-verified
elevation — the signal an admin page uses to hand the operator back to the gate.

⛔ **Two statuses, because the admin chain refuses in two places.**
`AdminAuthPipeline` answers **401** when the operator holds no admin session at
all; `RequireMFA` answers **403 `mfa_required`** when they hold one whose
verification has lapsed. Only the first was ever matched (`isUnauthorized` is
401-only), so an operator whose 30-minute window ran out got a generic "Action
failed. Please try again." on a page that could never succeed again, with no
way back to the gate but a reload.

⚠️ **Deliberately NOT folded into `isUnauthorized`.** That predicate is used by
every ordinary page, where a 403 means the age-gate and must stay local — see
its own docstring. Widening it would send a reader who hit the age-gate to a
session-expiry path. This one is for `/api/admin/*` callers only.

⚠️ A 403 from an admin route is taken as "needs elevation" without reading the
body, which also catches a role refusal. That is today's behaviour either way;
making a non-owner get a 404 rather than the MFA prompt is its own change.

-}
needsAdminElevation : Http.Error -> Bool
needsAdminElevation err =
    case err of
        Http.BadStatus 401 ->
            True

        Http.BadStatus 403 ->
            True

        _ ->
            False


{-| `needsAdminElevation`, for a request that was resolved rather than built.

⚖️ A sibling rather than a widening, because the two error types answer different
questions. `RequestError` distinguishes a rate limit from everything else, and a
**429 is emphatically not an elevation problem** — telling an operator to
re-authenticate because the server asked them to slow down would send them
through MFA to no effect.

⛔ Exists because the admin pages' requests became plans. `Api.resolveNoContent`
yields `Result RequestError ()`, so the pages that answer a 403 by sending the
operator back to the gate can no longer hand their error to the `Http.Error`
predicate. Unwrapping at each call site was the alternative; one named predicate
beside its twin is the same thing said once.

-}
needsAdminElevationOf : RequestError -> Bool
needsAdminElevationOf err =
    case err of
        RateLimited _ ->
            False

        RequestFailed httpError ->
            needsAdminElevation httpError


{-| True when an `Http.Error` is a 404 — the signal a resource is gone or hidden
(e.g. a blog post that resolves to `:hidden` after a block), so the caller can
render a graceful "no longer available" state instead of a technical error.
-}
isNotFound : Http.Error -> Bool
isNotFound err =
    case err of
        Http.BadStatus 404 ->
            True

        _ ->
            False


{-| An authenticated request's credential AND the handler for the one
failure every authed request can suffer: the session is gone.

⛔ A type, not a convention: with a bare token + callback, a 401 is just
another `Err`, and noticing it was opt-in — three settings forms did not
opt in and rendered "something went wrong" against a dead session. The
constructor demands a session-expiry msg, so a call site that ignores
expiry does not compile.

-}
type Authed err ok msg
    = Authed
        { token : Credentials
        , onExpired : msg
        , onResult : Result err ok -> msg
        }


{-| Build the credential-plus-handlers an authenticated endpoint requires.

The record is the gate: `onExpired` cannot be omitted, defaulted, or inferred.

-}
authed :
    Credentials
    -> { onExpired : msg, onResult : Result err ok -> msg }
    -> Authed err ok msg
authed token handlers =
    Authed
        { token = token
        , onExpired = handlers.onExpired
        , onResult = handlers.onResult
        }


{-| The `Authorization` header for an authenticated request. Unconditional by
construction — an `Authed` always holds a token — which is what makes a 401 from
one of these requests unambiguous.

`scripts/check-session-expiry-coverage.sh` reads this function's name to decide
which `Api` endpoints are mandatorily authenticated, so keep the header
construction here rather than inlining it at a call site.

-}
authedHeaders : String -> Authed err ok msg -> List Http.Header
authedHeaders method (Authed request) =
    httpHeaders method (Session request.token)


{-| The `Http.Expect` for an authenticated request: a 401 is diverted to
`onExpired` before the endpoint's own resolver ever sees the response.

Built on `expectStringResponse` rather than `expectJson`/`expectWhatever`
because those two collapse every non-2xx into an opaque `BadStatus` after the
fact — by then the status is a number in an error value that a caller may
ignore. Here the branch happens before the caller is handed anything.

-}
authedExpect :
    (Http.Response String -> Result err ok)
    -> Authed err ok msg
    -> Http.Expect msg
authedExpect resolve request =
    Http.expectStringResponse unwrapNever
        (\response -> Ok (interpretAuthed resolve request response))


{-| `Http.expectStringResponse` insists on a `Result`; `interpretAuthed` already
produces the final message, so the error side is uninhabited.
-}
unwrapNever : Result Never a -> a
unwrapNever result =
    case result of
        Ok value ->
            value

        Err impossible ->
            never impossible


{-| The whole 401 decision, as a pure function of the response — so it can be
tested directly instead of through a simulated effect that mirrors it (,
: a test that re-implements the thing under test agrees only with itself).
-}
interpretAuthed :
    (Http.Response String -> Result err ok)
    -> Authed err ok msg
    -> Http.Response String
    -> msg
interpretAuthed resolve (Authed request) response =
    interceptExpiry request.onExpired (resolve >> request.onResult) response


{-| What a 401 means on a request that definitely carried a credential, as one
function: the session is gone, so it becomes the expiry msg and the endpoint's
own handler never sees it.

⛔ ONE function because there are now TWO request paths — `Api.Authed` and
`Effect.authed`'s plan — and a status code that means "your session ended" on
one of them must not mean "something went wrong" on the other. Both route
through here, so there is a single decision to read, test and change rather than
two that agree only until someone edits one of them.

⚠️ `Effect.public` deliberately does NOT route through here, and that is the
distinction between the two plan constructors rather than an omission. An
endpoint that answers an anonymous reader can 401 for a reason that is not
expiry — `POST /api/auth/login` with the wrong password is the standing example
— and sending those to the expiry interceptor would sign out a visitor who was
never signed in. A public plan's 401 stays with the handler that asked for it.

⛔ **THE STATUS CODE IS NOT THE SIGNAL; THE SERVER'S REASON TOKEN IS.** This
read `metadata.statusCode == 401` and nothing else, which re-made a decision the
server had deliberately been changed to make for us — see `refusalToken`, which
is now the one place either request path reads it.

⚖️ **What the three reasons mean HERE, which is not what they mean at boot.**
The question at boot is "is this browser signed in?", so a first-time visitor is
one of the answers. The question here is narrower and the type answers half of
it already: an `Authed` always carries a credential, so this response is the
server refusing one we definitely sent.

  - `SessionWasRefused` — a session was presented and refused. The session is
    over.
  - `AnotherReason` — the server named something else (`unauthorized`,
    `invalid_token`, `token_expired`). On a request that carried a credential,
    that is still the credential not being accepted, so the session is over.
    ⚠️ This is also what keeps the MIXED-TRANSPORT case working from the other
    side: should the server ever stop reporting a refused cookie sent alongside
    a bearer as `session_expired` — as an earlier version of
    `AuthErrorHandler` did, by keying on Guardian's type rather than on the
    rejection — the reader still reaches the expiry path rather than a page
    error, because a client-side match on one literal is not what decides it.
  - `ReasonUnreadable` — the answer did not come from the application (every
    401 the SPA can receive carries a readable token; `refusalToken` records the
    measurement). So it is NOT evidence about the session, and signing the
    reader out on it is the defect this reason token exists to prevent, wearing
    the opposite face: an unexplained sign-out, mid-journey, on a proxy blip.
    It goes to the endpoint's own handler, whose failure state is a retry — the
    same answer the boot screen gives for not knowing, in the terms a page has.

⚠️ **NOT a third msg on the plan's record, and the reasoning rather than the
default.** `onExpired` earns its field twice over: the mistake it prevents is
FORGETTING a case whose consequence is destructive, and the caller holds
information the seam does not — where to send the reader, which draft to park on
the way. A third field has neither property. Every caller would fill it with the
failure handler it already passes as `onResponse`, so it would be ceremony at
every authenticated call site that adds no decision, and a field everyone fills
identically is a field someone eventually fills wrongly. Falling through to
`onResponse` IS "render your ordinary failure", said once, here, where the
reasoning can be read.

⚠️ **The residual, named rather than implied.** A page whose own result handler
re-tests the status with `isUnauthorized` will still re-classify an unreadable
401 as an expiry, so this is correct at the seam and not yet end-to-end for
those pages. MEASURED: five pages build authenticated plans AND still call
`isUnauthorized` themselves — `Page.Upload`, `Page.BookDetail`,
`Page.Bookshelf`, `Page.Bookshelf.ReadingPile` and `Page.Settings.Profile`, 21
such calls across 28 plans. They are the population of the sweep that removes
those re-tests, and the two changes meet in the same handlers.

-}
interceptExpiry : msg -> (Http.Response String -> msg) -> Http.Response String -> msg
interceptExpiry onExpired onResponse response =
    case response of
        Http.BadStatus_ metadata body ->
            if metadata.statusCode == 401 then
                case refusalToken body of
                    SessionWasRefused ->
                        onExpired

                    AnotherReason ->
                        onExpired

                    ReasonUnreadable ->
                        onResponse response

            else
                onResponse response

        _ ->
            onResponse response


{-| Resolver for an authenticated endpoint whose 2xx body is ignored — the
`Http.expectWhatever` equivalent.
-}
resolveWhatever : Http.Response String -> Result Http.Error ()
resolveWhatever =
    resolveBody (\_ -> Ok ())


{-| Resolver for an authenticated endpoint whose 2xx body is JSON — the
`Http.expectJson` equivalent.
-}
resolveJson : Decoder a -> Http.Response String -> Result Http.Error a
resolveJson decoder =
    resolveBody (Decode.decodeString decoder >> Result.mapError Decode.errorToString)


{-| The standard `Http.Response` → `Result Http.Error` translation that
`expectJson`/`expectWhatever` perform internally and do not export. The 401 case
never reaches here: `interpretAuthed` has already claimed it.
-}
resolveBody : (String -> Result String a) -> Http.Response String -> Result Http.Error a
resolveBody decode response =
    case response of
        Http.BadUrl_ url ->
            Err (Http.BadUrl url)

        Http.Timeout_ ->
            Err Http.Timeout

        Http.NetworkError_ ->
            Err Http.NetworkError

        Http.BadStatus_ metadata _ ->
            Err (Http.BadStatus metadata.statusCode)

        Http.GoodStatus_ _ bodyText ->
            decode bodyText |> Result.mapError Http.BadBody


{-| `POST /api/auth/refresh` — exchange a still-valid access token for a fresh
one before it expires. The 200 body is byte-identical to login's, so
`authResponseDecoder` reads it; a 401 means the session is no longer renewable
and the caller falls through to the session-expiry interceptor.
-}
refreshRequest : RequestSpec
refreshRequest =
    { method = "POST"
    , url = Api.Url.path [ "api", "auth", "refresh" ] []
    , body = Nothing
    }


{-| `DELETE /api/auth/logout` — ending the session, as data.

⚖️ Authenticated, so the plan takes an `onExpired` — and the sensible answer
is the same thing logging out does. A 401 means the session this request wanted
to end had already ended, which is the outcome the caller was asking for.

-}
logoutRequest : RequestSpec
logoutRequest =
    { method = "DELETE"
    , url = Api.Url.path [ "api", "auth", "logout" ] []
    , body = Nothing
    }


{-| A single curated transparency signal, carrying the teaching metadata the
public `/metrics` page renders as a "why we measure this" tooltip. Shared by both
the live signals and the durable aggregates. `value` is a plain number (a rate, a
count, a ratio, or a boolean-as-0/1) interpreted per `unit`.
-}
type alias TransparencyEntry =
    { key : String
    , label : String
    , what : String
    , how : String
    , why : String
    , unit : String
    , value : Float
    }


{-| The live-signals section of the transparency payload. The backend degrades to
`"unavailable"` (rather than an error) when Prometheus is unconfigured or every
whitelisted query fails, so the page can render the durable section regardless.
-}
type LiveSignals
    = LiveSignals (List TransparencyEntry)
    | LiveUnavailable


{-| The full public transparency payload (`GET /api/transparency/metrics`):
`{live, durable, generated_at, cache_ttl}` from `Stacks.Transparency.metrics/0`.
-}
type alias TransparencyMetrics =
    { live : LiveSignals
    , durable : List TransparencyEntry
    , generatedAt : String
    , cacheTtl : Int
    }


transparencyEntryDecoder : Decoder TransparencyEntry
transparencyEntryDecoder =
    Decode.map7 TransparencyEntry
        (Decode.field "key" Decode.string)
        (Decode.field "label" Decode.string)
        (Decode.field "what" Decode.string)
        (Decode.field "how" Decode.string)
        (Decode.field "why" Decode.string)
        (Decode.field "unit" Decode.string)
        (Decode.field "value" Decode.float)


{-| Decode the `live` field, which is EITHER a list of entries OR the JSON string
`"unavailable"` (the graceful-degradation sentinel). Any non-list is treated as
unavailable so a token-absent backend never surfaces as a decode error.
-}
liveSignalsDecoder : Decoder LiveSignals
liveSignalsDecoder =
    Decode.oneOf
        [ Decode.map LiveSignals (Decode.list transparencyEntryDecoder)
        , Decode.succeed LiveUnavailable
        ]


transparencyMetricsDecoder : Decoder TransparencyMetrics
transparencyMetricsDecoder =
    Decode.map4 TransparencyMetrics
        (Decode.field "live" liveSignalsDecoder)
        (Decode.field "durable" (Decode.list transparencyEntryDecoder))
        (Decode.field "generated_at" Decode.string)
        (Decode.field "cache_ttl" Decode.int)


{-| `GET /api/transparency/metrics` — the public, unauthenticated transparency
payload. No auth header: the endpoint is public and returns only curated,
anonymised aggregates.
-}
getTransparencyMetricsRequest : RequestSpec
getTransparencyMetricsRequest =
    { method = "GET"
    , url = Api.Url.path [ "api", "transparency", "metrics" ] []
    , body = Nothing
    }


{-| Init-step response from `POST /api/upload/init`.
-}
type alias UploadInit =
    { imageId : String
    , expiresIn : Int
    }


{-| ⚠️ `upload_url` is in the response and is deliberately NOT decoded. The
server still sends it, and it is correct — but a URL received at runtime cannot
be proven same-origin by anything that reads this file, and believing it was a
third-party URL is what dropped the CSRF proof from every photo upload.
`putUploadBytes` builds the path instead, from the `image_id` above.
-}
decodeUploadInit : Decoder UploadInit
decodeUploadInit =
    Decode.map2 UploadInit
        (Decode.field "image_id" Decode.string)
        (Decode.field "expires_in" Decode.int)


{-| `POST /api/upload/init` — allocates an image\_id server-side and reserves a
row for it. The bytes then go to `PUT /api/upload/:id/data`, a route on OUR
origin which proxies them to the configured storage backend; no object-storage
CORS allowlisting is involved, because the browser never talks to object
storage.

⚠️ This docstring said "R2 in production, Local in dev/preview" and that is not
established — nothing selects the R2 backend in any environment. Which store the
bytes reach is a deployment question, deliberately not asserted here.

-}
initUploadRequest : String -> RequestSpec
initUploadRequest contentType =
    { method = "POST"
    , url = Api.Url.path [ "api", "upload", "init" ] []
    , body = Just (Encode.object [ ( "content_type", Encode.string contentType ) ])
    }


{-| PUT the file bytes to our own upload route. Sends the raw File body; Elm's
Http uses XHR under the hood, so the JS-side compression monkey-patch in
`apps/core/assets/js/app.js` intercepts this automatically.

The one request on `uploadTimeout` rather than `standardTimeout`: it is the only
one carrying a file body, so its elapsed time is bytes moving rather than a
server thinking. See `uploadTimeout`.

⛔ **IT TAKES AN `imageId`, NOT A URL, AND THAT IS THE WHOLE POINT.** It used to
take the `upload_url` the server returned and declare the destination
`CrossOrigin`, on the belief that the URL was a presigned object-storage link.
It had not been one since July — the server returns a path on our own origin —
so the request was same-origin, state-changing, and sent no headers at all,
because `CrossOrigin` yields `[]` by construction. Once CSRF enforcement went
on, every photo upload was refused `absent_header`. Measured on a deployed
stack: `403` without the proof, `200` with it.

⚖️ Building the path here is what makes the destination checkable. A URL handed
over at runtime cannot be related to a `SameOrigin` claim by the compiler or by
`check-credential-origin.sh`; a literal prefix can, and the prefix is a path, so
the result is on our origin whatever the `imageId` contains.

-}
putUploadBytes :
    String
    -> File
    -> Credentials
    -> (Result Http.Error () -> msg)
    -> Cmd msg
putUploadBytes imageId file creds toMsg =
    Http.request
        { method = "PUT"
        , headers = httpHeaders "PUT" (Session creds)
        , url = baseUrl ++ "/api/upload/" ++ imageId ++ "/data"
        , body = Http.fileBody file
        , expect = Http.expectWhatever toMsg
        , timeout = uploadTimeout
        , tracker = Nothing
        }


{-| `POST /api/upload/:id/commit` — tells the backend the client's direct PUT
succeeded. The backend HEADs the object, flips the row from awaiting\_upload to
pending, and enqueues identification work.
-}
commitUploadRequest : String -> RequestSpec
commitUploadRequest imageId =
    { method = "POST"
    , url = Api.Url.path [ "api", "upload", imageId, "commit" ] []
    , body = Nothing
    }


{-| The commit response's `image_id`.
-}
commitUploadDecoder : Decoder String
commitUploadDecoder =
    Decode.field "image_id" Decode.string


{-| `POST /api/upload/:image_id/reject-identification` — the identification was
wrong. The server deletes any placement made from it and re-runs the vision
pipeline excluding the listed books; 202 means accepted, and the SSE stream
carries the new run's events.
-}
rejectIdentificationRequest :
    { imageId : String, rejectedBookIds : List String }
    -> RequestSpec
rejectIdentificationRequest { imageId, rejectedBookIds } =
    { method = "POST"
    , url = Api.Url.path [ "api", "upload", imageId, "reject-identification" ] []
    , body =
        Just
            (Encode.object
                [ ( "rejected_book_ids", Encode.list Encode.string rejectedBookIds ) ]
            )
    }


{-| Response from GET /api/books/:id — book with the viewer's placement data.

`placements` carries EVERY bookshelf the viewer has this book on; a book may
legally sit on several at once. `placement` is the first of them, kept
because most of the page only ever needs one (the rating, the visibility
control, the progress card all belong to a single placement) — but anything
answering "where is this book of mine?" must read `placements`.

-}
type alias BookDetailResponse =
    { book : Book
    , placement : Maybe Placement
    , bookshelfVisibility : Maybe String
    , placements : List Placement
    , myWriting : List MyWriting
    }


{-| Whether a post is published, as the server states it.

Read this rather than inferring from `publishedAt`. The contract's
`published_at` is a proto3 `string`, which has no null, so a generated decoder
turns a draft into `""` — not distinguishable from a post published at an
unknown time. `publication_state` is the field that carries the fact across.

`StateUnknown` is "the server did not say", and it is a real case rather than a
placeholder: an older server, or a response from somewhere this field has not
reached yet. The view says so instead of guessing, because both guesses are
wrong in a way a reader cannot see.

-}
type PublicationState
    = Draft
    | Published
    | StateUnknown


{-| One post the viewer has written about this book.

`publishedAt` is `Nothing` for a DRAFT. The server includes drafts deliberately
— these are the reader's own posts, and the query applies no `published_at`
filter — so the view must say which is which rather than render a blank date.

-}
type alias MyWriting =
    { id : String
    , title : String
    , publishedAt : Maybe String
    , publicationState : PublicationState
    }


publicationStateDecoder : Decoder PublicationState
publicationStateDecoder =
    Decode.string
        |> Decode.andThen
            (\s ->
                case s of
                    "draft" ->
                        Decode.succeed Draft

                    "PUBLICATION_STATE_DRAFT" ->
                        Decode.succeed Draft

                    "published" ->
                        Decode.succeed Published

                    "PUBLICATION_STATE_PUBLISHED" ->
                        Decode.succeed Published

                    _ ->
                        -- Including "PUBLICATION_STATE_UNSPECIFIED" and anything
                        -- a later contract adds. An unrecognised state is not a
                        -- decode failure — it would discard the post's title and
                        -- link over a label — but it must not silently become
                        -- `Published` either.
                        Decode.succeed StateUnknown
            )


myWritingDecoder : Decoder MyWriting
myWritingDecoder =
    Decode.map4 MyWriting
        (Decode.field "id" Decode.string)
        (Decode.field "title" Decode.string)
        (Decode.oneOf
            [ Decode.field "published_at" (Decode.nullable Decode.string)
            , Decode.succeed Nothing
            ]
        )
        (Decode.oneOf
            [ Decode.field "publication_state" publicationStateDecoder
            , Decode.succeed StateUnknown
            ]
        )


{-| Adapter: proto BookDetailResponse -> app BookDetailResponse.

⚠️ This decoder DROPPED `my_writing` until 2026-10-16, and the drop was visible
to readers: the server computed the viewer's posts about the book on every
authenticated request, serialised them, and the SPA threw them away — so the
writing section showed a stub to everyone. Three layers existed and the middle
one was missing, which is why a server test, a view test and a proto-decoder
test all passed at once.

Note what is NOT done here: `ProtoBookResp.decodeBookDetailResponse` reads
`my_writing` and has no production caller, so converging on it the way
`CatalogueResponse` and `SearchResponse` do would delete this hand-rolled
decoder entirely. That is the better end state and is deliberately left for its
own change. ⚠️ **Converging TODAY would reintroduce the defect this decoder was
just written to fix**, so read this before attempting it:

  - `book_responses.proto` types `published_at` as a plain proto3 `string`,
    which has no null. The generated decoder is therefore
    `D.oneOf [ D.field "published_at" D.string, D.succeed "" ]`, so a draft's
    `null` fails the inner decoder and lands as `""` — a blank date where a
    "Draft" label belongs. ✅ **No longer a blocker as of 2026-10-16**: the
    contract now carries `publication_state`, so a converged decoder can read
    the fact instead of interpreting the empty string. `myWritingDecoder` still
    lifts `published_at` to a `Maybe` because that remains the more direct
    representation for a view that formats a date, but nothing depends on it for
    correctness any more.
  - `placementDecoder` was not a plain proto decode either: it was a `oneOf`
    over all three placement shapes, with a hand-written guard on the presence
    of `bookshelf_name` separating the two that carry no embedded book.
    ✅ **Gone as of 2026-10-17.** The ambiguity was self-inflicted — each
    response message declares exactly one placement type, so every caller
    always knew which shape it was getting, and collapsing four
    distinctly-typed responses into one decoder discarded that. This decoder
    now reads `bookPlacementDecoder`, which is what `BookDetailResponse`
    declares.
  - `decodeBookPlacement` **could not fail**. All eight of its fields are
    `D.oneOf [ D.field …, D.succeed <default> ]`, so it succeeded on _any_ JSON
    value — `null` included — returning an all-defaults struct, and the
    generated `D.maybe (D.field "placement" decodeBookPlacement)` therefore
    yielded `Just <empty placement>` for `"placement": null`, never `Nothing`.
    This is the blocker `confirmResponseDecoder` cites. ✅ **Fixed at the source
    as of 2026-10-16**: codegen now wraps every message decoder in
    `requireObject`, so a non-object is refused and the `D.maybe` shape answers
    `Nothing`. Per-field proto3 defaulting is untouched — `{}` is still a valid
    message of all defaults — so the part of this bullet that remains true is
    the narrow one: an absent `bookshelf_visibility` still collapses to `""`,
    which is why this decoder lifts it by hand as a `Maybe`.

✅ **No blockers remain, and the last one dissolved rather than being fixed.**
It was stated as "any JSON object satisfies any message decoder, so a `oneOf`
over two untagged shapes at one key is undecidable without a discriminator in
the contract". Both halves are true; the conclusion was not. The contract never
asked anything to decide between them — `BookshelfResponse.placements` is
always `PlacementDetail`, `BookDetailResponse`/`BookConfirmResponse` always
`BookPlacement`, `PlacementRefResponse` always `PlacementRef` — so there was
nothing to decide, only type information to stop throwing away.

Adding the discriminator was measured before being rejected: repointing a
response field at a `oneof` envelope makes `buf breaking` exit 100 ("changed
type from BookPlacement to PlacementPayload"), so it would have needed a gate
suppression to re-supply what the contract already supplies.

The shape all of these shared is worth keeping in view: the generated decoder
SUCCEEDED and returned something wrong rather than failing, which is why none of
it surfaced as a decode error. The object guard restores a failure mode; using
the declared type removes the question.

-}
bookDetailResponseDecoder : Decoder BookDetailResponse
bookDetailResponseDecoder =
    Decode.map5 BookDetailResponse
        (Decode.field "book" bookDecoder)
        (Decode.oneOf
            [ Decode.field "placement" (Decode.nullable bookPlacementDecoder)
            , Decode.succeed Nothing
            ]
        )
        (Decode.oneOf
            [ Decode.at [ "placement", "bookshelf_visibility" ] (Decode.nullable Decode.string)
            , Decode.succeed Nothing
            ]
        )
        (Decode.oneOf
            [ Decode.field "placements" (Decode.list bookPlacementDecoder)
            , Decode.succeed []
            ]
        )
        (Decode.oneOf
            [ Decode.field "my_writing" (Decode.list myWritingDecoder)
            , Decode.succeed []
            ]
        )


{-| Lightweight placement summary for duplicate detection.
-}
type alias PlacementSummary =
    { bookId : String
    , bookshelfName : String
    }


{-| Adapter: proto PlacementSummary -> app PlacementSummary.
Fields match exactly.
-}
fromProtoPlacementSummary : ProtoPlacement.PlacementSummary -> PlacementSummary
fromProtoPlacementSummary proto =
    { bookId = proto.bookId
    , bookshelfName = proto.bookshelfName
    }


{-| `GET /api/books/:id` — a book with the viewer's placement data. Optional
auth: an anonymous reader gets the book without the placements.
-}
getBookRequest : String -> RequestSpec
getBookRequest bookId =
    { method = "GET"
    , url = Api.Url.path [ "api", "books", bookId ] []
    , body = Nothing
    }


{-| `GET /api/search` — book search. Optional auth like `searchUsersRequest`:
without a token the server answers with the catalogue slice alone, so an
anonymous reader still gets results rather than a 401.
-}
searchBooksRequest : String -> Bool -> RequestSpec
searchBooksRequest query deep =
    { method = "GET"
    , url =
        Api.Url.path
            [ "api", "search" ]
            (Url.Builder.string "q" query
                :: (if deep then
                        [ Url.Builder.string "scope" "deep" ]

                    else
                        []
                   )
            )
    , body = Nothing
    }


{-| The data of `getBookshelf`'s request — see `RequestSpec`.
-}
getBookshelfRequest : String -> RequestSpec
getBookshelfRequest shelfName =
    { method = "GET"
    , url = Api.Url.path [ "api", "bookshelves", shelfName ] []
    , body = Nothing
    }


{-| Error type for `moveBook`. The backend rejects a move that would
take the reading pile past its 50-book cap with a 422 whose body carries the
stable `reading_pile_full` code; `Http.expectWhatever` would discard that
body, so a custom expect surfaces it as a distinguishable constructor.
-}
type MoveError
    = ReadingPileFull
    | MoveHttpError Http.Error


{-| Decodes the 422 body's `error` code. Only `reading_pile_full` is
promoted to its own constructor; every other body stays a plain HTTP error.
Pure so the elm-program-test simulated effect can reuse the exact mapping.
-}
moveResponseToResult : Http.Response String -> Result MoveError ()
moveResponseToResult response =
    case response of
        Http.BadUrl_ url ->
            Err (MoveHttpError (Http.BadUrl url))

        Http.Timeout_ ->
            Err (MoveHttpError Http.Timeout)

        Http.NetworkError_ ->
            Err (MoveHttpError Http.NetworkError)

        Http.BadStatus_ metadata bodyText ->
            if
                metadata.statusCode
                    == 422
                    && Decode.decodeString (Decode.field "error" Decode.string) bodyText
                    == Ok "reading_pile_full"
            then
                Err ReadingPileFull

            else
                Err (MoveHttpError (Http.BadStatus metadata.statusCode))

        Http.GoodStatus_ _ _ ->
            Ok ()


{-| `PUT /api/placements/:id/move` — move a book between BOOKSHELVES (the five
named collections). The 422 body's `reading_pile_full` code is a real answer,
which is why the caller resolves the response rather than discarding it.
-}
moveBookRequest : String -> String -> RequestSpec
moveBookRequest placementId targetBookshelf =
    { method = "PUT"
    , url = Api.Url.path [ "api", "placements", placementId, "move" ] []
    , body =
        Just
            (Requests.encodeMoveBookRequest
                { bookshelf = targetBookshelf }
            )
    }


{-| `DELETE /api/placements/:id` — take a book off the shelf it sits on.
-}
removeBookRequest : String -> RequestSpec
removeBookRequest placementId =
    { method = "DELETE"
    , url = Api.Url.path [ "api", "placements", placementId ] []
    , body = Nothing
    }


{-| `POST /api/placements/:id/restore` — undo a removal.

Takes the id `removeBookRequest` was given: the undo clears `removed_at` on
that same row rather than placing the book again, so nothing a fresh placement
would lose is lost. **409 is a real answer** — the reader re-added the book
before pressing Undo.

-}
restoreBookRequest : String -> RequestSpec
restoreBookRequest placementId =
    { method = "POST"
    , url = Api.Url.path [ "api", "placements", placementId, "restore" ] []
    , body = Nothing
    }


{-| The reading-progress fields returned by `PUT /api/placements/:id/progress`
(`ProtoJSON.reading_progress/1`): `{id, reading_status, current_page,
started_at, finished_at}`. Only these fields come back — NOT a full placement —
so the host page folds them into the placement it already holds.
-}
type alias Progress =
    { id : String
    , readingStatus : Maybe ReadingStatus
    , currentPage : Maybe Int
    , startedAt : Maybe String
    , finishedAt : Maybe String
    }


{-| A progress-update failure.

A 422 carrying per-field `{errors: {current_page: [...]}}` (the page-count
ceiling, a negative page, or an invalid status) is surfaced as
`ProgressValidationFailed` so the page can explain "that page is past the end of
the book". Every other failure — including the missing-status 422, which uses
the `{error:...}` shape — is a `ProgressRequestFailed`.

-}
type ProgressError
    = ProgressValidationFailed (List ( String, List String ))
    | ProgressRequestFailed Http.Error


{-| `ProtoJSON.reading_progress/1` always emits all five fields (`id`,
`reading_status`, `current_page`, `started_at`, `finished_at`), any of the last
four possibly `null`. So each field is decoded fail-loudly with
`field … (nullable …)`: a `null` is a legitimate `Nothing`, but a value of the
wrong TYPE now fails the decode instead of being silently swallowed to
`Nothing` — the old `oneOf [ …, succeed Nothing ]` masked such server/contract
drift. `reading_status` is a free-form string the client maps to a known status
(`Maybe.andThen parseReadingStatus`); an unrecognised status stays `Nothing`.
-}
progressDecoder : Decoder Progress
progressDecoder =
    Decode.map5 Progress
        (Decode.field "id" Decode.string)
        (Decode.field "reading_status" (Decode.nullable Decode.string)
            |> Decode.map (Maybe.andThen parseReadingStatus)
        )
        (Decode.field "current_page" (Decode.nullable Decode.int))
        (Decode.field "started_at" (Decode.nullable Decode.string))
        (Decode.field "finished_at" (Decode.nullable Decode.string))


{-| Fold the reading-progress fields returned by the API into the placement the
host page already holds, so the badge and progress line re-render in place. One
home for the byte-identical fold both BookDetail and the Reading Pile card used
(item 5).
-}
foldProgress : Placement -> Progress -> Placement
foldProgress placement progress =
    { placement
        | readingStatus = progress.readingStatus
        , currentPage = progress.currentPage
        , startedAt = progress.startedAt
        , finishedAt = progress.finishedAt
    }


{-| The user-facing copy for a failed progress save, shared by every host so the
message and the current-page special case live in one place (item 5). The
host wraps this string in its own error element (classes differ per surface).
-}
progressErrorMessage : ProgressError -> String
progressErrorMessage error =
    case error of
        ProgressValidationFailed errs ->
            if List.any (\( field, _ ) -> field == "current_page") errs then
                "That page is past the end of the book."

            else
                "Couldn't save progress. Please try again."

        ProgressRequestFailed _ ->
            "Couldn't save progress. Please try again."


{-| Map the raw HTTP response into a typed progress result. Pure so the
elm-program-test simulated effect can reuse the exact mapping (mirrors
`moveResponseToResult`). A 422 whose body carries `{errors:...}` becomes
`ProgressValidationFailed`; everything else is a `ProgressRequestFailed`.
-}
progressResponseToResult : Http.Response String -> Result ProgressError Progress
progressResponseToResult response =
    case response of
        Http.BadUrl_ url ->
            Err (ProgressRequestFailed (Http.BadUrl url))

        Http.Timeout_ ->
            Err (ProgressRequestFailed Http.Timeout)

        Http.NetworkError_ ->
            Err (ProgressRequestFailed Http.NetworkError)

        Http.BadStatus_ metadata bodyText ->
            if metadata.statusCode == 422 then
                case Decode.decodeString registerErrorsDecoder bodyText of
                    Ok errors ->
                        Err (ProgressValidationFailed errors)

                    Err _ ->
                        Err (ProgressRequestFailed (Http.BadStatus 422))

            else
                Err (ProgressRequestFailed (Http.BadStatus metadata.statusCode))

        Http.GoodStatus_ _ bodyText ->
            case Decode.decodeString (Decode.field "placement" progressDecoder) bodyText of
                Ok progress ->
                    Ok progress

                Err err ->
                    Err (ProgressRequestFailed (Http.BadBody (Decode.errorToString err)))


{-| `PUT /api/placements/:id/progress` — update a placement's reading status
and, when reading, its current page. `reading_status` is required;
`current_page` is sent only when there is one.
-}
updateProgressRequest :
    String
    -> { readingStatus : String, currentPage : Maybe Int }
    -> RequestSpec
updateProgressRequest placementId body =
    { method = "PUT"
    , url = Api.Url.path [ "api", "placements", placementId, "progress" ] []
    , body = Just (encodeProgressBody body)
    }


encodeProgressBody : { readingStatus : String, currentPage : Maybe Int } -> Encode.Value
encodeProgressBody body =
    Encode.object
        (( "reading_status", Encode.string body.readingStatus )
            :: (case body.currentPage of
                    Just page ->
                        [ ( "current_page", Encode.int page ) ]

                    Nothing ->
                        []
               )
        )


{-| The data of `requestExport`'s request — see `RequestSpec`.
-}
requestExportRequest : RequestSpec
requestExportRequest =
    { method = "POST"
    , url = Api.Url.path [ "api", "gdpr", "export" ] []
    , body = Nothing
    }


{-| The data of `deleteAccount`'s request — see `RequestSpec`.
-}
deleteAccountRequest : RequestSpec
deleteAccountRequest =
    { method = "DELETE"
    , url = Api.Url.path [ "api", "gdpr", "account" ] []
    , body = Nothing
    }


{-| `POST /api/gdpr/consent` — recording an analytics consent decision, as data.
-}
saveConsentRequest : Bool -> RequestSpec
saveConsentRequest consent =
    { method = "POST"
    , url = Api.Url.path [ "api", "gdpr", "consent" ] []
    , body = Just (Requests.encodeConsentRequest { consent = consent })
    }


{-| `POST /api/gdpr/consent` — recording the writing-assistant consent decision, as data.

⚠️ Same endpoint as `saveConsentRequest`, distinguished only by the `type`
field. Kept as two specs rather than one parameterised by the type string,
because the consent `type` must be whitelisted server-side and a free `String`
parameter here would invite a value that is not.

-}
saveWritingAssistantConsentRequest : Bool -> RequestSpec
saveWritingAssistantConsentRequest consent =
    { method = "POST"
    , url = Api.Url.path [ "api", "gdpr", "consent" ] []
    , body =
        Just
            (Encode.object
                [ ( "consent", Encode.bool consent )
                , ( "type", Encode.string "writing_assistant" )
                ]
            )
    }


{-| Response from GET /api/catalogue — paginated book list.
-}
type alias CatalogueResponse =
    { books : List Book
    , total : Int
    , page : Int
    , perPage : Int
    }


{-| Adapter: proto CatalogueResponse -> app CatalogueResponse.
Proto has same fields but in different declaration order. We map through
the proto decoder and reorder.
-}
fromProtoCatalogueResponse : ProtoBookResp.CatalogueResponse -> CatalogueResponse
fromProtoCatalogueResponse proto =
    { books = List.map Types.Book.fromProtoBook proto.books
    , total = proto.total
    , page = proto.page
    , perPage = proto.perPage
    }


catalogueResponseDecoder : Decoder CatalogueResponse
catalogueResponseDecoder =
    Decode.map fromProtoCatalogueResponse ProtoBookResp.decodeCatalogueResponse


{-| A book the viewer already holds, matched by the search query, tagged with the
bookshelf it sits on (raw name, e.g. `"library"` / `"reading_pile"`). Rendered in
the "Your Collection" section. Mapped from a proto `SearchHit` whose
`collection` entries populate `bookshelf_name` and leave the label fields empty.
`snippet` is a deep-search `ts_headline` excerpt (`<mark>`-wrapped), non-empty
only when the match was on the description/review under `scope=deep`.
-}
type alias CollectionHit =
    { book : Book
    , bookshelfName : String
    , bookshelfNames : List String
    , snippet : String
    }


{-| A platform-visible book surfaced by the search, with its discoverable-by-design
provenance. `source` is `""` (a plain platform result — no label),
`"looking_for_home"` (an always-visible LFH advert → owner handle), or `"listed"`
(an active marketplace listing → owner handle + formatted price). Rendered in the
"On the Platform" section; the label is shown only when `source` is non-empty.
`snippet` is a deep-search `ts_headline` excerpt, non-empty only for a
description/review match under `scope=deep`.
-}
type alias PlatformHit =
    { book : Book
    , source : String
    , ownerHandle : String
    , price : String
    , snippet : String
    }


{-| The two search sections the page renders: the viewer's own matching books
("Your Collection") above platform-visible books ("On the Platform"). Either list
may be empty — its section then hides (see `Page.Search.view`).
-}
type alias SearchSections =
    { collection : List CollectionHit
    , platform : List PlatformHit
    }


fromProtoCollectionHit : ProtoBookResp.SearchHit -> CollectionHit
fromProtoCollectionHit hit =
    { book = Types.Book.fromProtoBook hit.book
    , bookshelfName = hit.bookshelfName
    , bookshelfNames =
        if List.isEmpty hit.bookshelfNames then
            List.filter (\name -> name /= "") [ hit.bookshelfName ]

        else
            hit.bookshelfNames
    , snippet = hit.snippet
    }


fromProtoPlatformHit : ProtoBookResp.SearchHit -> PlatformHit
fromProtoPlatformHit hit =
    { book = Types.Book.fromProtoBook hit.book
    , source = hit.source
    , ownerHandle = hit.ownerHandle
    , price = hit.price
    , snippet = hit.snippet
    }


{-| Adapter: proto SearchResponse -> the typed `SearchSections` the page renders.
The envelope also carries `query`/`count` and the legacy flat `results` list; the
page reads only the two typed sections (`collection`, `platform_hits`), so the
rest is dropped here (mirrors fromProtoCatalogueResponse's shaping).
-}
fromProtoSearchResponse : ProtoBookResp.SearchResponse -> SearchSections
fromProtoSearchResponse proto =
    { collection = List.map fromProtoCollectionHit proto.collection
    , platform = List.map fromProtoPlatformHit proto.platformHits
    }


{-| Decode GET /api/search's SearchResponse envelope through the generated
proto decoder, keeping search drift-proof by construction. Shared with
`TestHelpers.searchEffects` so the test mirror can never diverge.
-}
searchResponseDecoder : Decoder SearchSections
searchResponseDecoder =
    Decode.map fromProtoSearchResponse ProtoBookResp.decodeSearchResponse


{-| A single audit-log entry as shown on the read-only audit page.
The backend never includes any IP field, so none is decoded here.
-}
type alias AuditLogEntry =
    { id : String
    , action : String
    , resourceType : String
    , resourceId : Maybe String
    , occurredAt : String
    }


{-| Response from GET /api/settings/audit-log — the user's own paginated
audit history.
-}
type alias AuditLogResponse =
    { entries : List AuditLogEntry
    , total : Int
    , page : Int
    , perPage : Int
    }


auditLogEntryDecoder : Decoder AuditLogEntry
auditLogEntryDecoder =
    Decode.map5 AuditLogEntry
        (Decode.field "id" Decode.string)
        (Decode.field "action" Decode.string)
        (Decode.field "resource_type" Decode.string)
        (Decode.field "resource_id" (Decode.nullable Decode.string))
        (Decode.field "occurred_at" Decode.string)


auditLogResponseDecoder : Decoder AuditLogResponse
auditLogResponseDecoder =
    Decode.map4 AuditLogResponse
        (Decode.field "entries" (Decode.list auditLogEntryDecoder))
        (Decode.field "total" Decode.int)
        (Decode.field "page" Decode.int)
        (Decode.field "per_page" Decode.int)


{-| GET /api/settings/audit-log — the current reader's own audit history, as data.

⛔ There is no `Cmd`-returning companion any more. `Page.Settings.AuditLog` sends
this through `Effect.authed`, which makes saying what an expired session means a
condition of asking at all — the obligation the old wrapper left to a
`isUnauthorized` re-test in the page's result handler.

-}
getAuditLogRequest : RequestSpec
getAuditLogRequest =
    { method = "GET"
    , url = Api.Url.path [ "api", "settings", "audit-log" ] [ Url.Builder.string "page" "1" ]
    , body = Nothing
    }


{-| A single subject with the number of the user's own books that carry it.
-}
type alias SubjectCount =
    { subject : String
    , count : Int
    }


{-| A single BISAC code with the number of the user's own books that carry it.
-}
type alias BisacCount =
    { code : String
    , count : Int
    }


{-| The user's real interest profile — top subjects and BISAC codes, derived
from their own shelved books. Shown as fact.
-}
type alias InterestProfile =
    { topSubjects : List SubjectCount
    , topBisac : List BisacCount
    }


{-| The user's real behavioural profile from their own placement history.
`medianDaysToFinish` and `mostActiveHour` are absent (null) when there is not
enough data to compute them.
-}
type alias Behaviour =
    { booksShelved : Int
    , booksFinished : Int
    , booksAbandoned : Int
    , abandonmentRate : Float
    , medianDaysToFinish : Maybe Int
    , mostActiveHour : Maybe Int
    }


{-| The de-anonymisation demonstration: how unique the user's shelf is against
the corpus. `othersSharingAll` is null when it could not be computed;
`uniqueness` is one of "unique" | "rare" | "common" | "insufficient\_data" |
"unknown".
-}
type alias Deanonymisation =
    { sampleSize : Int
    , othersSharingAll : Maybe Int
    , uniqueness : String
    , explanation : String
    }


{-| A single labelled risk inference — an illustration of what a third party
_could_ infer. Never asserted as fact, never stored. Only present after the
user explicitly asks to reveal them.
-}
type alias RiskInference =
    { label : String
    , couldInfer : String
    , basis : String
    }


{-| The full ephemeral inference payload from GET /api/me/inferences. Computed
per-request from the user's own data and never persisted. `riskInferences` is
`Nothing` unless the request was made with `?reveal_risk=true`.
-}
type alias PersonalInferences =
    { interestProfile : InterestProfile
    , behaviour : Behaviour
    , deanonymisation : Deanonymisation
    , riskInferences : Maybe (List RiskInference)
    , generatedAt : String
    }


subjectCountDecoder : Decoder SubjectCount
subjectCountDecoder =
    Decode.map2 SubjectCount
        (Decode.field "subject" Decode.string)
        (Decode.field "count" Decode.int)


bisacCountDecoder : Decoder BisacCount
bisacCountDecoder =
    Decode.map2 BisacCount
        (Decode.field "code" Decode.string)
        (Decode.field "count" Decode.int)


interestProfileDecoder : Decoder InterestProfile
interestProfileDecoder =
    Decode.map2 InterestProfile
        (Decode.field "top_subjects" (Decode.list subjectCountDecoder))
        (Decode.field "top_bisac" (Decode.list bisacCountDecoder))


behaviourDecoder : Decoder Behaviour
behaviourDecoder =
    Decode.map6 Behaviour
        (Decode.field "books_shelved" Decode.int)
        (Decode.field "books_finished" Decode.int)
        (Decode.field "books_abandoned" Decode.int)
        (Decode.field "abandonment_rate" Decode.float)
        (Decode.field "median_days_to_finish" (Decode.nullable Decode.int))
        (Decode.field "most_active_hour" (Decode.nullable Decode.int))


deanonymisationDecoder : Decoder Deanonymisation
deanonymisationDecoder =
    Decode.map4 Deanonymisation
        (Decode.field "sample_size" Decode.int)
        (Decode.field "others_sharing_all" (Decode.nullable Decode.int))
        (Decode.field "uniqueness" Decode.string)
        (Decode.field "explanation" Decode.string)


riskInferenceDecoder : Decoder RiskInference
riskInferenceDecoder =
    Decode.map3 RiskInference
        (Decode.field "label" Decode.string)
        (Decode.field "could_infer" Decode.string)
        (Decode.field "basis" Decode.string)


{-| Decode the personal-inferences payload. `risk_inferences` is decoded with
`Decode.maybe` so an absent key (the default, un-revealed response) yields
`Nothing` rather than failing.
-}
personalInferencesDecoder : Decoder PersonalInferences
personalInferencesDecoder =
    Decode.map5 PersonalInferences
        (Decode.field "interest_profile" interestProfileDecoder)
        (Decode.field "behaviour" behaviourDecoder)
        (Decode.field "deanonymisation" deanonymisationDecoder)
        (Decode.maybe (Decode.field "risk_inferences" (Decode.list riskInferenceDecoder)))
        (Decode.field "generated_at" Decode.string)


{-| GET /api/me/inferences — the reader's own ephemeral inference profile, as data.

When `revealRisk` is `True` this appends `?reveal_risk=true`, so the response
includes the labelled risk-inference illustrations the page withholds by default.

⛔ There is no `Cmd`-returning companion any more. `Page.Insights` sends this
through `Effect.authed` from both of its call sites, which makes naming the
expired-session msg a condition of asking — an obligation that used to be an
`Api.isUnauthorized` re-test duplicated in two result handlers.

-}
getInferencesRequest : Bool -> RequestSpec
getInferencesRequest revealRisk =
    { method = "GET"
    , url =
        Api.Url.path [ "api", "me", "inferences" ]
            (if revealRisk then
                [ Url.Builder.string "reveal_risk" "true" ]

             else
                []
            )
    , body = Nothing
    }


{-| Error type for `placeBook`. The direct-place path — Upload,
Catalogue, and BookDetail "Add to Collection" — can hit the same reading-pile
cap the move path does: the backend rejects a placement that would take the
pile past 50 with a 422 whose body carries the stable `reading_pile_full`
code. `Http.expectJson` would collapse that into a bare `BadStatus 422`, so a
custom expect promotes it to `PlaceReadingPileFull`; every other failure stays
a `PlaceHttpError`. Mirrors `MoveError`, but keeps the `Placement` on success.
-}
type PlaceError
    = PlaceReadingPileFull
    | PlaceHttpError Http.Error


{-| Map the raw HTTP response into a typed place result. Pure so the
elm-program-test simulated effect can reuse the exact mapping (mirrors
`moveResponseToResult`). A 422 whose `error` code is `reading_pile_full`
becomes `PlaceReadingPileFull`; a good response decodes the placement.
-}
placeResponseToResult : Http.Response String -> Result PlaceError Placement
placeResponseToResult response =
    case response of
        Http.BadUrl_ url ->
            Err (PlaceHttpError (Http.BadUrl url))

        Http.Timeout_ ->
            Err (PlaceHttpError Http.Timeout)

        Http.NetworkError_ ->
            Err (PlaceHttpError Http.NetworkError)

        Http.BadStatus_ metadata bodyText ->
            if
                metadata.statusCode
                    == 422
                    && Decode.decodeString (Decode.field "error" Decode.string) bodyText
                    == Ok "reading_pile_full"
            then
                Err PlaceReadingPileFull

            else
                Err (PlaceHttpError (Http.BadStatus metadata.statusCode))

        Http.GoodStatus_ _ bodyText ->
            case Decode.decodeString (Decode.field "placement" placementRefDecoder) bodyText of
                Ok placement ->
                    Ok placement

                Err err ->
                    Err (PlaceHttpError (Http.BadBody (Decode.errorToString err)))


{-| The data of `placeBook`'s request — see `RequestSpec`.
-}
placeBookRequest : String -> String -> RequestSpec
placeBookRequest bookshelfName bookId =
    { method = "POST"
    , url = Api.Url.path [ "api", "bookshelves", bookshelfName, "placements" ] []
    , body =
        Just
            (Requests.encodePlaceBookRequest
                { bookId = bookId }
            )
    }


{-| `PUT /api/books/:id/age-gate` — the reader who added a book marks it adults
only. Raise-only: the backend permits raising the gate on this path, and
lowering it is owner-only.
-}
setBookAgeGateRequest : String -> RequestSpec
setBookAgeGateRequest bookId =
    { method = "PUT"
    , url = Api.Url.path [ "api", "books", bookId, "age-gate" ] []
    , body = Just (Encode.object [ ( "adults_only", Encode.bool True ) ])
    }


{-| The data of `getUserPlacements`'s request — see `RequestSpec`.
-}
getUserPlacementsRequest : RequestSpec
getUserPlacementsRequest =
    { method = "GET"
    , url = Api.Url.path [ "api", "placements", "mine" ] []
    , body = Nothing
    }


{-| The `GET /api/placements/mine` body: `{"placements": [...]}`, built by
`StacksWeb.BookshelfPlacementController.mine/2` straight off
`Shelving.get_user_placements_summary/1` (no ProtoJSON serializer in between).
Named and exported so the Catalogue program test decodes the real thing.
-}
placementsMineDecoder : Decoder (List PlacementSummary)
placementsMineDecoder =
    Decode.map .placements ProtoBookshelfResp.decodePlacementsMineResponse
        |> Decode.map (List.map fromProtoPlacementSummary)


{-| Which of `Books.confirm/2`'s branches answered.

The verb is one round trip that resolves the ISBN, creates the work and its
primary edition if the platform has never seen it, and places it — so the
outcome is not derivable from "did it 2xx". `source` carries it on the wire:
absent on the created branch, `"catalogue"` when the work already existed and
this request placed it, `"collection"` when it was already on the requested
bookshelf and nothing changed.

-}
type ConfirmOutcome
    = ConfirmCreated
    | ConfirmPlacedFromCatalogue
    | ConfirmAlreadyPlaced


{-| Response body of `POST /api/books/confirm`.

`placements` is EVERY active placement the reader now has of this book, oldest
first; `placement` is the one this request produced or matched. The difference
between the two is the duplicate notice — informational, never blocking (owner
ruling 2026-07-30).

-}
type alias ConfirmResponse =
    { book : Book
    , placement : Maybe Placement
    , placements : List Placement
    , outcome : ConfirmOutcome
    }


{-| A confirm failure the page has to tell apart.

`ConfirmMergeRequired` is the 409: the resolved title+author fuzzy-matched an
existing work (`Books.find_same_work/2`, Jaro-Winkler > 0.8), so the server
refused to mint a second work and named the one to merge into. It is the
prompt's trigger, not an error to show as "something went wrong" —
collapsing it into `Http.BadStatus 409` is what would lose it.

-}
type ConfirmError
    = ConfirmMergeRequired String
    | ConfirmIsbnNotFound
    | ConfirmHttpError Http.Error


{-| Pure request → result mapping, so the elm-program-test simulated effect
reuses the exact mapping the real `Cmd` does (mirrors `placeResponseToResult`).
-}
confirmResponseToResult : Http.Response String -> Result ConfirmError ConfirmResponse
confirmResponseToResult response =
    case response of
        Http.BadUrl_ url ->
            Err (ConfirmHttpError (Http.BadUrl url))

        Http.Timeout_ ->
            Err (ConfirmHttpError Http.Timeout)

        Http.NetworkError_ ->
            Err (ConfirmHttpError Http.NetworkError)

        Http.BadStatus_ metadata bodyText ->
            Err (confirmErrorFromBody metadata.statusCode bodyText)

        Http.GoodStatus_ _ bodyText ->
            case Decode.decodeString confirmResponseDecoder bodyText of
                Ok confirmed ->
                    Ok confirmed

                Err err ->
                    Err (ConfirmHttpError (Http.BadBody (Decode.errorToString err)))


confirmErrorFromBody : Int -> String -> ConfirmError
confirmErrorFromBody statusCode bodyText =
    let
        errorCode =
            Decode.decodeString (Decode.field "error" Decode.string) bodyText

        workId =
            Decode.decodeString (Decode.field "work_id" Decode.string) bodyText
    in
    case ( statusCode, errorCode, workId ) of
        ( 409, Ok "merge_required", Ok id ) ->
            ConfirmMergeRequired id

        ( 422, Ok "isbn_not_found", _ ) ->
            ConfirmIsbnNotFound

        _ ->
            ConfirmHttpError (Http.BadStatus statusCode)


{-| Adapter: the `BookConfirmResponse` wire shape → the app-level record.

Hand-rolled over the app-level `bookDecoder` / `bookPlacementDecoder` for one of
the reasons `bookDetailResponseDecoder` is — the third in that decoder's list:
`decodeBookPlacement` could not fail, so the generated
`D.maybe (D.field "placement" decodeBookPlacement)` turned a JSON `null` into
`Just <all-defaults struct>` rather than `Nothing`.

✅ **Both blockers are gone.** The object guard fixed that one (2026-10-16), so
the `D.maybe` shape now answers `Nothing`; and the `PlacementRef` ambiguity
dissolved (2026-10-17) once each caller used the type its own response declares.
`BookConfirmResponse.placement` is a `BookPlacement`, so that is what this reads.

⚠️ This is the THIRD hand-rolled decoder over the same book / placement /
placements triple, and what remains is **not** a wire problem: it is the
app-level `Placement` type being richer than any single proto message, so the
mapping from each shape into it lives here. Converging further means deciding
whether the app type should keep that shape at all — a different question from
the one this comment used to describe.

-}
confirmResponseDecoder : Decoder ConfirmResponse
confirmResponseDecoder =
    Decode.map4 ConfirmResponse
        (Decode.field "book" bookDecoder)
        (Decode.oneOf
            [ Decode.field "placement" (Decode.nullable bookPlacementDecoder)
            , Decode.succeed Nothing
            ]
        )
        (Decode.oneOf
            [ Decode.field "placements" (Decode.list bookPlacementDecoder)
            , Decode.succeed []
            ]
        )
        (Decode.map confirmOutcomeFromSource
            (Decode.oneOf
                [ Decode.field "source" Decode.string
                , Decode.succeed ""
                ]
            )
        )


confirmOutcomeFromSource : String -> ConfirmOutcome
confirmOutcomeFromSource source =
    case source of
        "catalogue" ->
            ConfirmPlacedFromCatalogue

        "collection" ->
            ConfirmAlreadyPlaced

        _ ->
            ConfirmCreated


{-| `POST /api/books/confirm` — file a manually entered ISBN on the chosen
bookshelf.
-}
confirmBookRequest : { isbn : String, shelfName : String } -> RequestSpec
confirmBookRequest body =
    { method = "POST"
    , url = Api.Url.path [ "api", "books", "confirm" ] []
    , body =
        Just
            (Encode.object
                [ ( "isbn", Encode.string body.isbn )
                , ( "shelf_name", Encode.string body.shelfName )
                ]
            )
    }


{-| The data of `getCatalogue`'s request — see `RequestSpec`.
-}
getCatalogueRequest :
    { search : Maybe String
    , subject : Maybe String
    , sort : String
    , page : Int
    }
    -> RequestSpec
getCatalogueRequest params =
    { method = "GET"
    , url =
        Api.Url.path [ "api", "catalogue" ]
            (List.filterMap identity
                [ Just (Url.Builder.string "sort" params.sort)
                , Just (Url.Builder.int "page" params.page)
                , params.search |> Maybe.map (Url.Builder.string "search")
                , params.subject |> Maybe.map (Url.Builder.string "subject")
                ]
            )
    , body = Nothing
    }


{-| The reader's own account, as the server holds it — the fields Settings →
Profile edits.

Deliberately not `Types.User`. That record is what the stored login blob can
reconstruct; this one is the answer to "what did the server actually keep",
which is a different question, and the difference is the whole point of asking.

-}
type alias Account =
    { displayName : String
    , handle : String
    , email : String
    , websiteUrl : String
    , countryCode : String
    , city : String
    , pendingEmail : Maybe String
    }


{-| Decoder for `GET /api/auth/me`'s `user` object.

`email` is required, so a body that is not an account — an error envelope, a
captive portal's HTML, `{}` — comes back `Err` and the page can say so. The
lenient alternative decodes those into six empty strings, which the form would
then render as the reader's account: a wrong answer stated confidently, and
indistinguishable from a reader who has filled nothing in.

The rest default to `""` because they are genuinely optional columns. Someone
who has never set a city is not a malformed response.

-}
accountDecoder : Decoder Account
accountDecoder =
    Decode.field "user"
        (Decode.map7 Account
            (optionalString "display_name")
            (optionalString "handle")
            (Decode.field "email" Decode.string)
            (optionalString "website_url")
            (optionalString "country_code")
            (optionalString "city")
            (Decode.maybe (Decode.field "pending_email" Decode.string))
        )


{-| GET /api/auth/me — the reader's own account. Sent through `Effect`, so
there is no `Cmd` twin here; the caller pairs this spec with `accountDecoder`.

Authenticated, and the one request whose 401 is least surprising: asking who you
are is exactly what discovers the session is gone. A caller must route that (see
`isUnauthorized`) rather than render "could not load your account", which tells
the reader to retry something that cannot work.

-}
getAccountRequest : RequestSpec
getAccountRequest =
    { method = "GET"
    , url = Api.Url.path [ "api", "auth", "me" ] []
    , body = Nothing
    }


{-| Who the server says the reader is.

⛔ This is the identity the app runs on, and it comes from the server on every
boot. It replaces a blob the SPA wrote to `localStorage` and read back — a copy
that went stale the moment anything changed server-side, and whose `role` field
decided what the reader could see. A promotion, a demotion or a renamed account
took effect only once the reader signed out and in again; until then the app
rendered an answer it had no business still believing.

`countryCode` and `city` are deliberately absent. They are on the wire, but
nothing reads them off the session, and a field carried for completeness is a
field that drifts unobserved.

-}
type alias Identity =
    { id : String
    , email : String
    , displayName : String
    , handle : String
    , role : String
    , consentAnalytics : Bool
    , consentWritingAssistant : Bool
    }


{-| Decode `GET /api/auth/me` into an identity.

⛔ `role` is REQUIRED, and that is the point of this decoder existing rather
than reusing the lenient proto one. The decoder it replaces read an absent role
as `"user"`, so a response that had lost the field — a serializer allowlist
edited, a proxy stripping it, an error envelope with a 200 — demoted an owner
to a reader and told nobody. The column is `null: false`, so an absent `role`
is never the account's real state; it is a broken answer, and a broken answer
must fail where it can be seen rather than resolve to the least-privileged
guess.

`id` and `email` are required for the same reason: there is no account without
them, so their absence means this is not an account. `displayName` and `handle`
are genuinely unset for some readers (both columns are nullable), so they
default — but only when ABSENT or `null`, never when the server sent something
unreadable.

-}
identityDecoder : Decoder Identity
identityDecoder =
    Decode.field "user"
        (Decode.map7 Identity
            (Decode.field "id" Decode.string)
            (Decode.field "email" Decode.string)
            (optionalString "display_name")
            (optionalString "handle")
            (Decode.field "role" Decode.string)
            (optionalBool "consent_analytics")
            (optionalBool "consent_writing_assistant")
        )


{-| `GET /api/auth/me` — who the session belongs to, as data.

⛔ THIS ONE HAS NO `onExpired` TO GIVE, and it is the reason `Effect.public`
exists alongside `authed`. A 401 here is the ANSWER, not a failure: it is the
server saying this session is not one. `Api.identityOutcome` classifies every
response shape into an outcome, which is why its resolver cannot fail
(`Err Never`). Routing a 401 to an expiry interceptor would make the boot
question unanswerable — the interceptor would fire before anyone learned there
was no session to begin with.

-}
identityRequest : RequestSpec
identityRequest =
    { method = "GET"
    , url = Api.Url.path [ "api", "auth", "me" ] []
    , body = Nothing
    }


{-| What asking who you are can tell you — four answers, not a `Result`.

⛔ **`NoSession` and `SessionRefused` are both 401s and they are NOT the same
thing.** One is a reader who was never signed in; the other is a reader whose
session the server has just refused. The second is owed an explanation, and the
first must not be given one — an unexplained sign-out is indistinguishable from
a deliberate one, and telling someone their session expired when they simply
arrived is the same defect pointing the other way.

⚠️ The CLIENT cannot make this distinction. The session cookie is `HttpOnly`,
so the page cannot see whether the browser sent one; only the server knows. It
reports it as the 401's `error` token, which is why this reads the body of a
failed response rather than taking `Http.expectJson`'s `BadStatus 401`.

⚖️ Four constructors rather than `Result Http.Error Identity` so the caller
never re-classifies an `Http.Error` it was handed. The decision "is this an
answer or a failure to get one" is made once, here, where the response is.

-}
type IdentityOutcome
    = IdentityKnown Identity
    | NoSession
    | SessionRefused
    | IdentityUnavailable BootFailure


{-| Why asking who you are did not get an answer, in terms the app can act on.

⛔ A DOMAIN REASON RATHER THAN AN `Http.Error`, because the only thing anyone
does with it is tell the reader what went wrong — and that mapping has to
happen somewhere. Doing it here, at the boundary where the response is, keeps
`Http` out of the model entirely; doing it at render time (which is where it
used to live) meant an `Http.Error` travelled through two domain types to reach
a `case` that turned it into a sentence.

⚖️ `Unreadable` is NOT a network problem and is kept separate for that reason:
it means the server answered and the answer was not something we can read,
which is ours to fix and is not likely to clear on a retry.

-}
type BootFailure
    = Unreachable
    | TooSlow
    | ServerSaid Int
    | Unreadable


{-| Read one `/api/auth/me` response into its outcome.
-}
identityOutcome : Http.Response String -> IdentityOutcome
identityOutcome response =
    case response of
        Http.GoodStatus_ _ body ->
            case Decode.decodeString identityDecoder body of
                Ok identity ->
                    IdentityKnown identity

                Err _ ->
                    -- A 200 that is not an account is a broken answer, not a
                    -- signed-out reader. It must not quietly sign anyone out.
                    IdentityUnavailable Unreadable

        Http.BadStatus_ metadata body ->
            if metadata.statusCode == 401 then
                refusalFrom body

            else
                IdentityUnavailable (ServerSaid metadata.statusCode)

        Http.NetworkError_ ->
            IdentityUnavailable Unreachable

        Http.Timeout_ ->
            IdentityUnavailable TooSlow

        Http.BadUrl_ _ ->
            IdentityUnavailable Unreadable


{-| What the server said when it refused a request with a 401.

⛔ **THE ONLY PLACE THAT READS THE REASON TOKEN.** There are two request paths
that have to know what a 401 means — boot's `refusalFrom` and every
authenticated request's `interceptExpiry` — and they used to answer it from
different signals: one read this token, the other read the status code alone.
The second re-made a decision that had already been settled, and settled
precisely because the client CANNOT make it from a status code: the session
cookie is `HttpOnly`, so the page cannot see whether the browser sent one. Only
the server knows, and it says so here. A second matcher on the literal beside
this one would reproduce that split one level down, so both callers come through
this function.

⚠️ **The token is not simply "`session_expired` or not", even server-side.**
`AuthErrorHandler` answers `session_expired` whenever a session cookie was
presented and refused — including alongside a bearer, which is the
mixed-transport case the cookie rollout exists to support, and which an earlier
version got wrong by matching on Guardian's type instead of the rejection. But
`AdminAuthPipeline` answers `unauthorized`, `AuthController` answers
`invalid_credentials`, and Guardian's own types (`invalid_token`,
`token_expired`) reach the wire for a refused bearer. All of those are
`AnotherReason`: a reason we can read, naming something that is not an expired
session.

⚖️ **Three values, not two, and the third is the finding rather than padding.**
The first version of the boot reader chose between two wrong answers. It read an
unparseable body as "no session" — the quiet option — on the grounds that
defaulting to "refused" would raise "we closed your session" at a reader who
never had one. Both were wrong because the question has a third answer: a 401
whose body we cannot read is not evidence about the session at all. A proxy's
HTML error page, a gateway error rendered as 401, or an error shape that changed
under us all mean we never reached the application. MEASURED across the server:
every 401 an SPA request can receive carries `{"error": "<token>"}` —
`AuthErrorHandler`, `AdminAuthPipeline`, `AuthController`, `AdminAuthController`
and `PartnerAuthPlug` all answer JSON; the one empty-bodied 401 (`MetricsAuth`)
guards `/internal/*`, which the SPA never calls. So `ReasonUnreadable` means the
answer did not come from us.

-}
type Refusal
    = SessionWasRefused
    | AnotherReason
    | ReasonUnreadable


{-| Read a 401's body into the reason the server gave for it.
-}
refusalToken : String -> Refusal
refusalToken body =
    case Decode.decodeString (Decode.field "error" Decode.string) body of
        Ok "session_expired" ->
            SessionWasRefused

        Ok _ ->
            AnotherReason

        Err _ ->
            ReasonUnreadable


{-| Which kind of 401 this is, in the terms BOOT needs: the question there is
"is this browser signed in?", and a first-time visitor is one of the answers.

So `AnotherReason` is `NoSession` — the server named something that is not an
expired session, and at boot that means there was nobody here. Nothing is said
to the reader, because an unexplained sign-out and a deliberate arrival must not
look the same.

`ReasonUnreadable` says what is true: we asked, and could not read the answer.
The boot screen offers a retry, which is the one response that fits not knowing.

⚠️ Mid-journey the same token means something different, because the question
is different — see `interceptExpiry`.

-}
refusalFrom : String -> IdentityOutcome
refusalFrom body =
    case refusalToken body of
        SessionWasRefused ->
            SessionRefused

        AnotherReason ->
            NoSession

        ReasonUnreadable ->
            IdentityUnavailable Unreadable


{-| A profile-update failure.

Like registration, a 422 carries per-field validation errors (`handle`,
`email`, `display_name`) so the settings page can explain the actual problem —
a taken/reserved/malformed handle surfaces its message under the field rather
than as a generic "could not save". Every other failure is a
`ProfileRequestFailed`.

-}
type ProfileError
    = ProfileValidationFailed (List ( String, List String ))
    | ProfileRequestFailed Http.Error


{-| What a saved profile came back as.

`email` is the address the account ANSWERS on, and `pendingEmail` the one waiting
to prove itself — an email change moves the second, never the first, so the form
must take both from the server rather than assuming the typed value landed.

-}
type alias ProfileSaved =
    { handle : String
    , email : String
    , pendingEmail : Maybe String
    }


{-| PUT /api/settings/profile — update display name, email, website URL, and handle.

`emailChanged` decides whether the email/current-password pair is sent at all
(see `encodeProfileBody`): an ordinary profile edit omits both so the server
treats it as a profile-only update rather than an email change.

-}
updateProfile :
    { displayName : String
    , email : String
    , websiteUrl : String
    , handle : String
    , currentPassword : String
    , emailChanged : Bool
    , handleChanged : Bool
    }
    -> Authed ProfileError ProfileSaved msg
    -> Cmd msg
updateProfile body request =
    Http.request
        { method = "PUT"
        , headers = authedHeaders "PUT" request
        , url = baseUrl ++ "/api/settings/profile"
        , body = Http.jsonBody (encodeProfileBody body)
        , expect = authedExpect resolveProfile request
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| Body for `PUT /api/settings/profile`. Unchanged keys are OMITTED, not
sent blank: `handle` can render empty for a session with no local handle,
and a blank write would NULL the real handle (NOT NULL column — the
server 500s). Omission keeps the stored value; genuine edits are sent
and server-validated.
-}
encodeProfileBody :
    { displayName : String
    , email : String
    , websiteUrl : String
    , handle : String
    , currentPassword : String
    , emailChanged : Bool
    , handleChanged : Bool
    }
    -> Encode.Value
encodeProfileBody body =
    Encode.object
        (List.concat
            [ [ ( "display_name", Encode.string body.displayName )
              , ( "website_url", Encode.string body.websiteUrl )
              ]
            , if body.handleChanged then
                [ ( "handle", Encode.string body.handle ) ]

              else
                []
            , if body.emailChanged then
                [ ( "email", Encode.string body.email )
                , ( "current_password", Encode.string body.currentPassword )
                ]

              else
                []
            ]
        )


{-| What the client falls back to when a 200 body cannot be read: the handle
empty (the caller keeps what it had) and NO pending change. Claiming a pending
change we did not read would put a panel on screen about a state we cannot see.
-}
emptyProfileSaved : ProfileSaved
emptyProfileSaved =
    { handle = "", email = "", pendingEmail = Nothing }


profileSavedDecoder : Decoder ProfileSaved
profileSavedDecoder =
    Decode.map3 ProfileSaved
        (Decode.oneOf [ Decode.field "handle" Decode.string, Decode.succeed "" ])
        (Decode.oneOf [ Decode.field "email" Decode.string, Decode.succeed "" ])
        (Decode.oneOf
            [ Decode.field "pending_email" (Decode.nullable Decode.string)
            , Decode.succeed Nothing
            ]
        )


{-| Keep the structured `{"errors":...}` payload a 422 carries so the caller
can surface the real reason a profile save was rejected (mirrors
`expectRegister`). On success it hands back the server-normalised handle (the
200 body echoes the lowercased value) so the settings page can reflect it.

There is deliberately no 401 branch: `interpretAuthed` diverts a 401 to
`onExpired` before this runs, so "session expired" cannot arrive here disguised
as `ProfileRequestFailed (BadStatus 401)` — which is precisely how the page
came to render "Please try again" at it.

-}
resolveProfile : Http.Response String -> Result ProfileError ProfileSaved
resolveProfile response =
    case response of
        Http.BadUrl_ url ->
            Err (ProfileRequestFailed (Http.BadUrl url))

        Http.Timeout_ ->
            Err (ProfileRequestFailed Http.Timeout)

        Http.NetworkError_ ->
            Err (ProfileRequestFailed Http.NetworkError)

        Http.BadStatus_ metadata bodyText ->
            if metadata.statusCode == 422 then
                case Decode.decodeString registerErrorsDecoder bodyText of
                    Ok errors ->
                        Err (ProfileValidationFailed errors)

                    Err _ ->
                        Err (ProfileRequestFailed (Http.BadStatus metadata.statusCode))

            else
                Err (ProfileRequestFailed (Http.BadStatus metadata.statusCode))

        Http.GoodStatus_ _ bodyText ->
            Ok (Result.withDefault emptyProfileSaved (Decode.decodeString profileSavedDecoder bodyText))


{-| `PUT /api/settings/location` — setting the reader's locality, as data.
-}
updateLocationRequest : { countryCode : String, city : String } -> RequestSpec
updateLocationRequest body =
    { method = "PUT"
    , url = Api.Url.path [ "api", "settings", "location" ] []
    , body =
        Just
            (Requests.encodeUpdateLocationRequest
                { countryCode = body.countryCode
                , city = body.city
                }
            )
    }


{-| `PUT /api/settings/password` — changing a password, as data.
-}
updatePasswordRequest : { currentPassword : String, newPassword : String } -> RequestSpec
updatePasswordRequest body =
    { method = "PUT"
    , url = Api.Url.path [ "api", "settings", "password" ] []
    , body =
        Just
            (Requests.encodeUpdatePasswordRequest
                { currentPassword = body.currentPassword
                , newPassword = body.newPassword
                }
            )
    }


{-| Notification preference flags.
-}
type alias NotificationPreferences =
    { priceDrops : Bool
    , newReviews : Bool
    , authorUpdates : Bool
    , eventAlerts : Bool
    }


{-| `GET /api/settings/notifications` — the reader's notification choices, as data.
-}
notificationsRequest : RequestSpec
notificationsRequest =
    { method = "GET"
    , url = Api.Url.path [ "api", "settings", "notifications" ] []
    , body = Nothing
    }


{-| Decode the four notification flags. Label↔field mapping mirrors
`updateNotifications`' encoder exactly: priceDrops↔notify\_wishlist\_availability,
newReviews↔notify\_marketplace, authorUpdates↔notify\_group\_invitations,
eventAlerts↔notify\_event\_matches.
-}
notificationPreferencesDecoder : Decoder NotificationPreferences
notificationPreferencesDecoder =
    Decode.map4 NotificationPreferences
        (Decode.field "notify_wishlist_availability" Decode.bool)
        (Decode.field "notify_marketplace" Decode.bool)
        (Decode.field "notify_group_invitations" Decode.bool)
        (Decode.field "notify_event_matches" Decode.bool)


{-| `PUT /api/settings/notifications` — saving the reader's notification choices, as data.

⚠️ The field names do not line up, and that is pre-existing: the model's
`priceDrops`/`newReviews`/`authorUpdates`/`eventAlerts` map onto the wire's
`notify_wishlist_availability`/`notify_marketplace`/`notify_group_invitations`/
`notify_event_matches`. The mapping moved here unchanged; renaming either side is
its own change.

-}
updateNotificationsRequest : NotificationPreferences -> RequestSpec
updateNotificationsRequest prefs =
    { method = "PUT"
    , url = Api.Url.path [ "api", "settings", "notifications" ] []
    , body =
        Just
            (Requests.encodeUpdateNotificationsRequest
                { notifyWishlistAvailability = prefs.priceDrops
                , notifyMarketplace = prefs.newReviews
                , notifyGroupInvitations = prefs.authorUpdates
                , notifyEventMatches = prefs.eventAlerts
                }
            )
    }


{-| Response from POST /api/books/:id/merge-format — the new edition.
-}
type alias MergeFormatResponse =
    { edition : Edition
    }


{-| Adapter: proto MergeFormatResponse -> app MergeFormatResponse.
Maps proto Edition through the app-level edition adapter.
-}
mergeFormatResponseDecoder : Decoder MergeFormatResponse
mergeFormatResponseDecoder =
    Decode.map (\resp -> { edition = Types.Book.fromProtoEdition resp.edition })
        ProtoBookResp.decodeMergeFormatResponse


{-| `POST /api/books/:id/merge-format` — add a new edition to a book the reader
already owns, rather than creating a second work for the same title.
-}
mergeFormatRequest : String -> { isbn : String, formatLabel : String } -> RequestSpec
mergeFormatRequest bookId body =
    { method = "POST"
    , url = Api.Url.path [ "api", "books", bookId, "merge-format" ] []
    , body =
        Just
            (Requests.encodeMergeFormatRequest
                { isbn = body.isbn
                , formatLabel = body.formatLabel
                }
            )
    }


{-| Parameters for creating a new listing.
-}
type alias ListingParams =
    { bookId : String
    , condition : String
    , pricingMode : String
    , priceZar : Maybe Int
    , contactInfo : String
    , description : String
    }


{-| `GET /api/listings` — the marketplace's active listings, as data.

⚖️ `public` with an OPTIONAL credential, for the same reason as the archive: the
browse grid is readable by anyone, and a session only changes what is in it.

-}
getListingsRequest : RequestSpec
getListingsRequest =
    { method = "GET"
    , url = Api.Url.path [ "api", "listings" ] []
    , body = Nothing
    }


{-| `GET /api/listings/mine` — the reader's own marketplace listings, as data.
-}
myListingsRequest : RequestSpec
myListingsRequest =
    { method = "GET"
    , url = Api.Url.path [ "api", "listings", "mine" ] []
    , body = Nothing
    }


{-| `POST /api/listings` — offering a book for sale, as data.
-}
createListingRequest : ListingParams -> RequestSpec
createListingRequest params =
    { method = "POST"
    , url = Api.Url.path [ "api", "listings" ] []
    , body =
        Just
            (Requests.encodeCreateListingRequest
                { -- Backend Marketplace.create_listing reads book_id; the
                  placementId = ""
                , bookId = params.bookId
                , condition = params.condition
                , pricingMode = params.pricingMode
                , priceZar = params.priceZar
                , contactInfo = params.contactInfo
                , description = params.description
                }
            )
    }


{-| `PUT /api/listings/:id/:transition` — moving a listing's state, as data.

⚖️ ONE spec where there were THREE — `activate`, `deactivate`, `sold` —
differing only in the final path segment. The transition is an argument now, and
a type, so an unknown one does not compile rather than 404ing.

⚠️ The id is percent-encoded, where the old builders concatenated it.

-}
listingTransitionRequest : String -> ListingTransition -> RequestSpec
listingTransitionRequest listingId transition =
    { method = "PUT"
    , url =
        Api.Url.path
            [ "api", "listings", listingId, listingTransitionSegment transition ]
            []
    , body = Nothing
    }


{-| What the seller did to a listing.
-}
type ListingTransition
    = ActivateListing
    | DeactivateListing
    | MarkListingSold


listingTransitionSegment : ListingTransition -> String
listingTransitionSegment transition =
    case transition of
        ActivateListing ->
            "activate"

        DeactivateListing ->
            "deactivate"

        MarkListingSold ->
            "sold"


{-| `GET /api/placements/mine` — the reader's own placements, as data.
-}
myPlacementsRequest : RequestSpec
myPlacementsRequest =
    { method = "GET"
    , url = Api.Url.path [ "api", "placements", "mine" ] []
    , body = Nothing
    }


{-| One page of the cross-author discovery feed.

`nextCursor` is `Nothing` at the end of the corpus, and it — not the length of
`posts` — is what says whether to ask again. The server reads its window BEFORE
applying visibility, so a page can come back short, or even empty, with more to
read behind it.

-}
type alias BlogPostPage =
    { posts : List BlogPostSummary
    , nextCursor : Maybe String
    }


blogPostPageDecoder : Decoder BlogPostPage
blogPostPageDecoder =
    Decode.map2 BlogPostPage
        (Decode.field "posts" (Decode.list blogPostSummaryDecoder))
        -- Absent on the single-author archive, which does not page, so `maybe`
        -- rather than `nullable`: a missing field is not a decode failure here.
        (Decode.maybe (Decode.field "next_cursor" Decode.string))


{-| `GET /api/blog/posts` — the public blog archive, as data.

⚖️ `public` with an OPTIONAL credential: a signed-in reader may see posts an
anonymous one may not, but an anonymous request is answered rather than refused.
`maybeCursor` carries the keyset page, so the archive extends instead of
reloading.

-}
getBlogPostsRequest : Maybe String -> RequestSpec
getBlogPostsRequest maybeCursor =
    { method = "GET"
    , url =
        Api.Url.path
            [ "api", "blog", "posts" ]
            (maybeCursor
                |> Maybe.map (Url.Builder.string "after")
                |> Maybe.map List.singleton
                |> Maybe.withDefault []
            )
    , body = Nothing
    }


{-| `GET /api/blog/posts/:id` — one blog post, as data.
-}
blogPostRequest : String -> RequestSpec
blogPostRequest postId =
    { method = "GET"
    , url = Api.Url.path [ "api", "blog", "posts", postId ] []
    , body = Nothing
    }


{-| `POST /api/blog/posts` — writing a new post, as data.
-}
createBlogPostRequest : { title : String, body : String, visibility : String } -> RequestSpec
createBlogPostRequest postData =
    { method = "POST"
    , url = Api.Url.path [ "api", "blog", "posts" ] []
    , body =
        Just
            (Requests.encodeCreateBlogPostRequest
                { title = postData.title
                , body = postData.body
                , visibility = postData.visibility
                }
            )
    }


{-| `PUT /api/blog/posts/:id` — revising a post, as data.
-}
updateBlogPostRequest : String -> { title : String, body : String, visibility : String } -> RequestSpec
updateBlogPostRequest postId postData =
    { method = "PUT"
    , url = Api.Url.path [ "api", "blog", "posts", postId ] []
    , body =
        Just
            (Requests.encodeUpdateBlogPostRequest
                { title = postData.title
                , body = postData.body
                , visibility = postData.visibility
                }
            )
    }


{-| The paste-ready copy of a post for Substack's editor.
-}
type alias SyndicationExport =
    { format : String
    , canonicalUrl : String
    , body : String
    }


{-| One recorded act of syndication. `syndicatedUrl` is Nothing until the
writer pastes the live Substack URL back ("Also published at").
-}
type alias Syndication =
    { id : String
    , target : String
    , method : String
    , canonicalUrl : String
    , syndicatedUrl : Maybe String
    , createdAt : String
    }


syndicationDecoder : Decoder Syndication
syndicationDecoder =
    Decode.map6 Syndication
        (Decode.field "id" Decode.string)
        (Decode.field "target" Decode.string)
        (Decode.field "method" Decode.string)
        (Decode.field "canonical_url" Decode.string)
        (Decode.field "syndicated_url" (Decode.nullable Decode.string))
        (Decode.field "created_at" Decode.string)


{-| `GET /api/blog/posts/:id/syndication` — a post rendered for another
platform's editor, as data.

⚖️ `format` is a real query PARAMETER now, where the builder appended
`"?format=" ++ format` to the path by hand.

-}
syndicationExportRequest : String -> String -> RequestSpec
syndicationExportRequest postId format =
    { method = "GET"
    , url =
        Api.Url.path [ "api", "blog", "posts", postId, "syndication" ]
            [ Url.Builder.string "format" format ]
    , body = Nothing
    }


{-| The export payload's decoder, exposed so a plan's caller can resolve it.
-}
syndicationExportDecoder : Decoder SyndicationExport
syndicationExportDecoder =
    Decode.map3 SyndicationExport
        (Decode.field "format" Decode.string)
        (Decode.field "canonical_url" Decode.string)
        (Decode.field "body" Decode.string)


{-| `GET /api/blog/posts/:id/syndications` — where a post has been cross-posted, as data.
-}
syndicationsRequest : String -> RequestSpec
syndicationsRequest postId =
    { method = "GET"
    , url = Api.Url.path [ "api", "blog", "posts", postId, "syndications" ] []
    , body = Nothing
    }


{-| `POST /api/blog/posts/:id/syndications` — noting a cross-post, as data.
-}
recordSyndicationRequest : String -> String -> RequestSpec
recordSyndicationRequest postId method =
    { method = "POST"
    , url = Api.Url.path [ "api", "blog", "posts", postId, "syndications" ] []
    , body = Just (Encode.object [ ( "method", Encode.string method ) ])
    }


{-| `PUT /api/blog/posts/:post/syndications/:id` — recording where a cross-post
landed, as data.
-}
updateSyndicationUrlRequest : String -> String -> String -> RequestSpec
updateSyndicationUrlRequest postId sid url =
    { method = "PUT"
    , url = Api.Url.path [ "api", "blog", "posts", postId, "syndications", sid ] []
    , body = Just (Encode.object [ ( "syndicated_url", Encode.string url ) ])
    }


{-| `PUT /api/blog/posts/:id` — flipping a post's syndicated flag, as data.
-}
setPostSyndicatedRequest : String -> Bool -> RequestSpec
setPostSyndicatedRequest postId syndicated =
    { method = "PUT"
    , url = Api.Url.path [ "api", "blog", "posts", postId ] []
    , body = Just (Encode.object [ ( "syndicated", Encode.bool syndicated ) ])
    }


{-| `POST /api/blog/posts/:id/publish` — making a post visible, as data.
-}
publishBlogPostRequest : String -> RequestSpec
publishBlogPostRequest postId =
    { method = "POST"
    , url = Api.Url.path [ "api", "blog", "posts", postId, "publish" ] []
    , body = Nothing
    }


{-| `PUT /api/blog/posts/:post/associations/:id/:verdict` — the author's answer
to a suggested book association, as data.

⚖️ ONE spec where there were two, differing only in the final segment.

-}
associationVerdictRequest : String -> String -> AssociationVerdict -> RequestSpec
associationVerdictRequest postId associationId verdict =
    { method = "PUT"
    , url =
        Api.Url.path
            [ "api", "blog", "posts", postId, "associations", associationId, associationVerdictSegment verdict ]
            []
    , body = Nothing
    }


{-| What the author decided about a suggested association.
-}
type AssociationVerdict
    = ConfirmAssociation
    | DismissAssociation


associationVerdictSegment : AssociationVerdict -> String
associationVerdictSegment verdict =
    case verdict of
        ConfirmAssociation ->
            "confirm"

        DismissAssociation ->
            "dismiss"


{-| `GET /api/posts/:id/comments` — a post's comment thread, as data.
-}
postCommentsRequest : String -> RequestSpec
postCommentsRequest postId =
    { method = "GET"
    , url = Api.Url.path [ "api", "posts", postId, "comments" ] []
    , body = Nothing
    }


{-| `POST /api/posts/:id/comments` — writing a comment, as data.

⚠️ `parent_id` is ABSENT rather than null for a top-level comment, which is
how the builder did it and is deliberate: an absent key and a null mean
different things to the server, and a null here would read as "reply to
nothing".

-}
createCommentRequest : String -> String -> Maybe String -> RequestSpec
createCommentRequest postId body maybeParentId =
    { method = "POST"
    , url = Api.Url.path [ "api", "posts", postId, "comments" ] []
    , body =
        Just
            (Encode.object
                ([ ( "body", Encode.string body ) ]
                    ++ (maybeParentId
                            |> Maybe.map (\pid -> [ ( "parent_id", Encode.string pid ) ])
                            |> Maybe.withDefault []
                       )
                )
            )
    }


{-| `DELETE /api/comments/:id` — removing a comment, as data.
-}
deleteCommentRequest : String -> RequestSpec
deleteCommentRequest commentId =
    { method = "DELETE"
    , url = Api.Url.path [ "api", "comments", commentId ] []
    , body = Nothing
    }


{-| `PUT /api/settings/profile_visibility` — who may see this reader's profile, as data.
-}
updateProfileVisibilityRequest : String -> RequestSpec
updateProfileVisibilityRequest visibility =
    { method = "PUT"
    , url = Api.Url.path [ "api", "settings", "profile_visibility" ] []
    , body = Just (Requests.encodeUpdateProfileVisibilityRequest { profileVisibility = visibility })
    }


{-| `PUT /api/bookshelves/:name/visibility` — who may see one bookshelf, as data.
-}
updateShelfVisibilityRequest : String -> String -> RequestSpec
updateShelfVisibilityRequest shelfName visibility =
    { method = "PUT"
    , url = Api.Url.path [ "api", "bookshelves", shelfName, "visibility" ] []
    , body = Just (Requests.encodeUpdateShelfVisibilityRequest { visibility = visibility })
    }


{-| `PUT /api/placements/:id/visibility`.

The server enforces the ceiling rule — a placement may not be more visible than
its parent bookshelf — and answers 422 when it is violated. The 200 body
carries the visibility actually stored, which is what the caller adopts.

-}
updatePlacementVisibilityRequest : String -> String -> RequestSpec
updatePlacementVisibilityRequest placementId visibility =
    { method = "PUT"
    , url = Api.Url.path [ "api", "placements", placementId, "visibility" ] []
    , body =
        Just
            (Requests.encodeUpdateShelfVisibilityRequest
                { visibility = visibility }
            )
    }


{-| The visibility the server actually stored.
-}
storedVisibilityDecoder : Decoder String
storedVisibilityDecoder =
    Decode.field "visibility" Decode.string


{-| `PUT /api/placements/:id/formats` — replace the set of formats a reader owns
for one placement.

A whole-list replacement, not a delta, so the caller sends the set it wants to
end up with. The 200 body carries the stored list, which is decoded back rather
than assuming the optimistic set survived — a server that normalises or rejects
a member stays visible.

-}
updatePlacementFormatsRequest : String -> List String -> RequestSpec
updatePlacementFormatsRequest placementId formats =
    { method = "PUT"
    , url = Api.Url.path [ "api", "placements", placementId, "formats" ] []
    , body =
        Just
            (Encode.object
                [ ( "formats", Encode.list Encode.string formats ) ]
            )
    }


{-| The formats the server actually stored, out of the `update_formats` body.
-}
placementFormatsDecoder : Decoder (List String)
placementFormatsDecoder =
    Decode.at [ "placement", "formats" ] (Decode.list Decode.string)


{-| Why a book would not move to the shelf row the reader picked.

A shelf row belongs to exactly one bookshelf, so the interesting rejection is
`wrong_bookshelf`: the row is real and the reader owns it, but it hangs in a
different bookcase. Telling them "failed, try again" invites the same click
forever, so it gets its own constructor and its own sentence.

⛔ 422 is read as `wrong_bookshelf` on status alone, without parsing the body.
The action answers 422 in two cases — a shelf on another bookshelf, and a
missing `shelf_id` — but it distinguishes them only in English prose
("shelf belongs to a different bookshelf" vs "shelf\_id is required"), and
matching on prose makes a copy edit a client bug. The second case is
unreachable from here: `movePlacementToShelfRequest` always writes the key.

-}
type ShelfMoveError
    = ShelfMoveNotFound
    | ShelfMoveForbidden
    | ShelfMoveWrongBookshelf
    | ShelfMoveHttpError Http.Error


{-| The shelf the placement ended up on, or why it did not move.

Success carries the server's `shelf_id` rather than `()`: the caller asked for a
row, and the row it gets back is the only one worth painting. 401 stays an
`Http.Error` so `isUnauthorized` still sees it and the session-expiry path runs.
Pure so the elm-program-test simulated effect can reuse the exact mapping.

-}
shelfMoveResponseToResult : Http.Response String -> Result ShelfMoveError String
shelfMoveResponseToResult response =
    case response of
        Http.BadUrl_ url ->
            Err (ShelfMoveHttpError (Http.BadUrl url))

        Http.Timeout_ ->
            Err (ShelfMoveHttpError Http.Timeout)

        Http.NetworkError_ ->
            Err (ShelfMoveHttpError Http.NetworkError)

        Http.BadStatus_ metadata _ ->
            case metadata.statusCode of
                403 ->
                    Err ShelfMoveForbidden

                404 ->
                    Err ShelfMoveNotFound

                422 ->
                    Err ShelfMoveWrongBookshelf

                code ->
                    Err (ShelfMoveHttpError (Http.BadStatus code))

        Http.GoodStatus_ _ bodyText ->
            case Decode.decodeString placementShelfDecoder bodyText of
                Ok shelfId ->
                    Ok shelfId

                Err err ->
                    Err (ShelfMoveHttpError (Http.BadBody (Decode.errorToString err)))


{-| The shelf the server put the placement on, out of the `move_to_shelf` body.
-}
placementShelfDecoder : Decoder String
placementShelfDecoder =
    Decode.at [ "placement", "shelf_id" ] Decode.string


{-| The reader-facing sentence for a rejected shelf move.
-}
shelfMoveErrorMessage : ShelfMoveError -> String
shelfMoveErrorMessage error =
    case error of
        ShelfMoveNotFound ->
            "That shelf is no longer there. Reload the page and try again."

        ShelfMoveForbidden ->
            "That shelf isn't yours to rearrange."

        ShelfMoveWrongBookshelf ->
            "That shelf belongs to a different bookshelf — move the book to that bookshelf first."

        ShelfMoveHttpError _ ->
            "We couldn't move the book to that shelf. Please try again."


{-| `PUT /api/placements/:id/shelf` — move a placement to a physical shelf row
within the bookshelf it already sits on.

⛔ This is not `moveBookRequest`. That one moves a book between BOOKSHELVES;
this moves it between the ROWS of one bookcase, and the server rejects a row
belonging to any other bookshelf rather than quietly performing the bookshelf
move as well.

-}
movePlacementToShelfRequest : String -> String -> RequestSpec
movePlacementToShelfRequest placementId shelfId =
    { method = "PUT"
    , url = Api.Url.path [ "api", "placements", placementId, "shelf" ] []
    , body = Just (Encode.object [ ( "shelf_id", Encode.string shelfId ) ])
    }


{-| A block failure.

The backend distinguishes three domain errors by a `{"error": "..."}` body:
`already_blocked` and `cannot_block_self` (both HTTP 422) and `not_found`
(HTTP 404). Every other failure (network, timeout, 401, unparsable body) is a
`BlockRequestFailed` carrying the raw `Http.Error` so the caller can still
detect session expiry via `isUnauthorized`.

-}
type BlockError
    = AlreadyBlocked
    | CannotBlockSelf
    | NotFound
    | BlockRequestFailed Http.Error


{-| A single blocked reader as returned by `GET /api/settings/blocked-users`.
-}
type alias BlockedUser =
    { id : String
    , displayName : String
    , blockedAt : String
    }


{-| Paginated response from `GET /api/settings/blocked-users`.
-}
type alias BlockedUsersResponse =
    { blockedUsers : List BlockedUser
    , total : Int
    , page : Int
    }


blockedUserDecoder : Decoder BlockedUser
blockedUserDecoder =
    Decode.map3 BlockedUser
        (Decode.field "id" Decode.string)
        (Decode.field "display_name" Decode.string)
        (Decode.field "blocked_at" Decode.string)


blockedUsersResponseDecoder : Decoder BlockedUsersResponse
blockedUsersResponseDecoder =
    Decode.map3 BlockedUsersResponse
        (Decode.field "blocked_users" (Decode.list blockedUserDecoder))
        (Decode.field "total" Decode.int)
        (Decode.field "page" Decode.int)


{-| What the server said about a block attempt, as a resolver.

⛔ A NAMED FUNCTION, extracted from the lambda inside the old `expectBlock`.
`Effect.authed` takes `onResponse : Http.Response String -> msg`, so a resolver
buried in an `Http.Expect` could not be reused by a plan — and this one carries
real meaning that must not be re-derived: `already_blocked`, `cannot_block_self`
and `not_found` are distinct outcomes the modal words differently.

-}
blockResponseToResult : Http.Response String -> Result BlockError ()
blockResponseToResult response =
    case response of
        Http.BadUrl_ url ->
            Err (BlockRequestFailed (Http.BadUrl url))

        Http.Timeout_ ->
            Err (BlockRequestFailed Http.Timeout)

        Http.NetworkError_ ->
            Err (BlockRequestFailed Http.NetworkError)

        Http.BadStatus_ metadata bodyText ->
            case Decode.decodeString (Decode.field "error" Decode.string) bodyText of
                Ok "already_blocked" ->
                    Err AlreadyBlocked

                Ok "cannot_block_self" ->
                    Err CannotBlockSelf

                Ok "not_found" ->
                    Err NotFound

                _ ->
                    Err (BlockRequestFailed (Http.BadStatus metadata.statusCode))

        Http.GoodStatus_ _ _ ->
            Ok ()


{-| `POST|DELETE /api/users/:id/block` — blocking or unblocking a reader, as data.

⚖️ ONE spec and one url for both, which is what the old pair obscured: they
differed ONLY in the HTTP method, and having two builders invited them to drift
on the path. The method is the decision here.

⚠️ The target id is percent-encoded, where the old builders concatenated it.

-}
blockRequest : String -> BlockAction -> RequestSpec
blockRequest targetUserId action =
    { method = blockActionMethod action
    , url = Api.Url.path [ "api", "users", targetUserId, "block" ] []
    , body = Nothing
    }


{-| Whether the reader is blocking someone or letting them back.
-}
type BlockAction
    = Block
    | Unblock


blockActionMethod : BlockAction -> String
blockActionMethod action =
    case action of
        Block ->
            "POST"

        Unblock ->
            "DELETE"


{-| `GET /api/settings/blocked-users` — who this reader has blocked, as data.

⚠️ The page number is a query PARAMETER now, where the old builder appended
`?page=` to the path by hand. `Api.Url.path` encodes it, so a page value could
not escape the query string even if it stopped being an `Int`.

-}
blockedUsersRequest : Int -> RequestSpec
blockedUsersRequest page =
    { method = "GET"
    , url = Api.Url.path [ "api", "settings", "blocked-users" ] [ Url.Builder.int "page" page ]
    , body = Nothing
    }


{-| A single shelf's saved visibility as returned by `GET /api/settings/privacy`.
-}
type alias ShelfVisibilitySetting =
    { name : String
    , visibility : String
    }


{-| The current user's saved privacy settings: their profile visibility plus the
per-shelf visibility overrides. Used to seed the privacy screen so a returning
user sees their stored values rather than hardcoded defaults.
-}
type alias PrivacySettings =
    { profileVisibility : String
    , shelves : List ShelfVisibilitySetting
    , consentAnalytics : Bool
    , consentWritingAssistant : Bool
    }


shelfVisibilitySettingDecoder : Decoder ShelfVisibilitySetting
shelfVisibilitySettingDecoder =
    Decode.map2 ShelfVisibilitySetting
        (Decode.field "name" Decode.string)
        (Decode.field "visibility" Decode.string)


privacySettingsDecoder : Decoder PrivacySettings
privacySettingsDecoder =
    Decode.map4 PrivacySettings
        (Decode.field "profile_visibility" Decode.string)
        (Decode.field "shelves" (Decode.list shelfVisibilitySettingDecoder))
        (Decode.field "consent_analytics" Decode.bool)
        (Decode.field "consent_writing_assistant" Decode.bool)


{-| `GET /api/settings/privacy` — the reader's privacy choices, as data.
-}
privacySettingsRequest : RequestSpec
privacySettingsRequest =
    { method = "GET"
    , url = Api.Url.path [ "api", "settings", "privacy" ] []
    , body = Nothing
    }


{-| A user's public profile as seen by a viewer: redacted identity fields plus
the bookshelves the viewer is allowed to see (visibility-filtered server-side).
-}
type alias PublicProfile =
    { handle : String
    , displayName : String
    , websiteUrl : String
    , city : String
    , countryCode : String
    , bookshelves : List ProfileShelfSummary
    }


type alias ProfileShelfSummary =
    { name : String
    , hasFeed : Bool
    }


publicProfileDecoder : Decoder PublicProfile
publicProfileDecoder =
    Decode.map6 PublicProfile
        (Decode.field "handle" Decode.string)
        (optionalString "display_name")
        (optionalString "website_url")
        (optionalString "city")
        (optionalString "country_code")
        (Decode.field "bookshelves" (Decode.list profileShelfSummaryDecoder))


profileShelfSummaryDecoder : Decoder ProfileShelfSummary
profileShelfSummaryDecoder =
    Decode.map2 ProfileShelfSummary
        (Decode.field "name" Decode.string)
        (Decode.oneOf [ Decode.field "has_feed" Decode.bool, Decode.succeed False ])


{-| Decodes a string field that may be absent or JSON null, defaulting to "".

⛔ Absent and _wrong_ are different answers. This was written as
`oneOf [ field, Decode.succeed "" ]`, and `oneOf` falls through on ANY failure
of the first branch — so a field arriving as a number, a list or an object
decoded to `""` exactly as an unset one did. The reader saw a blank name or a
blank city, and nothing reported that the server had sent something unreadable.

So the key's PRESENCE is established first (`Decode.value` succeeds on any
present value, and fails only when the key is missing). An absent key defaults;
a present key must then be a string or null, and anything else fails the decode
where it can be seen.

-}
optionalString : String -> Decoder String
optionalString field =
    Decode.maybe (Decode.field field Decode.value)
        |> Decode.andThen
            (\present ->
                case present of
                    Nothing ->
                        Decode.succeed ""

                    Just _ ->
                        Decode.field field (Decode.nullable Decode.string)
                            |> Decode.map (Maybe.withDefault "")
            )


{-| `optionalString`'s rule for a boolean: an absent or `null` flag is `False`,
and anything present that is not a boolean fails.

A consent flag's column carries `default: false` but no `NOT NULL`, so `null`
on the wire is reachable and means "never consented" — the same answer as
absent. A value that is neither is a response we cannot read, and reading it as
`False` would quietly withdraw a consent the reader gave.

-}
optionalBool : String -> Decoder Bool
optionalBool field =
    Decode.maybe (Decode.field field Decode.value)
        |> Decode.andThen
            (\present ->
                case present of
                    Nothing ->
                        Decode.succeed False

                    Just _ ->
                        Decode.field field (Decode.nullable Decode.bool)
                            |> Decode.map (Maybe.withDefault False)
            )


{-| `GET /api/u/:handle` — a reader's public profile, as data.

⚖️ **A PUBLIC plan with an OPTIONAL credential, which is not the same as an
unauthenticated one.** The server resolves what THIS viewer may see, so a
signed-in viewer sees more than an anonymous one — but an anonymous request is
answered rather than refused. That is `Effect.public`'s case exactly.

⚠️ So a 401 here is NOT routed to the expiry interceptor by the seam, and the
page keeps its own reading of one. On this endpoint that reading is right: an
anonymous request is answered 200 or 404, never 401, so a 401 can only mean a
credential was sent and refused. `Page.Profile` is therefore one of the places
where an `isUnauthorized` re-test is correct rather than residue.

⬛ The handle is percent-encoded by `Api.Url.path`, where the old builder
concatenated it into the URL unescaped.

-}
getProfileRequest : String -> RequestSpec
getProfileRequest handle =
    { method = "GET"
    , url = Api.Url.path [ "api", "u", handle ] []
    , body = Nothing
    }


{-| `POST /api/bookshelves/:name/shelves` — add a shelf row to the bottom of a
bookcase.

No body: the position is the server's to assign, and letting the client propose
one invites two tabs choosing the same.

-}
createShelfRequest : String -> RequestSpec
createShelfRequest bookshelfName =
    { method = "POST"
    , url = Api.Url.path [ "api", "bookshelves", bookshelfName, "shelves" ] []
    , body = Just (Encode.object [])
    }


{-| `DELETE /api/shelves/:id` — remove a shelf row.

⚠️ **422 means the row still has books on it** and the server refused. That is
an outcome the reader must be told about, not a transport failure to swallow —
deleting a row out from under its books would strand them.

-}
deleteShelfRequest : String -> RequestSpec
deleteShelfRequest shelfId =
    { method = "DELETE"
    , url = Api.Url.path [ "api", "shelves", shelfId ] []
    , body = Nothing
    }


{-| `PUT /api/bookshelves/:name/shelves/reorder` — set the order of every row in
a bookcase.

Sends the WHOLE order rather than "move row X to position N": the server then
has no ambiguity to resolve, and two reorders racing produce one of the two
orders rather than an interleaving neither reader asked for.

-}
reorderShelvesRequest : String -> List String -> RequestSpec
reorderShelvesRequest bookshelfName shelfIds =
    { method = "PUT"
    , url = Api.Url.path [ "api", "bookshelves", bookshelfName, "shelves", "reorder" ] []
    , body =
        Just
            (Encode.object [ ( "shelf_ids", Encode.list Encode.string shelfIds ) ])
    }


{-| `GET /api/u/:handle/bookshelves/:name` — another reader's bookshelf, for
read-only browsing. Optional auth: the viewer's identity is threaded so the
backend visibility-filters the placements.
-}
getProfileShelfRequest : String -> String -> RequestSpec
getProfileShelfRequest handle bookshelfName =
    { method = "GET"
    , url = Api.Url.path [ "api", "u", handle, "bookshelves", bookshelfName ] []
    , body = Nothing
    }


{-| A single people-search result — the redacted `public_profile_summary` shape
(handle + display\_name + location). Shelf-less; the server excludes ghosts and
blocked users from the result set in SQL, so every summary here is discoverable.
-}
type alias PublicProfileSummary =
    { handle : String
    , displayName : String
    , city : String
    , countryCode : String
    }


publicProfileSummaryDecoder : Decoder PublicProfileSummary
publicProfileSummaryDecoder =
    Decode.map4 PublicProfileSummary
        (Decode.field "handle" Decode.string)
        (optionalString "display_name")
        (optionalString "city")
        (optionalString "country_code")


{-| `GET /api/search/users` — people search. Optional auth: a signed-in
viewer's token lets the server apply bidirectional block-exclusion, and ghosts
are excluded server-side either way.
-}
searchUsersRequest : String -> RequestSpec
searchUsersRequest query =
    { method = "GET"
    , url = Api.Url.path [ "api", "search", "users" ] [ Url.Builder.string "q" query ]
    , body = Nothing
    }


{-| The people half of search: `{users: [...]}`.
-}
peopleSearchDecoder : Decoder (List PublicProfileSummary)
peopleSearchDecoder =
    Decode.field "users" (Decode.list publicProfileSummaryDecoder)


authHeaders : String -> Maybe Credentials -> List Http.Header
authHeaders method maybeToken =
    httpHeaders method (Optional maybeToken)


{-| Headers for a plan: the credential if there is one, and the proof from
whichever source holds it.

⛔ **ONE resolver, not two sources.** A signed-in reader's proof arrives inside
their `Credentials`; a signed-OUT visitor has no `Credentials` and their proof
arrives on the plan. Both are real and the request needs whichever exists — but
the CHOICE between them is made here, once, rather than at each call site.

⚠️ This exists because the proof was originally reachable only through a
credential, which made `POST /api/auth/login` — a write performed by definition
without a session — send no proof at all. Driven on a deployed preview; invisible
to 2208 unit tests, each of which built a credential in order to ask its
question.

⚖️ The credential's own proof wins when present, so a reader whose cookie has
rotated since boot still sends the value their session was established with
rather than two different ones on consecutive requests.

-}
planHeaders : String -> Maybe Credentials -> Maybe String -> List Http.Header
planHeaders method maybeToken planProof =
    case maybeToken of
        Just creds ->
            httpHeaders method (Optional (Just creds))

        Nothing ->
            proofHeaders method planProof


{-| A source as returned by the admin sources API.
-}
type alias AdminSource =
    { id : String
    , name : String
    , url : String
    , sourceType : String
    , status : String
    , confidenceScore : Float
    }


{-| Adapter: proto DiscoveredSource -> app AdminSource.
-}
fromProtoDiscoveredSource : ProtoSourceResp.DiscoveredSource -> AdminSource
fromProtoDiscoveredSource proto =
    { id = proto.id
    , name = proto.name
    , url = proto.url
    , sourceType = proto.type_
    , status = proto.status
    , confidenceScore = proto.confidence
    }


adminSourceDecoder : Decoder AdminSource
adminSourceDecoder =
    Decode.map fromProtoDiscoveredSource ProtoSourceResp.decodeDiscoveredSource


{-| Paginated admin sources response.
-}
type alias AdminSourcesResponse =
    { sources : List AdminSource
    , total : Int
    , page : Int
    , perPage : Int
    }


{-| Adapter: proto SourceAdminListResponse -> app AdminSourcesResponse.

Proto has no perPage field — we default to 20 (the server default page size).

-}
fromProtoSourceAdminListResponse : ProtoSourceResp.SourceAdminListResponse -> AdminSourcesResponse
fromProtoSourceAdminListResponse proto =
    { sources = List.map fromProtoDiscoveredSource proto.sources
    , total = proto.total
    , page = proto.page
    , perPage = 20
    }


adminSourcesResponseDecoder : Decoder AdminSourcesResponse
adminSourcesResponseDecoder =
    Decode.map fromProtoSourceAdminListResponse ProtoSourceResp.decodeSourceAdminListResponse


{-| The admin-session flow — the layer whose absence made four admin
pages dead: `/api/admin/*` requires an MFA-verified `admin_session`
token (IP- and boot\_id-bound), and the pages were passing the ordinary
Guardian token, so every admin surface 401'd. Two steps: password →
challenge id, TOTP → admin token; the token lives only in memory
(`Model.adminSession`), never localStorage.
-}
type alias AdminSession =
    { sessionId : String }


{-| Why a distinct error type rather than passing `Http.Error` up: every failure here has a
different remedy, and an operator staring at "something went wrong" cannot tell which. A wrong
password, a non-owner account, an unenrolled factor and a stale code are four different next
actions.
-}
type AdminAuthError
    = InvalidCredentials
    | NotAnOwner
    | MfaNotEnrolled
    | InvalidCode
    | InvalidSession
    | AlreadyVerified
    | AdminAuthTransport Http.Error


{-| POST /api/admin/auth/login — step 1. Returns an UNVERIFIED session id, not a usable token.
-}
adminLogin :
    Maybe String
    -> { email : String, password : String }
    -> (Result AdminAuthError AdminSession -> msg)
    -> Cmd msg
adminLogin proof body toMsg =
    Http.request
        { method = "POST"

        -- ⚠️ NO CREDENTIAL, DECLARED. This endpoint is unauthenticated:
        -- it IS the pre-authentication step —
        -- so it carries no session and is not a CSRF target: there is no ambient
        -- authority for a cross-site request to borrow. Stated rather than left as
        -- an empty list, so the absence is checkable instead of ambiguous.
        , headers = httpHeaders "POST" (NoCredential proof)
        , url = baseUrl ++ "/api/admin/auth/login"
        , body =
            Http.jsonBody
                (Encode.object
                    [ ( "email", Encode.string body.email )
                    , ( "password", Encode.string body.password )
                    ]
                )
        , expect =
            expectAdminJson toMsg
                (Decode.map AdminSession (Decode.field "session_id" Decode.string))
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| POST /api/admin/auth/verify\_mfa — step 2. Returns the admin token.
-}
adminVerifyMfa :
    Maybe String
    -> { sessionId : String, code : String }
    -> (Result AdminAuthError () -> msg)
    -> Cmd msg
adminVerifyMfa proof body toMsg =
    Http.request
        { method = "POST"

        -- ⚠️ NO CREDENTIAL, DECLARED. This endpoint is unauthenticated:
        -- it is the pre-authentication MFA step —
        -- so it carries no session and is not a CSRF target: there is no ambient
        -- authority for a cross-site request to borrow. Stated rather than left as
        -- an empty list, so the absence is checkable instead of ambiguous.
        , headers = httpHeaders "POST" (NoCredential proof)
        , url = baseUrl ++ "/api/admin/auth/verify_mfa"
        , body =
            Http.jsonBody
                (Encode.object
                    [ ( "session_id", Encode.string body.sessionId )
                    , ( "totp_code", Encode.string body.code )
                    ]
                )

        -- ⛔ NO TOKEN TO DECODE. The server records the elevation on the admin
        -- session itself and `AdminAuthPipeline` finds it from the authenticated
        -- reader, so success is a fact rather than a credential. This used to
        -- decode a second Guardian token the app then held in memory, where a
        -- reload lost it and re-prompted for a code the server had accepted.
        , expect = expectAdminJson toMsg (Decode.succeed ())
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| DELETE /api/admin/auth/logout — revoke THIS admin session server-side.

Send it with the ordinary session credential (`Main.sessionCredentials`). The
route reads the admin session off the admin pipeline, which now finds it from
the authenticated reader rather than from a token the client carries — so there
is one credential for this path and every other `/api/admin/*` path.

A `RequestSpec` rather than a `Cmd`-returning function because the caller
dispatches it through `Effect`, which is what lets a program test read the
request instead of restating it.

-}
adminLogoutRequest : RequestSpec
adminLogoutRequest =
    { method = "DELETE"
    , url = Api.Url.path [ "api", "admin", "auth", "logout" ] []
    , body = Nothing
    }


{-| What enrolment hands back: the `otpauth://` URI for an authenticator app, and one-time
recovery codes the operator must record before continuing.
-}
type alias AdminMfaEnrolment =
    { provisioningUri : String
    , recoveryCodes : List String
    }


{-| POST /api/admin/auth/mfa/setup — takes the ORDINARY owner token (no admin session exists yet).
-}
adminMfaSetup : Credentials -> (Result Http.Error AdminMfaEnrolment -> msg) -> Cmd msg
adminMfaSetup ownerToken toMsg =
    Http.request
        { method = "POST"
        , headers = httpHeaders "POST" (Session ownerToken)
        , url = baseUrl ++ "/api/admin/auth/mfa/setup"
        , body = Http.jsonBody (Encode.object [])
        , expect =
            Http.expectJson toMsg
                (Decode.map2 AdminMfaEnrolment
                    (Decode.field "provisioning_uri" Decode.string)
                    (Decode.field "recovery_codes" (Decode.list Decode.string))
                )
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| POST /api/admin/auth/mfa/confirm — completes enrolment.

Pass `secret` **exactly as it appears in the provisioning URI** — the `secret=` parameter, base32,
unmodified.

⚠️ It used to demand base64 of the raw bytes, which no client could produce: `adminMfaSetup` returns
only the URI, and the secret inside it is base32. Getting it wrong returned `422 invalid_code`,
reading as clock skew rather than an encoding mismatch. The endpoint was changed to accept what its
own setup call publishes (2026-07-29) rather than have every client base32-decode and re-encode.
**Do not "fix" this by implementing base32 in Elm** — the contract is correct now.

-}
adminMfaConfirm :
    Credentials
    -> { code : String, secret : String, recoveryCodes : List String }
    -> (Result Http.Error () -> msg)
    -> Cmd msg
adminMfaConfirm ownerToken body toMsg =
    Http.request
        { method = "POST"
        , headers = httpHeaders "POST" (Session ownerToken)
        , url = baseUrl ++ "/api/admin/auth/mfa/confirm"
        , body =
            Http.jsonBody
                (Encode.object
                    [ ( "totp_code", Encode.string body.code )
                    , ( "secret", Encode.string body.secret )
                    , ( "recovery_codes", Encode.list Encode.string body.recoveryCodes )
                    ]
                )
        , expect = Http.expectWhatever toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| Maps the endpoint's `{"error": "..."}` bodies onto `AdminAuthError`, so each failure keeps the
remedy the operator needs. An unrecognised shape stays transport-level rather than being guessed at.
-}
expectAdminJson : (Result AdminAuthError a -> msg) -> Decode.Decoder a -> Http.Expect msg
expectAdminJson toMsg decoder =
    Http.expectStringResponse toMsg
        (\response ->
            case response of
                Http.GoodStatus_ _ body ->
                    Decode.decodeString decoder body
                        |> Result.mapError (Http.BadBody << Decode.errorToString)
                        |> Result.mapError AdminAuthTransport

                Http.BadStatus_ _ body ->
                    Err (adminErrorFromBody body)

                Http.BadUrl_ url ->
                    Err (AdminAuthTransport (Http.BadUrl url))

                Http.Timeout_ ->
                    Err (AdminAuthTransport Http.Timeout)

                Http.NetworkError_ ->
                    Err (AdminAuthTransport Http.NetworkError)
        )


adminErrorFromBody : String -> AdminAuthError
adminErrorFromBody body =
    case Decode.decodeString (Decode.field "error" Decode.string) body of
        Ok "invalid_credentials" ->
            InvalidCredentials

        Ok "insufficient_role" ->
            NotAnOwner

        Ok "mfa_not_enrolled" ->
            MfaNotEnrolled

        Ok "invalid_code" ->
            InvalidCode

        Ok "invalid_session" ->
            InvalidSession

        -- The admin pipeline's own refusal body. It reaches the operator when a
        -- pipelined call fails session validation (revoked, expired, boot_id,
        -- or an IP that no longer matches) — every one of which means "this
        -- session is over", not "the network is down". Left unmapped, it fell
        -- to the transport catch-all and rendered as a connectivity error.
        Ok "unauthorized" ->
            InvalidSession

        Ok "already_verified" ->
            AlreadyVerified

        _ ->
            AdminAuthTransport (Http.BadBody body)


{-| A business waiting on a human decision about its listing.

`GET /api/admin/removal-requests`. A removal request whose contact address was not on the
listing's own domain cannot be auto-verified, so it parks with `exclusion_requested_at` set
and the listing **still live** until someone rules on it.

`email` is the whole reason a human is looking — it is what the reviewer judges. Without it
the queue is a list of names.

-}
type alias RemovalRequest =
    { id : String
    , name : String
    , url : String
    , sourceType : String
    , email : Maybe String
    , requestedAt : Maybe String
    }


removalRequestDecoder : Decoder RemovalRequest
removalRequestDecoder =
    Decode.map6 RemovalRequest
        (Decode.field "id" Decode.string)
        (Decode.field "name" Decode.string)
        (Decode.field "url" Decode.string)
        (Decode.field "type" Decode.string)
        (Decode.maybe (Decode.field "exclusion_email" Decode.string))
        (Decode.maybe (Decode.field "requested_at" Decode.string))


{-| `GET /api/admin/removal-requests` — the delisting queue, as data.
-}
removalRequestsRequest : RequestSpec
removalRequestsRequest =
    { method = "GET"
    , url = Api.Url.path [ "api", "admin", "removal-requests" ] []
    , body = Nothing
    }


{-| An invitation as the owner's list sees it: `codePrefix` only —
the full code is unrecoverable after issue, and only `createAdminInvite`'s
response ever carries it.
-}
type alias AdminInvite =
    { id : String
    , codePrefix : String
    , note : Maybe String
    , invitedEmail : Maybe String
    , maxUses : Int
    , useCount : Int
    , expiresAt : Maybe String
    , revokedAt : Maybe String
    , redeemedAt : Maybe String
    , redeemedByHandle : Maybe String
    }


andMap : Decoder a -> Decoder (a -> b) -> Decoder b
andMap =
    Decode.map2 (|>)


adminInviteDecoder : Decoder AdminInvite
adminInviteDecoder =
    Decode.succeed AdminInvite
        |> andMap (Decode.field "id" Decode.string)
        |> andMap (Decode.field "code_prefix" Decode.string)
        |> andMap (Decode.field "note" (Decode.nullable Decode.string))
        |> andMap (Decode.field "invited_email" (Decode.nullable Decode.string))
        |> andMap (Decode.field "max_uses" Decode.int)
        |> andMap (Decode.field "use_count" Decode.int)
        |> andMap (Decode.field "expires_at" (Decode.nullable Decode.string))
        |> andMap (Decode.field "revoked_at" (Decode.nullable Decode.string))
        |> andMap (Decode.field "redeemed_at" (Decode.nullable Decode.string))
        |> andMap (Decode.field "redeemed_by_handle" (Decode.nullable Decode.string))


{-| One reader's message in the owner's queue.

`body` is the reader's own free text, and this record is the only place in the
SPA it exists. It is fetched by the admin page and rendered there; nothing
caches it, and no other surface asks for it.

-}
type alias AdminFeedbackEntry =
    { id : String
    , body : String
    , pageContext : Maybe String
    , senderHandle : Maybe String
    , createdAt : String
    }


{-| One page of the queue, with the size of the whole queue beside it.

`total` is what lets the page say "1–25 of 143" rather than just listing what
came back. Without it a full page and a truncated queue are indistinguishable,
and the end that falls off is the oldest.

-}
type alias AdminFeedbackPage =
    { entries : List AdminFeedbackEntry
    , total : Int
    }


adminFeedbackEntryDecoder : Decoder AdminFeedbackEntry
adminFeedbackEntryDecoder =
    Decode.succeed AdminFeedbackEntry
        |> andMap (Decode.field "id" Decode.string)
        |> andMap (Decode.field "body" Decode.string)
        |> andMap (Decode.field "page_context" (Decode.nullable Decode.string))
        |> andMap (Decode.field "sender_handle" (Decode.nullable Decode.string))
        |> andMap (Decode.field "created_at" Decode.string)


adminFeedbackPageDecoder : Decoder AdminFeedbackPage
adminFeedbackPageDecoder =
    Decode.succeed AdminFeedbackPage
        |> andMap (Decode.field "feedback" (Decode.list adminFeedbackEntryDecoder))
        |> andMap (Decode.field "total" Decode.int)


{-| The data of `getAdminFeedback`'s request — see `RequestSpec`.

Factored out so the window can be asserted. Built inline, the query string was
the one piece of this change nothing could reach: an off-by-one in the offset
would serve the same page forever and every paging test would still pass,
because those tests assert the model, never the request.

-}
adminFeedbackRequest : { limit : Int, offset : Int } -> RequestSpec
adminFeedbackRequest window =
    { method = "GET"
    , url =
        Api.Url.path [ "api", "admin", "feedback" ]
            [ Url.Builder.int "limit" window.limit
            , Url.Builder.int "offset" window.offset
            ]
    , body = Nothing
    }


{-| The data of `sendFeedback`'s request — see `RequestSpec`.
-}
sendFeedbackRequest : { body : String, pageContext : String } -> RequestSpec
sendFeedbackRequest body =
    { method = "POST"
    , url = Api.Url.path [ "api", "feedback" ] []
    , body =
        Just
            (Encode.object
                [ ( "body", Encode.string body.body )
                , ( "page_context", Encode.string body.pageContext )
                ]
            )
    }


{-| `GET /api/admin/invites` — the invite list, as data.
-}
adminInvitesRequest : RequestSpec
adminInvitesRequest =
    { method = "GET"
    , url = Api.Url.path [ "api", "admin", "invites" ] []
    , body = Nothing
    }


{-| `POST /api/admin/invites` — minting an invite, as data.
-}
createAdminInviteRequest :
    { note : String, invitedEmail : String, maxUses : Int, expiresInDays : Maybe Int }
    -> RequestSpec
createAdminInviteRequest body =
    { method = "POST"
    , url = Api.Url.path [ "api", "admin", "invites" ] []
    , body =
        Just
            (Encode.object
                (List.filterMap identity
                    [ blankAsAbsent "note" body.note
                    , blankAsAbsent "invited_email" body.invitedEmail
                    , Just ( "max_uses", Encode.int body.maxUses )
                    , Maybe.map (\days -> ( "expires_in_days", Encode.int days )) body.expiresInDays
                    ]
                )
            )
    }


blankAsAbsent : String -> String -> Maybe ( String, Encode.Value )
blankAsAbsent key value =
    if String.trim value == "" then
        Nothing

    else
        Just ( key, Encode.string (String.trim value) )


{-| `DELETE /api/admin/invites/:id` — revoking an invite, as data.

⚠️ The id is percent-encoded by `Api.Url.path`, where the old builder
concatenated it into the URL.

-}
revokeAdminInviteRequest : String -> RequestSpec
revokeAdminInviteRequest id =
    { method = "DELETE"
    , url = Api.Url.path [ "api", "admin", "invites", id ] []
    , body = Nothing
    }


{-| `PUT /api/admin/removal-requests/:id/:decision` — the owner's answer to a
delisting request, as data.

⚖️ ONE spec where there were three functions. `honour` and `decline` differed
only in a path segment, so they were two wrappers delegating to a shared
`removalDecision` builder — three declarations to say one thing. As data the
decision is an argument, which is what it always was.

⚠️ The id is percent-encoded by `Api.Url.path`, where the old builder
concatenated it into the URL.

-}
removalDecisionRequest : String -> RemovalDecision -> RequestSpec
removalDecisionRequest requestId decision =
    { method = "PUT"
    , url =
        Api.Url.path
            [ "api", "admin", "removal-requests", requestId, removalDecisionSegment decision ]
            []
    , body = Nothing
    }


{-| Which way the owner answered a delisting request.

⛔ A TYPE rather than a `String`, because the old pair put the path segment at
the call site as a bare literal. A typo there was a 404 at runtime; here it does
not compile.

-}
type RemovalDecision
    = HonourRemoval
    | DeclineRemoval


removalDecisionSegment : RemovalDecision -> String
removalDecisionSegment decision =
    case decision of
        HonourRemoval ->
            "honour"

        DeclineRemoval ->
            "decline"


{-| `GET /api/admin/sources` — the source queue, as data.
-}
adminSourcesRequest : { status : Maybe String, page : Int } -> RequestSpec
adminSourcesRequest params =
    { method = "GET"
    , url =
        Api.Url.path [ "api", "admin", "sources" ]
            ([ Just (Url.Builder.int "page" params.page)
             , params.status |> Maybe.map (Url.Builder.string "status")
             ]
                |> List.filterMap identity
            )
    , body = Nothing
    }


{-| `PUT /api/admin/sources/:id/approve` — approving a pending source, as data.

⚠️ The id is percent-encoded, where the old builder concatenated it.

-}
approveSourceRequest : String -> RequestSpec
approveSourceRequest sourceId =
    { method = "PUT"
    , url = Api.Url.path [ "api", "admin", "sources", sourceId, "approve" ] []
    , body = Nothing
    }


{-| `PUT /api/admin/sources/:id/reject` — rejecting a pending source, as data.

⚠️ The id is percent-encoded, where the old builder concatenated it.

-}
rejectSourceRequest : String -> RequestSpec
rejectSourceRequest sourceId =
    { method = "PUT"
    , url = Api.Url.path [ "api", "admin", "sources", sourceId, "reject" ] []
    , body = Nothing
    }


{-| A book as returned by the owner moderation API.
-}
type alias AdminBook =
    { id : String
    , title : String
    , author : String
    , visibilityTier : String
    , isbn : Maybe String
    , coverImageUrl : Maybe String
    }


adminBookDecoder : Decoder AdminBook
adminBookDecoder =
    Decode.map6 AdminBook
        (Decode.field "id" Decode.string)
        (Decode.field "title" Decode.string)
        (Decode.oneOf [ Decode.field "author" Decode.string, Decode.succeed "" ])
        (Decode.field "visibility_tier" Decode.string)
        (Decode.maybe (Decode.field "isbn" Decode.string))
        (Decode.maybe (Decode.field "cover_image_url" Decode.string))


{-| Paginated admin books response.
-}
type alias AdminBooksResponse =
    { books : List AdminBook
    , total : Int
    , page : Int
    , perPage : Int
    }


adminBooksResponseDecoder : Decoder AdminBooksResponse
adminBooksResponseDecoder =
    Decode.map4 AdminBooksResponse
        (Decode.field "books" (Decode.list adminBookDecoder))
        (Decode.field "total" Decode.int)
        (Decode.field "page" Decode.int)
        (Decode.oneOf [ Decode.field "per_page" Decode.int, Decode.succeed 50 ])


{-| The data of `adminListBooks`'s request — see `RequestSpec`.
-}
adminListBooksRequest :
    { tier : Maybe String, search : Maybe String, page : Int }
    -> RequestSpec
adminListBooksRequest params =
    { method = "GET"
    , url =
        Api.Url.path [ "api", "admin", "books" ]
            (List.filterMap identity
                [ Just (Url.Builder.int "page" params.page)
                , params.tier |> Maybe.map (Url.Builder.string "tier")
                , params.search |> Maybe.map (Url.Builder.string "search")
                ]
            )
    , body = Nothing
    }


{-| The data of `adminSetBookAgeGate`'s request — see `RequestSpec`.
-}
adminSetBookAgeGateRequest : String -> Bool -> RequestSpec
adminSetBookAgeGateRequest bookId ageGated =
    { method = "PUT"
    , url = Api.Url.path [ "api", "admin", "books", bookId, "age-gate" ] []
    , body = Just (Encode.object [ ( "age_gated", Encode.bool ageGated ) ])
    }


{-| The `{book: ...}` envelope an admin book mutation answers with.
-}
adminBookEnvelopeDecoder : Decoder AdminBook
adminBookEnvelopeDecoder =
    Decode.field "book" adminBookDecoder


{-| Source health record from GET /api/admin/source-health.
-}
type alias SourceHealth =
    { name : String
    , sourceType : String
    , status : String
    , consecutiveFailures : Int
    , lastSuccess : Maybe String
    , lastFailure : Maybe String
    }


{-| Decoder for one source-health record.

The `/api/admin/source-health` endpoint emits `source_type` and `status`
as **plain strings** (not proto enums), alongside `last_success_at`/`last_failure_at`.
Decode that JSON shape directly rather than through the proto SourceHealthCheck decoder.

-}
sourceHealthDecoder : Decoder SourceHealth
sourceHealthDecoder =
    Decode.map6 SourceHealth
        (Decode.field "name" Decode.string)
        (Decode.field "source_type" Decode.string)
        (Decode.field "status" Decode.string)
        (Decode.field "consecutive_failures" Decode.int)
        (Decode.maybe (Decode.field "last_success_at" Decode.string))
        (Decode.maybe (Decode.field "last_failure_at" Decode.string))


sourceHealthListDecoder : Decoder (List SourceHealth)
sourceHealthListDecoder =
    Decode.field "data" (Decode.list sourceHealthDecoder)


{-| `GET /api/admin/source-health` — scraper source health, as data.
-}
sourceHealthRequest : RequestSpec
sourceHealthRequest =
    { method = "GET"
    , url = Api.Url.path [ "api", "admin", "source-health" ] []
    , body = Nothing
    }


{-| Onboarding status response from GET /api/onboarding/status.
-}
type alias OnboardingStatus =
    { completed : Bool
    , nextStep : Maybe String
    }


onboardingStatusDecoder : Decoder OnboardingStatus
onboardingStatusDecoder =
    Decode.map2 OnboardingStatus
        (Decode.oneOf [ Decode.field "completed" Decode.bool, Decode.succeed False ])
        (Decode.maybe (Decode.field "next_step" Decode.string)
            |> Decode.map
                (\ms ->
                    case ms of
                        Just "" ->
                            Nothing

                        other ->
                            other
                )
        )


{-| `GET /api/onboarding/status` — where the reader is in onboarding, as data.
-}
onboardingStatusRequest : RequestSpec
onboardingStatusRequest =
    { method = "GET"
    , url = Api.Url.path [ "api", "onboarding", "status" ] []
    , body = Nothing
    }


{-| `POST /api/onboarding/step/:step` — marking an onboarding step done, as data.
-}
completeOnboardingStepRequest : String -> RequestSpec
completeOnboardingStepRequest step =
    { method = "POST"
    , url = Api.Url.path [ "api", "onboarding", "step", step ] []
    , body = Nothing
    }


{-| `POST /api/groups` — starting a reading group, as data.

⚠️ `type` is fixed to `close_friends`, as it was in the builder. The endpoint
accepts others; this client only ever creates that one, so the literal stays
here rather than becoming a parameter nothing would vary.

-}
createGroupRequest : String -> RequestSpec
createGroupRequest name =
    { method = "POST"
    , url = Api.Url.path [ "api", "groups" ] []
    , body =
        Just
            (Encode.object
                [ ( "name", Encode.string name )
                , ( "type", Encode.string "close_friends" )
                ]
            )
    }


{-| `GET /api/groups/:id` — one reading group, as data.
-}
groupRequest : String -> RequestSpec
groupRequest groupId =
    { method = "GET"
    , url = Api.Url.path [ "api", "groups", groupId ] []
    , body = Nothing
    }


{-| `GET /api/groups/:id/feed` — one group's feed page, as data.

⚖️ The cursor is a real query PARAMETER now. The builder this replaces
assembled `"?before=" ++ cursor` by hand into the url string — and its own
comment records that this was _the one site in the module_ relying on the
weaker same-origin rule. As a spec the question does not arise: the url is an
`Api.Url.SameOriginUrl` and the cursor is an encoded parameter.

-}
groupFeedRequest : String -> Maybe String -> RequestSpec
groupFeedRequest groupId maybeCursor =
    { method = "GET"
    , url =
        Api.Url.path [ "api", "groups", groupId, "feed" ]
            (maybeCursor
                |> Maybe.map (Url.Builder.string "before")
                |> Maybe.map List.singleton
                |> Maybe.withDefault []
            )
    , body = Nothing
    }


{-| `POST /api/groups/:id/invitations` — inviting someone to a group, as data.
-}
inviteToGroupRequest : String -> String -> RequestSpec
inviteToGroupRequest groupId identifier =
    { method = "POST"
    , url = Api.Url.path [ "api", "groups", groupId, "invitations" ] []
    , body = Just (Encode.object [ ( "identifier", Encode.string identifier ) ])
    }


{-| `POST /api/groups/:group/invitations/:id/:answer` — answering a group
invitation, as data.

⚖️ ONE spec where there were two, which differed only in the final path
segment. The answer is an argument now, and a TYPE rather than a string, so a
typo in it does not compile instead of 404ing at runtime.

⚠️ Both ids are percent-encoded by `Api.Url.path`, where the old builders
concatenated them.

-}
invitationAnswerRequest : String -> String -> InvitationAnswer -> RequestSpec
invitationAnswerRequest groupId invitationId answer =
    { method = "POST"
    , url =
        Api.Url.path
            [ "api", "groups", groupId, "invitations", invitationId, invitationAnswerSegment answer ]
            []
    , body = Nothing
    }


{-| Which way a reader answered a group invitation.
-}
type InvitationAnswer
    = AcceptInvitation
    | DeclineInvitation


invitationAnswerSegment : InvitationAnswer -> String
invitationAnswerSegment answer =
    case answer of
        AcceptInvitation ->
            "accept"

        DeclineInvitation ->
            "decline"


{-| A member of a reading group, as the members endpoint returns them.
-}
type alias GroupMember =
    { userId : String
    , role : String
    , displayName : String
    }


groupMemberDecoder : Decoder GroupMember
groupMemberDecoder =
    Decode.map3 GroupMember
        (Decode.field "user_id" Decode.string)
        (Decode.field "role" Decode.string)
        (Decode.field "display_name" Decode.string)


{-| `GET /api/groups/:id/members` — who is in a group, as data.
-}
groupMembersRequest : String -> RequestSpec
groupMembersRequest groupId =
    { method = "GET"
    , url = Api.Url.path [ "api", "groups", groupId, "members" ] []
    , body = Nothing
    }


{-| `DELETE /api/groups/:id/members/:user` — removing someone from a group, as data.

⚠️ BOTH ids are percent-encoded, where the old builder concatenated them.

-}
removeGroupMemberRequest : String -> String -> RequestSpec
removeGroupMemberRequest groupId memberUserId =
    { method = "DELETE"
    , url = Api.Url.path [ "api", "groups", groupId, "members", memberUserId ] []
    , body = Nothing
    }


{-| `DELETE /api/groups/:id/leave` — leaving a group, as data.
-}
leaveGroupRequest : String -> RequestSpec
leaveGroupRequest groupId =
    { method = "DELETE"
    , url = Api.Url.path [ "api", "groups", groupId, "leave" ] []
    , body = Nothing
    }
