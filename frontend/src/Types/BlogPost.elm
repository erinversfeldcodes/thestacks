module Types.BlogPost exposing
    ( AssociationOutcome(..)
    , AssociationStatus(..)
    , BlogPost
    , BlogPostSummary
    , BookAssociation
    , Comment(..)
    , Visibility(..)
    , blogPostDecoder
    , blogPostShowDecoder
    , blogPostSummaryDecoder
    , commentAuthorId
    , commentBody
    , commentCreatedAt
    , commentDecoder
    , commentId
    , commentReplies
    , fromProtoAssociationOutcome
    , visibilityToString
    )

import Json.Decode as Decode exposing (Decoder)
import Stacks.Common.V1.Blog as Proto
import Types.ProtoHelpers exposing (emptyToNothing)


type Visibility
    = Owner
    | Group
    | Platform
    | Public


type alias BlogPost =
    { id : String
    , userId : String
    , title : String
    , body : String
    , visibility : Visibility
    , published : Bool
    , insertedAt : String
    , associations : List BookAssociation
    , authorDisplayName : String
    , authorHandle : String
    , syndicated : Bool
    , associationOutcome : AssociationOutcome
    }


{-| How the book-association pass ended, for the author's eyes.

⛔ `NotRunYet` is a distinct case and not a synonym for `FoundNothing`. A draft
nobody has scanned and a completed scan that found no books are different facts,
and showing the author the second when the first is true tells them something
false about their own post.

⚖️ `Failed` carries no detail, deliberately. The author can act on "this did not
work, and your post is fine"; the difference between an unparseable response and
a provider error is ours to fix, not theirs to read.

-}
type AssociationOutcome
    = NotRunYet
    | Associated
    | FoundNothing
    | Failed


type alias BlogPostSummary =
    { id : String
    , title : String
    , body : String
    , visibility : Visibility
    , published : Bool
    , insertedAt : String
    , authorDisplayName : Maybe String
    , authorHandle : Maybe String
    }


type alias BookAssociation =
    { id : String
    , bookId : String
    , bookTitle : String
    , confidence : Float
    , reasoning : String
    , status : AssociationStatus
    }


type Comment
    = Comment
        { id : String
        , postId : String
        , authorId : String
        , parentId : Maybe String
        , body : String
        , createdAt : String
        , replies : List Comment
        }


commentId : Comment -> String
commentId (Comment c) =
    c.id


commentAuthorId : Comment -> String
commentAuthorId (Comment c) =
    c.authorId


commentBody : Comment -> String
commentBody (Comment c) =
    c.body


commentCreatedAt : Comment -> String
commentCreatedAt (Comment c) =
    c.createdAt


commentReplies : Comment -> List Comment
commentReplies (Comment c) =
    c.replies


type AssociationStatus
    = Pending
    | Confirmed
    | Dismissed


visibilityToString : Visibility -> String
visibilityToString v =
    case v of
        Owner ->
            "owner"

        Group ->
            "group"

        Platform ->
            "platform"

        Public ->
            "public"


fromProtoVisibility : Proto.BlogVisibility -> Visibility
fromProtoVisibility pv =
    case pv of
        Proto.BlogVisibilityOwner ->
            Owner

        Proto.BlogVisibilityGroup ->
            Group

        Proto.BlogVisibilityPlatform ->
            Platform

        Proto.BlogVisibilityPublic ->
            Public

        Proto.BlogVisibilityUnspecified ->
            Owner


parseAssociationStatus : String -> AssociationStatus
parseAssociationStatus s =
    case s of
        "confirmed" ->
            Confirmed

        "dismissed" ->
            Dismissed

        _ ->
            Pending


{-| Map a proto BookAssociation to the app-level BookAssociation.

The proto type now includes bookTitle and status fields, so no
additional JSON decoding is needed.

-}
fromProtoAssociation : Proto.BookAssociation -> BookAssociation
fromProtoAssociation pa =
    { id = pa.id
    , bookId = pa.bookId
    , bookTitle = pa.bookTitle
    , confidence = pa.confidence
    , reasoning = pa.reasoning
    , status = parseAssociationStatus pa.status
    }


fromProtoBlogPost : Proto.BlogPost -> BlogPost
fromProtoBlogPost pb =
    { id = pb.id
    , userId = pb.userId
    , title = pb.title
    , body = pb.body
    , visibility = fromProtoVisibility pb.visibility
    , published = pb.publishedAt /= ""
    , insertedAt =
        if pb.createdAt /= "" then
            pb.createdAt

        else
            ""
    , associations = List.map fromProtoAssociation pb.associations
    , authorDisplayName = pb.authorDisplayName
    , authorHandle = pb.authorHandle
    , syndicated = pb.syndicated
    , associationOutcome = fromProtoAssociationOutcome pb.associationOutcome
    }


{-| ⚠️ An unrecognised outcome reads as `NotRunYet`, not as `Failed`.

A string this client has never heard of means the server grew a case the SPA has
not been taught, and claiming a failure the author can do nothing about would be
worse than staying quiet about a pass whose result we cannot interpret.

-}
fromProtoAssociationOutcome : String -> AssociationOutcome
fromProtoAssociationOutcome raw =
    case raw of
        "associated" ->
            Associated

        "no_books_found" ->
            FoundNothing

        "unreadable_response" ->
            Failed

        "unexpected_shape" ->
            Failed

        "llm_error" ->
            Failed

        _ ->
            NotRunYet


fromProtoBlogPostSummary : Proto.BlogPostSummary -> BlogPostSummary
fromProtoBlogPostSummary ps =
    { id = ps.id
    , title = ps.title
    , body = ps.body
    , visibility = fromProtoVisibility ps.visibility
    , published = False
    , insertedAt = ps.createdAt
    , authorDisplayName = emptyToNothing ps.authorDisplayName
    , authorHandle = emptyToNothing ps.authorHandle
    }


{-| Decode a full BlogPost from JSON.

Delegates entirely to the proto decoder, then maps to the app type.

-}
blogPostDecoder : Decoder BlogPost
blogPostDecoder =
    Decode.map fromProtoBlogPost Proto.decodeBlogPost


{-| Decode a post's show response, associations included.

⛔ THE ASSOCIATIONS RIDE THE ENVELOPE, NOT THE POST, AND READING ONLY THE POST
MEANT THE COMPONENT NEVER RECEIVED ANY.

`GET /api/blog/posts/:id` answers `{post: …, associations: […]}`. The post
serializer's take-list does not include `associations` — deliberately, because
the envelope's copies carry `book_title` and an owner-gated `reasoning` that the
post serializer cannot know — but the SPA decoded `Decode.field "post"` alone and
then read `post.associations`, which the generated decoder fills from _inside_
the post object with `D.oneOf [ …, D.succeed [] ]`.

⚠️ So an absent key became an empty list, silently, and
`Components.BookAssociations.view` was called with `associations = []` on every
load. "Books from my shelves", the confidence badges and the Confirm/Dismiss
controls were unreachable in the running app, behind a green suite — every test
rendered the component with an empty list, which is the same shape the broken
payload produced, so nothing could tell the two apart.

⚖️ Decoding the sibling key is the fix rather than widening the post, because
the ownership filter and the `reasoning` redaction live in the controller where
the viewer is known.

-}
blogPostShowDecoder : Decoder BlogPost
blogPostShowDecoder =
    Decode.map2
        (\post associations -> { post | associations = associations })
        (Decode.field "post" blogPostDecoder)
        (Decode.oneOf
            [ Decode.field "associations" (Decode.list associationDecoder)
            , Decode.succeed []
            ]
        )


{-| An association as the envelope sends it.

⚠️ `reasoning` is absent for a non-owner — the controller deletes the key rather
than blanking it — so it decodes optionally. `confidence` likewise: the server
sends what the model said, and a null means the model did not answer that part.

-}
associationDecoder : Decoder BookAssociation
associationDecoder =
    Decode.map6 BookAssociation
        (Decode.field "id" Decode.string)
        (Decode.field "book_id" Decode.string)
        (Decode.oneOf [ Decode.field "book_title" Decode.string, Decode.succeed "" ])
        (Decode.oneOf [ Decode.field "confidence" Decode.float, Decode.succeed 0.0 ])
        (Decode.oneOf [ Decode.field "reasoning" Decode.string, Decode.succeed "" ])
        (Decode.map statusFromString
            (Decode.oneOf [ Decode.field "status" Decode.string, Decode.succeed "" ])
        )


statusFromString : String -> AssociationStatus
statusFromString raw =
    case raw of
        "confirmed" ->
            Confirmed

        "dismissed" ->
            Dismissed

        _ ->
            Pending


{-| Decode a Comment from JSON. Replies are recursive via Decode.lazy.
-}
commentDecoder : Decoder Comment
commentDecoder =
    Decode.map7
        (\id postId authorId parentId body createdAt replies ->
            Comment
                { id = id
                , postId = postId
                , authorId = authorId
                , parentId = parentId
                , body = body
                , createdAt = createdAt
                , replies = replies
                }
        )
        (Decode.field "id" Decode.string)
        (Decode.field "postId" Decode.string)
        (Decode.field "authorId" Decode.string)
        (Decode.field "parentId" (Decode.nullable Decode.string))
        (Decode.field "body" Decode.string)
        (Decode.field "createdAt" Decode.string)
        (Decode.oneOf
            [ Decode.field "replies" (Decode.list (Decode.lazy (\_ -> commentDecoder)))
            , Decode.succeed []
            ]
        )


{-| Decode a BlogPostSummary from JSON.

Delegates to the proto BlogPostSummary decoder, then derives the published
flag from the published\_at timestamp (non-empty means published).

`published` stays outside the proto message — it is a reserved field there and
the controller never sends it, so it is derived here rather than decoded. The
body and the author, by contrast, ARE on the message: a list that cannot show a
preview or say who wrote a post is not a summary of anything.

-}
blogPostSummaryDecoder : Decoder BlogPostSummary
blogPostSummaryDecoder =
    Proto.decodeBlogPostSummary
        |> Decode.andThen
            (\protoSummary ->
                Decode.map
                    (\published ->
                        let
                            base =
                                fromProtoBlogPostSummary protoSummary
                        in
                        { base | published = Maybe.withDefault False published }
                    )
                    (Decode.oneOf
                        [ Decode.map (\pa -> Just (pa /= "")) (Decode.field "published_at" Decode.string)
                        , Decode.succeed Nothing
                        ]
                    )
            )
