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
        , describe "the affordance is visible, not only audible (#363)"
            [ hiddenBookHasVisiblePadlock
            , visibleBookHasNoPadlock
            , padlockIsDecorative
            , hiddenBookCarriesNoInlineOpacity
            , visibleBookCarriesNoInlineOpacity
            ]
        ]


{-| ⛔ The whole affordance used to be `opacity: 0.35` plus an aria-label suffix.
A screen-reader user was told the book was private; a sighted one saw a book that
was merely faint on a shelf that already shades by depth — and at 0.35 the
spine's own title fell under the contrast floor, so the one book whose privacy
you might want to check was the one you could not read.
-}
hiddenBookHasVisiblePadlock : Test
hiddenBookHasVisiblePadlock =
    test "a hidden placement renders a padlock a sighted reader can see" <|
        \_ ->
            hiddenBook
                |> Query.fromHtml
                |> Query.find [ Selector.class "book__lock" ]
                |> Query.has [ Selector.text "🔒" ]


visibleBookHasNoPadlock : Test
visibleBookHasNoPadlock =
    test "a visible placement renders no padlock" <|
        \_ ->
            -- The positive control for the assertion above: without it, a
            -- padlock rendered unconditionally would also pass.
            visibleBook
                |> Query.fromHtml
                |> Query.hasNot [ Selector.class "book__lock" ]


padlockIsDecorative : Test
padlockIsDecorative =
    test "the padlock is aria-hidden — the aria-label already says it" <|
        \_ ->
            hiddenBook
                |> Query.fromHtml
                |> Query.find [ Selector.class "book__lock" ]
                |> Query.has
                    [ Selector.attribute
                        (Html.Attributes.attribute "aria-hidden" "true")
                    ]


hiddenBookCarriesNoInlineOpacity : Test
hiddenBookCarriesNoInlineOpacity =
    test "the hidden treatment is a stylesheet rule, not an inline style" <|
        \_ ->
            -- An inline style beats every rule in main.css, so it cannot be
            -- overridden, reviewed, or seen by scripts/check-css.sh. The
            -- treatment now lives in `.book--hidden`, where it can be.
            hiddenBook
                |> Query.fromHtml
                |> Query.hasNot
                    [ Selector.attribute (Html.Attributes.style "opacity" "0.35") ]


visibleBookCarriesNoInlineOpacity : Test
visibleBookCarriesNoInlineOpacity =
    test "positive control — a visible book has never carried one either" <|
        \_ ->
            visibleBook
                |> Query.fromHtml
                |> Query.hasNot
                    [ Selector.attribute (Html.Attributes.style "opacity" "0.35") ]


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
