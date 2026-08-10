module Api exposing
    ( AdminAuthError(..)
    , AdminBook
    , AdminBooksResponse
    , AdminInvite
    , AdminMfaEnrolment
    , AdminSession
    , AdminSource
    , AdminSourcesResponse
    , AuditLogEntry
    , AuditLogResponse
    , AuthResponse
    , Authed
    , Behaviour
    , BisacCount
    , BlockError(..)
    , BlockedUser
    , BlockedUsersResponse
    , BookDetailResponse
    , CatalogueResponse
    , CollectionHit
    , ConfirmError(..)
    , ConfirmOutcome(..)
    , ConfirmResponse
    , Deanonymisation
    , ImportError(..)
    , ImportRow
    , InboxItem
    , InboxKind(..)
    , InterestProfile
    , InviteStatus
    , LibraryImport
    , ListingParams
    , LiveSignals(..)
    , MergeFormatResponse
    , MoveError(..)
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
    , ProfileShelfSummary
    , Progress
    , ProgressError(..)
    , PublicProfile
    , PublicProfileSummary
    , RegisterError(..)
    , RemovalOutcome(..)
    , RemovalRequest
    , RequestError(..)
    , RequestSpec
    , RiskInference
    , SearchSections
    , ShelfVisibilitySetting
    , SourceHealth
    , SubjectCount
    , Syndication
    , SyndicationExport
    , TransparencyEntry
    , TransparencyMetrics
    , UploadInit
    , acceptInvitation
    , activateListing
    , adminBookDecoder
    , adminBooksResponseDecoder
    , adminListBooks
    , adminLogin
    , adminMfaConfirm
    , adminMfaSetup
    , adminSetBookAgeGate
    , adminVerifyMfa
    , approveSource
    , auditLogResponseDecoder
    , authResponseDecoder
    , authed
    , awaitingConfirmationCount
    , blockUser
    , bookDetailResponseDecoder
    , catalogueResponseDecoder
    , checkInvite
    , commitUpload
    , completeOnboardingStep
    , confirmAssociation
    , confirmBook
    , confirmBookRequest
    , confirmResponseToResult
    , createAdminInvite
    , createBlogPost
    , createComment
    , createGoodreadsImport
    , createGroup
    , createListing
    , createShelf
    , deactivateListing
    , declineInvitation
    , declineRemovalRequest
    , deleteAccount
    , deleteComment
    , deleteShelf
    , dismissAssociation
    , encodeProfileBody
    , fetchSyndicationExport
    , foldProgress
    , forgotPassword
    , getAdminInvites
    , getAdminSources
    , getAuditLog
    , getBlogPost
    , getBlogPosts
    , getBook
    , getBookRequest
    , getBookshelf
    , getCatalogue
    , getGroup
    , getGroupFeed
    , getImport
    , getImportRows
    , getInferences
    , getListings
    , getMyListings
    , getMyPlacements
    , getNotifications
    , getOnboardingStatus
    , getPostComments
    , getPrivacySettings
    , getProfile
    , getProfileShelf
    , getRemovalRequests
    , getSourceHealth
    , getTransparencyMetrics
    , getUploadInbox
    , getUserPlacements
    , honourRemovalRequest
    , initUpload
    , interpretAuthed
    , inviteToGroup
    , isNotFound
    , isUnauthorized
    , leaveGroup
    , listBlockedUsers
    , login
    , logout
    , mergeFormat
    , mergeFormatRequest
    , mergeFormatResponseDecoder
    , moveBook
    , moveResponseToResult
    , personalInferencesDecoder
    , placeBook
    , placeResponseToResult
    , placementsMineDecoder
    , progressErrorMessage
    , progressResponseToResult
    , publicProfileDecoder
    , publicProfileSummaryDecoder
    , publishBlogPost
    , putFileToR2
    , recordSyndication
    , refresh
    , register
    , rejectIdentification
    , rejectSource
    , removeBook
    , reorderShelves
    , requestExport
    , requestListingRemoval
    , resendConfirmation
    , resetPassword
    , resolveAuthResponse
    , resolveNoContent
    , resolveProfile
    , resolveRegister
    , resolveWhatever
    , restoreBook
    , retryAfterSeconds
    , revokeAdminInvite
    , saveConsent
    , saveWritingAssistantConsent
    , searchBooks
    , searchResponseDecoder
    , searchUsers
    , setBookAgeGate
    , setPostSyndicated
    , soldListing
    , standardTimeout
    , streamEventDecoder
    , transparencyMetricsDecoder
    , unblockUser
    , updateBlogPost
    , updateLocation
    , updateNotifications
    , updatePassword
    , updatePlacementVisibility
    , updateProfile
    , updateProfileVisibility
    , updateProgress
    , updateShelfVisibility
    , updateSyndicationUrl
    , uploadTimeout
    )

{-| Every HTTP call the SPA makes, and every decoder that reads a server
response.

A note on the size of the `exposing` list: several decoders here are exported
only so `tests/TestHelpers.elm` and the program tests can wire the REAL decoder
into their simulated effects. That is deliberate and is accepted repo practice.
The alternative — a hand-written "mirror" of the decoder living in the test
harness — is what let the upload SSE wire format drift for months: the mirrors
and the fixtures agreed with each other while disagreeing with the server, and
breaking every production wire field left the whole Elm suite green (Issue
#328). A test that decodes with its own copy of the decoder is testing the
copy.

`elm-review`'s `NoUnused.Exports` reviews `src/` and `tests/` together, so each
of these exports stays justified only while a test consumes it — land an
exposure together with its consumer, never on its own.

The same reasoning covers the `*Request` builders (`RequestSpec`,
`confirmBookRequest`, `getBookRequest`, `mergeFormatRequest`): they carry a
request's method/url/body as data so `TestHelpers`' simulated effects derive
the request from the SAME definition production sends, instead of hand-building
a copy (Issue #347). The demonstrated hole was exactly #328's, on the request
side: hardcoding `confirmBook`'s `shelf_name` left all 1,353 Elm tests green,
because the only test of that body asserted against the translator's copy.

-}

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
import Types.BlogPost exposing (BlogPost, BlogPostSummary, Comment, blogPostDecoder, blogPostSummaryDecoder, commentDecoder)
import Types.Book exposing (Book, Edition, bookDecoder)
import Types.FeedItem exposing (FeedResponse, feedResponseDecoder)
import Types.Group exposing (Group, GroupInvitation, groupDecoder, groupInvitationDecoder)
import Types.Listing exposing (Listing, ListingsResponse, listingDecoder, listingsResponseDecoder)
import Types.Placement exposing (Placement, ReadingStatus, parseReadingStatus, placementDecoder, placementSummaryDecoder)
import Types.ProtoHelpers exposing (emptyToNothing)
import Types.Shelf exposing (BookshelfResponse, Shelf, bookshelfResponseDecoder, shelvesResponseDecoder)
import Url.Builder


baseUrl : String
baseUrl =
    ""


{-| A request's data — method, url, JSON body — apart from the `Http.request`
that sends it (Issue #347).

`elm-program-test` cannot run a real `Http.request`, so `TestHelpers`'
translators must construct `SimulatedEffect`s. Before this seam they
hand-copied the URL, method and body — and a divergence between the copy and
the `Api.*` function it stood in for was invisible to the whole suite (the
translator's merge-format request really had drifted: it sent an empty body
where production sends the proto-encoded `{isbn, format_label}`). Production
and the translator now consume one definition; only the transport differs.

`body = Nothing` means an empty body — kept as data (not `Http.Body`) because
`elm/http` and `SimulatedEffect.Http` have distinct body types.

-}
type alias RequestSpec =
    { method : String
    , url : String
    , body : Maybe Encode.Value
    }


specHttpBody : RequestSpec -> Http.Body
specHttpBody spec =
    case spec.body of
        Just value ->
            Http.jsonBody value

        Nothing ->
            Http.emptyBody


{-| How long a request may hang before `elm/http` gives up and reports
`Http.Timeout` (Issue #362).

⛔ **`timeout = Nothing` does not mean "no timeout configured". It means "wait
forever".** Every request in this file carried it, and the consequence is not
abstract: a connection that opens and then stalls — a machine that went to sleep
mid-response, a proxy holding the socket, a captive portal — never resolves, so
the page's `RemoteData` never leaves `Loading`. The `Failure` branch that every
page carefully writes is, for that whole class of failure, dead code. The reader
waits on a spinner with no end and no explanation, and their only move is to
reload a page that gave them no reason to.

A dropped connection is not this case: the browser reports `NetworkError` at
once, and offline navigation is caught earlier still by the connectivity banner.
This bound is for the failure that looks, from inside the app, exactly like a
slow success.

**Fifteen seconds.** Every JSON endpoint here answers in well under a second in
practice; the slowest real path is a cold Fly machine, seconds not tens of
seconds. Below ~10s a reader on a genuinely poor connection would be cut off
mid-success; much above 15s and "it is broken" has already been the honest
answer for some time. Fifteen buys the cold start and still fails inside the
span of a person's patience.

-}
standardTimeout : Maybe Float
standardTimeout =
    Just 15000


{-| The bound for a request whose body is a file (Issue #362).

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


{-| The identification status of an uploaded image.

The wire carries a status string from the DB (`"pending"`, `"resolved"`,
`"rejected"`) plus the SSE loop's synthetic `"timeout"`. Anything else is a
status the server grew after this client shipped, and is read as still-in-flight
(`Pending`) rather than as a terminal outcome we would guess wrong.

⛔ **`"timeout"` is not a rejection** (Issue #374). It used to decode to
`Rejected` with a `null` rejection\_reason, and `Page.Upload` reads a
`Rejected`-with-no-reason as "we could not read the ISBN" — so a reader whose
photo the pipeline never answered for was told their photo was unreadable. The
server knows the difference (`UploadController.sse_receive_loop/4` emits the two
statuses from two different branches) and said so on the wire; it was this
decoder that threw the distinction away. Keeping `TimedOut` separate is what
lets the page say the one true thing it knows: no answer came back.

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


{-| Decoder for SSE frames from `GET /api/upload/:image_id/stream`.

There is exactly ONE wire shape, and the server owns it:
`StacksWeb.ProtoJSON.poll_response/1`
(`apps/core/lib/stacks_web/proto_json.ex:525-534`), mirrored by
`proto/stacks/common/v1/upload.proto`'s `PollResponse`. It is snake\_case, and
it always emits all six keys — `book_ids` defaults to `[]` and `is_duplicate`
to `false` server-side, so neither is ever absent, and `book_id` /
`rejection_reason` arrive as JSON `null` rather than going missing.

Every field is therefore REQUIRED here. This decoder used to accept a
camelCase alternative for five of the six and fall back to `Decode.succeed`
defaults for all of them, which meant no test could ever notice a wire rename:
the fixtures spoke camelCase, production spoke snake\_case, and both "passed".
Do not reintroduce a `oneOf`/`succeed` fallback for a field the server always
sends — that is precisely the hole (Issue #328).

Heartbeat frames (`{"type":"heartbeat"}`) deliberately fail this decoder;
`Page.Upload.StreamEvent` treats a decode error as "ignore, stay put".

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


{-| What an upload in the inbox is waiting for (Issue #351).

⛔ These two are **not** a scale from good to bad, and must never be summed.
`AwaitingConfirmation` is a job for the reader that the reader can finish;
`Failed` is news they were never given, because the only place a rejection was
ever rendered was a page they had already closed. The navigation badge counts
the first kind and nothing else — a badge showing a number no action can clear
is a worse defect than no badge, and it is the one a single `List.length` would
produce.

`KindUnknown` is deliberately absent: the server owns this vocabulary, and a
token this client does not recognise is a wire break, not a third kind of
waiting. The decoder fails on it rather than inventing a screen for it.

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
    Decode.map4 InboxItem
        (Decode.field "image_id" Decode.string)
        (Decode.field "kind" inboxKindDecoder)
        (Decode.field "book_ids" (Decode.list Decode.string))
        (Decode.field "rejection_reason" (Decode.nullable Decode.string))


{-| `GET /api/uploads/inbox` — every upload this reader has not finished with.

Every field is required, for the same reason `streamEventDecoder`'s are
(Issue #328): `StacksWeb.ProtoJSON.upload_inbox_item/1` emits all four on every
branch, `book_ids` defaulting to `[]` and `rejection_reason` arriving as JSON
`null`. A `Decode.succeed` fallback here would mean a wire rename could never
redden a test.

-}
uploadInboxDecoder : Decoder (List InboxItem)
uploadInboxDecoder =
    Decode.field "items" (Decode.list inboxItemDecoder)


getUploadInbox : String -> (Result Http.Error (List InboxItem) -> msg) -> Cmd msg
getUploadInbox token toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/uploads/inbox"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg uploadInboxDecoder
        , timeout = standardTimeout
        , tracker = Nothing
        }



-- GOODREADS LIBRARY IMPORT (US-1.1.9)


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


{-| Upload refusals the page owes distinct copy for. The server answers each
with a distinct status (409 / 413 / 422), so the STATUS is the discriminant —
no body parse to drift.
-}
type ImportError
    = ImportInProgress
    | ImportFileTooLarge
    | ImportUnrecognised
    | ImportRequestFailed Http.Error


libraryImportDecoder : Decoder LibraryImport
libraryImportDecoder =
    -- All fields required: ImportController.import_json/1 emits every one on
    -- every branch. A fallback here would let a wire rename pass silently.
    Decode.succeed LibraryImport
        |> andMap (Decode.field "id" Decode.string)
        |> andMap (Decode.field "status" Decode.string)
        |> andMap (Decode.field "filename" Decode.string)
        |> andMap (Decode.field "row_count" Decode.int)
        |> andMap (Decode.field "processed_count" Decode.int)
        |> andMap (Decode.field "shelved_count" Decode.int)
        |> andMap (Decode.field "duplicate_count" Decode.int)
        |> andMap (Decode.field "unverified_count" Decode.int)
        |> andMap (Decode.field "unreadable_count" Decode.int)


importRowDecoder : Decoder ImportRow
importRowDecoder =
    Decode.map7 ImportRow
        (Decode.field "row_number" Decode.int)
        (Decode.field "title" Decode.string)
        (Decode.field "author" Decode.string)
        (Decode.field "isbn13" Decode.string)
        (Decode.field "goodreads_shelf" Decode.string)
        (Decode.field "outcome" (Decode.nullable Decode.string))
        (Decode.field "reason" (Decode.nullable Decode.string))


{-| `POST /api/imports/goodreads` — the export CSV as a multipart `file`.
The parse happens synchronously server-side, so a refusal (wrong file, one
already running, too large) arrives on THIS response, not minutes later.
-}
createGoodreadsImport : String -> File -> (Result ImportError LibraryImport -> msg) -> Cmd msg
createGoodreadsImport token file toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
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

                Http.BadStatus_ metadata _ ->
                    case metadata.statusCode of
                        409 ->
                            Err ImportInProgress

                        413 ->
                            Err ImportFileTooLarge

                        422 ->
                            Err ImportUnrecognised

                        status ->
                            Err (ImportRequestFailed (Http.BadStatus status))

                Http.BadUrl_ url ->
                    Err (ImportRequestFailed (Http.BadUrl url))

                Http.Timeout_ ->
                    Err (ImportRequestFailed Http.Timeout)

                Http.NetworkError_ ->
                    Err (ImportRequestFailed Http.NetworkError)


{-| `GET /api/imports/:id` — polled while the job runs.
-}
getImport : String -> String -> (Result Http.Error LibraryImport -> msg) -> Cmd msg
getImport token importId toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/imports/" ++ importId
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg (Decode.field "import" libraryImportDecoder)
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| `GET /api/imports/:id/rows` — the per-row report.
-}
getImportRows : String -> String -> (Result Http.Error (List ImportRow) -> msg) -> Cmd msg
getImportRows token importId toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/imports/" ++ importId ++ "/rows"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg (Decode.field "rows" (Decode.list importRowDecoder))
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| A request failure the rate limiter may have caused, carrying the wait the
server named (Issue #374).

⛔ **This type exists because `Http.Error` structurally cannot carry it.**
`Http.expectJson` and `Http.expectWhatever` collapse every non-2xx response into
`Http.BadStatus Int`: the status number survives and the **headers do not**. But
`retry-after` is a header — `StacksWeb.Plugs.RateLimiter` sets it beside the 429
— so a caller holding an `Http.Error` has no way to learn how long to wait, and
its copy must either say nothing or invent a number. Inventing one is the exact
untruth this issue exists to remove: it would still read "wait 60 seconds" the
day the plug changes to 30, and no test could notice.

Endpoints in the `:auth` rate-limit bucket resolve through
`expectStringResponse` and return this instead. The rest of the app keeps
`Http.Error` and gets the unnumbered wait copy, which is what the 423 lockout
message already says — a message with no interval in it is honest at any limit.

-}
type RequestError
    = RateLimited (Maybe Int)
    | RequestFailed Http.Error


{-| The wait a 429 named, in seconds — `Nothing` when it named none, or named
something that is not a positive whole number of seconds (Issue #374).

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
it. `registerResponseResult` used to be such a mirror, and #328 is the record of
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
than guessing. A 429 carries the rate limiter's wait (Issue #374). Every other
failure (network, timeout, unexpected status, or a 422 whose body we could not
parse) is a `RegisterRequestFailed`.

-}
type RegisterError
    = RegisterValidationFailed (List ( String, List String ))
    | RegisterRateLimited (Maybe Int)
    | RegisterInviteRefused String
    | RegisterRequestFailed Http.Error


{-| Decode the backend's `{"errors": {field: [msg, ...]}}` 422 body. See
`format_errors/1` in the Elixir `StacksWeb.ChangesetHelpers`.
-}
registerErrorsDecoder : Decoder (List ( String, List String ))
registerErrorsDecoder =
    Decode.field "errors" (Decode.keyValuePairs (Decode.list Decode.string))


{-| The invite gate's refusal body — only `invite_*` reasons qualify, so an
unrelated `{"error": ...}` still reads as its plain HTTP status.
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


{-| What `GET /api/auth/invite/:code` says about a redeemable code (US-14.1.3).
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


{-| Look an invitation code up before offering the Register form (US-14.1.3).
The failure statuses (404/410/403/409) arrive as `BadStatus` — the card maps
them to copy; it never needs the body's error string because the status alone
distinguishes the four refusals.
-}
checkInvite : String -> (Result Http.Error InviteStatus -> msg) -> Cmd msg
checkInvite code toMsg =
    Http.request
        { method = "GET"
        , headers = []
        , url = baseUrl ++ "/api/auth/invite/" ++ code
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg inviteStatusDecoder
        , timeout = standardTimeout
        , tracker = Nothing
        }


register :
    { email : String, password : String, displayName : String, inviteCode : String }
    -> (Result RegisterError () -> msg)
    -> Cmd msg
register body toMsg =
    Http.request
        { method = "POST"
        , headers = []
        , url = baseUrl ++ "/api/auth/register"
        , body =
            Http.jsonBody
                (Requests.encodeRegisterRequest
                    { email = body.email
                    , password = body.password
                    , displayName = body.displayName
                    , inviteCode = body.inviteCode
                    }
                )
        , expect = expectRegister toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| `Http.expectJson` discards the response body on a non-2xx status, which
would throw away the structured `{"errors": ...}` payload a 422 carries. This
custom expect keeps those field errors so the caller can surface the real
reason a registration was rejected — and, since #374, the 429's `retry-after`
for the same reason: it is the only place the number is still readable.

The resolver is a named top-level function rather than a lambda so the
program-test harness can run **this** function instead of the hand-written
mirror of it that `TestHelpers` used to carry.

-}
expectRegister : (Result RegisterError () -> msg) -> Http.Expect msg
expectRegister toMsg =
    Http.expectStringResponse toMsg resolveRegister


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
                -- The invite gate answers 403/409/410 with {"error":
                -- "invite_*"} (US-14.1.3); carry the bounded reason string so
                -- the card can explain, falling through to the plain status
                -- for any other refusal.
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


{-| POST /api/auth/login. Answers with `RequestError` rather than `Http.Error`
so a 429 arrives with the wait the server named (Issue #374); this endpoint is
in the `:auth` rate-limit bucket, which is the tightest one in the app, and a
mistyped password is the commonest way a reader reaches it.
-}
login :
    { email : String, password : String }
    -> (Result RequestError AuthResponse -> msg)
    -> Cmd msg
login body toMsg =
    Http.request
        { method = "POST"
        , headers = []
        , url = baseUrl ++ "/api/auth/login"
        , body =
            Http.jsonBody
                (Requests.encodeLoginRequest
                    { email = body.email
                    , password = body.password
                    }
                )
        , expect = Http.expectStringResponse toMsg resolveAuthResponse
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| Request a password-reset email. The backend always responds 200 (no user
enumeration), so the caller only distinguishes a throttle from any other
transport error — never one address from another.
-}
forgotPassword : String -> (Result RequestError () -> msg) -> Cmd msg
forgotPassword email toMsg =
    Http.request
        { method = "POST"
        , headers = []
        , url = baseUrl ++ "/api/auth/forgot-password"
        , body = Http.jsonBody (Encode.object [ ( "email", Encode.string email ) ])
        , expect = Http.expectStringResponse toMsg resolveNoContent
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| Ask for a fresh email-confirmation link (Issue #373, US-14.4.2).

Same shape as `forgotPassword` and for the same reason: the backend answers
identically for an address awaiting confirmation, an address already confirmed
and an address with no account at all, so there is nothing here to decode. A
`Result` with a `()` in it is the honest type — the caller genuinely cannot learn
which of the three happened, and giving it a richer type would be inventing an
answer the server deliberately refused to give.

-}
resendConfirmation : String -> (Result RequestError () -> msg) -> Cmd msg
resendConfirmation email toMsg =
    Http.request
        { method = "POST"
        , headers = []
        , url = baseUrl ++ "/api/auth/resend-confirmation"
        , body = Http.jsonBody (Encode.object [ ( "email", Encode.string email ) ])
        , expect = Http.expectStringResponse toMsg resolveNoContent
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| Set a new password using the signed token from a reset email. 400 =
invalid/expired token, 422 = password validation failed.
-}
resetPassword :
    { token : String, password : String }
    -> (Result Http.Error () -> msg)
    -> Cmd msg
resetPassword body toMsg =
    Http.request
        { method = "POST"
        , headers = []
        , url = baseUrl ++ "/api/auth/reset-password"
        , body =
            Http.jsonBody
                (Encode.object
                    [ ( "token", Encode.string body.token )
                    , ( "password", Encode.string body.password )
                    ]
                )
        , expect = Http.expectWhatever toMsg
        , timeout = standardTimeout
        , tracker = Nothing
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


{-| POST /api/opt-out — ask for a business listing to be removed.

Unauthenticated by design (US-2.5.3: "does not require account creation"). The contact
address is how the request is verified: a matching domain is applied at once, anything
else is queued for review.

404 means no listing matches the URL, 422 means the address was not a valid email.

-}
requestListingRemoval :
    { url : String, email : String, reason : String }
    -> (Result Http.Error RemovalOutcome -> msg)
    -> Cmd msg
requestListingRemoval body toMsg =
    Http.request
        { method = "POST"
        , headers = []
        , url = baseUrl ++ "/api/opt-out"
        , body =
            Http.jsonBody
                (Encode.object
                    [ ( "url", Encode.string body.url )
                    , ( "email", Encode.string body.email )
                    , ( "reason", Encode.string body.reason )
                    ]
                )
        , expect = Http.expectJson toMsg removalOutcomeDecoder
        , timeout = standardTimeout
        , tracker = Nothing
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
                        -- Fails rather than defaulting. An unrecognised status defaulting
                        -- to Removed would tell a business their listing is gone on the
                        -- strength of a value we do not understand.
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


{-| An authenticated request's credential AND the handler for the one failure
every authenticated request can suffer: the session is gone (Issue #361).

⛔ **Why this is a type and not a convention.** An authed call used to take a
bare `String` token and a `Result Http.Error a -> msg` callback, which makes a
401 just another `Err` — indistinguishable, at the type level, from a timeout.
Noticing it was therefore opt-in, and three settings write-forms did not opt in:
`Password`, `Profile` and `Notifications` each answered a mid-form 401 with
"Please try again". That is a lie. The session is gone; retrying cannot work,
and the reader retypes a password into a form that will 401 again. No test
failed, and none could: there was no place in the types where the question was
even asked. `isUnauthorized` exists, but a helper you have to remember to call
is a convention, and this codebase has already measured what conventions are
worth (#303/#309 — four admin surfaces, unit-tested and unreachable).

A page cannot call an `Authed` endpoint without building one of these, and it
cannot build one without naming `onExpired`: a record literal must supply every
field. There is no default, no wildcard, and no `_ ->` branch to hide behind —
unlike an exhaustiveness check, which `_ ->` satisfies. A page that ignores
session expiry does not compile.

`onExpired` is a plain `msg` rather than `Http.Error -> msg` on purpose: a 401
on a request that definitely carried a credential means exactly one thing, so
there is nothing left to inspect and no way to mistake it for a rate limit.

Note the phrase "definitely carried a credential". This is for MANDATORY auth
only. Optional-auth endpoints (`authHeaders : Maybe String -> …`, e.g.
`getProfile`, `getListings`) are valid anonymously, so a 401 from one of those
is not an expiry signal and must not be routed as one.

-}
type Authed err ok msg
    = Authed
        { token : String
        , onExpired : msg
        , onResult : Result err ok -> msg
        }


{-| Build the credential-plus-handlers an authenticated endpoint requires.

The record is the gate: `onExpired` cannot be omitted, defaulted, or inferred.

-}
authed :
    String
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
authedHeaders : Authed err ok msg -> List Http.Header
authedHeaders (Authed request) =
    [ Http.header "Authorization" ("Bearer " ++ request.token) ]


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
tested directly instead of through a simulated effect that mirrors it (#302,
#328: a test that re-implements the thing under test agrees only with itself).
-}
interpretAuthed :
    (Http.Response String -> Result err ok)
    -> Authed err ok msg
    -> Http.Response String
    -> msg
interpretAuthed resolve (Authed request) response =
    case response of
        Http.BadStatus_ metadata _ ->
            if metadata.statusCode == 401 then
                request.onExpired

            else
                request.onResult (resolve response)

        _ ->
            request.onResult (resolve response)


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


{-| POST /api/auth/refresh — exchange the current (still-valid) access token for
a fresh one before it expires (Issue #173 proactive silent renewal). The 200
body is byte-identical to login's, so we reuse `authResponseDecoder`. A 401/error
here means the session is no longer renewable and the caller falls through to the
session-expiry interceptor.
-}
refresh :
    String
    -> (Result Http.Error AuthResponse -> msg)
    -> Cmd msg
refresh token toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/auth/refresh"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg authResponseDecoder
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| DELETE /api/auth/logout — invalidate the current session server-side
(revokes the token via guardian\_db, Issue #124 A2). The method MUST be DELETE
to match the router; a POST silently 404s the SPA catch-all, leaving the token
valid until its TTL — caught by the logout E2E (auth.spec.ts).
-}
logout :
    String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
logout token toMsg =
    Http.request
        { method = "DELETE"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/auth/logout"
        , body = Http.emptyBody
        , expect = Http.expectWhatever toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }



-- TRANSPARENCY (#241 → #235)


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
payload (#241). No auth header: the endpoint is public and returns only curated,
anonymised aggregates.
-}
getTransparencyMetrics :
    (Result Http.Error TransparencyMetrics -> msg)
    -> Cmd msg
getTransparencyMetrics toMsg =
    Http.request
        { method = "GET"
        , headers = []
        , url = baseUrl ++ "/api/transparency/metrics"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg transparencyMetricsDecoder
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| Init-step response from `POST /api/upload/init`.
-}
type alias UploadInit =
    { imageId : String
    , uploadUrl : String
    , expiresIn : Int
    }


decodeUploadInit : Decoder UploadInit
decodeUploadInit =
    Decode.map3 UploadInit
        (Decode.field "image_id" Decode.string)
        (Decode.field "upload_url" Decode.string)
        (Decode.field "expires_in" Decode.int)


{-| `POST /api/upload/init` — allocates an image\_id server-side and
returns a Phoenix-served `upload_url` (`PUT /api/upload/:id/data`) the
client PUTs the bytes to. Phoenix proxies them to the configured storage
backend (R2 in production, Local in dev/preview); same-origin, so no R2
CORS allowlisting is needed.
-}
initUpload :
    String
    -> String
    -> (Result Http.Error UploadInit -> msg)
    -> Cmd msg
initUpload contentType token toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/upload/init"
        , body =
            Http.jsonBody
                (Encode.object [ ( "content_type", Encode.string contentType ) ])
        , expect = Http.expectJson toMsg decodeUploadInit
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| PUT the file bytes to the presigned R2 URL. Sends the raw File body;
Elm's Http uses XHR under the hood, so the JS-side compression
monkey-patch in `apps/core/assets/js/app.js` intercepts this
automatically. No auth header — the presigned URL signature IS the
authorisation.

The one request on `uploadTimeout` rather than `standardTimeout`: it is the only
one carrying a file body, so its elapsed time is bytes moving rather than a
server thinking. See `uploadTimeout`.

-}
putFileToR2 :
    String
    -> File
    -> (Result Http.Error () -> msg)
    -> Cmd msg
putFileToR2 url file toMsg =
    Http.request
        { method = "PUT"
        , headers = []
        , url = url
        , body = Http.fileBody file
        , expect = Http.expectWhatever toMsg
        , timeout = uploadTimeout
        , tracker = Nothing
        }


{-| `POST /api/upload/:id/commit` — signals to the backend that the
client's direct PUT to R2 succeeded. Backend HEADs R2, flips the row
from awaiting\_upload → pending, and enqueues identification work.
Returns the image\_id on success.
-}
commitUpload :
    String
    -> String
    -> (Result Http.Error String -> msg)
    -> Cmd msg
commitUpload imageId token toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/upload/" ++ imageId ++ "/commit"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg (Decode.field "image_id" Decode.string)
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| POST /api/upload/:image\_id/reject-identification — tell the server the
current identification was wrong; the server will delete any placement
created from it and re-run the vision pipeline excluding the listed books.
Returns 202 on accept; the SSE stream emits new events as the new
IdentifyBookJob runs.
-}
rejectIdentification :
    { imageId : String, rejectedBookIds : List String, token : String }
    -> (Result Http.Error () -> msg)
    -> Cmd msg
rejectIdentification { imageId, rejectedBookIds, token } toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/upload/" ++ imageId ++ "/reject-identification"
        , body =
            Http.jsonBody
                (Encode.object
                    [ ( "rejected_book_ids", Encode.list Encode.string rejectedBookIds ) ]
                )
        , expect = Http.expectWhatever toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| Response from GET /api/books/:id — book with the viewer's placement data.

`placements` carries EVERY bookshelf the viewer has this book on; a book may
legally sit on several at once (#333). `placement` is the first of them, kept
because most of the page only ever needs one (the rating, the visibility
control, the progress card all belong to a single placement) — but anything
answering "where is this book of mine?" must read `placements`.

-}
type alias BookDetailResponse =
    { book : Book
    , placement : Maybe Placement
    , bookshelfVisibility : Maybe String
    , placements : List Placement
    }


{-| Adapter: proto BookDetailResponse -> app BookDetailResponse.

Proto includes myWriting (dropped). Proto book/placement are proto types
decoded through the existing app-level decoders which already delegate to proto.

-}
bookDetailResponseDecoder : Decoder BookDetailResponse
bookDetailResponseDecoder =
    Decode.map4 BookDetailResponse
        (Decode.field "book" bookDecoder)
        -- Decode.maybe alone is insufficient here: the proto-generated placementDecoder
        -- decodes JSON null as a default struct (all fields empty/zero) because each
        -- field uses `D.oneOf [D.field "..." ..., D.succeed default]`. Using
        -- Decode.nullable ensures JSON null → Nothing; non-null → Just placement.
        -- Decode.oneOf handles the case where the field is absent entirely.
        (Decode.oneOf
            [ Decode.field "placement" (Decode.nullable placementDecoder)
            , Decode.succeed Nothing
            ]
        )
        -- The parent bookshelf's visibility (the placement ceiling), denormalised
        -- onto the placement payload. Absent → Nothing (no client-side greying).
        (Decode.oneOf
            [ Decode.at [ "placement", "bookshelf_visibility" ] (Decode.nullable Decode.string)
            , Decode.succeed Nothing
            ]
        )
        -- Every placement the viewer has of this book, oldest first (#333). An
        -- absent key decodes to [] rather than failing, so an older server (or
        -- the /api/books/isbn lookup before it carried them) degrades to "no
        -- multi-shelf notice" instead of a decode error that blanks the page.
        (Decode.oneOf
            [ Decode.field "placements" (Decode.list placementDecoder)
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


getBook :
    String
    -> Maybe String
    -> (Result Http.Error BookDetailResponse -> msg)
    -> Cmd msg
getBook bookId maybeToken toMsg =
    let
        spec =
            getBookRequest bookId
    in
    Http.request
        { method = spec.method
        , headers =
            case maybeToken of
                Just token ->
                    [ Http.header "Authorization" ("Bearer " ++ token) ]

                Nothing ->
                    []
        , url = spec.url
        , body = specHttpBody spec
        , expect = Http.expectJson toMsg bookDetailResponseDecoder
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| The data of `getBook`'s request — see `RequestSpec`.
-}
getBookRequest : String -> RequestSpec
getBookRequest bookId =
    { method = "GET"
    , url = baseUrl ++ "/api/books/" ++ bookId
    , body = Nothing
    }


searchBooks :
    String
    -> Bool
    -> String
    -> (Result Http.Error SearchSections -> msg)
    -> Cmd msg
searchBooks query deep token toMsg =
    let
        -- Deep search opts into description/review matching via `scope=deep`
        -- (#284). The default (title-only) search emits NO scope param, so the
        -- backend's default behaviour is unchanged and the wire URL stays
        -- byte-identical to the pre-#284 request.
        queryParams =
            Url.Builder.string "q" query
                :: (if deep then
                        [ Url.Builder.string "scope" "deep" ]

                    else
                        []
                   )
    in
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = Url.Builder.crossOrigin baseUrl [ "api", "search" ] queryParams
        , body = Http.emptyBody

        -- SearchController.index returns the SearchResponse envelope carrying
        -- `collection` (the viewer's own placements) and `platform_hits`
        -- (platform-visible books, some label-bearing). Decode it through the
        -- generated proto decoder (mirrors catalogueResponseDecoder) into the
        -- typed `SearchSections` the search page renders as two sections (#285).
        , expect = Http.expectJson toMsg searchResponseDecoder
        , timeout = standardTimeout
        , tracker = Nothing
        }


getBookshelf :
    String
    -> String
    -> (Result Http.Error BookshelfResponse -> msg)
    -> Cmd msg
getBookshelf shelfName token toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/bookshelves/" ++ shelfName
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg bookshelfResponseDecoder
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| Error type for `moveBook` (#276). The backend rejects a move that would
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


expectMove : (Result MoveError () -> msg) -> Http.Expect msg
expectMove toMsg =
    Http.expectStringResponse toMsg moveResponseToResult


moveBook :
    String
    -> String
    -> String
    -> (Result MoveError () -> msg)
    -> Cmd msg
moveBook placementId targetBookshelf token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/placements/" ++ placementId ++ "/move"
        , body =
            Http.jsonBody
                (Requests.encodeMoveBookRequest
                    { bookshelf = targetBookshelf }
                )
        , expect = expectMove toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }


removeBook :
    String
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
removeBook placementId token toMsg =
    Http.request
        { method = "DELETE"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/placements/" ++ placementId
        , body = Http.emptyBody
        , expect = Http.expectWhatever toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| `POST /api/placements/:id/restore` — undo a removal (US-1.6.4 extension).

Takes the id `removeBook` was given, because the undo clears `removed_at` on
that same row rather than placing the book again; see
`Stacks.Shelving.restore_placement/2` for what a fresh placement would lose.

The response body is the restored placement, and the caller deliberately does
not decode it: `Page.Bookshelf` refetches the whole bookshelf afterwards for the
reason `reloadShelves` documents — the server's answer about where a book sits
is the only trustworthy one. `expectWhatever` still surfaces the status, which
is what matters here, because **409 is a real answer**: the reader re-added the
book before pressing Undo.

-}
restoreBook :
    String
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
restoreBook placementId token toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/placements/" ++ placementId ++ "/restore"
        , body = Http.emptyBody
        , expect = Http.expectWhatever toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }



-- READING PROGRESS (US-1.6.6)


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
the `{error: ...}` shape — is a `ProgressRequestFailed`.

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
(#281 item 5).
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
message and the current-page special case live in one place (#281 item 5). The
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
`moveResponseToResult`). A 422 whose body carries `{errors: ...}` becomes
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


{-| PUT /api/placements/:id/progress — update a placement's reading status and
(when reading) current page. `reading_status` is required; `current_page` is
sent only when present.
-}
updateProgress :
    String
    -> { readingStatus : String, currentPage : Maybe Int }
    -> String
    -> (Result ProgressError Progress -> msg)
    -> Cmd msg
updateProgress placementId body token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/placements/" ++ placementId ++ "/progress"
        , body = Http.jsonBody (encodeProgressBody body)
        , expect = Http.expectStringResponse toMsg progressResponseToResult
        , timeout = standardTimeout
        , tracker = Nothing
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


{-| POST /api/gdpr/export — queue an export of the user's personal data.

The backend responds 202 Accepted and processes the export asynchronously, so
the client only needs to confirm the request was queued; the response body is
not consumed.

-}
requestExport :
    String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
requestExport token toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/gdpr/export"
        , body = Http.emptyBody
        , expect = Http.expectWhatever toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| DELETE /api/gdpr/account — queue erasure of the user's account and personal
data.

The backend responds 202 Accepted and processes the deletion asynchronously, so
the client only needs to confirm the request was queued; the response body is
not consumed. On success the caller is logged out.

-}
deleteAccount :
    String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
deleteAccount token toMsg =
    Http.request
        { method = "DELETE"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/gdpr/account"
        , body = Http.emptyBody
        , expect = Http.expectWhatever toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| POST /api/gdpr/consent — save the user's analytics consent preference.
-}
saveConsent :
    Bool
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
saveConsent consent token toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/gdpr/consent"
        , body = Http.jsonBody (Requests.encodeConsentRequest { consent = consent })
        , expect = Http.expectWhatever toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| POST /api/gdpr/consent — save the user's writing-assistant consent
preference. Sends `type: "writing_assistant"` so the backend targets the
`consent_writing_assistant` flag (Issue #184). Revoking triggers a server-side
purge of the user's writing-assistant data.
-}
saveWritingAssistantConsent :
    Bool
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
saveWritingAssistantConsent consent token toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/gdpr/consent"
        , body =
            Http.jsonBody
                (Encode.object
                    [ ( "consent", Encode.bool consent )
                    , ( "type", Encode.string "writing_assistant" )
                    ]
                )
        , expect = Http.expectWhatever toMsg
        , timeout = standardTimeout
        , tracker = Nothing
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
the "Your Collection" section (#285). Mapped from a proto `SearchHit` whose
`collection` entries populate `bookshelf_name` and leave the label fields empty.
`snippet` is a deep-search `ts_headline` excerpt (`<mark>`-wrapped), non-empty
only when the match was on the description/review under `scope=deep` (#284).
-}
type alias CollectionHit =
    { book : Book
    , bookshelfName : String
    , bookshelfNames : List String
    , snippet : String
    }


{-| A platform-visible book surfaced by the search, with its discoverable-by-design
provenance (#285). `source` is `""` (a plain platform result — no label),
`"looking_for_home"` (an always-visible LFH advert → owner handle), or `"listed"`
(an active marketplace listing → owner handle + formatted price). Rendered in the
"On the Platform" section; the label is shown only when `source` is non-empty.
`snippet` is a deep-search `ts_headline` excerpt, non-empty only for a
description/review match under `scope=deep` (#284).
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

    -- A book on several bookshelves used to be annotated with just one of them
    -- (#333). Fall back to the singular name when the list is absent, so an
    -- older server still names the one shelf it knows about rather than none.
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


{-| GET /api/settings/audit-log — fetch the current user's audit history.
-}
getAuditLog :
    String
    -> (Result Http.Error AuditLogResponse -> msg)
    -> Cmd msg
getAuditLog token toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/settings/audit-log?page=1"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg auditLogResponseDecoder
        , timeout = standardTimeout
        , tracker = Nothing
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


{-| GET /api/me/inferences — fetch the current user's own ephemeral inference
profile. When `revealRisk` is `True`, appends `?reveal_risk=true` so the
response includes the labelled risk-inference illustrations.
-}
getInferences :
    Bool
    -> String
    -> (Result Http.Error PersonalInferences -> msg)
    -> Cmd msg
getInferences revealRisk token toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url =
            baseUrl
                ++ "/api/me/inferences"
                ++ (if revealRisk then
                        "?reveal_risk=true"

                    else
                        ""
                   )
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg personalInferencesDecoder
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| Error type for `placeBook` (#276/#281). The direct-place path — Upload,
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
            case Decode.decodeString (Decode.field "placement" placementDecoder) bodyText of
                Ok placement ->
                    Ok placement

                Err err ->
                    Err (PlaceHttpError (Http.BadBody (Decode.errorToString err)))


expectPlace : (Result PlaceError Placement -> msg) -> Http.Expect msg
expectPlace toMsg =
    Http.expectStringResponse toMsg placeResponseToResult


{-| POST /api/bookshelves/:name/placements — place a book on a bookshelf.
-}
placeBook :
    String
    -> String
    -> String
    -> (Result PlaceError Placement -> msg)
    -> Cmd msg
placeBook bookshelfName bookId token toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/bookshelves/" ++ bookshelfName ++ "/placements"
        , body =
            Http.jsonBody
                (Requests.encodePlaceBookRequest
                    { bookId = bookId }
                )
        , expect = expectPlace toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| PUT /api/books/:id/age-gate — the user who added a book marks it
"adults only" (raise-only). Body `{"adults_only": true}`. The backend
permits only raising the gate for the user path; lowering is owner-only.
-}
setBookAgeGate :
    String
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
setBookAgeGate bookId token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/books/" ++ bookId ++ "/age-gate"
        , body = Http.jsonBody (Encode.object [ ( "adults_only", Encode.bool True ) ])
        , expect = Http.expectWhatever toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| GET /api/placements/mine — fetch summary of user's active placements.
-}
getUserPlacements :
    String
    -> (Result Http.Error (List PlacementSummary) -> msg)
    -> Cmd msg
getUserPlacements token toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/placements/mine"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg placementsMineDecoder
        , timeout = standardTimeout
        , tracker = Nothing
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


{-| Which of `Books.confirm/2`'s branches answered (#343).

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
US-1.1.8 prompt's trigger, not an error to show as "something went wrong" —
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

Hand-rolled over the app-level `bookDecoder` / `placementDecoder` for the same
reason `bookDetailResponseDecoder` is: the proto-generated placement decoder
turns a JSON `null` into a default struct rather than `Nothing`.

-}
confirmResponseDecoder : Decoder ConfirmResponse
confirmResponseDecoder =
    Decode.map4 ConfirmResponse
        (Decode.field "book" bookDecoder)
        (Decode.oneOf
            [ Decode.field "placement" (Decode.nullable placementDecoder)
            , Decode.succeed Nothing
            ]
        )
        (Decode.oneOf
            [ Decode.field "placements" (Decode.list placementDecoder)
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


{-| POST /api/books/confirm — the manual-entry verb (#343).

One round trip does the whole of "add this ISBN to that bookshelf": resolve it
against Open Library / Google Books, create the work and primary edition if the
platform has never seen the ISBN, refuse (409) if it is a second edition of a
work we already hold, and place it — atomically. The client used to reassemble
this out of `GET /api/books/isbn/:isbn` plus
`POST /api/bookshelves/:name/placements`, which could only ever add books the
catalogue already had.

The body is encoded inline rather than through `Stacks.Api.V1.Requests` because
no `ConfirmBookRequest` message exists in `proto/stacks/api/v1/requests.proto`
(the endpoint predates it and the controller reads raw params) — same as
`setBookAgeGate`.

-}
confirmBook :
    { isbn : String, shelfName : String }
    -> String
    -> (Result ConfirmError ConfirmResponse -> msg)
    -> Cmd msg
confirmBook body token toMsg =
    let
        spec =
            confirmBookRequest body
    in
    Http.request
        { method = spec.method
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = spec.url
        , body = specHttpBody spec
        , expect = Http.expectStringResponse toMsg confirmResponseToResult
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| The data of `confirmBook`'s request — see `RequestSpec`.
-}
confirmBookRequest : { isbn : String, shelfName : String } -> RequestSpec
confirmBookRequest body =
    { method = "POST"
    , url = baseUrl ++ "/api/books/confirm"
    , body =
        Just
            (Encode.object
                [ ( "isbn", Encode.string body.isbn )
                , ( "shelf_name", Encode.string body.shelfName )
                ]
            )
    }


{-| GET /api/catalogue — fetch paginated book catalogue.
-}
getCatalogue :
    { search : Maybe String
    , subject : Maybe String
    , sort : String
    , page : Int
    }
    -> (Result Http.Error CatalogueResponse -> msg)
    -> Cmd msg
getCatalogue params toMsg =
    let
        queryParams =
            [ Just (Url.Builder.string "sort" params.sort)
            , Just (Url.Builder.int "page" params.page)
            , params.search |> Maybe.map (Url.Builder.string "search")
            , params.subject |> Maybe.map (Url.Builder.string "subject")
            ]
                |> List.filterMap identity
    in
    Http.request
        { method = "GET"
        , headers = []
        , url = Url.Builder.absolute [ "api", "catalogue" ] queryParams
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg catalogueResponseDecoder
        , timeout = standardTimeout
        , tracker = Nothing
        }


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
    -> Authed ProfileError String msg
    -> Cmd msg
updateProfile body request =
    Http.request
        { method = "PUT"
        , headers = authedHeaders request
        , url = baseUrl ++ "/api/settings/profile"
        , body = Http.jsonBody (encodeProfileBody body)
        , expect = authedExpect resolveProfile request
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| Body for `PUT /api/settings/profile`.

Each key that can be left unchanged is sent ONLY when it actually changed:

  - `handle` is omitted unless edited. The field can render empty for a session
    that carries no handle locally (e.g. an injected/minted session), and a
    blank `handle` would otherwise write NULL over the user's real handle (the
    column is NOT NULL — the server 500s). Omitting an unchanged handle keeps
    the stored value; a genuine edit is still sent and server-validated.
  - `email` + `current_password` are omitted unless the email changed. The
    server treats a payload without an `email` key as a profile-only update
    (`Accounts.update_profile/2` → `email_change?/2`), so an ordinary edit never
    demands the current password.

The proto-generated `Requests.encodeUpdateProfileRequest` always emits every
field and so cannot express this conditional omission; the body is built here.

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


{-| Keep the structured `{"errors": ...}` payload a 422 carries so the caller
can surface the real reason a profile save was rejected (mirrors
`expectRegister`). On success it hands back the server-normalised handle (the
200 body echoes the lowercased value) so the settings page can reflect it.

There is deliberately no 401 branch: `interpretAuthed` diverts a 401 to
`onExpired` before this runs, so "session expired" cannot arrive here disguised
as `ProfileRequestFailed (BadStatus 401)` — which is precisely how the page
came to render "Please try again" at it.

-}
resolveProfile : Http.Response String -> Result ProfileError String
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
            case Decode.decodeString (Decode.field "handle" Decode.string) bodyText of
                Ok handle ->
                    Ok handle

                Err _ ->
                    Ok ""


{-| PUT /api/settings/location — update the user's location.
-}
updateLocation :
    { countryCode : String, city : String }
    -> Authed Http.Error () msg
    -> Cmd msg
updateLocation body request =
    Http.request
        { method = "PUT"
        , headers = authedHeaders request
        , url = "/api/settings/location"
        , body =
            Http.jsonBody
                (Requests.encodeUpdateLocationRequest
                    { countryCode = body.countryCode
                    , city = body.city
                    }
                )
        , expect = authedExpect resolveWhatever request
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| PUT /api/settings/password — change the user's password.
-}
updatePassword :
    { currentPassword : String, newPassword : String }
    -> Authed Http.Error () msg
    -> Cmd msg
updatePassword body request =
    Http.request
        { method = "PUT"
        , headers = authedHeaders request
        , url = baseUrl ++ "/api/settings/password"
        , body =
            Http.jsonBody
                (Requests.encodeUpdatePasswordRequest
                    { currentPassword = body.currentPassword
                    , newPassword = body.newPassword
                    }
                )
        , expect = authedExpect resolveWhatever request
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| Notification preference flags.
-}
type alias NotificationPreferences =
    { priceDrops : Bool
    , newReviews : Bool
    , authorUpdates : Bool
    , eventAlerts : Bool
    }


{-| GET /api/settings/notifications — the current user's stored notification
preferences, so the settings screen hydrates from saved values instead of
hardcoded defaults. The endpoint always returns all four booleans (never null),
so a strict field decoder is safe.
-}
getNotifications :
    Authed Http.Error NotificationPreferences msg
    -> Cmd msg
getNotifications request =
    Http.request
        { method = "GET"
        , headers = authedHeaders request
        , url = baseUrl ++ "/api/settings/notifications"
        , body = Http.emptyBody
        , expect = authedExpect (resolveJson notificationPreferencesDecoder) request
        , timeout = standardTimeout
        , tracker = Nothing
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


{-| PUT /api/settings/notifications — update notification preferences.
-}
updateNotifications :
    NotificationPreferences
    -> Authed Http.Error () msg
    -> Cmd msg
updateNotifications prefs request =
    Http.request
        { method = "PUT"
        , headers = authedHeaders request
        , url = baseUrl ++ "/api/settings/notifications"
        , body =
            Http.jsonBody
                (Requests.encodeUpdateNotificationsRequest
                    { notifyWishlistAvailability = prefs.priceDrops
                    , notifyMarketplace = prefs.newReviews
                    , notifyGroupInvitations = prefs.authorUpdates
                    , notifyEventMatches = prefs.eventAlerts
                    }
                )
        , expect = authedExpect resolveWhatever request
        , timeout = standardTimeout
        , tracker = Nothing
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


{-| POST /api/books/:id/merge-format — add a new edition (ISBN/format) to an existing book.
-}
mergeFormat :
    String
    -> { isbn : String, formatLabel : String }
    -> String
    -> (Result Http.Error MergeFormatResponse -> msg)
    -> Cmd msg
mergeFormat bookId body token toMsg =
    let
        spec =
            mergeFormatRequest bookId body
    in
    Http.request
        { method = spec.method
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = spec.url
        , body = specHttpBody spec
        , expect = Http.expectJson toMsg mergeFormatResponseDecoder
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| The data of `mergeFormat`'s request — see `RequestSpec`.
-}
mergeFormatRequest : String -> { isbn : String, formatLabel : String } -> RequestSpec
mergeFormatRequest bookId body =
    { method = "POST"
    , url = baseUrl ++ "/api/books/" ++ bookId ++ "/merge-format"
    , body =
        Just
            (Requests.encodeMergeFormatRequest
                { isbn = body.isbn
                , formatLabel = body.formatLabel
                }
            )
    }



-- MARKETPLACE LISTINGS


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


{-| GET /api/listings — fetch active marketplace listings.
-}
getListings :
    Maybe String
    -> (Result Http.Error ListingsResponse -> msg)
    -> Cmd msg
getListings maybeToken toMsg =
    Http.request
        { method = "GET"
        , headers =
            case maybeToken of
                Just token ->
                    [ Http.header "Authorization" ("Bearer " ++ token) ]

                Nothing ->
                    []
        , url = baseUrl ++ "/api/listings"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg listingsResponseDecoder
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| GET /api/listings/mine — fetch the current user's listings.
-}
getMyListings :
    String
    -> (Result Http.Error ListingsResponse -> msg)
    -> Cmd msg
getMyListings token toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/listings/mine"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg listingsResponseDecoder
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| POST /api/listings — create a new listing.
-}
createListing :
    ListingParams
    -> String
    -> (Result Http.Error Listing -> msg)
    -> Cmd msg
createListing params token toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/listings"
        , body =
            Http.jsonBody
                (Requests.encodeCreateListingRequest
                    { -- Backend Marketplace.create_listing reads book_id; the
                      -- legacy placement_id field is left empty.
                      placementId = ""
                    , bookId = params.bookId
                    , condition = params.condition
                    , pricingMode = params.pricingMode
                    , priceZar = params.priceZar
                    , contactInfo = params.contactInfo
                    , description = params.description
                    }
                )
        , expect = Http.expectJson toMsg (Decode.field "listing" listingDecoder)
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| PUT /api/listings/:id/activate — activate a draft listing.
-}
activateListing :
    String
    -> String
    -> (Result Http.Error Listing -> msg)
    -> Cmd msg
activateListing listingId token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/listings/" ++ listingId ++ "/activate"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg (Decode.field "listing" listingDecoder)
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| PUT /api/listings/:id/deactivate — deactivate an active listing.
-}
deactivateListing :
    String
    -> String
    -> (Result Http.Error Listing -> msg)
    -> Cmd msg
deactivateListing listingId token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/listings/" ++ listingId ++ "/deactivate"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg (Decode.field "listing" listingDecoder)
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| PUT /api/listings/:id/sold — mark a listing as sold.
-}
soldListing :
    String
    -> String
    -> (Result Http.Error Listing -> msg)
    -> Cmd msg
soldListing listingId token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/listings/" ++ listingId ++ "/sold"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg (Decode.field "listing" listingDecoder)
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| GET /api/placements/mine — fetch the current user's placements with book data.
Used by the create listing form to select which book to list.
-}
getMyPlacements :
    String
    -> (Result Http.Error (List Placement) -> msg)
    -> Cmd msg
getMyPlacements token toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/placements/mine"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg (Decode.field "placements" (Decode.list placementSummaryDecoder))
        , timeout = standardTimeout
        , tracker = Nothing
        }



-- BLOG


{-| GET /api/blog/posts — fetch all blog posts.
-}
getBlogPosts :
    Maybe String
    -> (Result Http.Error (List BlogPostSummary) -> msg)
    -> Cmd msg
getBlogPosts maybeToken toMsg =
    Http.request
        { method = "GET"
        , headers =
            case maybeToken of
                Just token ->
                    [ Http.header "Authorization" ("Bearer " ++ token) ]

                Nothing ->
                    []
        , url = baseUrl ++ "/api/blog/posts"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg (Decode.field "posts" (Decode.list blogPostSummaryDecoder))
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| GET /api/blog/posts/:id — fetch a single blog post.
-}
getBlogPost :
    String
    -> Maybe String
    -> (Result Http.Error BlogPost -> msg)
    -> Cmd msg
getBlogPost postId maybeToken toMsg =
    Http.request
        { method = "GET"
        , headers =
            case maybeToken of
                Just token ->
                    [ Http.header "Authorization" ("Bearer " ++ token) ]

                Nothing ->
                    []
        , url = baseUrl ++ "/api/blog/posts/" ++ postId
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg (Decode.field "post" blogPostDecoder)
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| POST /api/blog/posts — create a new blog post. Returns the new post ID.
-}
createBlogPost :
    { title : String, body : String, visibility : String }
    -> String
    -> (Result Http.Error String -> msg)
    -> Cmd msg
createBlogPost postData token toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/blog/posts"
        , body =
            Http.jsonBody
                (Requests.encodeCreateBlogPostRequest
                    { title = postData.title
                    , body = postData.body
                    , visibility = postData.visibility
                    }
                )
        , expect = Http.expectJson toMsg (Decode.at [ "post", "id" ] Decode.string)
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| PUT /api/blog/posts/:id — update an existing blog post. Returns the post ID.
-}
updateBlogPost :
    String
    -> { title : String, body : String, visibility : String }
    -> String
    -> (Result Http.Error String -> msg)
    -> Cmd msg
updateBlogPost postId postData token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/blog/posts/" ++ postId
        , body =
            Http.jsonBody
                (Requests.encodeUpdateBlogPostRequest
                    { title = postData.title
                    , body = postData.body
                    , visibility = postData.visibility
                    }
                )
        , expect = Http.expectJson toMsg (Decode.at [ "post", "id" ] Decode.string)
        , timeout = standardTimeout
        , tracker = Nothing
        }



-- SYNDICATION (US-6.2.1)


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


{-| `GET /api/blog/posts/:id/syndication?format=html|markdown`.
-}
fetchSyndicationExport :
    String
    -> String
    -> String
    -> (Result Http.Error SyndicationExport -> msg)
    -> Cmd msg
fetchSyndicationExport token postId format toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/blog/posts/" ++ postId ++ "/syndication?format=" ++ format
        , body = Http.emptyBody
        , expect =
            Http.expectJson toMsg
                (Decode.map3 SyndicationExport
                    (Decode.field "format" Decode.string)
                    (Decode.field "canonical_url" Decode.string)
                    (Decode.field "body" Decode.string)
                )
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| `POST /api/blog/posts/:id/syndications` — record that a copy went out.
-}
recordSyndication :
    String
    -> String
    -> String
    -> (Result Http.Error Syndication -> msg)
    -> Cmd msg
recordSyndication token postId method toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/blog/posts/" ++ postId ++ "/syndications"
        , body = Http.jsonBody (Encode.object [ ( "method", Encode.string method ) ])
        , expect = Http.expectJson toMsg (Decode.field "syndication" syndicationDecoder)
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| `PUT /api/blog/posts/:id/syndications/:sid` — paste the live Substack URL
back in, closing the POSSE loop.
-}
updateSyndicationUrl :
    String
    -> String
    -> String
    -> String
    -> (Result Http.Error Syndication -> msg)
    -> Cmd msg
updateSyndicationUrl token postId sid url toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/blog/posts/" ++ postId ++ "/syndications/" ++ sid
        , body = Http.jsonBody (Encode.object [ ( "syndicated_url", Encode.string url ) ])
        , expect = Http.expectJson toMsg (Decode.field "syndication" syndicationDecoder)
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| `PUT /api/blog/posts/:id` with ONLY `syndicated` — the per-post feed
tickbox. Partial on purpose: title/body/visibility stay untouched.
-}
setPostSyndicated :
    String
    -> String
    -> Bool
    -> (Result Http.Error Bool -> msg)
    -> Cmd msg
setPostSyndicated token postId syndicated toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/blog/posts/" ++ postId
        , body = Http.jsonBody (Encode.object [ ( "syndicated", Encode.bool syndicated ) ])
        , expect = Http.expectJson toMsg (Decode.at [ "post", "syndicated" ] Decode.bool)
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| POST /api/blog/posts/:id/publish — publish a blog post.
-}
publishBlogPost :
    String
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
publishBlogPost postId token toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/blog/posts/" ++ postId ++ "/publish"
        , body = Http.emptyBody
        , expect = Http.expectWhatever toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| PUT /api/blog/posts/:post\_id/associations/:id/confirm — confirm a book association.
-}
confirmAssociation :
    String
    -> String
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
confirmAssociation postId associationId token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/blog/posts/" ++ postId ++ "/associations/" ++ associationId ++ "/confirm"
        , body = Http.emptyBody
        , expect = Http.expectWhatever toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| PUT /api/blog/posts/:post\_id/associations/:id/dismiss — dismiss a book association.
-}
dismissAssociation :
    String
    -> String
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
dismissAssociation postId associationId token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/blog/posts/" ++ postId ++ "/associations/" ++ associationId ++ "/dismiss"
        , body = Http.emptyBody
        , expect = Http.expectWhatever toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| GET /api/posts/:post\_id/comments — fetch comments for a post.
-}
getPostComments :
    String
    -> Maybe String
    -> (Result Http.Error (List Comment) -> msg)
    -> Cmd msg
getPostComments postId maybeToken toMsg =
    Http.request
        { method = "GET"
        , headers =
            case maybeToken of
                Just token ->
                    [ Http.header "Authorization" ("Bearer " ++ token) ]

                Nothing ->
                    []
        , url = baseUrl ++ "/api/posts/" ++ postId ++ "/comments"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg (Decode.field "comments" (Decode.list commentDecoder))
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| POST /api/posts/:post\_id/comments — create a comment or reply.
-}
createComment :
    String
    -> String
    -> Maybe String
    -> String
    -> (Result Http.Error Comment -> msg)
    -> Cmd msg
createComment postId body maybeParentId token toMsg =
    let
        parentField =
            case maybeParentId of
                Just pid ->
                    [ ( "parent_id", Encode.string pid ) ]

                Nothing ->
                    []
    in
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/posts/" ++ postId ++ "/comments"
        , body =
            Http.jsonBody
                (Encode.object
                    ([ ( "body", Encode.string body ) ] ++ parentField)
                )
        , expect = Http.expectJson toMsg (Decode.field "comment" commentDecoder)
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| DELETE /api/comments/:id — delete a comment.
-}
deleteComment :
    String
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
deleteComment commentId token toMsg =
    Http.request
        { method = "DELETE"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/comments/" ++ commentId
        , body = Http.emptyBody
        , expect = Http.expectWhatever toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }



-- PRIVACY / VISIBILITY


{-| PUT /api/settings/profile\_visibility — update profile visibility.
-}
updateProfileVisibility :
    String
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
updateProfileVisibility visibility token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/settings/profile_visibility"
        , body =
            Http.jsonBody
                (Requests.encodeUpdateProfileVisibilityRequest
                    { profileVisibility = visibility }
                )
        , expect = Http.expectWhatever toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| PUT /api/bookshelves/:id/visibility — update shelf visibility.
-}
updateShelfVisibility :
    String
    -> String
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
updateShelfVisibility shelfName visibility token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/bookshelves/" ++ shelfName ++ "/visibility"
        , body =
            Http.jsonBody
                (Requests.encodeUpdateShelfVisibilityRequest
                    { visibility = visibility }
                )
        , expect = Http.expectWhatever toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| PUT /api/placements/:id/visibility — update a single placement's visibility.

The server enforces the ceiling rule (a placement may not be more visible than
its parent bookshelf) and returns 422 if violated. The 200 body is `{id,
visibility}`; we decode the confirmed visibility string back so the caller can
reconcile local state with what the server actually stored.

-}
updatePlacementVisibility :
    String
    -> String
    -> String
    -> (Result Http.Error String -> msg)
    -> Cmd msg
updatePlacementVisibility placementId visibility token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/placements/" ++ placementId ++ "/visibility"
        , body =
            Http.jsonBody
                (Requests.encodeUpdateShelfVisibilityRequest
                    { visibility = visibility }
                )
        , expect = Http.expectJson toMsg (Decode.field "visibility" Decode.string)
        , timeout = standardTimeout
        , tracker = Nothing
        }



-- BLOCKING / SOCIAL


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


{-| `Http.expectWhatever` would collapse the backend's `{"error": ...}` body
into an opaque `BadStatus`, losing the difference between `already_blocked`,
`cannot_block_self`, and `not_found`. This custom expect keeps that reason so
the UI can explain what actually happened.
-}
expectBlock : (Result BlockError () -> msg) -> Http.Expect msg
expectBlock toMsg =
    Http.expectStringResponse toMsg <|
        \response ->
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


{-| POST /api/users/:id/block — block another reader. On success the backend
returns `{"blocked": true}`; the resolved-visibility layer then hides that
reader's content bidirectionally on the next fetch.
-}
blockUser :
    String
    -> String
    -> (Result BlockError () -> msg)
    -> Cmd msg
blockUser targetUserId token toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/users/" ++ targetUserId ++ "/block"
        , body = Http.emptyBody
        , expect = expectBlock toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| DELETE /api/users/:id/block — unblock a reader. Returns `{"blocked": false}`
on success, 404 `not_found` when no block existed.
-}
unblockUser :
    String
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
unblockUser targetUserId token toMsg =
    Http.request
        { method = "DELETE"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/users/" ++ targetUserId ++ "/block"
        , body = Http.emptyBody
        , expect = Http.expectWhatever toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| GET /api/settings/blocked-users — the current reader's blocked list, one
page (20 readers) at a time. `page` is 1-based; the response echoes back the
page and total so the caller can offer a "Load more" affordance.
-}
listBlockedUsers :
    String
    -> Int
    -> (Result Http.Error BlockedUsersResponse -> msg)
    -> Cmd msg
listBlockedUsers token page toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/settings/blocked-users?page=" ++ String.fromInt page
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg blockedUsersResponseDecoder
        , timeout = standardTimeout
        , tracker = Nothing
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


{-| GET /api/settings/privacy — the current user's saved profile visibility and
per-shelf visibility overrides, used to seed the privacy settings screen.
-}
getPrivacySettings :
    String
    -> (Result Http.Error PrivacySettings -> msg)
    -> Cmd msg
getPrivacySettings token toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/settings/privacy"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg privacySettingsDecoder
        , timeout = standardTimeout
        , tracker = Nothing
        }



-- PUBLIC PROFILE (/u/:handle) — #214


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

    -- True only when the bookshelf is platform-visible, which is the sole case that
    -- has an Atom feed. Sent by the server rather than derived here, so the rule lives
    -- next to `Feeds.resolve_platform_bookshelf/2` instead of being duplicated — and so
    -- a public payload never has to disclose the visibility tier itself.
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
        -- Defaults to False when absent so an older server cannot make the client offer
        -- a subscribe link that would 403. Absent means "unknown", and unknown must not
        -- mean "yes" for something a reader will paste into their feed reader.
        (Decode.oneOf [ Decode.field "has_feed" Decode.bool, Decode.succeed False ])


{-| Decodes a string field that may be absent or JSON null, defaulting to "".
`Decode.nullable` handles a present-but-null value explicitly; an absent key
falls through to "".
-}
optionalString : String -> Decoder String
optionalString field =
    Decode.oneOf
        [ Decode.field field (Decode.nullable Decode.string) |> Decode.map (Maybe.withDefault "")
        , Decode.succeed ""
        ]


{-| GET /api/u/:handle. Optional auth — pass the viewer's token when signed in so
the server resolves what THIS viewer may see; `Nothing` for an anonymous viewer.
-}
getProfile : Maybe String -> String -> (Result Http.Error PublicProfile -> msg) -> Cmd msg
getProfile maybeToken handle toMsg =
    Http.request
        { method = "GET"
        , headers = authHeaders maybeToken
        , url = baseUrl ++ "/api/u/" ++ handle
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg publicProfileDecoder
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| Add a shelf to the bottom of a bookshelf.

`POST /api/bookshelves/:bookshelfName/shelves`. Takes no body: position is the server's
to assign, and letting the client propose one invites two tabs choosing the same.

-}
createShelf : String -> String -> (Result Http.Error () -> msg) -> Cmd msg
createShelf bookshelfName token toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/bookshelves/" ++ bookshelfName ++ "/shelves"
        , body = Http.jsonBody (Encode.object [])
        , expect = Http.expectWhatever toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| Remove a shelf.

`DELETE /api/shelves/:id`.

⚠️ **422 means the shelf still has books on it** and the server refused. That is a real
outcome a reader must be told about, not a transport failure to swallow — deleting a shelf
out from under its books would strand them.

-}
deleteShelf : String -> String -> (Result Http.Error () -> msg) -> Cmd msg
deleteShelf shelfId token toMsg =
    Http.request
        { method = "DELETE"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/shelves/" ++ shelfId
        , body = Http.emptyBody
        , expect = Http.expectWhatever toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| Set the order of every shelf in a bookshelf.

`PUT /api/bookshelves/:bookshelfName/shelves/reorder` with the full ordered id list.

Sends the **whole** order rather than "move shelf X to position N": the server then has no
ambiguity to resolve, and two reorders racing produce one of the two orders rather than an
interleaving neither reader asked for.

-}
reorderShelves : String -> List String -> String -> (Result Http.Error () -> msg) -> Cmd msg
reorderShelves bookshelfName shelfIds token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/bookshelves/" ++ bookshelfName ++ "/shelves/reorder"
        , body =
            Http.jsonBody
                (Encode.object [ ( "shelf_ids", Encode.list Encode.string shelfIds ) ])
        , expect = Http.expectWhatever toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| Fetch another reader's bookshelf for read-only browsing.

`GET /api/u/:handle/bookshelves/:bookshelfName` (optional auth — the viewer's
identity is threaded so the backend visibility-filters the placements). The
payload shape matches the owner's own shelf, so it reuses `shelvesResponseDecoder`.

-}
getProfileShelf :
    Maybe String
    -> String
    -> String
    -> (Result Http.Error (List Shelf) -> msg)
    -> Cmd msg
getProfileShelf maybeToken handle bookshelfName toMsg =
    Http.request
        { method = "GET"
        , headers = authHeaders maybeToken
        , url = baseUrl ++ "/api/u/" ++ handle ++ "/bookshelves/" ++ bookshelfName
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg shelvesResponseDecoder
        , timeout = standardTimeout
        , tracker = Nothing
        }



-- PEOPLE SEARCH (/api/search/users) — #217


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


{-| GET /api/search/users?q=<term>. Optional auth — pass the viewer's token when
signed in so the server can apply bidirectional block-exclusion; `Nothing` for
an anonymous viewer (ghosts are still excluded server-side).
-}
searchUsers :
    Maybe String
    -> String
    -> (Result Http.Error (List PublicProfileSummary) -> msg)
    -> Cmd msg
searchUsers maybeToken query toMsg =
    Http.request
        { method = "GET"
        , headers = authHeaders maybeToken
        , url = Url.Builder.crossOrigin baseUrl [ "api", "search", "users" ] [ Url.Builder.string "q" query ]
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg (Decode.field "users" (Decode.list publicProfileSummaryDecoder))
        , timeout = standardTimeout
        , tracker = Nothing
        }


authHeaders : Maybe String -> List Http.Header
authHeaders maybeToken =
    case maybeToken of
        Just token ->
            [ Http.header "Authorization" ("Bearer " ++ token) ]

        Nothing ->
            []



-- ADMIN: SOURCE APPROVAL


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


{-| The admin-session flow (#303).

⚠️ **This is the layer whose absence made four admin pages dead.** `/api/admin/*` sits behind
`pipeline :admin` → `AdminAuthPipeline` (requires a token whose `typ` is `"admin_session"`,
IP- and boot\_id-bound) → `RequireMFA` (verified within 30 minutes). The pages were passing the
ordinary Guardian token, which that pipeline rejects with **401** — so source approval, scraper
health, book moderation and the removal queue had never loaded for anyone.

The flow is two steps because MFA is a second factor, not a second password:

1.  `adminLogin` — owner email + password → a `session_id` for an **unverified** admin session.
    Refuses non-owners (403 `insufficient_role`) and owners with no MFA enrolled
    (403 `mfa_not_enrolled`).
2.  `adminVerifyMfa` — that `session_id` + a TOTP code → the **admin token**.

`adminMfaSetup` / `adminMfaConfirm` are the one-off enrolment path, and they take the **ordinary**
owner token rather than an admin one — necessarily, since you cannot hold an admin session before
enrolling the factor it requires.

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
    { email : String, password : String }
    -> (Result AdminAuthError AdminSession -> msg)
    -> Cmd msg
adminLogin body toMsg =
    Http.request
        { method = "POST"
        , headers = []
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
    { sessionId : String, code : String }
    -> (Result AdminAuthError String -> msg)
    -> Cmd msg
adminVerifyMfa body toMsg =
    Http.request
        { method = "POST"
        , headers = []
        , url = baseUrl ++ "/api/admin/auth/verify_mfa"
        , body =
            Http.jsonBody
                (Encode.object
                    [ ( "session_id", Encode.string body.sessionId )
                    , ( "totp_code", Encode.string body.code )
                    ]
                )
        , expect = expectAdminJson toMsg (Decode.field "token" Decode.string)
        , timeout = standardTimeout
        , tracker = Nothing
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
adminMfaSetup : String -> (Result Http.Error AdminMfaEnrolment -> msg) -> Cmd msg
adminMfaSetup ownerToken toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ ownerToken) ]
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
    String
    -> { code : String, secret : String, recoveryCodes : List String }
    -> (Result Http.Error () -> msg)
    -> Cmd msg
adminMfaConfirm ownerToken body toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ ownerToken) ]
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

        Ok "already_verified" ->
            AlreadyVerified

        _ ->
            AdminAuthTransport (Http.BadBody body)


{-| A business waiting on a human decision about its listing (US-2.5.3, campaign G6).

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


{-| GET /api/admin/removal-requests — the pending queue, oldest first.
-}
getRemovalRequests : String -> (Result Http.Error (List RemovalRequest) -> msg) -> Cmd msg
getRemovalRequests token toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/admin/removal-requests"
        , body = Http.emptyBody
        , expect =
            Http.expectJson toMsg (Decode.field "requests" (Decode.list removalRequestDecoder))
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| An invitation as the owner's list sees it (US-14.1.3): `codePrefix` only —
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



-- Applicative helper for records past map8 — local, tiny, standard shape.


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


{-| GET /api/admin/invites — every invitation, newest first.
-}
getAdminInvites : String -> (Result Http.Error (List AdminInvite) -> msg) -> Cmd msg
getAdminInvites token toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/admin/invites"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg (Decode.field "invites" (Decode.list adminInviteDecoder))
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| POST /api/admin/invites — write an invitation. The `code` in this response
is the ONLY time the full code exists in the clear.
-}
createAdminInvite :
    String
    -> { note : String, invitedEmail : String, maxUses : Int, expiresInDays : Maybe Int }
    -> (Result Http.Error ( AdminInvite, String ) -> msg)
    -> Cmd msg
createAdminInvite token body toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/admin/invites"
        , body =
            Http.jsonBody
                (Encode.object
                    (List.filterMap identity
                        [ blankAsAbsent "note" body.note
                        , blankAsAbsent "invited_email" body.invitedEmail
                        , Just ( "max_uses", Encode.int body.maxUses )
                        , Maybe.map (\days -> ( "expires_in_days", Encode.int days )) body.expiresInDays
                        ]
                    )
                )
        , expect =
            Http.expectJson toMsg
                (Decode.field "invite"
                    (Decode.map2 Tuple.pair adminInviteDecoder (Decode.field "code" Decode.string))
                )
        , timeout = standardTimeout
        , tracker = Nothing
        }


blankAsAbsent : String -> String -> Maybe ( String, Encode.Value )
blankAsAbsent key value =
    if String.trim value == "" then
        Nothing

    else
        Just ( key, Encode.string (String.trim value) )


{-| DELETE /api/admin/invites/:id — revoke. A timestamp, never a row delete.
-}
revokeAdminInvite : String -> String -> (Result Http.Error () -> msg) -> Cmd msg
revokeAdminInvite token id toMsg =
    Http.request
        { method = "DELETE"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/admin/invites/" ++ id
        , body = Http.emptyBody
        , expect = Http.expectWhatever toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| PUT /api/admin/removal-requests/:id/honour — **take the listing down.**

⚠️ **Not `approveSource`.** `approveSource` _publishes_ a listing; this unpublishes one. Two
actions that sound alike, act on the same row, and do opposite things — so both the endpoint
and this function are named for what happens to the _listing_, not for the reviewer's verdict
on the request. Read the name twice before wiring a button to it.

-}
honourRemovalRequest : String -> String -> (Result Http.Error () -> msg) -> Cmd msg
honourRemovalRequest requestId token toMsg =
    removalDecision requestId "honour" token toMsg


{-| PUT /api/admin/removal-requests/:id/decline — the listing stays up.
-}
declineRemovalRequest : String -> String -> (Result Http.Error () -> msg) -> Cmd msg
declineRemovalRequest requestId token toMsg =
    removalDecision requestId "decline" token toMsg


removalDecision : String -> String -> String -> (Result Http.Error () -> msg) -> Cmd msg
removalDecision requestId action token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/admin/removal-requests/" ++ requestId ++ "/" ++ action
        , body = Http.emptyBody
        , expect = Http.expectWhatever toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| GET /api/admin/sources — fetch paginated admin sources, optionally filtered by status.
-}
getAdminSources :
    { status : Maybe String, page : Int }
    -> String
    -> (Result Http.Error AdminSourcesResponse -> msg)
    -> Cmd msg
getAdminSources params token toMsg =
    let
        queryParams =
            [ Just (Url.Builder.int "page" params.page)
            , params.status |> Maybe.map (Url.Builder.string "status")
            ]
                |> List.filterMap identity
    in
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = Url.Builder.absolute [ "api", "admin", "sources" ] queryParams
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg adminSourcesResponseDecoder
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| PUT /api/admin/sources/:id/approve — approve a pending source.
-}
approveSource :
    String
    -> String
    -> (Result Http.Error AdminSource -> msg)
    -> Cmd msg
approveSource sourceId token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/admin/sources/" ++ sourceId ++ "/approve"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg (Decode.field "source" adminSourceDecoder)
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| PUT /api/admin/sources/:id/reject — reject a pending source.
-}
rejectSource :
    String
    -> String
    -> (Result Http.Error AdminSource -> msg)
    -> Cmd msg
rejectSource sourceId token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/admin/sources/" ++ sourceId ++ "/reject"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg (Decode.field "source" adminSourceDecoder)
        , timeout = standardTimeout
        , tracker = Nothing
        }



-- ADMIN: BOOK MODERATION (age gate)


{-| A book as returned by the owner moderation API (#118).
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


{-| GET /api/admin/books — fetch paginated books for moderation, optionally
filtered by tier (`public` | `age_gated`) and/or a title search.
-}
adminListBooks :
    { tier : Maybe String, search : Maybe String, page : Int }
    -> String
    -> (Result Http.Error AdminBooksResponse -> msg)
    -> Cmd msg
adminListBooks params token toMsg =
    let
        queryParams =
            [ Just (Url.Builder.int "page" params.page)
            , params.tier |> Maybe.map (Url.Builder.string "tier")
            , params.search |> Maybe.map (Url.Builder.string "search")
            ]
                |> List.filterMap identity
    in
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = Url.Builder.absolute [ "api", "admin", "books" ] queryParams
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg adminBooksResponseDecoder
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| PUT /api/admin/books/:id/age-gate — owner sets a book's age gate in either
direction. Body `{"age_gated": Bool}`. Returns the updated book.
-}
adminSetBookAgeGate :
    String
    -> Bool
    -> String
    -> (Result Http.Error AdminBook -> msg)
    -> Cmd msg
adminSetBookAgeGate bookId ageGated token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/admin/books/" ++ bookId ++ "/age-gate"
        , body = Http.jsonBody (Encode.object [ ( "age_gated", Encode.bool ageGated ) ])
        , expect = Http.expectJson toMsg (Decode.field "book" adminBookDecoder)
        , timeout = standardTimeout
        , tracker = Nothing
        }



-- SOURCE HEALTH (admin scraper page)


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


{-| GET /api/admin/source-health — fetch per-source health status.
-}
getSourceHealth :
    String
    -> (Result Http.Error (List SourceHealth) -> msg)
    -> Cmd msg
getSourceHealth token toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/admin/source-health"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg sourceHealthListDecoder
        , timeout = standardTimeout
        , tracker = Nothing
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


{-| GET /api/onboarding/status — fetch current step completion state.
-}
getOnboardingStatus :
    String
    -> (Result Http.Error OnboardingStatus -> msg)
    -> Cmd msg
getOnboardingStatus token toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/onboarding/status"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg onboardingStatusDecoder
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| PUT /api/onboarding/step/:step — mark a step as complete. Returns updated status.
-}
completeOnboardingStep :
    String
    -> String
    -> (Result Http.Error OnboardingStatus -> msg)
    -> Cmd msg
completeOnboardingStep step token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/onboarding/step/" ++ step
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg onboardingStatusDecoder
        , timeout = standardTimeout
        , tracker = Nothing
        }


createGroup :
    String
    -> String
    -> (Result Http.Error Group -> msg)
    -> Cmd msg
createGroup name token toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/groups"
        , body =
            Http.jsonBody
                (Encode.object
                    [ ( "name", Encode.string name )
                    , ( "type", Encode.string "close_friends" )
                    ]
                )
        , expect = Http.expectJson toMsg (Decode.field "group" groupDecoder)
        , timeout = standardTimeout
        , tracker = Nothing
        }


getGroup :
    String
    -> String
    -> (Result Http.Error Group -> msg)
    -> Cmd msg
getGroup groupId token toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/groups/" ++ groupId
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg (Decode.field "group" groupDecoder)
        , timeout = standardTimeout
        , tracker = Nothing
        }


getGroupFeed :
    String
    -> String
    -> Maybe String
    -> (Result Http.Error FeedResponse -> msg)
    -> Cmd msg
getGroupFeed groupId token maybeCursor toMsg =
    let
        url =
            case maybeCursor of
                Nothing ->
                    baseUrl ++ "/api/groups/" ++ groupId ++ "/feed"

                Just cursor ->
                    baseUrl ++ "/api/groups/" ++ groupId ++ "/feed?before=" ++ cursor
    in
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = url
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg feedResponseDecoder
        , timeout = standardTimeout
        , tracker = Nothing
        }


inviteToGroup :
    String
    -> String
    -> String
    -> (Result Http.Error GroupInvitation -> msg)
    -> Cmd msg
inviteToGroup groupId identifier token toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/groups/" ++ groupId ++ "/invitations"
        , body =
            Http.jsonBody
                (Encode.object
                    [ ( "identifier", Encode.string identifier )
                    ]
                )
        , expect = Http.expectJson toMsg (Decode.field "invitation" groupInvitationDecoder)
        , timeout = standardTimeout
        , tracker = Nothing
        }


acceptInvitation :
    String
    -> String
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
acceptInvitation groupId invitationId token toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/groups/" ++ groupId ++ "/invitations/" ++ invitationId ++ "/accept"
        , body = Http.emptyBody
        , expect = Http.expectWhatever toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }


declineInvitation :
    String
    -> String
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
declineInvitation groupId invitationId token toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/groups/" ++ groupId ++ "/invitations/" ++ invitationId ++ "/decline"
        , body = Http.emptyBody
        , expect = Http.expectWhatever toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }


leaveGroup :
    String
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
leaveGroup groupId token toMsg =
    Http.request
        { method = "DELETE"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/groups/" ++ groupId ++ "/leave"
        , body = Http.emptyBody
        , expect = Http.expectWhatever toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }
