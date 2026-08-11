module ShelfOrganiserTest exposing (suite)

{-| Tests shelf organisation.

The backend has had 35 tests and 90 seeded rows for months with **no client call at all**,
so this is the reachability half. Two things are worth guarding:

1.  **The reorder arithmetic.** An off-by-one puts a shelf one place from where the reader
    put it, which looks like a flickering glitch rather than a bug and ships easily. The
    downward-move case is the one that gets it wrong, because removing the item first
    shifts every later index down by one.

2.  **Both affordances exist.** The decision was drag _and_ explicit controls, and the
    explicit ones are the keyboard path. A regression that quietly drops the buttons would
    leave the feature unusable without a mouse while still looking finished.

-}

import Components.ShelfOrganiser as Organiser
import Expect
import Html
import Html.Attributes
import Json.Encode as Encode
import Test exposing (Test, describe, test)
import Test.Html.Event as Event
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Types.Placement exposing (Placement)
import Types.Shelf exposing (Shelf)


shelf : String -> Int -> Shelf
shelf id books =
    { id = id
    , position = 0
    , placements = List.repeat books placeholderPlacement
    }


{-| A placement standing in for "this shelf has a book on it". Only the count is read, so
every field is the empty case — a fixture that looked like real data would invite a test to
assert on it and couple to the shape.
-}
placeholderPlacement : Placement
placeholderPlacement =
    { id = "placement"
    , book = Nothing
    , position = Nothing
    , placedAt = Nothing
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


ids : List Shelf -> List String
ids =
    List.map .id


three : List Shelf
three =
    [ shelf "a" 0, shelf "b" 0, shelf "c" 0 ]


render : List Shelf -> Query.Single Organiser.Msg
render shelves =
    Organiser.view { shelves = shelves, state = Organiser.init, busy = False }
        |> Query.fromHtml


suite : Test
suite =
    describe "ShelfOrganiser"
        [ describe "moveUp"
            [ test "moves a shelf one place earlier" <|
                \_ -> moveUpIds "b" three |> Expect.equal [ "b", "a", "c" ]
            , test "is a no-op at the top" <|
                \_ -> moveUpIds "a" three |> Expect.equal [ "a", "b", "c" ]
            , test "is a no-op for an id not in the list" <|
                \_ -> moveUpIds "zzz" three |> Expect.equal [ "a", "b", "c" ]
            ]
        , describe "moveDown"
            [ test "moves a shelf one place later" <|
                \_ ->
                    moveDownIds "a" three |> Expect.equal [ "b", "a", "c" ]
            , test "moves the middle shelf to the end" <|
                \_ -> moveDownIds "b" three |> Expect.equal [ "a", "c", "b" ]
            , test "is a no-op at the bottom" <|
                \_ -> moveDownIds "c" three |> Expect.equal [ "a", "b", "c" ]
            ]
        , describe "moveUp and moveDown are inverses"
            [ test "down then up returns the original order" <|
                \_ ->
                    three
                        |> Organiser.moveDown "a"
                        |> Organiser.moveUp "a"
                        |> ids
                        |> Expect.equal [ "a", "b", "c" ]
            , test "up then down returns the original order" <|
                \_ ->
                    three
                        |> Organiser.moveUp "c"
                        |> Organiser.moveDown "c"
                        |> ids
                        |> Expect.equal [ "a", "b", "c" ]
            ]
        , describe "moveTo — the drag-and-drop path"
            [ test "moves a shelf to an arbitrary later index" <|
                \_ ->
                    Organiser.moveTo 0 2 three |> ids |> Expect.equal [ "b", "c", "a" ]
            , test "moves a shelf to an arbitrary earlier index" <|
                \_ ->
                    Organiser.moveTo 2 0 three |> ids |> Expect.equal [ "c", "a", "b" ]
            , test "clamps a target past the end instead of dropping the shelf" <|
                \_ ->
                    Organiser.moveTo 0 99 three |> ids |> Expect.equal [ "b", "c", "a" ]
            , test "clamps a negative target" <|
                \_ ->
                    Organiser.moveTo 2 -5 three |> ids |> Expect.equal [ "c", "a", "b" ]
            , test "an out-of-range source is a no-op, not a crash" <|
                \_ ->
                    Organiser.moveTo 9 0 three |> ids |> Expect.equal [ "a", "b", "c" ]
            , test "never loses or duplicates a shelf" <|
                \_ ->
                    Organiser.moveTo 1 2 three
                        |> List.length
                        |> Expect.equal 3
            , test "handles a single-shelf list" <|
                \_ ->
                    Organiser.moveTo 0 1 [ shelf "only" 0 ]
                        |> ids
                        |> Expect.equal [ "only" ]
            , test "handles an empty list" <|
                \_ -> Organiser.moveTo 0 1 [] |> ids |> Expect.equal []
            ]
        , describe "orderedIds"
            [ test "is the full order, since the server takes the whole list" <|
                \_ -> Organiser.orderedIds three |> Expect.equal [ "a", "b", "c" ]
            ]
        , describe "both affordances are present"
            [ test "every row is draggable" <|
                \_ ->
                    render three
                        |> Query.findAll [ Selector.attribute (attr "draggable" "true") ]
                        |> Query.count (Expect.equal 3)
            , test "every row also has explicit move buttons — the keyboard path" <|
                \_ ->
                    render three
                        |> Query.findAll [ Selector.attribute (attr "data-testid" "shelf-move-up") ]
                        |> Query.count (Expect.equal 3)
            , test "the move buttons carry an aria-label naming the shelf" <|
                \_ ->
                    render three
                        |> Query.findAll
                            [ Selector.attribute (attr "aria-label" "Move shelf 1 down") ]
                        |> Query.count (Expect.equal 1)
            ]
        , describe "controls are disabled when they cannot succeed"
            [ test "up is disabled on the first shelf" <|
                \_ ->
                    render three
                        |> Query.findAll [ Selector.attribute (attr "data-testid" "shelf-move-up") ]
                        |> Query.first
                        |> Query.has [ Selector.disabled True ]
            , test "down is disabled on the last shelf" <|
                \_ ->
                    render three
                        |> Query.findAll
                            [ Selector.attribute (attr "data-testid" "shelf-move-down") ]
                        |> Query.index -1
                        |> Query.has [ Selector.disabled True ]
            , test "remove is disabled while a shelf holds books" <|
                \_ ->
                    Organiser.view
                        { shelves = [ shelf "full" 3 ], state = Organiser.init, busy = False }
                        |> Query.fromHtml
                        |> Query.find [ Selector.attribute (attr "data-testid" "shelf-remove") ]
                        |> Query.has [ Selector.disabled True ]
            , test "remove is enabled on an empty shelf" <|
                \_ ->
                    render [ shelf "empty" 0 ]
                        |> Query.find [ Selector.attribute (attr "data-testid" "shelf-remove") ]
                        |> Query.has [ Selector.disabled False ]
            , test "everything is disabled while a request is in flight" <|
                \_ ->
                    Organiser.view
                        { shelves = three, state = Organiser.init, busy = True }
                        |> Query.fromHtml
                        |> Query.find [ Selector.attribute (attr "data-testid" "shelf-add") ]
                        |> Query.has [ Selector.disabled True ]
            ]
        , describe "the drag events do not cancel the drag they are part of"
            [ test "dragover must NOT emit DragEnd — that killed every drop" <|
                \_ ->
                    render three
                        |> Query.findAll [ Selector.attribute (attr "data-testid" "shelf-row") ]
                        |> Query.first
                        |> Event.simulate (Event.custom "dragover" (Encode.object []))
                        |> Event.toResult
                        |> Expect.equal (Ok Organiser.DragOver)
            , test "dragstart still starts the drag" <|
                \_ ->
                    render three
                        |> Query.findAll [ Selector.attribute (attr "data-testid" "shelf-row") ]
                        |> Query.index 1
                        |> Event.simulate (Event.custom "dragstart" (Encode.object []))
                        |> Event.toResult
                        |> Expect.equal (Ok (Organiser.DragStart "b"))
            , test "drop targets the row it landed on" <|
                \_ ->
                    render three
                        |> Query.findAll [ Selector.attribute (attr "data-testid" "shelf-row") ]
                        |> Query.first
                        |> Event.simulate (Event.custom "drop" (Encode.object []))
                        |> Event.toResult
                        |> Expect.equal (Ok (Organiser.DropOn "a"))
            , test "dragend is still reachable, for a drag abandoned off-target" <|
                \_ ->
                    render three
                        |> Query.findAll [ Selector.attribute (attr "data-testid" "shelf-row") ]
                        |> Query.first
                        |> Event.simulate (Event.custom "dragend" (Encode.object []))
                        |> Event.toResult
                        |> Expect.equal (Ok Organiser.DragEnd)
            ]
        , describe "the row says how full a shelf is"
            [ test "names an empty shelf as empty, so Remove reads as safe" <|
                \_ -> render [ shelf "e" 0 ] |> Query.has [ Selector.text "empty" ]
            , test "singular for one book" <|
                \_ -> render [ shelf "s" 1 ] |> Query.has [ Selector.text "1 book" ]
            , test "plural for several" <|
                \_ -> render [ shelf "p" 4 ] |> Query.has [ Selector.text "4 books" ]
            ]
        ]


moveUpIds : String -> List Shelf -> List String
moveUpIds id shelves =
    Organiser.moveUp id shelves |> ids


moveDownIds : String -> List Shelf -> List String
moveDownIds id shelves =
    Organiser.moveDown id shelves |> ids


attr : String -> String -> Html.Attribute msg
attr =
    Html.Attributes.attribute
