module BookDecoder exposing (suite)

import Expect
import Json.Decode as Decode
import Test exposing (Test, describe, test)
import Types.Book exposing (VisibilityTier(..), authorName, bookCoverImageUrl, bookDecoder, bookIsbn, bookPageCount, bookPublicationYear)


minimalBookJson : String
minimalBookJson =
    """
    {
        "id": "book-001",
        "title": "The Great Book",
        "author": {
            "id": "author-001",
            "name": "Jane Doe"
        },
        "editions": [],
        "edition_count": 0,
        "visibility_tier": "public"
    }
    """


fullBookJson : String
fullBookJson =
    """
    {
        "id": "book-002",
        "title": "Another Fine Book",
        "author": {
            "id": "author-002",
            "name": "John Smith",
            "bio": "A prolific author of fine books."
        },
        "description": "A wonderful book about things.",
        "editions": [
            {
                "id": "ed-001",
                "isbn": "0306406152",
                "cover_image_url": "https://example.com/cover.jpg",
                "page_count": 350,
                "publisher": "Good Books Press",
                "publication_year": 2020,
                "is_primary": true
            }
        ],
        "primary_edition": {
            "id": "ed-001",
            "isbn": "0306406152",
            "cover_image_url": "https://example.com/cover.jpg",
            "page_count": 350,
            "publisher": "Good Books Press",
            "publication_year": 2020,
            "is_primary": true
        },
        "edition_count": 1,
        "subjects": ["fiction", "adventure"],
        "visibility_tier": "public"
    }
    """


invalidVisibilityJson : String
invalidVisibilityJson =
    """
    {
        "id": "book-003",
        "title": "Bad Book",
        "author": {
            "id": "author-003",
            "name": "Nobody"
        },
        "editions": [],
        "edition_count": 0,
        "visibility_tier": "unknown_tier"
    }
    """


suite : Test
suite =
    describe "Book JSON decoder"
        [ test "decodes minimal book payload" <|
            \_ ->
                let
                    result =
                        Decode.decodeString bookDecoder minimalBookJson
                in
                case result of
                    Ok book ->
                        Expect.all
                            [ \b -> Expect.equal "book-001" b.id
                            , \b -> Expect.equal "The Great Book" b.title
                            , \b -> Expect.equal "Jane Doe" (authorName b)
                            , \b -> Expect.equal Nothing b.description
                            , \b -> Expect.equal Nothing (bookCoverImageUrl b)
                            , \b -> Expect.equal [] b.subjects
                            , \b -> Expect.equal Public b.visibilityTier
                            , \b -> Expect.equal "" (bookIsbn b)
                            , \b -> Expect.equal 0 b.editionCount
                            ]
                            book

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "decodes full book payload with editions" <|
            \_ ->
                let
                    result =
                        Decode.decodeString bookDecoder fullBookJson
                in
                case result of
                    Ok book ->
                        Expect.all
                            [ \b -> Expect.equal "book-002" b.id
                            , \b -> Expect.equal "Another Fine Book" b.title
                            , \b -> Expect.equal (Just "A wonderful book about things.") b.description
                            , \b -> Expect.equal (Just 350) (bookPageCount b)
                            , \b -> Expect.equal (Just 2020) (bookPublicationYear b)
                            , \b -> Expect.equal [ "fiction", "adventure" ] b.subjects
                            , \b -> Expect.equal "0306406152" (bookIsbn b)
                            , \b -> Expect.equal 1 b.editionCount
                            , \b -> Expect.equal 1 (List.length b.editions)
                            , \b ->
                                Expect.equal
                                    (Just "A prolific author of fine books.")
                                    (Maybe.andThen .bio b.author)
                            ]
                            book

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "unknown visibility tier defaults to Public (proto3 resilience)" <|
            \_ ->
                let
                    result =
                        Decode.decodeString bookDecoder invalidVisibilityJson
                in
                case result of
                    Ok book ->
                        Expect.equal Public book.visibilityTier

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "author name is decoded correctly" <|
            \_ ->
                let
                    result =
                        Decode.decodeString bookDecoder minimalBookJson
                in
                case result of
                    Ok book ->
                        Expect.equal "Jane Doe" (authorName book)

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "missing title defaults to empty string (proto3 resilience)" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "id": "book-004",
                            "author": {
                                "id": "author-004",
                                "name": "Test Author"
                            },
                            "editions": [],
                            "edition_count": 0,
                            "visibility_tier": "public"
                        }
                        """

                    result =
                        Decode.decodeString bookDecoder json
                in
                case result of
                    Ok book ->
                        Expect.equal "" book.title

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "decodes age_gated visibility tier" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "id": "book-ag",
                            "title": "Age Gated Book",
                            "author": {
                                "id": "author-ag",
                                "name": "Mature Author"
                            },
                            "editions": [],
                            "edition_count": 0,
                            "visibility_tier": "age_gated"
                        }
                        """

                    result =
                        Decode.decodeString bookDecoder json
                in
                case result of
                    Ok book ->
                        Expect.equal AgeGated book.visibilityTier

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "decodes book with null author" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "id": "book-na",
                            "title": "Authorless Book",
                            "author": null,
                            "editions": [],
                            "edition_count": 0,
                            "visibility_tier": "public"
                        }
                        """

                    result =
                        Decode.decodeString bookDecoder json
                in
                case result of
                    Ok book ->
                        Expect.equal Nothing book.author

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "primary edition fields are accessible via helpers" <|
            \_ ->
                let
                    result =
                        Decode.decodeString bookDecoder fullBookJson
                in
                case result of
                    Ok book ->
                        Expect.all
                            [ \b -> Expect.equal (Just "https://example.com/cover.jpg") (bookCoverImageUrl b)
                            , \b -> Expect.equal (Just 350) (bookPageCount b)
                            , \b -> Expect.equal (Just 2020) (bookPublicationYear b)
                            ]
                            book

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "bookPageCount is Nothing when the book has no primary edition" <|
            \_ ->
                let
                    result =
                        Decode.decodeString bookDecoder minimalBookJson
                in
                case result of
                    Ok book ->
                        Expect.equal Nothing (bookPageCount book)

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "bookPageCount is Nothing when the primary edition omits page_count" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "id": "book-no-pages",
                            "title": "Pageless Edition",
                            "author": {
                                "id": "author-np",
                                "name": "Anon"
                            },
                            "editions": [
                                {
                                    "id": "ed-np",
                                    "isbn": "0306406152",
                                    "is_primary": true
                                }
                            ],
                            "primary_edition": {
                                "id": "ed-np",
                                "isbn": "0306406152",
                                "is_primary": true
                            },
                            "edition_count": 1,
                            "visibility_tier": "public"
                        }
                        """

                    result =
                        Decode.decodeString bookDecoder json
                in
                case result of
                    Ok book ->
                        Expect.equal Nothing (bookPageCount book)

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        ]
