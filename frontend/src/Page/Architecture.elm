module Page.Architecture exposing (view)

{-| The long-form architecture-and-costs essay, linked from the /metrics costs
widget ("a full discussion of why all of these expenses are incurred").

The essay itself is being written on `draft/architecture-essay` and lands when
the owner is happy with it; until then this route serves an honest placeholder
rather than a half-finished piece with the author's working notes showing.

-}

import Html exposing (Html, a, div, h1, p, text)
import Html.Attributes exposing (class, href)
import Util.TestId exposing (testId)


view : Html msg
view =
    div [ class "page page--about curator-desk", testId "architecture-page" ]
        [ h1 [ class "page__title about__title" ] [ text "No such thing as a free lunch" ]
        , p [ class "about__lede" ]
            [ text "The full story of how The Stacks is built — what runs where, what it costs, and why each of those choices was made — is still being written. Check back here to learn more about the architecture in the future. In the meantime, the "
            , a [ class "about__prose-link", href "/metrics", testId "architecture-metrics-link" ]
                [ text "costs page" ]
            , text " already shows the line-by-line bill, live."
            ]
        ]
