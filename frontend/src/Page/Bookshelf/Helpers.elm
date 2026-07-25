module Page.Bookshelf.Helpers exposing
    ( groupIntoRows
    , minShelfRows
    , pickTexture
    , viewBookcase
    , viewEmptyShelfMessage
    , viewShelfLabel
    , viewShelfRow
    , viewShelfRowClickable
    )

import Components.Spine exposing (SpineTexture(..), WearLevel, book, spineWidth)
import Html exposing (Html, button, div, p, span, text)
import Html.Attributes exposing (attribute, class, id, tabindex)
import Html.Events exposing (onClick)
import Types.Book exposing (Book, bookCoverImageUrl, bookPageCount)
import Types.Placement exposing (Placement)


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
                pageCount =
                    case p.book of
                        Just bk ->
                            Maybe.withDefault 200 (bookPageCount bk)

                        Nothing ->
                            200

                w =
                    spineWidth pageCount + 2
            in
            if currentWidth + w > maxWidth && not (List.isEmpty currentRow) then
                List.reverse currentRow :: groupIntoRowsHelp maxWidth w [ p ] rest

            else
                groupIntoRowsHelp maxWidth (currentWidth + w) (p :: currentRow) rest


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
            "Shelf — " ++ String.fromInt bookCount ++ " books"
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
            , hidden = placement.visibility == Just "owner"
            , hasWriting = placement.hasUserWriting
            }
        ]


{-| Render a shelf row where each book spine is clickable.
The onBookClicked callback receives the Book data when a spine is clicked.
-}
viewShelfRowClickable : WearLevel -> (Book -> msg) -> List Placement -> Html msg
viewShelfRowClickable wearLevel onBookClicked placements =
    let
        bookCount =
            List.length placements

        shelfAriaLabel =
            "Shelf — " ++ String.fromInt bookCount ++ " books"
    in
    div [ class "shelf-row" ]
        [ div [ class "shelf-row__back" ] []
        , div
            [ class "shelf-row__books"
            , attribute "role" "list"
            , attribute "aria-label" shelfAriaLabel
            ]
            (List.map (viewClickableSpine wearLevel onBookClicked) placements)
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
viewClickableSpine : WearLevel -> (Book -> msg) -> Placement -> Html msg
viewClickableSpine wearLevel onBookClicked placement =
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
    in
    button
        [ class "book-button"
        , attribute "role" "listitem"
        , id ("spine-" ++ bookData.id)
        , tabindex 0
        , onClick (onBookClicked bookData)
        ]
        [ Components.Spine.book
            { pageCount = Maybe.withDefault 200 (bookPageCount bookData)
            , wearLevel = wearLevel
            , texture = texture
            , title = bookData.title
            , author = Types.Book.authorName bookData
            , coverImageUrl = bookCoverImageUrl bookData
            , hidden = placement.visibility == Just "owner"
            , hasWriting = placement.hasUserWriting
            }
        ]
