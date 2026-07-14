module Types.Placement exposing
    ( Format(..)
    , Placement
    , ReadingStatus(..)
    , placementDecoder
    , placementSummaryDecoder
    )

import Json.Decode as Decode exposing (Decoder)
import Stacks.Common.V1.Placement as Proto
import Types.Book exposing (Book, VisibilityTier(..), fromProtoBook)
import Types.ProtoHelpers exposing (emptyToNothing, zeroToNothing)


type Format
    = Physical
    | EBook
    | Audiobook


type ReadingStatus
    = ToRead
    | Reading
    | Completed
    | Abandoned


type alias Placement =
    { id : String
    , book : Maybe Book
    , position : Maybe Int
    , placedAt : Maybe String
    , formats : List Format
    , personalRating : Maybe Int
    , notes : Maybe String
    , bookshelfName : Maybe String
    , readingStatus : Maybe ReadingStatus
    , currentPage : Maybe Int
    , startedAt : Maybe String
    , finishedAt : Maybe String
    , visibility : Maybe String
    }



-- MAPPING


parseFormat : String -> Maybe Format
parseFormat s =
    case s of
        "physical" ->
            Just Physical

        "ebook" ->
            Just EBook

        "audiobook" ->
            Just Audiobook

        _ ->
            Nothing


parseReadingStatus : String -> Maybe ReadingStatus
parseReadingStatus s =
    case s of
        "to_read" ->
            Just ToRead

        "reading" ->
            Just Reading

        "completed" ->
            Just Completed

        "abandoned" ->
            Just Abandoned

        _ ->
            Nothing



-- DECODERS


{-| The placement decoder unifies the multiple proto placement shapes
(PlacementDetail with embedded book, BookPlacement with bookshelf\_name,
and PlacementRef) into the single app-level Placement type.

It tries decoding the full shape (with embedded book) first, then
falls back to the slim shape (with bookshelf\_name, no book).

-}
placementDecoder : Decoder Placement
placementDecoder =
    -- Capture a top-level `visibility` field regardless of which base placement
    -- shape matched — the proto base decoders drop unknown fields, so we layer
    -- the optional visibility read on top.
    Decode.map2 (\p vis -> { p | visibility = vis })
        placementBaseDecoder
        (Decode.maybe (Decode.field "visibility" Decode.string))


placementBaseDecoder : Decoder Placement
placementBaseDecoder =
    Decode.oneOf
        [ placementWithBookDecoder
        , placementWithoutBookDecoder
        ]


{-| Decode the slim placement summary returned by GET /api/placements/mine
(`{book_id, bookshelf_name, title}`). Unlike `placementDecoder`, this reads the
flat summary shape directly and builds a display-only Placement whose `book` is
a stub carrying just the book id and title — enough for the CreateListing
dropdown, which uses the book id as the option value and the title as the label.

The other consumer of GET /api/placements/mine (`Main.GotPlacementCheck`) only
inspects `List.isEmpty`, so the stub shape is safe for it too.

-}
placementSummaryDecoder : Decoder Placement
placementSummaryDecoder =
    Decode.map3
        (\bookId bsName title ->
            { id = bookId
            , book = Just (bookStub bookId title)
            , position = Nothing
            , placedAt = Nothing
            , formats = []
            , personalRating = Nothing
            , notes = Nothing
            , bookshelfName = emptyToNothing bsName
            , readingStatus = Nothing
            , currentPage = Nothing
            , startedAt = Nothing
            , finishedAt = Nothing
            , visibility = Nothing
            }
        )
        (Decode.oneOf [ Decode.field "book_id" Decode.string, Decode.succeed "" ])
        (Decode.oneOf [ Decode.field "bookshelf_name" Decode.string, Decode.succeed "" ])
        (Decode.oneOf [ Decode.field "title" Decode.string, Decode.succeed "" ])


{-| A display-only Book stub carrying just an id and title. All other fields are
defaulted — the CreateListing dropdown only needs the id (option value) and the
title (label).
-}
bookStub : String -> String -> Book
bookStub bookId title =
    { id = bookId
    , title = title
    , author = Nothing
    , description = Nothing
    , editions = []
    , primaryEdition = Nothing
    , editionCount = 0
    , subjects = []
    , visibilityTier = Public
    }


{-| Decode a placement that has an embedded book (PlacementDetail shape).

The proto PlacementDetail decoder already parses the embedded book field.
We map it through fromProtoBook to convert to the app-level Book type,
treating a default (empty-id) proto Book as absent.

The proto PlacementDetail type does not include bookshelf\_name, but the API
may send it alongside the embedded book (e.g. GET /api/bookshelves/:name
returns placements with both book and bookshelf\_name). We decode it
optionally so it is captured when present.

-}
placementWithBookDecoder : Decoder Placement
placementWithBookDecoder =
    Decode.map2
        (\detail bsName ->
            let
                maybeBook =
                    if detail.book.id == "" && detail.book.title == "" then
                        Nothing

                    else
                        Just (fromProtoBook detail.book)
            in
            { id = detail.id
            , book = maybeBook
            , position = zeroToNothing detail.position
            , placedAt = emptyToNothing detail.placedAt
            , formats = List.filterMap parseFormat detail.formats
            , personalRating = zeroToNothing detail.personalRating
            , notes = emptyToNothing detail.notes
            , bookshelfName = bsName
            , readingStatus = parseReadingStatus detail.readingStatus
            , currentPage = zeroToNothing detail.currentPage
            , startedAt = emptyToNothing detail.startedAt
            , finishedAt = emptyToNothing detail.finishedAt
            , visibility = Nothing
            }
        )
        Proto.decodePlacementDetail
        (Decode.maybe (Decode.field "bookshelf_name" Decode.string))


{-| Decode a placement without an embedded book.
Handles both BookPlacement (with bookshelf\_name) and minimal PlacementRef payloads.
Delegates to proto decoders and maps to the app-level Placement type.

BookPlacement is tried first, guarded by the presence of bookshelf\_name, because
both proto decoders use oneOf-with-succeed defaults and would otherwise always
match. PlacementRef is the fallback for payloads that carry position/placedAt
but no bookshelf\_name.

-}
placementWithoutBookDecoder : Decoder Placement
placementWithoutBookDecoder =
    Decode.oneOf
        [ Decode.field "bookshelf_name" Decode.string
            |> Decode.andThen (\_ -> Decode.map fromProtoBookPlacement Proto.decodeBookPlacement)
        , Decode.map fromProtoPlacementRef Proto.decodePlacementRef
        ]


{-| Map a proto BookPlacement (has bookshelf\_name, formats, notes) to app Placement.
-}
fromProtoBookPlacement : Proto.BookPlacement -> Placement
fromProtoBookPlacement bp =
    { id = bp.id
    , book = Nothing
    , position = Nothing
    , placedAt = Nothing
    , formats = List.filterMap parseFormat bp.formats
    , personalRating = zeroToNothing bp.personalRating
    , notes = emptyToNothing bp.notes
    , bookshelfName = emptyToNothing bp.bookshelfName
    , readingStatus = Nothing
    , currentPage = Nothing
    , startedAt = Nothing
    , finishedAt = Nothing
    , visibility = Nothing
    }


{-| Map a proto PlacementRef (minimal id + position + timestamps) to app Placement.
-}
fromProtoPlacementRef : Proto.PlacementRef -> Placement
fromProtoPlacementRef pr =
    { id = pr.id
    , book = Nothing
    , position = zeroToNothing pr.position
    , placedAt = emptyToNothing pr.placedAt
    , formats = []
    , personalRating = Nothing
    , notes = Nothing
    , bookshelfName = Nothing
    , readingStatus = Nothing
    , currentPage = Nothing
    , startedAt = Nothing
    , finishedAt = Nothing
    , visibility = Nothing
    }
