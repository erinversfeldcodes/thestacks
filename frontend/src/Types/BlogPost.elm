module Types.BlogPost exposing
    ( AssociationStatus(..)
    , BlogPost
    , BlogPostSummary
    , BookAssociation
    , Comment(..)
    , Visibility(..)
    , blogPostDecoder
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
import Stacks.Common.V1.Blog as Proto


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
    }


type alias BlogPostSummary =
    { id : String
    , title : String
    , body : String
    , visibility : Visibility
    , published : Bool
    , insertedAt : String
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



-- HELPERS


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



-- MAPPING FROM PROTO


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
    }


fromProtoBlogPostSummary : Proto.BlogPostSummary -> BlogPostSummary
fromProtoBlogPostSummary ps =
    { id = ps.id
    , title = ps.title
    , body = ""
    , visibility = fromProtoVisibility ps.visibility
    , published = False
    , insertedAt = ps.createdAt
    }



-- DECODERS


{-| Decode a full BlogPost from JSON.

Delegates entirely to the proto decoder, then maps to the app type.

-}
blogPostDecoder : Decoder BlogPost
blogPostDecoder =
    Decode.map fromProtoBlogPost Proto.decodeBlogPost


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
The proto BlogPostSummary has no body or published fields -- published is a
reserved field in the proto and is never sent by the controller.

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
