module Types.Placement exposing
    ( Format(..)
    , Placement
    , placementDecoder
    )

import Json.Decode as Decode exposing (Decoder)
import Types.Book exposing (Book, bookDecoder)


type Format
    = Physical
    | EBook
    | Audiobook


formatDecoder : Decoder Format
formatDecoder =
    Decode.string
        |> Decode.andThen
            (\s ->
                case s of
                    "physical" ->
                        Decode.succeed Physical

                    "ebook" ->
                        Decode.succeed EBook

                    "audiobook" ->
                        Decode.succeed Audiobook

                    _ ->
                        Decode.fail ("Unknown format: " ++ s)
            )


type alias Placement =
    { id : String
    , book : Maybe Book
    , position : Int
    , placedAt : String
    , formats : List Format
    , personalRating : Maybe Int
    , notes : Maybe String
    }


placementDecoder : Decoder Placement
placementDecoder =
    Decode.map7 Placement
        (Decode.field "id" Decode.string)
        (Decode.maybe (Decode.field "book" bookDecoder))
        (Decode.field "position" Decode.int)
        (Decode.field "placed_at" Decode.string)
        (Decode.oneOf
            [ Decode.field "formats" (Decode.list formatDecoder)
            , Decode.succeed []
            ]
        )
        (Decode.maybe (Decode.field "personal_rating" Decode.int))
        (Decode.maybe (Decode.field "notes" Decode.string))
