module Page.Bookshelf.GridNav exposing
    ( Key(..)
    , keyDecoder
    , nextFocus
    )

{-| Roving-tabindex arrow-key navigation over the bookcase grid (388,
). The grid is not rectangular — rows pack by accumulated spine
width — so ↑/↓ cannot be "same index, next row". The column model is
nearest-x (owner decision): a vertical move lands on the book whose
horizontal centre is closest in the adjacent row. One tab stop for the
whole grid; arrows rove within it.
-}

import Json.Decode as Decode


{-| The keys the grid handles. Deliberately closed: `keyDecoder` fails on
everything else, so Tab keeps tabbing and Enter/Space keep clicking the
button — the decoder's failure is what scopes `preventDefaultOn` to exactly
the navigation keys.
-}
type Key
    = ArrowLeft
    | ArrowRight
    | ArrowUp
    | ArrowDown
    | Home
    | End


{-| Decode a `keydown` into a `Key`, failing for keys the grid does not own.
-}
keyDecoder : Decode.Decoder Key
keyDecoder =
    Decode.field "key" Decode.string
        |> Decode.andThen
            (\key ->
                case key of
                    "ArrowLeft" ->
                        Decode.succeed ArrowLeft

                    "ArrowRight" ->
                        Decode.succeed ArrowRight

                    "ArrowUp" ->
                        Decode.succeed ArrowUp

                    "ArrowDown" ->
                        Decode.succeed ArrowDown

                    "Home" ->
                        Decode.succeed Home

                    "End" ->
                        Decode.succeed End

                    _ ->
                        Decode.fail "not a grid navigation key"
            )


{-| The book to focus after pressing `key` on `currentId`, over the packed
rows — `Nothing` when the move falls off the grid (first/last row vertically,
row ends horizontally) or when `currentId` is not in it, so the caller leaves
focus where it is.
-}
nextFocus : Key -> String -> List (List ( String, Int )) -> Maybe String
nextFocus key currentId rows =
    locate currentId rows
        |> Maybe.andThen
            (\( rowIndex, row, colIndex ) ->
                case key of
                    ArrowLeft ->
                        row |> idAt (colIndex - 1)

                    ArrowRight ->
                        row |> idAt (colIndex + 1)

                    Home ->
                        row |> idAt 0

                    End ->
                        row |> idAt (List.length row - 1)

                    ArrowUp ->
                        vertical -1 rowIndex row colIndex rows

                    ArrowDown ->
                        vertical 1 rowIndex row colIndex rows
            )


vertical : Int -> Int -> List ( String, Int ) -> Int -> List (List ( String, Int )) -> Maybe String
vertical direction rowIndex row colIndex rows =
    let
        targetRow =
            rows
                |> List.drop (rowIndex + direction)
                |> List.head
    in
    if rowIndex + direction < 0 then
        Nothing

    else
        Maybe.map2 nearestX (centerAt colIndex row) targetRow
            |> Maybe.andThen identity


{-| The id in `row` whose x-centre is nearest to `x` — ties go to the earlier
book, which keeps repeated ↑↓ from drifting rightward across equal spines.
-}
nearestX : Int -> List ( String, Int ) -> Maybe String
nearestX x row =
    row
        |> withCenters
        |> List.map (\( bookId, center ) -> ( bookId, abs (center - x) ))
        |> List.sortBy Tuple.second
        |> List.head
        |> Maybe.map Tuple.first


{-| Each book paired with its x-centre: cumulative offset plus half its width.
-}
withCenters : List ( String, Int ) -> List ( String, Int )
withCenters row =
    row
        |> List.foldl
            (\( bookId, width ) ( offset, acc ) ->
                ( offset + width, ( bookId, offset + width // 2 ) :: acc )
            )
            ( 0, [] )
        |> Tuple.second
        |> List.reverse


centerAt : Int -> List ( String, Int ) -> Maybe Int
centerAt colIndex row =
    row
        |> withCenters
        |> List.drop colIndex
        |> List.head
        |> Maybe.map Tuple.second


idAt : Int -> List ( String, Int ) -> Maybe String
idAt index row =
    if index < 0 then
        Nothing

    else
        row |> List.drop index |> List.head |> Maybe.map Tuple.first


{-| ( row index, that row, column index) of `bookId`.
-}
locate : String -> List (List ( String, Int )) -> Maybe ( Int, List ( String, Int ), Int )
locate bookId rows =
    rows
        |> List.indexedMap Tuple.pair
        |> List.filterMap
            (\( rowIndex, row ) ->
                row
                    |> List.indexedMap Tuple.pair
                    |> List.filterMap
                        (\( colIndex, ( candidate, _ ) ) ->
                            if candidate == bookId then
                                Just ( rowIndex, row, colIndex )

                            else
                                Nothing
                        )
                    |> List.head
            )
        |> List.head
