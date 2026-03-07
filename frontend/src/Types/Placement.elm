module Types.Placement exposing
    ( Format(..)
    , Placement
    , PlacementHistory
    , formatDecoder
    , formatToString
    , placementDecoder
    , placementHistoryDecoder
    )

import Json.Decode as Decode exposing (Decoder)
import Types.Bookshelf exposing (Bookshelf, bookshelfFromString)


type Format
    = Physical
    | EBook
    | Audiobook


formatToString : Format -> String
formatToString format =
    case format of
        Physical ->
            "physical"

        EBook ->
            "ebook"

        Audiobook ->
            "audiobook"


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
    , bookId : String
    , bookshelf : Bookshelf
    , placedAt : String
    , removedAt : Maybe String
    , formats : List Format
    , personalRating : Maybe Int
    , notes : Maybe String
    }


type alias PlacementHistory =
    List Placement


bookshelfDecoder : Decoder Bookshelf
bookshelfDecoder =
    Decode.string
        |> Decode.andThen
            (\s ->
                case bookshelfFromString s of
                    Just b ->
                        Decode.succeed b

                    Nothing ->
                        Decode.fail ("Unknown bookshelf: " ++ s)
            )


placementDecoder : Decoder Placement
placementDecoder =
    Decode.map8 Placement
        (Decode.field "id" Decode.string)
        (Decode.field "book_id" Decode.string)
        (Decode.field "shelf_name" bookshelfDecoder)
        (Decode.field "placed_at" Decode.string)
        (Decode.maybe (Decode.field "removed_at" Decode.string))
        (Decode.oneOf
            [ Decode.field "formats" (Decode.list formatDecoder)
            , Decode.succeed []
            ]
        )
        (Decode.maybe (Decode.field "personal_rating" Decode.int))
        (Decode.maybe (Decode.field "notes" Decode.string))


placementHistoryDecoder : Decoder PlacementHistory
placementHistoryDecoder =
    Decode.list placementDecoder
