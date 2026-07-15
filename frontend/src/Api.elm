module Api exposing
    ( AdminSource
    , AdminSourcesResponse
    , AuditLogEntry
    , AuditLogResponse
    , AuthResponse
    , BlockError(..)
    , BlockedUser
    , BlockedUsersResponse
    , BookDetailResponse
    , CatalogueResponse
    , EnrichmentGaps
    , ListingParams
    , MergeFormatResponse
    , MetricsDashboard
    , NotificationPreferences
    , OnboardingStatus
    , PlacementSummary
    , PollResponse
    , PollStatus(..)
    , PrivacySettings
    , ProfileError(..)
    , ProfileShelfSummary
    , PublicProfile
    , QualityTrends
    , RegisterError(..)
    , ShelfVisibilitySetting
    , SourceHealth
    , UploadInit
    , acceptInvitation
    , activateListing
    , addShelf
    , approveSource
    , auditLogResponseDecoder
    , blockUser
    , commitUpload
    , completeOnboardingStep
    , confirmAssociation
    , createBlogPost
    , createComment
    , createGroup
    , createListing
    , deactivateListing
    , declineInvitation
    , deleteAccount
    , deleteComment
    , dismissAssociation
    , getAdminSources
    , getAuditLog
    , getBlogPost
    , getBlogPosts
    , getBook
    , getBookshelf
    , getCatalogue
    , getEnrichmentGaps
    , getGroup
    , getGroupFeed
    , getListings
    , getMetrics
    , getMyListings
    , getMyPlacements
    , getOnboardingStatus
    , getPostComments
    , getPrivacySettings
    , getProfile
    , getQualityTrends
    , getSourceHealth
    , getUserPlacements
    , initUpload
    , inviteToGroup
    , isNotFound
    , isUnauthorized
    , leaveGroup
    , listBlockedUsers
    , login
    , logout
    , lookupByIsbn
    , mergeFormat
    , moveBook
    , placeBook
    , publishBlogPost
    , putFileToR2
    , refresh
    , register
    , rejectIdentification
    , rejectSource
    , removeBook
    , requestExport
    , saveConsent
    , saveWritingAssistantConsent
    , searchBooks
    , soldListing
    , streamEventDecoder
    , unblockUser
    , updateAgeVerification
    , updateBlogPost
    , updateLocation
    , updateNotifications
    , updatePassword
    , updatePlacementVisibility
    , updateProfile
    , updateProfileVisibility
    , updateShelfVisibility
    )

import File exposing (File)
import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Stacks.Api.V1.Admin as ProtoAdmin
import Stacks.Api.V1.AuthResponses as ProtoAuth
import Stacks.Api.V1.BookResponses as ProtoBookResp
import Stacks.Api.V1.BookshelfResponses as ProtoBookshelfResp
import Stacks.Api.V1.Requests as Requests
import Stacks.Api.V1.SourceResponses as ProtoSourceResp
import Stacks.Common.V1.Placement as ProtoPlacement
import Stacks.Monitoring.V1.SourceHealthCheck as ProtoHealth
import Types.BlogPost exposing (BlogPost, BlogPostSummary, Comment, blogPostDecoder, blogPostSummaryDecoder, commentDecoder)
import Types.Book exposing (Book, Edition, bookDecoder)
import Types.FeedItem exposing (FeedResponse, feedResponseDecoder)
import Types.Group exposing (Group, GroupInvitation, groupDecoder, groupInvitationDecoder)
import Types.Listing exposing (Listing, ListingsResponse, listingDecoder, listingsResponseDecoder)
import Types.Placement exposing (Placement, placementDecoder, placementSummaryDecoder)
import Types.ProtoHelpers exposing (emptyToNothing)
import Types.Shelf exposing (Shelf, shelfDecoder, shelvesResponseDecoder)
import Url.Builder


baseUrl : String
baseUrl =
    ""


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
Fails loudly on unknown values rather than silently falling through.
-}
type PollStatus
    = Pending
    | Resolved
    | Rejected


{-| Response from GET /api/upload/:image\_id/status.
bookId is present only when status is Resolved and a book was identified.
isDuplicate is true when the identified book is already on one of the user's shelves.
-}
type alias PollResponse =
    { imageId : String
    , status : PollStatus
    , bookId : Maybe String
    , bookIds : List String
    , rejectionReason : Maybe String
    , isDuplicate : Maybe Bool
    }


{-| Decoder for SSE stream events from /api/upload/:id/stream.

SSE events use camelCase JSON keys (standard JSON API convention), while the
proto-generated decoder uses snake\_case. This decoder handles both.

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
                        Rejected

                    _ ->
                        Pending
            , bookId = emptyToNothing (Maybe.withDefault "" bookId)
            , bookIds = bookIds
            , rejectionReason = emptyToNothing (Maybe.withDefault "" rejectionReason)
            , isDuplicate =
                if isDuplicate == Just True then
                    Just True

                else
                    Nothing
            }
        )
        (Decode.oneOf [ Decode.field "imageId" Decode.string, Decode.field "image_id" Decode.string, Decode.succeed "" ])
        (Decode.oneOf [ Decode.field "status" Decode.string, Decode.succeed "" ])
        (Decode.oneOf
            [ Decode.field "bookId" (Decode.nullable Decode.string)
            , Decode.field "book_id" (Decode.nullable Decode.string)
            , Decode.succeed Nothing
            ]
        )
        (Decode.oneOf
            [ Decode.field "bookIds" (Decode.list Decode.string)
            , Decode.field "book_ids" (Decode.list Decode.string)
            , Decode.succeed []
            ]
        )
        (Decode.oneOf
            [ Decode.field "rejectionReason" (Decode.nullable Decode.string)
            , Decode.field "rejection_reason" (Decode.nullable Decode.string)
            , Decode.succeed Nothing
            ]
        )
        (Decode.oneOf
            [ Decode.field "isDuplicate" (Decode.nullable Decode.bool)
            , Decode.field "is_duplicate" (Decode.nullable Decode.bool)
            , Decode.succeed Nothing
            ]
        )


{-| A registration failure.

A 422 carries per-field validation errors (keyed by field name — `email`,
`password`, `display_name`) so the UI can explain the _actual_ problem rather
than guessing. Every other failure (network, timeout, unexpected status, or a
422 whose body we could not parse) is a `RegisterRequestFailed`.

-}
type RegisterError
    = RegisterValidationFailed (List ( String, List String ))
    | RegisterRequestFailed Http.Error


{-| Decode the backend's `{"errors": {field: [msg, ...]}}` 422 body. See
`format_errors/1` in the Elixir `StacksWeb.ChangesetHelpers`.
-}
registerErrorsDecoder : Decoder (List ( String, List String ))
registerErrorsDecoder =
    Decode.field "errors" (Decode.keyValuePairs (Decode.list Decode.string))


register :
    { email : String, password : String, displayName : String }
    -> (Result RegisterError () -> msg)
    -> Cmd msg
register body toMsg =
    Http.post
        { url = baseUrl ++ "/api/auth/register"
        , body =
            Http.jsonBody
                (Requests.encodeRegisterRequest
                    { email = body.email
                    , password = body.password
                    , displayName = body.displayName
                    }
                )
        , expect = expectRegister toMsg
        }


{-| `Http.expectJson` discards the response body on a non-2xx status, which
would throw away the structured `{"errors": ...}` payload a 422 carries. This
custom expect keeps those field errors so the caller can surface the real
reason a registration was rejected.
-}
expectRegister : (Result RegisterError () -> msg) -> Http.Expect msg
expectRegister toMsg =
    Http.expectStringResponse toMsg <|
        \response ->
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

                    else
                        Err (RegisterRequestFailed (Http.BadStatus metadata.statusCode))

                Http.GoodStatus_ _ bodyText ->
                    case Decode.decodeString registrationResponseDecoder bodyText of
                        Ok value ->
                            Ok value

                        Err err ->
                            Err (RegisterRequestFailed (Http.BadBody (Decode.errorToString err)))


login :
    { email : String, password : String }
    -> (Result Http.Error AuthResponse -> msg)
    -> Cmd msg
login body toMsg =
    Http.post
        { url = baseUrl ++ "/api/auth/login"
        , body =
            Http.jsonBody
                (Requests.encodeLoginRequest
                    { email = body.email
                    , password = body.password
                    }
                )
        , expect = Http.expectJson toMsg authResponseDecoder
        }


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
        , timeout = Nothing
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
        , timeout = Nothing
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
returns a presigned R2 PUT URL the client can upload to directly. The
Phoenix handler only touches the DB + SigV4 signing, not the bytes.
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
        , timeout = Nothing
        , tracker = Nothing
        }


{-| PUT the file bytes to the presigned R2 URL. Sends the raw File body;
Elm's Http uses XHR under the hood, so the JS-side compression
monkey-patch in `apps/core/assets/js/app.js` intercepts this
automatically. No auth header — the presigned URL signature IS the
authorisation.
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
        , tracker = Nothing
        }


{-| Response from GET /api/books/:id — book with optional placement data.
-}
type alias BookDetailResponse =
    { book : Book
    , placement : Maybe Placement
    , bookshelfVisibility : Maybe String
    }


{-| Adapter: proto BookDetailResponse -> app BookDetailResponse.

Proto includes myWriting (dropped). Proto book/placement are proto types
decoded through the existing app-level decoders which already delegate to proto.

-}
bookDetailResponseDecoder : Decoder BookDetailResponse
bookDetailResponseDecoder =
    Decode.map3 BookDetailResponse
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
    Http.request
        { method = "GET"
        , headers =
            case maybeToken of
                Just token ->
                    [ Http.header "Authorization" ("Bearer " ++ token) ]

                Nothing ->
                    []
        , url = baseUrl ++ "/api/books/" ++ bookId
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg bookDetailResponseDecoder
        , timeout = Nothing
        , tracker = Nothing
        }


searchBooks :
    String
    -> String
    -> (Result Http.Error (List Book) -> msg)
    -> Cmd msg
searchBooks query token toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = Url.Builder.crossOrigin baseUrl [ "api", "books", "search" ] [ Url.Builder.string "q" query ]
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg (Decode.list bookDecoder)
        , timeout = Nothing
        , tracker = Nothing
        }


getBookshelf :
    String
    -> String
    -> (Result Http.Error (List Shelf) -> msg)
    -> Cmd msg
getBookshelf shelfName token toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/bookshelves/" ++ shelfName
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg shelvesResponseDecoder
        , timeout = Nothing
        , tracker = Nothing
        }


addShelf :
    String
    -> String
    -> (Result Http.Error Shelf -> msg)
    -> Cmd msg
addShelf shelfName token toMsg =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/bookshelves/" ++ shelfName ++ "/shelves"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg shelfDecoder
        , timeout = Nothing
        , tracker = Nothing
        }


moveBook :
    String
    -> String
    -> String
    -> (Result Http.Error () -> msg)
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
        , expect = Http.expectWhatever toMsg
        , timeout = Nothing
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
        , timeout = Nothing
        , tracker = Nothing
        }


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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
        , tracker = Nothing
        }


{-| PUT /api/settings/age\_verification — save the user's age verification status.
-}
updateAgeVerification :
    Bool
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
updateAgeVerification verified token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/settings/age_verification"
        , body = Http.jsonBody (Requests.encodeAgeVerificationRequest { ageVerified = verified })
        , expect = Http.expectWhatever toMsg
        , timeout = Nothing
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
        , timeout = Nothing
        , tracker = Nothing
        }


{-| POST /api/bookshelves/:name/placements — place a book on a bookshelf.
-}
placeBook :
    String
    -> String
    -> String
    -> (Result Http.Error Placement -> msg)
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
        , expect = Http.expectJson toMsg (Decode.field "placement" placementDecoder)
        , timeout = Nothing
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
        , expect =
            Http.expectJson toMsg
                (Decode.map .placements ProtoBookshelfResp.decodePlacementsMineResponse
                    |> Decode.map (List.map fromProtoPlacementSummary)
                )
        , timeout = Nothing
        , tracker = Nothing
        }


{-| GET /api/books/isbn/:isbn — look up a book by ISBN.
-}
lookupByIsbn :
    String
    -> String
    -> (Result Http.Error BookDetailResponse -> msg)
    -> Cmd msg
lookupByIsbn isbn token toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/books/isbn/" ++ isbn
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg bookDetailResponseDecoder
        , timeout = Nothing
        , tracker = Nothing
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
        , timeout = Nothing
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
-}
updateProfile :
    { displayName : String, email : String, websiteUrl : String, handle : String }
    -> String
    -> (Result ProfileError String -> msg)
    -> Cmd msg
updateProfile body token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/settings/profile"
        , body =
            Http.jsonBody
                (Requests.encodeUpdateProfileRequest
                    { displayName = body.displayName
                    , email = body.email
                    , websiteUrl = body.websiteUrl
                    , currentPassword = ""
                    , handle = body.handle
                    }
                )
        , expect = expectProfile toMsg
        , timeout = Nothing
        , tracker = Nothing
        }


{-| Keep the structured `{"errors": ...}` payload a 422 carries so the caller
can surface the real reason a profile save was rejected (mirrors
`expectRegister`). On success it hands back the server-normalised handle (the
200 body echoes the lowercased value) so the settings page can reflect it.
-}
expectProfile : (Result ProfileError String -> msg) -> Http.Expect msg
expectProfile toMsg =
    Http.expectStringResponse toMsg <|
        \response ->
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
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
updateLocation body token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = "/api/settings/location"
        , body =
            Http.jsonBody
                (Requests.encodeUpdateLocationRequest
                    { countryCode = body.countryCode
                    , city = body.city
                    }
                )
        , expect = Http.expectWhatever toMsg
        , timeout = Nothing
        , tracker = Nothing
        }


{-| PUT /api/settings/password — change the user's password.
-}
updatePassword :
    { currentPassword : String, newPassword : String }
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
updatePassword body token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/settings/password"
        , body =
            Http.jsonBody
                (Requests.encodeUpdatePasswordRequest
                    { currentPassword = body.currentPassword
                    , newPassword = body.newPassword
                    }
                )
        , expect = Http.expectWhatever toMsg
        , timeout = Nothing
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


{-| PUT /api/settings/notifications — update notification preferences.
-}
updateNotifications :
    NotificationPreferences
    -> String
    -> (Result Http.Error () -> msg)
    -> Cmd msg
updateNotifications prefs token toMsg =
    Http.request
        { method = "PUT"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
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
        , expect = Http.expectWhatever toMsg
        , timeout = Nothing
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
    Http.request
        { method = "POST"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/books/" ++ bookId ++ "/merge-format"
        , body =
            Http.jsonBody
                (Requests.encodeMergeFormatRequest
                    { isbn = body.isbn
                    , formatLabel = body.formatLabel
                    }
                )
        , expect = Http.expectJson toMsg mergeFormatResponseDecoder
        , timeout = Nothing
        , tracker = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
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
    }


shelfVisibilitySettingDecoder : Decoder ShelfVisibilitySetting
shelfVisibilitySettingDecoder =
    Decode.map2 ShelfVisibilitySetting
        (Decode.field "name" Decode.string)
        (Decode.field "visibility" Decode.string)


privacySettingsDecoder : Decoder PrivacySettings
privacySettingsDecoder =
    Decode.map2 PrivacySettings
        (Decode.field "profile_visibility" Decode.string)
        (Decode.field "shelves" (Decode.list shelfVisibilitySettingDecoder))


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
        , timeout = Nothing
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
    { name : String }


publicProfileDecoder : Decoder PublicProfile
publicProfileDecoder =
    Decode.map6 PublicProfile
        (Decode.field "handle" Decode.string)
        (Decode.field "display_name" Decode.string)
        (optionalString "website_url")
        (optionalString "city")
        (optionalString "country_code")
        (Decode.field "bookshelves" (Decode.list profileShelfSummaryDecoder))


profileShelfSummaryDecoder : Decoder ProfileShelfSummary
profileShelfSummaryDecoder =
    Decode.map ProfileShelfSummary (Decode.field "name" Decode.string)


{-| Decodes a string field that may be absent or JSON null, defaulting to "".
-}
optionalString : String -> Decoder String
optionalString field =
    Decode.oneOf
        [ Decode.field field Decode.string
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
        , tracker = Nothing
        }



-- ADMIN: METRICS


{-| Source health record from GET /api/metrics/source-health.
-}
type alias SourceHealth =
    { name : String
    , sourceType : String
    , status : String
    , consecutiveFailures : Int
    , lastSuccess : Maybe String
    , lastFailure : Maybe String
    }


{-| Adapter: proto SourceHealthCheck -> app SourceHealth.
Proto uses typed enums for status/sourceType; API sends string values.
-}
fromProtoSourceHealthCheck : ProtoHealth.SourceHealthCheck -> SourceHealth
fromProtoSourceHealthCheck proto =
    { name = proto.sourceName
    , sourceType = sourceTypeToString proto.sourceType
    , status = healthStatusToString proto.status
    , consecutiveFailures = proto.consecutiveFailures
    , lastSuccess = proto.lastSuccessAt
    , lastFailure = proto.lastFailureAt
    }


sourceTypeToString : ProtoHealth.SourceType -> String
sourceTypeToString st =
    case st of
        ProtoHealth.SourceTypeScraperConfig ->
            "scraper_config"

        ProtoHealth.SourceTypeReviewSource ->
            "review_source"

        ProtoHealth.SourceTypeRssFeed ->
            "rss_feed"

        ProtoHealth.SourceTypeEventSource ->
            "event_source"

        ProtoHealth.SourceTypeLlmOutput ->
            "llm_output"

        ProtoHealth.SourceTypeUnspecified ->
            "unspecified"


healthStatusToString : ProtoHealth.HealthStatus -> String
healthStatusToString hs =
    case hs of
        ProtoHealth.HealthStatusHealthy ->
            "healthy"

        ProtoHealth.HealthStatusDegraded ->
            "degraded"

        ProtoHealth.HealthStatusBroken ->
            "broken"

        ProtoHealth.HealthStatusUnspecified ->
            "unspecified"


sourceHealthDecoder : Decoder SourceHealth
sourceHealthDecoder =
    Decode.map fromProtoSourceHealthCheck ProtoHealth.decodeSourceHealthCheck


{-| GET /api/metrics/source-health — fetch per-source health status.
-}
getSourceHealth :
    String
    -> (Result Http.Error (List SourceHealth) -> msg)
    -> Cmd msg
getSourceHealth token toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/metrics/source-health"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg (Decode.field "sources" (Decode.list sourceHealthDecoder))
        , timeout = Nothing
        , tracker = Nothing
        }


{-| Main metrics dashboard data from GET /api/metrics.
-}
type alias MetricsDashboard =
    { totalBooks : Int
    , coverPercentage : Float
    , pricePercentage : Float
    , reviewPercentage : Float
    , gdprImagesPending : Int
    , costs : List CostItem
    }


type alias CostItem =
    { name : String
    , category : String
    , amountZar : Int
    }


{-| Adapter: proto MetricsDashboard -> app MetricsDashboard.

Maps the proto's nested structure to the app's flat shape. Quality percentages
come from the first quality trend row (if present). Costs are flattened from
CostBreakdown.categories, attaching each category name to its items.

-}
fromProtoMetricsDashboard : ProtoAdmin.MetricsDashboard -> MetricsDashboard
fromProtoMetricsDashboard proto =
    let
        firstTrend =
            List.head proto.qualityTrends

        coverPct =
            firstTrend |> Maybe.map .coverPct |> Maybe.withDefault 0.0

        pricePct =
            firstTrend |> Maybe.map .pricePct |> Maybe.withDefault 0.0

        reviewPct =
            firstTrend |> Maybe.map .reviewPct |> Maybe.withDefault 0.0

        flattenCategory cat =
            List.map (fromProtoCostItem cat.category) cat.items
    in
    { totalBooks = proto.systemHealth.totalBooks
    , coverPercentage = coverPct
    , pricePercentage = pricePct
    , reviewPercentage = reviewPct
    , gdprImagesPending = proto.gdpr.imagesPendingDeletion
    , costs = List.concatMap flattenCategory proto.costs.categories
    }


{-| Adapter: proto CostItem -> app CostItem, attaching the parent category name.
-}
fromProtoCostItem : String -> ProtoAdmin.CostItem -> CostItem
fromProtoCostItem categoryName proto =
    { name = proto.service
    , category = categoryName
    , amountZar = proto.amountCents
    }


metricsDashboardDecoder : Decoder MetricsDashboard
metricsDashboardDecoder =
    Decode.map fromProtoMetricsDashboard ProtoAdmin.decodeMetricsDashboard


{-| GET /api/metrics — fetch main dashboard data.
-}
getMetrics :
    String
    -> (Result Http.Error MetricsDashboard -> msg)
    -> Cmd msg
getMetrics token toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/metrics"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg metricsDashboardDecoder
        , timeout = Nothing
        , tracker = Nothing
        }


{-| Quality trend data from GET /api/metrics/quality-trends.

The proto has QualityTrendRow with percentage floats. The API endpoint wraps these
in a list; we take the two most recent rows to compute trend direction (up/down/flat)
by comparing cover\_pct, price\_pct, and review\_pct.

-}
type alias QualityTrends =
    { coverTrend : String
    , priceTrend : String
    , reviewTrend : String
    }


{-| Adapter: list of proto QualityTrendRow -> app QualityTrends.

Compares the two most recent rows to derive trend direction. If fewer than two
rows are available, defaults to "flat".

-}
fromProtoQualityTrendRows : List ProtoAdmin.QualityTrendRow -> QualityTrends
fromProtoQualityTrendRows rows =
    let
        sorted =
            List.sortBy .snapshotDate rows |> List.reverse

        trendDir prev cur =
            if cur > prev then
                "up"

            else if cur < prev then
                "down"

            else
                "flat"
    in
    case sorted of
        current :: previous :: _ ->
            { coverTrend = trendDir previous.coverPct current.coverPct
            , priceTrend = trendDir previous.pricePct current.pricePct
            , reviewTrend = trendDir previous.reviewPct current.reviewPct
            }

        _ ->
            { coverTrend = "flat"
            , priceTrend = "flat"
            , reviewTrend = "flat"
            }


qualityTrendsDecoder : Decoder QualityTrends
qualityTrendsDecoder =
    Decode.map fromProtoQualityTrendRows
        (Decode.list ProtoAdmin.decodeQualityTrendRow)


{-| GET /api/metrics/quality-trends — fetch quality trend indicators.
-}
getQualityTrends :
    String
    -> (Result Http.Error QualityTrends -> msg)
    -> Cmd msg
getQualityTrends token toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/metrics/quality-trends"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg qualityTrendsDecoder
        , timeout = Nothing
        , tracker = Nothing
        }


{-| Enrichment gap counts from GET /api/metrics/enrichment-gaps.
-}
type alias EnrichmentGaps =
    { booksWithoutPrices : Int
    , booksWithoutCovers : Int
    , booksWithoutReviews : Int
    }


{-| Adapter: proto EnrichmentGaps -> app EnrichmentGaps.
Proto includes a status field which the app type does not need.
-}
fromProtoEnrichmentGaps : ProtoAdmin.EnrichmentGaps -> EnrichmentGaps
fromProtoEnrichmentGaps proto =
    { booksWithoutPrices = proto.booksWithoutPrices
    , booksWithoutCovers = proto.booksWithoutCovers
    , booksWithoutReviews = proto.booksWithoutReviews
    }


enrichmentGapsDecoder : Decoder EnrichmentGaps
enrichmentGapsDecoder =
    Decode.map fromProtoEnrichmentGaps ProtoAdmin.decodeEnrichmentGaps


{-| GET /api/metrics/enrichment-gaps — fetch enrichment gap counts.
-}
getEnrichmentGaps :
    String
    -> (Result Http.Error EnrichmentGaps -> msg)
    -> Cmd msg
getEnrichmentGaps token toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" ("Bearer " ++ token) ]
        , url = baseUrl ++ "/api/metrics/enrichment-gaps"
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg enrichmentGapsDecoder
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
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
        , timeout = Nothing
        , tracker = Nothing
        }
