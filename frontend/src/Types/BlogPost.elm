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


visibilityDecoder : Decoder Visibility
visibilityDecoder =
    Decode.string
        |> Decode.andThen
            (\s ->
                case s of
                    "owner" ->
                        Decode.succeed Owner

                    "group" ->
                        Decode.succeed Group

                    "platform" ->
                        Decode.succeed Platform

                    _ ->
                        Decode.fail ("Unknown visibility: " ++ s)
            )


visibilityToString : Visibility -> String
visibilityToString v =
    case v of
        Owner ->
            "owner"

        Group ->
            "group"

        Platform ->
            "platform"


associationStatusDecoder : Decoder AssociationStatus
associationStatusDecoder =
    Decode.string
        |> Decode.andThen
            (\s ->
                case s of
                    "pending" ->
                        Decode.succeed Pending

                    "confirmed" ->
                        Decode.succeed Confirmed

                    "dismissed" ->
                        Decode.succeed Dismissed

                    _ ->
                        Decode.fail ("Unknown association status: " ++ s)
            )


bookAssociationDecoder : Decoder BookAssociation
bookAssociationDecoder =
    Decode.map6 BookAssociation
        (Decode.field "id" Decode.string)
        (Decode.field "book_id" Decode.string)
        (Decode.field "book_title" Decode.string)
        (Decode.field "confidence" Decode.float)
        (Decode.oneOf
            [ Decode.field "reasoning" Decode.string
            , Decode.succeed ""
            ]
        )
        (Decode.field "status" associationStatusDecoder)


blogPostDecoder : Decoder BlogPost
blogPostDecoder =
    Decode.map8 BlogPost
        (Decode.field "id" Decode.string)
        (Decode.oneOf
            [ Decode.field "user_id" Decode.string
            , Decode.succeed ""
            ]
        )
        (Decode.field "title" Decode.string)
        (Decode.field "body" Decode.string)
        (Decode.field "visibility" visibilityDecoder)
        (Decode.oneOf
            [ Decode.field "published" Decode.bool
            , Decode.succeed False
            ]
        )
        (Decode.field "inserted_at" Decode.string)
        (Decode.oneOf
            [ Decode.field "associations" (Decode.list bookAssociationDecoder)
            , Decode.succeed []
            ]
        )


blogPostSummaryDecoder : Decoder BlogPostSummary
blogPostSummaryDecoder =
    Decode.map6 BlogPostSummary
        (Decode.field "id" Decode.string)
        (Decode.field "title" Decode.string)
        (Decode.field "body" Decode.string)
        (Decode.field "visibility" visibilityDecoder)
        (Decode.oneOf
            [ Decode.field "published" Decode.bool
            , Decode.succeed False
            ]
        )
        (Decode.field "inserted_at" Decode.string)
