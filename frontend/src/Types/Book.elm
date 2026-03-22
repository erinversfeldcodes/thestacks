module Types.Book exposing
    ( Author
    , Book
    , Edition
    , VisibilityTier(..)
    , authorName
    , bookCoverImageUrl
    , bookDecoder
    , bookIsbn
    , bookPageCount
    , bookPublicationYear
    , editionDecoder
    )

import Json.Decode as Decode exposing (Decoder)


type alias Author =
    { id : String
    , name : String
    , bio : Maybe String
    , website : Maybe String
    }


type VisibilityTier
    = Public
    | AgeGated
    | Unlisted
    | Private


type alias Edition =
    { id : String
    , isbn : String
    , formatLabel : Maybe String
    , coverImageUrl : Maybe String
    , pageCount : Maybe Int
    , publisher : Maybe String
    , publicationYear : Maybe Int
    , isPrimary : Bool
    }


type alias Book =
    { id : String
    , title : String
    , author : Maybe Author
    , description : Maybe String
    , editions : List Edition
    , primaryEdition : Maybe Edition
    , editionCount : Int
    , subjects : List String
    , visibilityTier : VisibilityTier
    }



-- HELPERS


{-| Returns the author's name, or "Unknown Author" when author is nil.
-}
authorName : Book -> String
authorName book =
    case book.author of
        Just a ->
            a.name

        Nothing ->
            "Unknown Author"


{-| ISBN from the primary edition, or empty string.
-}
bookIsbn : Book -> String
bookIsbn book =
    case book.primaryEdition of
        Just ed ->
            ed.isbn

        Nothing ->
            ""


{-| Cover image URL from the primary edition.
-}
bookCoverImageUrl : Book -> Maybe String
bookCoverImageUrl book =
    book.primaryEdition |> Maybe.andThen .coverImageUrl


{-| Page count from the primary edition.
-}
bookPageCount : Book -> Maybe Int
bookPageCount book =
    book.primaryEdition |> Maybe.andThen .pageCount


{-| Publication year from the primary edition.
-}
bookPublicationYear : Book -> Maybe Int
bookPublicationYear book =
    book.primaryEdition |> Maybe.andThen .publicationYear



-- DECODERS


authorDecoder : Decoder Author
authorDecoder =
    Decode.map4 Author
        (Decode.field "id" Decode.string)
        (Decode.field "name" Decode.string)
        (Decode.maybe (Decode.field "bio" Decode.string))
        (Decode.maybe (Decode.field "website" Decode.string))


visibilityTierDecoder : Decoder VisibilityTier
visibilityTierDecoder =
    Decode.string
        |> Decode.andThen
            (\s ->
                case s of
                    "public" ->
                        Decode.succeed Public

                    "age_gated" ->
                        Decode.succeed AgeGated

                    "unlisted" ->
                        Decode.succeed Unlisted

                    "private" ->
                        Decode.succeed Private

                    _ ->
                        Decode.fail ("Unknown visibility tier: " ++ s)
            )


{-| Decodes an optional integer field. Returns Nothing when the field is absent
or null, Just n when present with an integer value, and fails if the field is
present with the wrong type.
-}
optionalInt : String -> Decoder (Maybe Int)
optionalInt fieldName =
    Decode.value
        |> Decode.andThen
            (\json ->
                case Decode.decodeValue (Decode.field fieldName Decode.value) json of
                    Err _ ->
                        Decode.succeed Nothing

                    Ok _ ->
                        Decode.field fieldName (Decode.nullable Decode.int)
            )


editionDecoder : Decoder Edition
editionDecoder =
    Decode.map8 Edition
        (Decode.field "id" Decode.string)
        (Decode.field "isbn" Decode.string)
        (Decode.maybe (Decode.field "format_label" Decode.string))
        (Decode.maybe (Decode.field "cover_image_url" Decode.string))
        (optionalInt "page_count")
        (Decode.maybe (Decode.field "publisher" Decode.string))
        (optionalInt "publication_year")
        (Decode.oneOf
            [ Decode.field "is_primary" Decode.bool
            , Decode.succeed False
            ]
        )


bookDecoder : Decoder Book
bookDecoder =
    Decode.map8
        (\id title author description editions primaryEdition editionCount subjects ->
            { id = id
            , title = title
            , author = author
            , description = description
            , editions = editions
            , primaryEdition = primaryEdition
            , editionCount = editionCount
            , subjects = subjects
            , visibilityTier = Public
            }
        )
        (Decode.field "id" Decode.string)
        (Decode.field "title" Decode.string)
        (Decode.field "author" (Decode.nullable authorDecoder))
        (Decode.maybe (Decode.field "description" Decode.string))
        (Decode.oneOf
            [ Decode.field "editions" (Decode.list editionDecoder)
            , Decode.succeed []
            ]
        )
        (Decode.maybe (Decode.field "primary_edition" editionDecoder))
        (Decode.oneOf
            [ Decode.field "edition_count" Decode.int
            , Decode.succeed 0
            ]
        )
        (Decode.oneOf
            [ Decode.field "subjects" (Decode.list Decode.string)
            , Decode.succeed []
            ]
        )
        |> Decode.andThen
            (\partial ->
                Decode.map (\vt -> { partial | visibilityTier = vt })
                    (Decode.field "visibility_tier" visibilityTierDecoder)
            )
