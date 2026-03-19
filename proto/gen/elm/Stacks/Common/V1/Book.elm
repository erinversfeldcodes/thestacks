module Stacks.Common.V1.Book exposing
    ( Author
    , Book
    , Edition
    , EditionFormat(..)
    , ISBN
    , ISBNFormat(..)
    , VisibilityTier(..)
    , decodeAuthor
    , decodeBook
    , decodeEdition
    , decodeEditionFormat
    , decodeISBN
    , decodeISBNFormat
    , decodeVisibilityTier
    , encodeAuthor
    , encodeBook
    , encodeEdition
    , encodeEditionFormat
    , encodeISBN
    , encodeISBNFormat
    , encodeVisibilityTier
    )

{-| Generated Elm JSON decoders/encoders for stacks.common.v1 book.proto.

DO NOT EDIT MANUALLY. Regenerate via scripts/gen-elm-proto.sh after modifying book.proto.

JSON on the wire — these decoders consume the JSON representation of the Protobuf messages.
Field numbers are not present in JSON; json\_name attributes from the .proto file determine keys.

-}

import Json.Decode as D
import Json.Decode.Pipeline as P
import Json.Encode as E



-- Enums


type ISBNFormat
    = ISBNFormatUnspecified
    | ISBNFormatIsbn10
    | ISBNFormatIsbn13


decodeISBNFormat : D.Decoder ISBNFormat
decodeISBNFormat =
    D.string
        |> D.andThen
            (\s ->
                case s of
                    "ISBN_FORMAT_ISBN_10" ->
                        D.succeed ISBNFormatIsbn10

                    "ISBN_FORMAT_ISBN_13" ->
                        D.succeed ISBNFormatIsbn13

                    _ ->
                        D.succeed ISBNFormatUnspecified
            )


encodeISBNFormat : ISBNFormat -> E.Value
encodeISBNFormat f =
    case f of
        ISBNFormatUnspecified ->
            E.string "ISBN_FORMAT_UNSPECIFIED"

        ISBNFormatIsbn10 ->
            E.string "ISBN_FORMAT_ISBN_10"

        ISBNFormatIsbn13 ->
            E.string "ISBN_FORMAT_ISBN_13"


type EditionFormat
    = EditionFormatUnspecified
    | EditionFormatHardcover
    | EditionFormatPaperback
    | EditionFormatEbook
    | EditionFormatAudiobook
    | EditionFormatLargePrint


decodeEditionFormat : D.Decoder EditionFormat
decodeEditionFormat =
    D.string
        |> D.andThen
            (\s ->
                case s of
                    "EDITION_FORMAT_HARDCOVER" ->
                        D.succeed EditionFormatHardcover

                    "EDITION_FORMAT_PAPERBACK" ->
                        D.succeed EditionFormatPaperback

                    "EDITION_FORMAT_EBOOK" ->
                        D.succeed EditionFormatEbook

                    "EDITION_FORMAT_AUDIOBOOK" ->
                        D.succeed EditionFormatAudiobook

                    "EDITION_FORMAT_LARGE_PRINT" ->
                        D.succeed EditionFormatLargePrint

                    _ ->
                        D.succeed EditionFormatUnspecified
            )


encodeEditionFormat : EditionFormat -> E.Value
encodeEditionFormat f =
    case f of
        EditionFormatUnspecified ->
            E.string "EDITION_FORMAT_UNSPECIFIED"

        EditionFormatHardcover ->
            E.string "EDITION_FORMAT_HARDCOVER"

        EditionFormatPaperback ->
            E.string "EDITION_FORMAT_PAPERBACK"

        EditionFormatEbook ->
            E.string "EDITION_FORMAT_EBOOK"

        EditionFormatAudiobook ->
            E.string "EDITION_FORMAT_AUDIOBOOK"

        EditionFormatLargePrint ->
            E.string "EDITION_FORMAT_LARGE_PRINT"


type VisibilityTier
    = VisibilityTierUnspecified
    | VisibilityTierPublic
    | VisibilityTierUnlisted
    | VisibilityTierPrivate


decodeVisibilityTier : D.Decoder VisibilityTier
decodeVisibilityTier =
    D.string
        |> D.andThen
            (\s ->
                case s of
                    "VISIBILITY_TIER_PUBLIC" ->
                        D.succeed VisibilityTierPublic

                    "VISIBILITY_TIER_UNLISTED" ->
                        D.succeed VisibilityTierUnlisted

                    "VISIBILITY_TIER_PRIVATE" ->
                        D.succeed VisibilityTierPrivate

                    _ ->
                        D.succeed VisibilityTierUnspecified
            )


encodeVisibilityTier : VisibilityTier -> E.Value
encodeVisibilityTier t =
    case t of
        VisibilityTierUnspecified ->
            E.string "VISIBILITY_TIER_UNSPECIFIED"

        VisibilityTierPublic ->
            E.string "VISIBILITY_TIER_PUBLIC"

        VisibilityTierUnlisted ->
            E.string "VISIBILITY_TIER_UNLISTED"

        VisibilityTierPrivate ->
            E.string "VISIBILITY_TIER_PRIVATE"



-- Messages


type alias ISBN =
    { value : String
    , format : ISBNFormat
    }


decodeISBN : D.Decoder ISBN
decodeISBN =
    D.succeed ISBN
        |> P.required "value" D.string
        |> P.required "format" decodeISBNFormat


encodeISBN : ISBN -> E.Value
encodeISBN isbn =
    E.object
        [ ( "value", E.string isbn.value )
        , ( "format", encodeISBNFormat isbn.format )
        ]


type alias Author =
    { id : String
    , name : String
    , websiteUrl : String
    , rssFeedUrl : String
    }


decodeAuthor : D.Decoder Author
decodeAuthor =
    D.succeed Author
        |> P.required "id" D.string
        |> P.required "name" D.string
        |> P.optional "website_url" D.string ""
        |> P.optional "rss_feed_url" D.string ""


encodeAuthor : Author -> E.Value
encodeAuthor author =
    E.object
        [ ( "id", E.string author.id )
        , ( "name", E.string author.name )
        , ( "website_url", E.string author.websiteUrl )
        , ( "rss_feed_url", E.string author.rssFeedUrl )
        ]


type alias Book =
    { id : String
    , title : String
    , authorId : String
    , description : String
    , subjects : List String
    , visibilityTier : VisibilityTier
    }


decodeBook : D.Decoder Book
decodeBook =
    D.succeed Book
        |> P.required "id" D.string
        |> P.required "title" D.string
        |> P.required "author_id" D.string
        |> P.optional "description" D.string ""
        |> P.optional "subjects" (D.list D.string) []
        |> P.optional "visibility_tier" decodeVisibilityTier VisibilityTierUnspecified


encodeBook : Book -> E.Value
encodeBook book =
    E.object
        [ ( "id", E.string book.id )
        , ( "title", E.string book.title )
        , ( "author_id", E.string book.authorId )
        , ( "description", E.string book.description )
        , ( "subjects", E.list E.string book.subjects )
        , ( "visibility_tier", encodeVisibilityTier book.visibilityTier )
        ]


type alias Edition =
    { id : String
    , bookId : String
    , isbn : ISBN
    , format : EditionFormat
    , isPrimary : Bool
    , coverImageUrl : String
    , pageCount : Int
    , publisher : String
    , publicationYear : Int
    }


decodeEdition : D.Decoder Edition
decodeEdition =
    D.succeed Edition
        |> P.required "id" D.string
        |> P.required "book_id" D.string
        |> P.required "isbn" decodeISBN
        |> P.optional "format" decodeEditionFormat EditionFormatUnspecified
        |> P.optional "is_primary" D.bool False
        |> P.optional "cover_image_url" D.string ""
        |> P.optional "page_count" D.int 0
        |> P.optional "publisher" D.string ""
        |> P.optional "publication_year" D.int 0


encodeEdition : Edition -> E.Value
encodeEdition edition =
    E.object
        [ ( "id", E.string edition.id )
        , ( "book_id", E.string edition.bookId )
        , ( "isbn", encodeISBN edition.isbn )
        , ( "format", encodeEditionFormat edition.format )
        , ( "is_primary", E.bool edition.isPrimary )
        , ( "cover_image_url", E.string edition.coverImageUrl )
        , ( "page_count", E.int edition.pageCount )
        , ( "publisher", E.string edition.publisher )
        , ( "publication_year", E.int edition.publicationYear )
        ]
