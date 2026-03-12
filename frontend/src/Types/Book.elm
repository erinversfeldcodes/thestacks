module Types.Book exposing
    ( Author
    , Book
    , VisibilityTier(..)
    , bookDecoder
    )

import Json.Decode as Decode exposing (Decoder)


type alias Author =
    { id : String
    , name : String
    , bio : Maybe String
    }


type VisibilityTier
    = Public
    | Unlisted
    | Private


type alias Book =
    { id : String
    , isbn : String
    , title : String
    , author : Author
    , description : Maybe String
    , coverImageUrl : Maybe String
    , pageCount : Maybe Int
    , publisher : Maybe String
    , publicationYear : Maybe Int
    , subjects : List String
    , visibilityTier : VisibilityTier
    }


authorDecoder : Decoder Author
authorDecoder =
    Decode.map3 Author
        (Decode.field "id" Decode.string)
        (Decode.field "name" Decode.string)
        (Decode.maybe (Decode.field "bio" Decode.string))


visibilityTierDecoder : Decoder VisibilityTier
visibilityTierDecoder =
    Decode.string
        |> Decode.andThen
            (\s ->
                case s of
                    "public" ->
                        Decode.succeed Public

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


bookDecoder : Decoder Book
bookDecoder =
    Decode.map8
        (\id isbn title author description coverImageUrl pageCount publisher ->
            { id = id
            , isbn = isbn
            , title = title
            , author = author
            , description = description
            , coverImageUrl = coverImageUrl
            , pageCount = pageCount
            , publisher = publisher
            , publicationYear = Nothing
            , subjects = []
            , visibilityTier = Public
            }
        )
        (Decode.field "id" Decode.string)
        (Decode.field "isbn" Decode.string)
        (Decode.field "title" Decode.string)
        (Decode.field "author" authorDecoder)
        (Decode.maybe (Decode.field "description" Decode.string))
        (Decode.maybe (Decode.field "cover_image_url" Decode.string))
        (optionalInt "page_count")
        (Decode.maybe (Decode.field "publisher" Decode.string))
        |> Decode.andThen
            (\partial ->
                Decode.map3
                    (\publicationYear subjects visibilityTier ->
                        { partial
                            | publicationYear = publicationYear
                            , subjects = subjects
                            , visibilityTier = visibilityTier
                        }
                    )
                    (optionalInt "publication_year")
                    (Decode.oneOf
                        [ Decode.field "subjects" (Decode.list Decode.string)
                        , Decode.succeed []
                        ]
                    )
                    (Decode.field "visibility_tier" visibilityTierDecoder)
            )
