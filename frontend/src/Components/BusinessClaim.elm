module Components.BusinessClaim exposing (view)

{-| The way out, for a business that never asked to be named here.

The Stacks lists bookshops and the places people read by finding them publicly,
which means a shop can appear on this platform without anyone having asked it
first. The removal form is unauthenticated for that reason, and this link is the
other half of the same argument: an owner who has to go looking for the form has
not really been offered anything.

It renders in the footer of the block that did the naming rather than in a site
footer, because that is where the owner arrives — on the page about their own
shop, not at the front door. It is deliberately quiet: a reader browsing for a
book is not the audience, and the only person scanning for these words already
knows what they are looking for.

⚠️ Render it only where a business is actually named. The form's first question
is the listing's web address, so offering it beside a block that named nobody
sends the owner to a question they cannot answer.

-}

import Html exposing (Html, a, text)
import Html.Attributes exposing (class, href)
import Navigation.Route as Route
import Util.TestId exposing (testId)


view : Html msg
view =
    a
        [ class "business-claim"
        , href (Route.toPath Route.ListingRemoval)
        , testId "business-claim"
        ]
        [ text "Is this your business?" ]
