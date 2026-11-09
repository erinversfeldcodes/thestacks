module Types.BlogPost exposing
    ( AssociationOutcome
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
    , visibilityToString
    )

import Json.Decode as Decode exposing (Decoder)
import Stacks.Api.V1.BlogResponses as Envelope
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


{-| How the book-association pass over a post ended.

⛔ THIS IS THE GENERATED PROTO ENUM, NOT A HAND-WRITTEN COPY. It was a bare
`string` on `BlogPost` with the vocabulary written down in five places, and on
the day it shipped three of them disagreed — the `.proto` comment omitted
`unexpected_shape`, a value the worker records and the database CHECK permits,
so this module's `case` had no branch for something the server genuinely sends.
Two consequences were user-visible and both were fixed by hand.

⚖️ Now a new outcome is a non-exhaustive-case compile error here rather than a
silent fall-through to a default. Proto3 enums are open, so `Unspecified` still
absorbs a value this build has not been taught — what changed is that adding one
to the contract breaks the build instead of changing nothing.

-}
type alias AssociationOutcome =
    Envelope.AssociationOutcome


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

    -- ⛔ ALWAYS EMPTY HERE, AND THE ENVELOPE FILLS IT. This read
    -- `List.map fromProtoAssociation pb.associations`, which was
    -- STRUCTURALLY DEAD: `pb.associations` comes from an "associations" key
    -- INSIDE the post object, and no serializer emits one — `blog_post`'s
    -- `Map.take` excludes it, and `grep associations proto_json.ex` finds
    -- nothing. The server sends them as a SIBLING key, which
    -- `blogPostShowDecoder` reads and which overwrites this field anyway.
    --
    -- ⚠️ Measured: replacing `pb.associations` with `[]` left 2303 tests
    -- passing. So `fromProtoAssociation` and `parseAssociationStatus` were
    -- unreachable on every live path, and the latter duplicated
    -- `statusFromString` verbatim two functions away — two spellings of one
    -- rule, one of them dead. Both are deleted.
    , associations = []
    , authorDisplayName = pb.authorDisplayName
    , authorHandle = pb.authorHandle
    , syndicated = pb.syndicated

    -- ⚖️ Unspecified here, and the envelope fills it — the same reason
    -- `associations` is empty above. The outcome is not an attribute of the
    -- post but the result of the most recent pass OVER it, so it rides
    -- `BlogPostShowResponse` beside the associations rather than on `BlogPost`.
    , associationOutcome = Envelope.AssociationOutcomeUnspecified
    }


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
    Decode.map3
        (\post associations outcome ->
            { post | associations = associations, associationOutcome = outcome }
        )
        (Decode.field "post" blogPostDecoder)
        -- ⛔ REQUIRED, NOT DEFAULTED, AND THAT IS THE WHOLE POINT OF THIS
        -- DECODER EXISTING.
        --
        -- It was `oneOf [ field, succeed [] ]`, which is the exact mechanism of
        -- the defect this decoder was written to fix: the generated proto
        -- decoder's `D.oneOf [ …, D.succeed [] ]` turned an absent key into an
        -- empty list, silently, and the component rendered nothing on every
        -- load. Reproducing that tolerance one level up meant a reviewer could
        -- DELETE the guard and the suite still passed 2298/0.
        --
        -- ⚖️ `GET /api/blog/posts/:id` always emits `associations` (possibly
        -- `[]`) — `blog_controller.ex` sends it unconditionally, and all three
        -- call sites of this decoder hit that one endpoint. So an absent key is
        -- not a shape the server can produce, and tolerating it only buys
        -- silence if a producer change ever does. Failing loudly is what makes
        -- such a change visible.
        (Decode.field "associations" (Decode.list associationDecoder))
        -- ⚖️ Read from the envelope with the GENERATED decoder, which accepts
        -- both the proto spelling and the lowercase wire spelling the
        -- controller actually sends.
        --
        -- ⛔ TWO ARMS, EACH WITH A JOB A READER CAN STATE WITHOUT THE OTHER:
        -- "the key is present, string or null" and "the key is absent". The key
        -- is ABSENT when there is nothing to say — a non-owner, or an owner
        -- whose post has no finished pass — which is the server's real shape,
        -- asserted on the controller side.
        --
        -- ⚖️ It was three arms, with an explicit `Decode.null` between them.
        -- That shape created its own hazard: the null arm is behaviourally
        -- redundant with the trailing fallback, so a reader could take it as
        -- load-bearing and the fallback as dead, then delete the wrong one. A
        -- comment saying "this arm is redundant" is an invitation to delete it,
        -- and the knowledge goes with it. `Decode.nullable` is the idiom that
        -- already means what the comment would have had to explain, and it puts
        -- the null-to-UNSPECIFIED mapping in code rather than prose.
        --
        -- ⚠️ The explicit `null` arm is defence, not the normal path, and it
        -- used to be the normal path: the controller sent
        -- `"association_outcome": null` unconditionally, which decoded only
        -- because `decodeAssociationOutcome` opens with `Decode.string`, which
        -- FAILS on `null`, and a bare `oneOf` fallback absorbed that failure.
        -- So every non-owner's view depended on a swallowed decode error. The
        -- server no longer sends it, and a proxy or a non-Elm producer still
        -- might, so it is handled on purpose rather than by accident.
        (Decode.oneOf
            [ Decode.field "association_outcome"
                (Decode.nullable Envelope.decodeAssociationOutcome)
                |> Decode.map (Maybe.withDefault Envelope.AssociationOutcomeUnspecified)
            , Decode.succeed Envelope.AssociationOutcomeUnspecified
            ]
        )


{-| An association as the envelope sends it.

⚠️ `reasoning` is absent for a non-owner — the controller deletes the key rather
than blanking it — so it decodes optionally. ⛔ `confidence` is NOT likewise, and
this clause used to say it was: it is `Decode.field "confidence" Decode.float`,
REQUIRED, six lines below. The server always sends it, and a decoder that
tolerated its absence would have absorbed a producer that stopped.

-}
associationDecoder : Decoder BookAssociation
associationDecoder =
    Decode.map6 BookAssociation
        (Decode.field "id" Decode.string)
        (Decode.field "book_id" Decode.string)
        -- ⚖️ `book_title`, `confidence` and `status` are REQUIRED, because the
        -- only producer always sends them: `proto_json.ex`'s
        -- `blog_association/2` merges `book_title` and `status`
        -- unconditionally, and `confidence` is `null: false` on the column and
        -- always serialized. A default for a key the server cannot omit buys
        -- nothing and costs silence — and each of these three had a specific
        -- lie waiting: `status` defaulting to `Pending` makes every
        -- association read as pending for the owner and **vanish** for anyone
        -- else, and `confidence` defaulting to `0.0` renders "0%" with a
        -- low-confidence badge.
        (Decode.field "book_title" Decode.string)
        (Decode.field "confidence" Decode.float)
        -- ⬛ `reasoning` IS the exception, and the only honest fallback here:
        -- the controller DELETES the key for a non-owner rather than blanking
        -- it, so its absence is a real server state and carries meaning.
        (Decode.oneOf [ Decode.field "reasoning" Decode.string, Decode.succeed "" ])
        (Decode.map statusFromString (Decode.field "status" Decode.string))


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
