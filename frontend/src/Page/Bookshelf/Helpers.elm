module Page.Bookshelf.Helpers exposing
    ( SpineGridConfig
    , groupIntoRows
    , minShelfRows
    , pickTexture
    , placementSpineWidth
    , viewBookcase
    , viewEmptyShelfMessage
    , viewLoadingShelfRows
    , viewShelfLabel
    , viewShelfRow
    , viewShelfRowClickable
    )

import Components.Spine exposing (SpineTexture(..), WearLevel, book, spineHeight, spineWidth)
import Html exposing (Html, button, div, p, span, text)
import Html.Attributes exposing (attribute, class, id, style, tabindex)
import Html.Events exposing (onClick, preventDefaultOn)
import Json.Decode as Decode
import Page.Bookshelf.GridNav as GridNav
import Types.Book exposing (Book, bookCoverImageUrl, bookPageCount)
import Types.Placement as Placement exposing (Placement)
import Util.Plural


{-| Pick a texture deterministically from the title.
-}
pickTexture : String -> SpineTexture
pickTexture s =
    let
        h =
            List.foldl (\c acc -> acc + Char.toCode c) 0 (String.toList s)
    in
    if modBy 3 h == 0 then
        Leather

    else
        Cloth


{-| Group placements into shelf rows based on accumulated spine width,
matching the mockup's approach of fitting books until a max width is reached.
-}
groupIntoRows : Int -> List Placement -> List (List Placement)
groupIntoRows maxWidth placements =
    groupIntoRowsHelp maxWidth 0 [] placements


groupIntoRowsHelp : Int -> Int -> List Placement -> List Placement -> List (List Placement)
groupIntoRowsHelp maxWidth currentWidth currentRow remaining =
    case remaining of
        [] ->
            if List.isEmpty currentRow then
                []

            else
                [ List.reverse currentRow ]

        p :: rest ->
            let
                w =
                    placementSpineWidth p
            in
            if currentWidth + w > maxWidth && not (List.isEmpty currentRow) then
                List.reverse currentRow :: groupIntoRowsHelp maxWidth w [ p ] rest

            else
                groupIntoRowsHelp maxWidth (currentWidth + w) (p :: currentRow) rest


{-| The horizontal room one placement's spine occupies in a row (spine + gap).

Exposed because `GridNav`'s nearest-x arithmetic (#388) must reason with the
SAME widths this packer laid the row out with — a second width formula would
navigate a different bookcase than the one on screen.

-}
placementSpineWidth : Placement -> Int
placementSpineWidth placement =
    let
        pageCount =
            case placement.book of
                Just bk ->
                    Maybe.withDefault 200 (bookPageCount bk)

                Nothing ->
                    200
    in
    spineWidth pageCount + 2


{-| Render a bookcase frame wrapping inner content with side panels.
-}
viewBookcase : List (Html msg) -> Html msg
viewBookcase content =
    div [ class "bookcase" ]
        [ div [ class "bookcase__side bookcase__side--left" ] []
        , div [ class "bookcase__side bookcase__side--right" ] []
        , div [ class "bookcase__inner" ] content
        ]


{-| Render a shelf label with an aria-label for accessibility.
-}
viewShelfLabel : String -> Html msg
viewShelfLabel label =
    div [ class "shelf-label", attribute "aria-label" label ]
        [ span [] [ text label ] ]


{-| Render a single shelf row matching the mockup structure:
.shelf-row > .shelf-row\_\_back + .shelf-row\_\_books + .shelf-row\_\_plank + .shelf-row\_\_lip
-}
viewShelfRow : WearLevel -> List Placement -> Html msg
viewShelfRow wearLevel placements =
    let
        bookCount =
            List.length placements

        shelfAriaLabel =
            "Shelf — " ++ Util.Plural.books bookCount
    in
    div [ class "shelf-row" ]
        [ div [ class "shelf-row__back" ] []
        , div
            [ class "shelf-row__books"
            , attribute "role" "list"
            , attribute "aria-label" shelfAriaLabel
            ]
            (List.map (viewSpine wearLevel) placements)
        , div [ class "shelf-row__plank" ] []
        , div [ class "shelf-row__lip" ] []
        ]


{-| Render a book element with role="listitem" for accessibility.
Uses the new `book` function from Components.Spine that produces
the full 3D structure with spine and cover.
-}
viewSpine : WearLevel -> Placement -> Html msg
viewSpine wearLevel placement =
    let
        bookData =
            case placement.book of
                Just bk ->
                    { title = bk.title
                    , author = Types.Book.authorName bk
                    , pageCount = Maybe.withDefault 200 (bookPageCount bk)
                    , coverUrl = bookCoverImageUrl bk
                    }

                Nothing ->
                    { title = "Unknown Title"
                    , author = "Unknown Author"
                    , pageCount = 200
                    , coverUrl = Nothing
                    }

        texture =
            pickTexture bookData.title
    in
    div [ attribute "role" "listitem" ]
        [ book
            { pageCount = bookData.pageCount
            , wearLevel = wearLevel
            , texture = texture
            , title = bookData.title
            , author = bookData.author
            , coverImageUrl = bookData.coverUrl
            , hidden = Placement.isHidden placement
            , hasWriting = placement.hasUserWriting
            }
        ]


{-| Render a shelf row where each book spine is clickable.
The onBookClicked callback receives the Book data when a spine is clicked.

`tabStopId` is the roving tabindex (#388): exactly one spine per bookcase
carries `tabindex 0` — the last-focused one, or the grid's first spine — and
every other spine is reachable from it with the arrow keys via `onNavKey`.
`Nothing` (no roving state, e.g. the plain `viewShelfRow`) leaves every spine
a tab stop, the pre-#388 behaviour.

-}
type alias SpineGridConfig msg =
    { wearLevel : WearLevel
    , onBookClicked : Book -> msg
    , onNavKey : String -> GridNav.Key -> msg
    , tabStopId : Maybe String
    }


viewShelfRowClickable : SpineGridConfig msg -> List Placement -> Html msg
viewShelfRowClickable config placements =
    let
        bookCount =
            List.length placements

        shelfAriaLabel =
            "Shelf — " ++ Util.Plural.books bookCount
    in
    div [ class "shelf-row" ]
        [ div [ class "shelf-row__back" ] []
        , div
            [ class "shelf-row__books"
            , attribute "role" "list"
            , attribute "aria-label" shelfAriaLabel
            ]
            (List.map (viewClickableSpine config) placements)
        , div [ class "shelf-row__plank" ] []
        , div [ class "shelf-row__lip" ] []
        ]


{-| A shelf row with a centered message — used as the first row when the bookshelf is empty.
-}
viewEmptyShelfMessage : String -> Html msg
viewEmptyShelfMessage message =
    div [ class "shelf-row shelf-row--empty" ]
        [ div [ class "shelf-row__back" ] []
        , div [ class "shelf-row__books shelf-row__books--message" ]
            [ p [ class "shelf-row__empty-text" ] [ text message ] ]
        , div [ class "shelf-row__plank" ] []
        , div [ class "shelf-row__lip" ] []
        ]


{-| A bookcase-full of placeholder spines, for the moment the shelves are still
in flight.

⛔ **This exists because "no books yet" and "we do not know yet" used to render
the same thing.** `Page.Bookshelf` gave `Loading` the same branch as `NotAsked`
— an empty bookcase — which is also what an empty shelf looks like. Driven live
on 2026-07-30: navigating to a shelf with no connection painted a serene, empty
bookcase and stopped. The reader is told their shelves are empty; the truth is
that the request never completed. For a product whose whole subject is the books
someone owns, that is the worst sentence the page can say wrongly.

So the loading row is not a spinner bolted onto the empty state — it is the
opposite claim, made in the same visual language: spine-shaped placeholders on a
real shelf, saying "books are coming" where the empty row says "there are none".
The widths come from `spineWidth` on a fixed spread of page counts, so the rows
have the irregular rhythm of an actual shelf rather than rows of identical bars.

⚠️ **It returns every row, not one row to pad out with `minShelfRows`.** Padding
would fill the rest of the bookcase with `shelf-row--empty` — the empty state's
own marker — putting "this shelf is empty" back on the waiting page in the one
place a reader and a test both look.

`aria-hidden` on the placeholders: they carry no information a screen reader can
use. The announcement is the `role="status"` region around the bookcase (see
`Page.Bookshelf.viewLoadingBookshelf`), which says it once, in words.

-}
viewLoadingShelfRows : List (Html msg)
viewLoadingShelfRows =
    List.map viewLoadingShelfRow skeletonRows


viewLoadingShelfRow : List Int -> Html msg
viewLoadingShelfRow pageCounts =
    div [ class "shelf-row shelf-row--loading" ]
        [ div [ class "shelf-row__back" ] []
        , div
            [ class "shelf-row__books shelf-row__books--loading"
            , attribute "aria-hidden" "true"
            ]
            (List.map viewSkeletonSpine pageCounts)
        , div [ class "shelf-row__plank" ] []
        , div [ class "shelf-row__lip" ] []
        ]


{-| Page counts for the placeholder spines, a row at a time. Arbitrary, but
fixed rather than random: a shelf whose skeleton reshuffles on every re-render
reads as broken.

Row lengths are chosen to fill `bookcaseInnerWidth` (~990px at ~42px a spine,
including the 2px gap) — the first draft used twelve and left half of every
shelf visibly bare, which reads as an emptying shelf rather than a filling one.
Found by looking at it in a browser. The last row runs short on purpose: a
bookcase that is still being filled.

-}
skeletonRows : List (List Int)
skeletonRows =
    [ [ 320, 180, 640, 240, 900, 150, 420, 700, 260, 540, 200, 380, 610, 230, 480, 170, 730, 290, 550, 210, 660, 340, 450 ]
    , [ 210, 760, 300, 480, 160, 620, 340, 900, 220, 400, 580, 250, 690, 190, 520, 360, 270, 810, 230, 440, 600, 180, 500 ]
    , [ 640, 190, 430, 820, 270, 350, 700, 200, 560, 310, 240, 470, 880, 220, 390, 650, 180, 530, 300, 720, 250, 410, 590 ]
    , [ 380, 520, 170, 660, 290, 750, 230, 460, 340 ]
    ]


viewSkeletonSpine : Int -> Html msg
viewSkeletonSpine pageCount =
    div
        [ class "book-skeleton"
        , style "width" (String.fromInt (spineWidth pageCount) ++ "px")
        , style "height" (String.fromInt (spineHeight pageCount) ++ "px")
        ]
        []


{-| An empty shelf row — just the back, plank, and lip with no books.
-}
viewEmptyShelfRow : Html msg
viewEmptyShelfRow =
    div [ class "shelf-row shelf-row--empty" ]
        [ div [ class "shelf-row__back" ] []
        , div [ class "shelf-row__books" ] []
        , div [ class "shelf-row__plank" ] []
        , div [ class "shelf-row__lip" ] []
        ]


{-| Pad a list of shelf row views to at least `minRows` by appending empty shelves.
-}
minShelfRows : Int -> List (Html msg) -> List (Html msg)
minShelfRows minRows rows =
    let
        padding =
            max 0 (minRows - List.length rows)
    in
    rows ++ List.repeat padding viewEmptyShelfRow


{-| Render a clickable book spine wrapped in a button element.
The onBookClicked callback receives the Book data when the spine is clicked.
Reusable across all shelf pages (Library, AntiLibrary, WishList, ReadingPile).
-}
viewClickableSpine : SpineGridConfig msg -> Placement -> Html msg
viewClickableSpine config placement =
    let
        bookData =
            case placement.book of
                Just bk ->
                    bk

                Nothing ->
                    { id = ""
                    , title = "Unknown Title"
                    , author = Nothing
                    , description = Nothing
                    , editions = []
                    , primaryEdition = Nothing
                    , editionCount = 0
                    , subjects = []
                    , visibilityTier = Types.Book.Public
                    }

        texture =
            pickTexture bookData.title

        -- Roving tabindex (#388): one tab stop per bookcase. No roving state
        -- (tabStopId = Nothing) keeps every spine tabbable.
        spineTabIndex =
            case config.tabStopId of
                Nothing ->
                    0

                Just tabStopId ->
                    if tabStopId == bookData.id then
                        0

                    else
                        -1
    in
    button
        [ class "book-button"
        , attribute "role" "listitem"
        , id ("spine-" ++ bookData.id)
        , tabindex spineTabIndex

        -- Arrows/Home/End move focus; the decoder FAILS for every other key,
        -- so Tab keeps tabbing and Enter/Space keep clicking. preventDefault
        -- stops the arrows scrolling the page under the move.
        , preventDefaultOn "keydown"
            (GridNav.keyDecoder
                |> Decode.map (\key -> ( config.onNavKey bookData.id key, True ))
            )
        , onClick (config.onBookClicked bookData)
        ]
        [ Components.Spine.book
            { pageCount = Maybe.withDefault 200 (bookPageCount bookData)
            , wearLevel = config.wearLevel
            , texture = texture
            , title = bookData.title
            , author = Types.Book.authorName bookData
            , coverImageUrl = bookCoverImageUrl bookData
            , hidden = Placement.isHidden placement
            , hasWriting = placement.hasUserWriting
            }
        ]
