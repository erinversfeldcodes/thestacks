module Api exposing
    ( Account
    , AdminAuthError(..)
    , AdminBook
    , AdminBooksResponse
    , AdminFeedbackEntry
    , AdminInvite
    , AdminMfaEnrolment
    , AdminSession
    , AdminSource
    , AdminSourcesResponse
    , AuditLogEntry
    , AuditLogResponse
    , AuthResponse
    , Authed
    , AuthorEvent
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
    , ProfileSaved
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
    , ShelfMoveError(..)
    , ShelfVisibilitySetting
    , SourceHealth
    , SubjectCount
    , Syndication
    , SyndicationExport
    , TransparencyEntry
    , TransparencyMetrics
    , UploadInit
    , acceptInvitation
    , accountDecoder
    , activateListing
    , adminBookEnvelopeDecoder
    , adminBooksResponseDecoder
    , adminListBooks
    , adminListBooksRequest
    , adminLogin
    , adminLogoutRequest
    , adminMfaConfirm
    , adminMfaSetup
    , adminSetBookAgeGate
    , adminSetBookAgeGateRequest
    , adminVerifyMfa
    , approveSource
    , auditLogResponseDecoder
    , authHeaders
    , authResponseDecoder
    , authed
    , authorEventsDecoder
    , awaitingConfirmationCount
    , blockUser
    , bookDetailResponseDecoder
    , catalogueResponseDecoder
    , checkInviteRequest
    , commitUploadDecoder
    , commitUploadRequest
    , completeOnboardingStep
    , confirmAssociation
    , confirmBookRequest
    , confirmResponseToResult
    , createAdminInvite
    , createBlogPost
    , createComment
    , createGoodreadsImport
    , createGroup
    , createListing
    , createShelfRequest
    , deactivateListing
    , declineInvitation
    , declineRemovalRequest
    , decodeUploadInit
    , deleteAccount
    , deleteAccountRequest
    , deleteComment
    , deleteShelfRequest
    , dismissAssociation
    , encodeProfileBody
    , fetchSyndicationExport
    , foldProgress
    , forgotPasswordRequest
    , getAccountRequest
    , getAdminFeedback
    , getAdminInvites
    , getAdminSources
    , getAuditLog
    , getAuditLogRequest
    , getAuthorEventsRequest
    , getBlogPost
    , getBlogPosts
    , getBookRequest
    , getBookshelf
    , getBookshelfRequest
    , getCatalogue
    , getCatalogueRequest
    , getGroup
    , getGroupFeed
    , getImport
    , getImportRows
    , getInferences
    , getInferencesRequest
    , getListings
    , getMyListings
    , getMyPlacements
    , getNotifications
    , getOnboardingStatus
    , getPostComments
    , getPrivacySettings
    , getProfile
    , getProfileShelfRequest
    , getRemovalRequests
    , getSourceHealth
    , getTransparencyMetrics
    , getUploadInbox
    , getUserPlacements
    , getUserPlacementsRequest
    , honourRemovalRequest
    , initUploadRequest
    , interpretAuthed
    , inviteStatusDecoder
    , inviteToGroup
    , isNotFound
    , isUnauthorized
    , leaveGroup
    , listBlockedUsers
    , loginRequest
    , logout
    , mergeFormatRequest
    , mergeFormatResponseDecoder
    , moveBookRequest
    , movePlacementToShelfRequest
    , moveResponseToResult
    , peopleSearchDecoder
    , personalInferencesDecoder
    , placeBook
    , placeBookRequest
    , placeResponseToResult
    , placementFormatsDecoder
    , placementsMineDecoder
    , progressErrorMessage
    , progressResponseToResult
    , publicProfileDecoder
    , publicProfileSummaryDecoder
    , publishBlogPost
    , putFileToR2
    , recordSyndication
    , refresh
    , refreshRequest
    , registerRequest
    , rejectIdentificationRequest
    , rejectSource
    , removeBookRequest
    , reorderShelvesRequest
    , requestExport
    , requestExportRequest
    , requestListingRemoval
    , resendConfirmationRequest
    , resetPassword
    , resolveAuthResponse
    , resolveJson
    , resolveNoContent
    , resolveProfile
    , resolveRegister
    , resolveWhatever
    , restoreBookRequest
    , retryAfterSeconds
    , revokeAdminInvite
    , saveConsent
    , saveWritingAssistantConsent
    , searchBooksRequest
    , searchResponseDecoder
    , searchUsersRequest
    , sendFeedback
    , sendFeedbackRequest
    , setBookAgeGateRequest
    , setPostSyndicated
    , shelfMoveErrorMessage
    , shelfMoveResponseToResult
    , soldListing
    , specHttpBody
    , standardTimeout
    , storedVisibilityDecoder
    , streamEventDecoder
    , transparencyMetricsDecoder
    , unblockUser
    , updateBlogPost
    , updateLocation
    , updateNotifications
    , updatePassword
    , updatePlacementFormatsRequest
    , updatePlacementVisibilityRequest
    , updateProfile
    , updateProfileVisibility
    , updateProgressRequest
    , updateShelfVisibility
    , updateSyndicationUrl
    , uploadTimeout
    )

{-| Every HTTP call the SPA makes, and every decoder that reads a server
response. The large `exposing` list is deliberate: decoders are exported
so tests wire the REAL decoder into simulated effects — a hand-written
test mirror is what let the upload SSE wire format drift for months.
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
import Types.Shelf exposing (BookshelfResponse, bookshelfResponseDecoder)
import Url.Builder


baseUrl : String
baseUrl =
    ""


{-| A request's data — method, url, JSON body — apart from the
`Http.request` that sends it. `elm-program-test` cannot run real
requests, so test translators build `SimulatedEffect`s; before this seam
they hand-copied url/method/body, and a drifted copy was invisible to
the whole suite. Both production and tests now consume the same spec.
-}
type alias RequestSpec =
    { method : String
    , url : String
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

Every field is required, for the same reason `streamEventDecoder`'s are: `StacksWeb.ProtoJSON.upload_inbox_item/1` emits all four on every
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
    , url = baseUrl ++ "/api/authors/" ++ authorId ++ "/events"
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


{-| Upload refusals the page owes distinct copy for. The server answers each
with a distinct status, so the STATUS is the discriminant —
no body parse to drift.
-}
type ImportError
    = ImportInProgress
    | ImportFileTooLarge
    | ImportUnrecognised
    | ImportRequestFailed Http.Error


libraryImportDecoder : Decoder LibraryImport
libraryImportDecoder =
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


{-| What `GET /api/auth/invite/:code` says about a redeemable code.
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


{-| `GET /api/auth/invite/:code` — look an invitation code up before offering
the Register form.

The four refusals arrive as plain `BadStatus`; the status alone tells them
apart, so the card maps status to copy and never reads the body.

-}
checkInviteRequest : String -> RequestSpec
checkInviteRequest code =
    { method = "GET"
    , url = baseUrl ++ "/api/auth/invite/" ++ code
    , body = Nothing
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
    , url = baseUrl ++ "/api/auth/register"
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
    , url = baseUrl ++ "/api/auth/login"
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
    , url = baseUrl ++ "/api/auth/forgot-password"
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
    , url = baseUrl ++ "/api/auth/resend-confirmation"
    , body = Just (Encode.object [ ( "email", Encode.string email ) ])
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

Unauthenticated by design (: "does not require account creation"). The contact
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
tested directly instead of through a simulated effect that mirrors it (,
: a test that re-implements the thing under test agrees only with itself).
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
a fresh one before it expires. The 200
body is byte-identical to login's, so we reuse `authResponseDecoder`. A 401/error
here means the session is no longer renewable and the caller falls through to the
session-expiry interceptor.
-}
refresh :
    String
    -> (Result Http.Error AuthResponse -> msg)
    -> Cmd msg
refresh token toMsg =
    let
        spec =
            refreshRequest
    in
    Http.request
        { method = spec.method
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = spec.url
        , body = specHttpBody spec
        , expect = Http.expectJson toMsg authResponseDecoder
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| `POST /api/auth/refresh` — exchange a still-valid access token for a fresh
one before it expires. The 200 body is byte-identical to login's, so
`authResponseDecoder` reads it; a 401 means the session is no longer renewable
and the caller falls through to the session-expiry interceptor.
-}
refreshRequest : RequestSpec
refreshRequest =
    { method = "POST"
    , url = baseUrl ++ "/api/auth/refresh"
    , body = Nothing
    }


{-| DELETE /api/auth/logout — invalidate the current session server-side
(revokes the token via guardian\_db, A2). The method MUST be DELETE
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


{-| `POST /api/upload/init` — allocates an image\_id server-side and returns a
Phoenix-served `upload_url` (`PUT /api/upload/:id/data`) the client PUTs the
bytes to. Phoenix proxies them to the configured storage backend (R2 in
production, Local in dev/preview); same-origin, so no R2 CORS allowlisting is
needed.
-}
initUploadRequest : String -> RequestSpec
initUploadRequest contentType =
    { method = "POST"
    , url = baseUrl ++ "/api/upload/init"
    , body = Just (Encode.object [ ( "content_type", Encode.string contentType ) ])
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


{-| `POST /api/upload/:id/commit` — tells the backend the client's direct PUT
succeeded. The backend HEADs the object, flips the row from awaiting\_upload to
pending, and enqueues identification work.
-}
commitUploadRequest : String -> RequestSpec
commitUploadRequest imageId =
    { method = "POST"
    , url = baseUrl ++ "/api/upload/" ++ imageId ++ "/commit"
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
    , url = baseUrl ++ "/api/upload/" ++ imageId ++ "/reject-identification"
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
    }


{-| Adapter: proto BookDetailResponse -> app BookDetailResponse.

Proto includes myWriting (dropped). Proto book/placement are proto types
decoded through the existing app-level decoders which already delegate to proto.

-}
bookDetailResponseDecoder : Decoder BookDetailResponse
bookDetailResponseDecoder =
    Decode.map4 BookDetailResponse
        (Decode.field "book" bookDecoder)
        (Decode.oneOf
            [ Decode.field "placement" (Decode.nullable placementDecoder)
            , Decode.succeed Nothing
            ]
        )
        (Decode.oneOf
            [ Decode.at [ "placement", "bookshelf_visibility" ] (Decode.nullable Decode.string)
            , Decode.succeed Nothing
            ]
        )
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


{-| `GET /api/books/:id` — a book with the viewer's placement data. Optional
auth: an anonymous reader gets the book without the placements.
-}
getBookRequest : String -> RequestSpec
getBookRequest bookId =
    { method = "GET"
    , url = baseUrl ++ "/api/books/" ++ bookId
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
        Url.Builder.crossOrigin baseUrl
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


getBookshelf :
    String
    -> String
    -> (Result Http.Error BookshelfResponse -> msg)
    -> Cmd msg
getBookshelf shelfName token toMsg =
    let
        spec =
            getBookshelfRequest shelfName
    in
    Http.request
        { method = spec.method
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = spec.url
        , body = specHttpBody spec
        , expect = Http.expectJson toMsg bookshelfResponseDecoder
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| The data of `getBookshelf`'s request — see `RequestSpec`.
-}
getBookshelfRequest : String -> RequestSpec
getBookshelfRequest shelfName =
    { method = "GET"
    , url = baseUrl ++ "/api/bookshelves/" ++ shelfName
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
    , url = baseUrl ++ "/api/placements/" ++ placementId ++ "/move"
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
    , url = baseUrl ++ "/api/placements/" ++ placementId
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
    , url = baseUrl ++ "/api/placements/" ++ placementId ++ "/restore"
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
    , url = baseUrl ++ "/api/placements/" ++ placementId ++ "/progress"
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
    let
        spec =
            requestExportRequest
    in
    Http.request
        { method = spec.method
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = spec.url
        , body = specHttpBody spec
        , expect = Http.expectWhatever toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| The data of `requestExport`'s request — see `RequestSpec`.
-}
requestExportRequest : RequestSpec
requestExportRequest =
    { method = "POST"
    , url = baseUrl ++ "/api/gdpr/export"
    , body = Nothing
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
    let
        spec =
            deleteAccountRequest
    in
    Http.request
        { method = spec.method
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = spec.url
        , body = specHttpBody spec
        , expect = Http.expectWhatever toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| The data of `deleteAccount`'s request — see `RequestSpec`.
-}
deleteAccountRequest : RequestSpec
deleteAccountRequest =
    { method = "DELETE"
    , url = baseUrl ++ "/api/gdpr/account"
    , body = Nothing
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
`consent_writing_assistant` flag. Revoking triggers a server-side
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


{-| GET /api/settings/audit-log — fetch the current user's audit history.
-}
getAuditLog :
    String
    -> (Result Http.Error AuditLogResponse -> msg)
    -> Cmd msg
getAuditLog token toMsg =
    let
        spec =
            getAuditLogRequest
    in
    Http.request
        { method = spec.method
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = spec.url
        , body = specHttpBody spec
        , expect = Http.expectJson toMsg auditLogResponseDecoder
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| The data of `getAuditLog`'s request — see `RequestSpec`.
-}
getAuditLogRequest : RequestSpec
getAuditLogRequest =
    { method = "GET"
    , url = baseUrl ++ "/api/settings/audit-log?page=1"
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
    let
        spec =
            getInferencesRequest revealRisk
    in
    Http.request
        { method = spec.method
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = spec.url
        , body = specHttpBody spec
        , expect = Http.expectJson toMsg personalInferencesDecoder
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| The data of `getInferences`'s request — see `RequestSpec`.
-}
getInferencesRequest : Bool -> RequestSpec
getInferencesRequest revealRisk =
    { method = "GET"
    , url =
        baseUrl
            ++ "/api/me/inferences"
            ++ (if revealRisk then
                    "?reveal_risk=true"

                else
                    ""
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
    let
        spec =
            placeBookRequest bookshelfName bookId
    in
    Http.request
        { method = spec.method
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = spec.url
        , body = specHttpBody spec
        , expect = expectPlace toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| The data of `placeBook`'s request — see `RequestSpec`.
-}
placeBookRequest : String -> String -> RequestSpec
placeBookRequest bookshelfName bookId =
    { method = "POST"
    , url = baseUrl ++ "/api/bookshelves/" ++ bookshelfName ++ "/placements"
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
    , url = baseUrl ++ "/api/books/" ++ bookId ++ "/age-gate"
    , body = Just (Encode.object [ ( "adults_only", Encode.bool True ) ])
    }


{-| GET /api/placements/mine — fetch summary of user's active placements.
-}
getUserPlacements :
    String
    -> (Result Http.Error (List PlacementSummary) -> msg)
    -> Cmd msg
getUserPlacements token toMsg =
    let
        spec =
            getUserPlacementsRequest
    in
    Http.request
        { method = spec.method
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = spec.url
        , body = specHttpBody spec
        , expect = Http.expectJson toMsg placementsMineDecoder
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| The data of `getUserPlacements`'s request — see `RequestSpec`.
-}
getUserPlacementsRequest : RequestSpec
getUserPlacementsRequest =
    { method = "GET"
    , url = baseUrl ++ "/api/placements/mine"
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


{-| `POST /api/books/confirm` — file a manually entered ISBN on the chosen
bookshelf.
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
        spec =
            getCatalogueRequest params
    in
    Http.request
        { method = spec.method
        , headers = []
        , url = spec.url
        , body = specHttpBody spec
        , expect = Http.expectJson toMsg catalogueResponseDecoder
        , timeout = standardTimeout
        , tracker = Nothing
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
        Url.Builder.absolute [ "api", "catalogue" ]
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
    , url = baseUrl ++ "/api/auth/me"
    , body = Nothing
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
        , headers = authedHeaders request
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


{-| `POST /api/books/:id/merge-format` — add a new edition to a book the reader
already owns, rather than creating a second work for the same title.
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


{-| `PUT /api/placements/:id/visibility`.

The server enforces the ceiling rule — a placement may not be more visible than
its parent bookshelf — and answers 422 when it is violated. The 200 body
carries the visibility actually stored, which is what the caller adopts.

-}
updatePlacementVisibilityRequest : String -> String -> RequestSpec
updatePlacementVisibilityRequest placementId visibility =
    { method = "PUT"
    , url = baseUrl ++ "/api/placements/" ++ placementId ++ "/visibility"
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
    , url = baseUrl ++ "/api/placements/" ++ placementId ++ "/formats"
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
    , url = baseUrl ++ "/api/placements/" ++ placementId ++ "/shelf"
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


{-| `Http.expectWhatever` would collapse the backend's `{"error":...}` body
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


{-| `POST /api/bookshelves/:name/shelves` — add a shelf row to the bottom of a
bookcase.

No body: the position is the server's to assign, and letting the client propose
one invites two tabs choosing the same.

-}
createShelfRequest : String -> RequestSpec
createShelfRequest bookshelfName =
    { method = "POST"
    , url = baseUrl ++ "/api/bookshelves/" ++ bookshelfName ++ "/shelves"
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
    , url = baseUrl ++ "/api/shelves/" ++ shelfId
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
    , url = baseUrl ++ "/api/bookshelves/" ++ bookshelfName ++ "/shelves/reorder"
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
    , url = baseUrl ++ "/api/u/" ++ handle ++ "/bookshelves/" ++ bookshelfName
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
    , url = Url.Builder.crossOrigin baseUrl [ "api", "search", "users" ] [ Url.Builder.string "q" query ]
    , body = Nothing
    }


{-| The people half of search: `{users: [...]}`.
-}
peopleSearchDecoder : Decoder (List PublicProfileSummary)
peopleSearchDecoder =
    Decode.field "users" (Decode.list publicProfileSummaryDecoder)


authHeaders : Maybe String -> List Http.Header
authHeaders maybeToken =
    case maybeToken of
        Just token ->
            [ Http.header "Authorization" ("Bearer " ++ token) ]

        Nothing ->
            []


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


{-| DELETE /api/admin/auth/logout — revoke THIS admin session server-side.

Send it with the admin token (`Main.adminTokenFor`), never the ordinary one: the
route reads the session off the admin pipeline, so the Guardian token 401s here
exactly as it does on every other `/api/admin/*` path.

A `RequestSpec` rather than a `Cmd`-returning function because the caller
dispatches it through `Effect`, which is what lets a program test read the
request instead of restating it.

-}
adminLogoutRequest : RequestSpec
adminLogoutRequest =
    { method = "DELETE"
    , url = baseUrl ++ "/api/admin/auth/logout"
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


adminFeedbackEntryDecoder : Decoder AdminFeedbackEntry
adminFeedbackEntryDecoder =
    Decode.succeed AdminFeedbackEntry
        |> andMap (Decode.field "id" Decode.string)
        |> andMap (Decode.field "body" Decode.string)
        |> andMap (Decode.field "page_context" (Decode.nullable Decode.string))
        |> andMap (Decode.field "sender_handle" (Decode.nullable Decode.string))
        |> andMap (Decode.field "created_at" Decode.string)


{-| GET /api/admin/feedback — the owner's queue, newest first.
-}
getAdminFeedback : String -> (Result Http.Error (List AdminFeedbackEntry) -> msg) -> Cmd msg
getAdminFeedback token toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/admin/feedback"
        , body = Http.emptyBody
        , expect =
            Http.expectJson toMsg (Decode.field "feedback" (Decode.list adminFeedbackEntryDecoder))
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| POST /api/feedback — send the reader's message.

The 201 carries no body back, deliberately, so this resolves to `()`: there is
nothing to render but the acknowledgement, and re-displaying what they just
typed would be the server telling them what they already know.

-}
sendFeedback : { body : String, pageContext : String } -> Authed Http.Error () msg -> Cmd msg
sendFeedback body request =
    let
        spec =
            sendFeedbackRequest body
    in
    Http.request
        { method = spec.method
        , headers = authedHeaders request
        , url = spec.url
        , body = specHttpBody spec
        , expect = authedExpect resolveWhatever request
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| The data of `sendFeedback`'s request — see `RequestSpec`.
-}
sendFeedbackRequest : { body : String, pageContext : String } -> RequestSpec
sendFeedbackRequest body =
    { method = "POST"
    , url = baseUrl ++ "/api/feedback"
    , body =
        Just
            (Encode.object
                [ ( "body", Encode.string body.body )
                , ( "page_context", Encode.string body.pageContext )
                ]
            )
    }


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
        spec =
            adminListBooksRequest params
    in
    Http.request
        { method = spec.method
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = spec.url
        , body = specHttpBody spec
        , expect = Http.expectJson toMsg adminBooksResponseDecoder
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| The data of `adminListBooks`'s request — see `RequestSpec`.
-}
adminListBooksRequest :
    { tier : Maybe String, search : Maybe String, page : Int }
    -> RequestSpec
adminListBooksRequest params =
    { method = "GET"
    , url =
        Url.Builder.absolute [ "api", "admin", "books" ]
            (List.filterMap identity
                [ Just (Url.Builder.int "page" params.page)
                , params.tier |> Maybe.map (Url.Builder.string "tier")
                , params.search |> Maybe.map (Url.Builder.string "search")
                ]
            )
    , body = Nothing
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
    let
        spec =
            adminSetBookAgeGateRequest bookId ageGated
    in
    Http.request
        { method = spec.method
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = spec.url
        , body = specHttpBody spec
        , expect = Http.expectJson toMsg adminBookEnvelopeDecoder
        , timeout = standardTimeout
        , tracker = Nothing
        }


{-| The data of `adminSetBookAgeGate`'s request — see `RequestSpec`.
-}
adminSetBookAgeGateRequest : String -> Bool -> RequestSpec
adminSetBookAgeGateRequest bookId ageGated =
    { method = "PUT"
    , url = baseUrl ++ "/api/admin/books/" ++ bookId ++ "/age-gate"
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
