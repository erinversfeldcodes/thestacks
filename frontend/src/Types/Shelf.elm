module Types.Shelf exposing (BookshelfResponse, Shelf, bookshelfResponseDecoder, shelvesResponseDecoder)

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
