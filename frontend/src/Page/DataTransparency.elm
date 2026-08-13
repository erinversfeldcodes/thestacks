module Page.DataTransparency exposing (view)

{-| The long-form data-transparency essay linked from the /metrics
subtitle ("this piece"). Owner-authored copy, edited in place like
Page.About — each section below is a placeholder awaiting the owner's
text. Reuses the About page's `about__*` classes on purpose: same
long-form-prose styling, and no new CSS classes to orphan.
-}

import Html exposing (Html, a, div, h1, h2, p, section, text)
import Html.Attributes exposing (class, href)
import Util.TestId exposing (testId)


view : Html msg
view =
    div [ class "page page--about curator-desk", testId "data-transparency-page" ]
        [ h1 [ class "page__title about__title" ] [ text "Why we show you everything" ]
        , p [ class "about__lede" ]
            [ text "On data transparency: what The Stacks measures, what it refuses to measure, and why the numbers are public. (Placeholder — the owner is writing this piece.)" ]
        , viewWhatWeMeasure
        , viewWhatWeRefuse
        , viewWhyPublic
        , viewYourData
        , viewBackLink
        ]


viewWhatWeMeasure : Html msg
viewWhatWeMeasure =
    section [ class "about__section" ]
        [ h2 [ class "about__section-title" ] [ text "What we measure" ]
        , p [ class "about__section-prose" ]
            [ text "(Placeholder — describe what the platform observes about itself and its readers, and the aggregate-only boundary.)" ]
        ]


viewWhatWeRefuse : Html msg
viewWhatWeRefuse =
    section [ class "about__section" ]
        [ h2 [ class "about__section-title" ] [ text "What we refuse to measure" ]
        , p [ class "about__section-prose" ]
            [ text "(Placeholder — the identifying data that is deliberately never collected, and the lines that will not be crossed.)" ]
        ]


viewWhyPublic : Html msg
viewWhyPublic =
    section [ class "about__section" ]
        [ h2 [ class "about__section-title" ] [ text "Why the numbers are public" ]
        , p [ class "about__section-prose" ]
            [ text "(Placeholder — the case for showing operators' dashboards and real running costs to everyone, instead of selling data quietly.)" ]
        ]


viewYourData : Html msg
viewYourData =
    section [ class "about__section" ]
        [ h2 [ class "about__section-title" ] [ text "Your data is yours" ]
        , p [ class "about__section-prose" ]
            [ text "(Placeholder — personal metrics visible only to their owner, and the export and erasure rights that back it all up.)" ]
        ]


viewBackLink : Html msg
viewBackLink =
    section [ class "about__section" ]
        [ p [ class "about__section-prose" ]
            [ a [ class "about__link", href "/metrics", testId "transparency-metrics-link" ]
                [ text "See the numbers themselves →" ]
            ]
        ]
