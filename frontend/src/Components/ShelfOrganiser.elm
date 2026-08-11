module Components.ShelfOrganiser exposing
    ( Msg(..)
    , State
    , init
    , moveDown
    , moveTo
    , moveUp
    , orderedIds
    , view
    )

{-| Organising the physical shelves inside a bookshelf (US-1.7.1 / #190, campaign G5).

⚠️ **Terminology, because conflating these is easy and expensive:** a _bookshelf_ is a
named virtual collection (library, antilibrary…); a _shelf_ is a physical horizontal row
inside it (`op.shelves`). This component organises _shelves_.


## Why both drag and buttons

Decided 2026-07-28: build **both** drag-and-drop and explicit controls. Drag-only was
never the cheaper option — it needs a keyboard path regardless, so "drag now, accessible
later" is the same work with the accessible half deferred until an audit forces it. The
up/down buttons _are_ that keyboard path, and they are also faster than dragging for a
single step, which is the common case.

Both drive the same pure functions below, so the two affordances cannot drift into
disagreeing about what a move means.


## Why the pure functions are the interesting part

Reordering is where this can be silently wrong: an off-by-one puts a shelf one place from
where the reader dropped it, which looks like a glitch rather than a bug and is easy to
ship. So `moveUp`/`moveDown`/`moveTo` are total, tested against the edges, and hold no
state — the view and the HTTP call are thin over them.

-}

import Html exposing (Html, button, div, li, span, text, ul)
import Html.Attributes exposing (attribute, class, disabled, draggable, title)
import Html.Events exposing (on, onClick)
import Json.Decode as Decode
import Types.Shelf exposing (Shelf)
import Util.TestId exposing (testId)


{-| Which shelf is mid-drag, if any. Deliberately the only state: the shelf order itself
lives with the caller, so there is one source of truth rather than a copy to keep in sync.
-}
type alias State =
    { dragging : Maybe String }


init : State
init =
    { dragging = Nothing }


type Msg
    = AddShelf
    | RemoveShelf String
    | MoveUp String
    | MoveDown String
    | DragStart String
    | DragEnd
    | DragOver
    | DropOn String


{-| Move a shelf one place earlier. A no-op at the top, and for an unknown id.

Total by construction: every caller passes an id from the list it just rendered, but a
stale click from a re-render must not be able to reorder something else or crash.

-}
moveUp : String -> List Shelf -> List Shelf
moveUp id shelves =
    case indexOf id shelves of
        Just i ->
            moveTo i (i - 1) shelves

        Nothing ->
            shelves


{-| Move a shelf one place later. A no-op at the bottom, and for an unknown id.
-}
moveDown : String -> List Shelf -> List Shelf
moveDown id shelves =
    case indexOf id shelves of
        Just i ->
            moveTo i (i + 1) shelves

        Nothing ->
            shelves


{-| Move the item at `from` to index `to`.

Removes first, then inserts at `to` in the shortened list — which is what "move to index
`to`" means, and sidesteps the off-by-one that inserting into the _original_ indices would
cause on a downward move.

⚠️ **The `clamp` is belt-and-braces, not load-bearing, and I checked rather than assumed.**
A mutation probe replacing `target` with the raw `to` left all 28 tests green: `List.take`
and `List.drop` already clamp negative and over-long values, so out-of-range targets behave
identically either way. It is kept because it makes the `from == target` early return
honest for an out-of-range drop, and because a reader should not have to know that
`List.take -5` is `[]` to trust this. But it is not what makes the arithmetic correct — the
remove-then-insert order is.

-}
moveTo : Int -> Int -> List Shelf -> List Shelf
moveTo from to shelves =
    let
        len =
            List.length shelves

        target =
            clamp 0 (len - 1) to
    in
    if from == target || from < 0 || from >= len then
        shelves

    else
        case
            ( List.take from shelves ++ List.drop (from + 1) shelves
            , List.drop from shelves |> List.head
            )
        of
            ( without, Just moved ) ->
                List.take target without ++ (moved :: List.drop target without)

            _ ->
                shelves


{-| The order to send to the server — the whole list, not a delta.
-}
orderedIds : List Shelf -> List String
orderedIds =
    List.map .id


indexOf : String -> List Shelf -> Maybe Int
indexOf id shelves =
    shelves
        |> List.indexedMap (\i shelf -> ( i, shelf.id ))
        |> List.filter (\( _, shelfId ) -> shelfId == id)
        |> List.head
        |> Maybe.map Tuple.first


{-| The organiser.

`busy` disables every control while a request is in flight, so a reader cannot queue two
conflicting orders — the second would win arbitrarily.

-}
view : { shelves : List Shelf, state : State, busy : Bool } -> Html Msg
view { shelves, state, busy } =
    div [ class "shelf-organiser" ]
        [ ul [ class "shelf-organiser__list" ]
            (List.indexedMap (viewRow shelves state busy) shelves)
        , button
            [ class "shelf-organiser__add"
            , onClick AddShelf
            , disabled busy
            , testId "shelf-add"
            ]
            [ text "Add a shelf" ]
        ]


viewRow : List Shelf -> State -> Bool -> Int -> Shelf -> Html Msg
viewRow shelves state busy index shelf =
    let
        isLast =
            index == List.length shelves - 1

        bookCount =
            List.length shelf.placements
    in
    li
        [ class "shelf-organiser__row"
        , classIf (state.dragging == Just shelf.id) "shelf-organiser__row--dragging"
        , draggable "true"
        , on "dragstart" (Decode.succeed (DragStart shelf.id))
        , on "dragend" (Decode.succeed DragEnd)
        , preventDefaultOn "dragover"
        , on "drop" (Decode.succeed (DropOn shelf.id))
        , testId "shelf-row"
        ]
        [ span [ class "shelf-organiser__handle", attribute "aria-hidden" "true" ] [ text "⠿" ]
        , span [ class "shelf-organiser__label" ]
            [ text ("Shelf " ++ String.fromInt (index + 1))
            , span [ class "shelf-organiser__count" ] [ text (bookLabel bookCount) ]
            ]
        , button
            [ class "shelf-organiser__move"
            , onClick (MoveUp shelf.id)
            , disabled (busy || index == 0)
            , title "Move this shelf up"
            , attribute "aria-label" ("Move shelf " ++ String.fromInt (index + 1) ++ " up")
            , testId "shelf-move-up"
            ]
            [ text "↑" ]
        , button
            [ class "shelf-organiser__move"
            , onClick (MoveDown shelf.id)
            , disabled (busy || isLast)
            , title "Move this shelf down"
            , attribute "aria-label" ("Move shelf " ++ String.fromInt (index + 1) ++ " down")
            , testId "shelf-move-down"
            ]
            [ text "↓" ]
        , button
            [ class "shelf-organiser__remove"
            , onClick (RemoveShelf shelf.id)
            , disabled (busy || bookCount > 0)
            , title
                (if bookCount > 0 then
                    "Move its books elsewhere before removing this shelf"

                 else
                    "Remove this empty shelf"
                )
            , testId "shelf-remove"
            ]
            [ text "Remove" ]
        ]


bookLabel : Int -> String
bookLabel count =
    case count of
        0 ->
            " — empty"

        1 ->
            " — 1 book"

        n ->
            " — " ++ String.fromInt n ++ " books"


classIf : Bool -> String -> Html.Attribute msg
classIf cond name =
    if cond then
        class name

    else
        class ""


{-| `dragover` must be prevented or the browser refuses the drop.

⚠️ **It must carry `DragOver`, which does nothing — not `DragEnd`, which cancels the drag.**
This originally sent `DragEnd` on the reasoning that the message was irrelevant and only
`preventDefault` mattered. It was not irrelevant: `DragEnd` clears `dragging`, and `dragover`
fires _continuously_ while the pointer is over a row, so `dragging` was always `Nothing` by
the time `drop` arrived. `DropOn`'s `Nothing` branch then returned silently and **no drop ever
reordered anything**. Drag-and-drop could not have worked in any browser.

Proven on a preview, 2026-07-28: `dragstart` → `drop` reorders; `dragstart` → `dragover` →
`drop` does nothing. The difference is this one message.

So `DragOver` exists purely to be inert, and that is the point — a message with no handler
body is safe here, whereas reusing a meaningful one is not.

-}
preventDefaultOn : String -> Html.Attribute Msg
preventDefaultOn event =
    Html.Events.preventDefaultOn event (Decode.succeed ( DragOver, True ))
