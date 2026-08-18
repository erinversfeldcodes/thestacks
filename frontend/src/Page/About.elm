module Page.About exposing (view)

{-| The public About page. Carries the owner's approved launch
copy, one drafted section per `section.about__section` in the draft's
order, so a copy edit is a local change. "The wider shelf" (partner
events) describes an aspiration the platform is built for, not a live
feature — the copy is deliberately future-tense.
-}

import Html exposing (Html, a, div, h1, h2, li, p, section, strong, text, ul)
import Html.Attributes exposing (class, href)
import Util.TestId exposing (testId)


view : Html msg
view =
    div [ class "page page--about curator-desk", testId "about-page" ]
        (viewHero ++ viewSections ++ viewTransparency)


{-| Hero / one-liner. The bold line is the lede; the sentence beneath it sets the
tone.
-}
viewHero : List (Html msg)
viewHero =
    [ h1 [ class "page__title about__title" ] [ text "About The Stacks" ]
    , p [ class "about__lede" ]
        [ text "A quiet place for the books you own, the pieces you've read, and the knowledge you're still circling." ]
    , p [ class "about__section-prose" ]
        [ text "The Stacks is a self-hosted home for your library — the read and the unread alike — built for people who believe a bookshelf is a kind of autobiography." ]
    ]


viewSections : List (Html msg)
viewSections =
    [ viewWhatItIs
    , viewFiveShelves
    , viewWhatYouCanDo
    , viewBuiltToBeYours
    , viewWiderShelf
    , viewClosing
    ]


viewWhatItIs : Html msg
viewWhatItIs =
    section [ class "about__section" ]
        [ h2 [ class "about__section-title" ] [ text "What The Stacks is" ]
        , p [ class "about__section-prose" ]
            [ text "The Stacks is a source-available reading-management and book-discovery platform. It keeps your collection on your own terms: no ads, no selling your reading habits, no algorithm deciding what you should want next. Just your books and the things you've read, arranged the way a good shelf is — with room for the ones you haven't gotten around to yet." ]
        , p [ class "about__section-prose" ]
            [ text "It's built around a simple conviction: things you haven't read matter as much as the ones you have. Umberto Eco called that unread portion an "
            , strong [] [ text "antilibrary" ]
            , text " — a private promise of everything still ahead of you. The Stacks gives it a shelf of its own."
            ]
        ]


viewFiveShelves : Html msg
viewFiveShelves =
    section [ class "about__section" ]
        [ h2 [ class "about__section-title" ] [ text "The five shelves" ]
        , p [ class "about__section-prose" ]
            [ text "Every book you add finds a home on one of five shelves:" ]
        , ul [ class "about__shelves" ]
            [ viewShelf "Antilibrary" "owned, unread. The promise."
            , viewShelf "Library" "read, and kept."
            , viewShelf "Reading pile" "what you're in the middle of right now."
            , viewShelf "Wishlist" "not yet yours, but wanted."
            , viewShelf "Looking for a home" "read, and ready to pass on."
            ]
        , p [ class "about__section-prose" ]
            [ text "Move a book between them as your relationship with it changes." ]
        ]


viewShelf : String -> String -> Html msg
viewShelf name description =
    li [ class "about__shelf" ]
        [ strong [ class "about__shelf-name" ] [ text name ]
        , text (" — " ++ description)
        ]


viewWhatYouCanDo : Html msg
viewWhatYouCanDo =
    section [ class "about__section" ]
        [ h2 [ class "about__section-title" ] [ text "What you can do" ]
        , ul [ class "about__do-list" ]
            [ viewDo "Add a book by its cover."
                "Photograph a spine or a barcode and The Stacks identifies it — every title verified against a real catalogue before it enters your collection, so your shelves never fill up with guesses."
            , viewDo "Arrange a bookcase that looks like yours."
                "Real spines, real proportions, shelved the way you'd shelve them."
            , viewDo "Keep it private, or share a shelf."
                "You decide what any other person can see, down to the individual book."
            , viewDo "Take your library with you."
                "Export everything you've stored, whenever you like — it's yours."
            ]
        , p [ class "about__coming-soon" ]
            [ text "Coming soon: adding other pieces of writing — blogs, scientific articles and musings." ]
        ]


viewDo : String -> String -> Html msg
viewDo title description =
    li [ class "about__do-item" ]
        [ strong [ class "about__do-title" ] [ text title ]
        , text (" " ++ description)
        ]


viewBuiltToBeYours : Html msg
viewBuiltToBeYours =
    section [ class "about__section" ]
        [ h2 [ class "about__section-title" ] [ text "Built to be yours" ]
        , p [ class "about__section-prose" ]
            [ text "The Stacks is source-available and privately hosted. Read the code, take inspiration from it, and build something similar for yourself — but be a mensch and don't fork this one, or I'll have to come find you every time I fix a bug of my own." ]
        , p [ class "about__section-prose" ]
            [ text "Privacy isn't a setting here, it's the default. Your data is classified, minimised, and erasable: ask to be forgotten and you are, completely. Reading is a private act, and The Stacks treats it that way, allowing you to invite a close circle to share your reflections with — but by default encouraging depth and range rather than shallow performance." ]
        ]


{-| The wider shelf — PRESENT TENSE (owner ruling, see module doc).
-}
viewWiderShelf : Html msg
viewWiderShelf =
    section [ class "about__section" ]
        [ h2 [ class "about__section-title" ] [ text "The wider shelf" ]
        , p [ class "about__section-prose" ]
            [ text "Bookshops, reading groups, and cafés can share what they're up to — a signing, a new arrival, a Thursday-evening meeting — and it surfaces alongside the books it's about. They send to the platform; they never see you." ]
        ]


viewClosing : Html msg
viewClosing =
    section [ class "about__section" ]
        [ p [ class "about__closing" ]
            [ text "Pull up a chair. The Stacks is quieter than the internet, and it's here to give you the space to think." ]
        ]


{-| Preserved from: About is still the only entry point to the public
transparency surface and the cost-transparency page, and the E2E specs drive
these two links by their test ids.
-}
viewTransparency : List (Html msg)
viewTransparency =
    [ section [ class "about__transparency" ]
        [ h2 [ class "about__section-title" ] [ text "Radical transparency" ]
        , p [ class "about__section-prose" ]
            [ text "We show what we measure, how we run the platform, and what it costs — the same signals operators see, with plain explanations of why." ]
        , a [ class "about__link about__link--metrics", href "/metrics", testId "about-metrics-link" ]
            [ text "See what we measure" ]
        , a [ class "about__link about__link--costs", href "/costs", testId "about-costs-link" ]
            [ text "See what it costs to run" ]
        , a [ class "about__link about__link--faq", href "/faq", testId "about-faq-link" ]
            [ text "Questions, answered" ]
        ]
    ]
