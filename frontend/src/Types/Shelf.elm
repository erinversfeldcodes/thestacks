module Types.Shelf exposing (Shelf, shelvesResponseDecoder)

import Json.Decode as Decode
import Types.Placement exposing (Placement, placementDecoder)


type alias Shelf =
    { id : String
    , position : Int
    , placements : List Placement
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
