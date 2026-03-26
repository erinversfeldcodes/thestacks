module Types.BlogPost exposing
    ( AssociationStatus(..)
    , BlogPost
    , BlogPostSummary
    , BookAssociation
    , Visibility(..)
    , blogPostDecoder
    , blogPostSummaryDecoder
    , visibilityToString
    )

import Json.Decode as Decode exposing (Decoder)
import Stacks.Common.V1.Blog as Proto


type Visibility
    = Owner
    | Group
    | Platform


type alias BlogPost =
    { id : String
    , userId : String
    , title : String
    , body : String
    , visibility : Visibility
    , published : Bool
    , insertedAt : String
    , associations : List BookAssociation
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


{-| Decode a BlogPostSummary from JSON.

Delegates to the proto BlogPostSummary decoder, then derives the published
flag from the published\_at timestamp (non-empty means published).
The proto BlogPostSummary has no body or published fields — published is a
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
