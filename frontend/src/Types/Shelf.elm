module Types.Shelf exposing (BookshelfResponse, Shelf, bookshelfResponseDecoder, rowLabel, shelvesResponseDecoder)

import Json.Decode as Decode
import Types.Placement exposing (Placement, placementDecoder)


type alias Shelf =
    { id : String
    , position : Int
    , placements : List Placement
    }


{-| The owner's own `GET /api/bookshelves/:name` payload: the shelves plus the
bookshelf's real `op.visibility_level`. Visibility drives the RSS gate on the
owner's bookshelf page, so — unlike the shared `shelvesResponseDecoder` used by
the read-only public-profile path — this response carries it.
-}
type alias BookshelfResponse =
    { shelves : List Shelf
    , visibility : String
    }


{-| What a reader calls the shelf at `index` in an ordered bookcase.

A shelf row has no `name` column — it is the second one down, and nothing else.
Both places that show rows (the organiser, and the book-detail row picker) have
to say the same number for the same row, so the sentence lives once. The index
is the row's place in the ordered list, not its `position` value, because
`position` is a sort key the server is free to leave gapped.

-}
rowLabel : Int -> String
rowLabel index =
    "Shelf " ++ String.fromInt (index + 1)


shelfDecoder : Decode.Decoder Shelf
shelfDecoder =
    Decode.map3 Shelf
        (Decode.field "id" Decode.string)
        (Decode.field "position" Decode.int)
        (Decode.field "placements" (Decode.list placementDecoder))


shelvesResponseDecoder : Decode.Decoder (List Shelf)
shelvesResponseDecoder =
    Decode.field "shelves" (Decode.list shelfDecoder)


{-| Decoder for the owner's own bookshelf response. Tolerant of an
older/absent `visibility` (defaults to `"owner"`, the enum default) so a stale
payload never fails the decode — and a non-platform default keeps RSS hidden.
-}
bookshelfResponseDecoder : Decode.Decoder BookshelfResponse
bookshelfResponseDecoder =
    Decode.map2 BookshelfResponse
        (Decode.field "shelves" (Decode.list shelfDecoder))
        (Decode.oneOf
            [ Decode.field "visibility" Decode.string
            , Decode.succeed "owner"
            ]
        )
