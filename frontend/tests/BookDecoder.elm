module BookDecoder exposing (suite)

import Expect
import Json.Decode as Decode
import Test exposing (Test, describe, test)
import Types.Book exposing (VisibilityTier(..), bookDecoder)


minimalBookJson : String
minimalBookJson =
    """
    {
        "id": "book-001",
        "isbn": "9780306406157",
        "title": "The Great Book",
        "author": {
            "id": "author-001",
            "name": "Jane Doe"
        },
        "visibility_tier": "public"
    }
    """


fullBookJson : String
fullBookJson =
    """
    {
        "id": "book-002",
        "isbn": "0306406152",
        "title": "Another Fine Book",
        "author": {
            "id": "author-002",
            "name": "John Smith",
            "bio": "A prolific author of fine books."
        },
        "description": "A wonderful book about things.",
        "cover_image_url": "https://example.com/cover.jpg",
        "page_count": 350,
        "publisher": "Good Books Press",
        "publication_year": 2020,
        "subjects": ["fiction", "adventure"],
        "visibility_tier": "public"
    }
    """


invalidVisibilityJson : String
invalidVisibilityJson =
    """
    {
        "id": "book-003",
        "isbn": "9780306406157",
        "title": "Bad Book",
        "author": {
            "id": "author-003",
            "name": "Nobody"
        },
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
                            , \b -> Expect.equal "9780306406157" b.isbn
                            , \b -> Expect.equal "The Great Book" b.title
                            , \b -> Expect.equal "Jane Doe" b.author.name
                            , \b -> Expect.equal Nothing b.description
                            , \b -> Expect.equal Nothing b.coverImageUrl
                            , \b -> Expect.equal [] b.subjects
                            , \b -> Expect.equal Public b.visibilityTier
                            ]
                            book

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "decodes full book payload" <|
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
                            , \b -> Expect.equal (Just 350) b.pageCount
                            , \b -> Expect.equal (Just 2020) b.publicationYear
                            , \b -> Expect.equal [ "fiction", "adventure" ] b.subjects
                            , \b ->
                                Expect.equal
                                    (Just "A prolific author of fine books.")
                                    b.author.bio
                            ]
                            book

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "fails on invalid visibility tier" <|
            \_ ->
                let
                    result =
                        Decode.decodeString bookDecoder invalidVisibilityJson
                in
                case result of
                    Ok _ ->
                        Expect.fail "Expected decode failure for unknown visibility tier"

                    Err _ ->
                        Expect.pass
        , test "author name is decoded correctly" <|
            \_ ->
                let
                    result =
                        Decode.decodeString bookDecoder minimalBookJson
                in
                case result of
                    Ok book ->
                        Expect.equal "Jane Doe" book.author.name

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "fails when required field title is missing" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "id": "book-004",
                            "isbn": "9780306406157",
                            "author": {
                                "id": "author-004",
                                "name": "Test Author"
                            },
                            "visibility_tier": "public"
                        }
                        """

                    result =
                        Decode.decodeString bookDecoder json
                in
                case result of
                    Ok _ ->
                        Expect.fail "Expected decode failure when title is missing"

                    Err _ ->
                        Expect.pass
        , test "fails when page_count is wrong type (string instead of int)" <|
            \_ ->
                let
                    json =
                        """
                        {
                            "id": "book-005",
                            "isbn": "9780306406157",
                            "title": "Type Error Book",
                            "author": {
                                "id": "author-005",
                                "name": "Test Author"
                            },
                            "page_count": "not-a-number",
                            "visibility_tier": "public"
                        }
                        """

                    result =
                        Decode.decodeString bookDecoder json
                in
                case result of
                    Ok _ ->
                        Expect.fail "Expected decode failure when page_count is a string"

                    Err _ ->
                        Expect.pass
        ]
