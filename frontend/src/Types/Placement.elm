module Types.Placement exposing
    ( Format(..)
    , Placement
    , ReadingStatus(..)
    , bookPlacementDecoder
    , formatToString
    , isHidden
    , parseFormat
    , parseReadingStatus
    , placementDetailDecoder
    , placementRefDecoder
    , placementSummaryDecoder
    , readingStatusToString
    )

import Json.Decode as Decode exposing (Decoder)
import Stacks.Common.V1.Placement as Proto
import Types.Book exposing (Book, VisibilityTier(..), fromProtoBook)
import Types.ProtoHelpers exposing (emptyToNothing, zeroToNothing)
import Types.Visibility as Visibility exposing (Visibility)


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
    , visibility : Maybe Visibility
    , hasUserWriting : Bool
    }


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


{-| The wire spelling of a format — the inverse of `parseFormat`, and the only
thing `op.bookshelf_placements.formats` stores. The column is a free
`{:array, :string}`, so a spelling these two disagree on round-trips as silence:
the server stores it and `parseFormat` drops it on the way back.
-}
formatToString : Format -> String
formatToString format =
    case format of
        Physical ->
            "physical"

        EBook ->
            "ebook"

        Audiobook ->
            "audiobook"


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


{-| Whether this placement is hidden from everyone but its owner.

⛔ The ONE reader of `placement.visibility` for this question. It was written out
three times — twice in `Page.Bookshelf.Helpers`, once in
`Page.Bookshelf.ReadingPile` — each as `placement.visibility == Just "owner"`,
and each feeding the same `hidden` field of `Components.Spine.book`. Three copies
of one sentence ("an owner-only placement is a hidden one"), none of which the
compiler could check against the enum.

Note what this is NOT: it is not "the shelf is private". A placement on a public
shelf can be owner-only, which is exactly the case the spine's hidden treatment
exists to show.

-}
isHidden : Placement -> Bool
isHidden placement =
    placement.visibility == Just Visibility.Owner


{-| The wire value for a reading status — the inverse of `parseReadingStatus`.
Used when building the `PUT /api/placements/:id/progress` request body.
-}
readingStatusToString : ReadingStatus -> String
readingStatusToString status =
    case status of
        ToRead ->
            "to_read"

        Reading ->
            "reading"

        Completed ->
            "completed"

        Abandoned ->
            "abandoned"


{-| ONE DECODER PER WIRE SHAPE, and the caller picks — because the contract
already says which one it is sending.

There used to be a single `placementDecoder` here, a `Decode.oneOf` over all
three proto placement shapes, with a hand-written guard on the presence of
`bookshelf_name` to separate the two that have no embedded book. That guard was
the only thing standing between a `BookPlacement` and being decoded as a
`PlacementRef`, and it was unsound: `proto_json.ex` emits
`bookshelf_name: bookshelf && bookshelf.name`, so the field arrives as JSON
`null` whenever the bookshelf is absent, `Decode.field "bookshelf_name"
Decode.string` fails on null, and the decoder fell through to the wrong branch.

⚠️ **The ambiguity was self-inflicted.** The contract never had it. Each
response message declares exactly one placement type:

    BookshelfResponse.placements    -> PlacementDetail  (embedded book)
    BookDetailResponse.placement    -> BookPlacement    (bookshelf_name)
    BookConfirmResponse.placement   -> BookPlacement
    PlacementRefResponse.placement  -> PlacementRef     (slim)

So every caller has always known which shape it was getting. Collapsing four
distinctly-typed responses into one decoder threw that away, and then needed a
runtime discriminator to recover information the types already carried.

Adding a discriminator to the wire was considered and rejected on measurement:
repointing a response field at a `oneof` envelope makes `buf breaking` exit 100
("changed type from BookPlacement to PlacementPayload"), so it would have needed
a gate suppression — to re-supply what the contract supplies for free.

Each decoder below layers only the fields its own shape actually carries:
`visibility` is on `PlacementDetail` and `BookPlacement` but not `PlacementRef`,
and `has_user_writing` is added by `shelf_with_placements/3` to the detail shape
alone.

-}
placementDetailDecoder : Decoder Placement
placementDetailDecoder =
    Decode.map3 (\p vis writing -> { p | visibility = vis, hasUserWriting = writing })
        placementWithBookDecoder
        visibilityField
        hasUserWritingField


{-| `BookPlacement` — the current user's placement for one book, carrying
`bookshelf_name` and no embedded book. Sent by `BookDetailResponse` and
`BookConfirmResponse`.
-}
bookPlacementDecoder : Decoder Placement
bookPlacementDecoder =
    Decode.map2 (\p vis -> { p | visibility = vis })
        (Decode.map fromProtoBookPlacement Proto.decodeBookPlacement)
        visibilityField


{-| `PlacementRef` — the slim create/move acknowledgement. Carries no
`visibility`, so none is layered on: a `Nothing` here means "this shape does not
report visibility", which is the truth, rather than "visibility unknown".
-}
placementRefDecoder : Decoder Placement
placementRefDecoder =
    Decode.map fromProtoPlacementRef Proto.decodePlacementRef


visibilityField : Decoder (Maybe Visibility)
visibilityField =
    Decode.maybe (Decode.field "visibility" Decode.string)
        |> Decode.map (Maybe.andThen Visibility.fromString)


hasUserWritingField : Decoder Bool
hasUserWritingField =
    Decode.oneOf
        [ Decode.field "has_user_writing" Decode.bool
        , Decode.succeed False
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
            , hasUserWriting = False
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
            , hasUserWriting = False
            }
        )
        Proto.decodePlacementDetail
        (Decode.maybe (Decode.field "bookshelf_name" Decode.string))


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
    , hasUserWriting = False
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
    , hasUserWriting = False
    }
