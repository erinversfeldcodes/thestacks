module SpineHiddenTest exposing (suite)

{-| Tests for the faint-outline "hidden placement" rendering in
Components.Spine.book. When a placement is owner-only (hidden) on an
otherwise-visible shelf, the owner still sees a faint outline spine so they
know the book is there but private.
-}

import Components.Spine exposing (SpineTexture(..), WearLevel(..), book)
import Html
import Html.Attributes
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector


suite : Test
suite =
    describe "Components.Spine hidden placement rendering"
        [ hiddenBookHasHiddenClass
        , hiddenBookHasHiddenAria
        , visibleBookHasNoHiddenClass
        ]


hiddenBook : Html.Html msg
hiddenBook =
    book
        { pageCount = 400
        , wearLevel = Pristine
        , texture = Leather
        , title = "The Secret History"
        , author = "Donna Tartt"
        , coverImageUrl = Nothing
        , hidden = True
        , hasWriting = False
        }


visibleBook : Html.Html msg
visibleBook =
    book
        { pageCount = 400
        , wearLevel = Pristine
        , texture = Leather
        , title = "The Secret History"
        , author = "Donna Tartt"
        , coverImageUrl = Nothing
        , hidden = False
        , hasWriting = False
        }


hiddenBookHasHiddenClass : Test
hiddenBookHasHiddenClass =
    test "a hidden placement renders the faint-outline modifier class" <|
        \_ ->
            hiddenBook
                |> Query.fromHtml
                |> Query.has [ Selector.class "book--hidden" ]


hiddenBookHasHiddenAria : Test
hiddenBookHasHiddenAria =
    test "a hidden placement announces its hidden state in the aria-label" <|
        \_ ->
            hiddenBook
                |> Query.fromHtml
                |> Query.has
                    [ Selector.attribute
                        (Html.Attributes.attribute "aria-label" "Book: The Secret History by Donna Tartt, 400 pages, hidden (only visible to you)")
                    ]


visibleBookHasNoHiddenClass : Test
visibleBookHasNoHiddenClass =
    test "a visible placement does not render the hidden modifier class" <|
        \_ ->
            visibleBook
                |> Query.fromHtml
                |> Query.hasNot [ Selector.class "book--hidden" ]
