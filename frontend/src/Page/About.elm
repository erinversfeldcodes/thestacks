module Page.About exposing (view)

{-| A minimal public About page (Issue #235).

Its job is to be the single, uncluttered navbar entry point that leads to the
public transparency surface (`/metrics`) and the cost-transparency page
(`/costs`). Static — no model, no messages. Placeholder prose the owner will
refine later.

-}

import Html exposing (Html, a, div, h1, h2, p, section, text)
import Html.Attributes exposing (class, href)
import Util.TestId exposing (testId)


view : Html msg
view =
    div [ class "page page--about curator-desk", testId "about-page" ]
        [ h1 [ class "page__title about__title" ] [ text "About The Stacks" ]
        , p [ class "about__lede" ]
            [ text "An open-source, self-hosted book management and discovery platform, built anti-surveillance and GDPR-first. Placeholder copy — the owner will refine this." ]
        , section [ class "about__transparency" ]
            [ h2 [ class "about__section-title" ] [ text "Radical transparency" ]
            , p [ class "about__section-prose" ]
                [ text "We show what we measure, how we run the platform, and what it costs — the same signals operators see, with plain explanations of why." ]
            , a [ class "about__link about__link--metrics", href "/metrics", testId "about-metrics-link" ]
                [ text "See what we measure" ]
            , a [ class "about__link about__link--costs", href "/costs", testId "about-costs-link" ]
                [ text "See what it costs to run" ]
            ]
        ]
