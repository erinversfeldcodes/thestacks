module ProgressSaveContract exposing (Outcome(..), label, outcomes, response)

{-| The outcomes a reading-progress save can end in, written once and driven
against every host that owns a progress card.

⛔ THIS EXISTS BECAUSE THE TWO HOSTS WERE WRONG IDENTICALLY, NOT DIFFERENTLY.

`Page.BookDetail` and `Page.Bookshelf.ReadingPile` share a card component and
have now diverged four times in four review rounds, each divergence introduced
while repairing the previous one. The repair reflex that grew out of that was
"fix one host, then go and check the other" — and it cannot find a defect both
hosts have, because checking the other host shows you the same code. That is
exactly what happened with the 401 branch: both returned the model untouched
while their own `else` branch cleared the in-flight flag, so a save that failed
on an expired session left the card reading "Saving…" with Save disabled, and no
response ever coming.

⚠️ And a shared update helper would have made that WORSE, not better.
Deduplicating the code deduplicates the defect: one handler wrong once is still
every host wrong. What catches convergence as well as divergence is a shared
list of CASES, written against intended behaviour rather than against either
host's current code, with each host driving the list through its own UI.

⚠️ Adding a variant here adds a case to every host automatically, because each
host maps over `outcomes` rather than listing them. That is deliberate: a
behaviour cannot be added to one host and forgotten in the other, and `label`
and `response` below stop compiling until the new variant is described.

-}

import Dict
import Http


{-| What came back from `PUT /api/placements/:id/progress`.

`SessionRejected` is the case that was missing. It is not a variant of
`ServerRefused`: `Api.isUnauthorized` is 401-only and routes to the deferred
session-expiry net, which may ADOPT a token another tab refreshed and cancel the
logout — so the page is still on screen afterwards, which is precisely when a
stuck in-flight flag becomes permanent rather than invisible behind a redirect.

-}
type Outcome
    = Saved
    | ServerRefused
    | SessionRejected


{-| Every outcome, in the order a host should report them.
-}
outcomes : List Outcome
outcomes =
    [ Saved, ServerRefused, SessionRejected ]


{-| The test name fragment for an outcome.
-}
label : Outcome -> String
label outcome =
    case outcome of
        Saved ->
            "a save the server accepted"

        ServerRefused ->
            "a save the server refused with a 500"

        SessionRejected ->
            "a save refused with a 401 because the session expired"


{-| The HTTP response for an outcome.

`savedBody` is the host's own success payload, because each host's placement has
a different id and the response has to decode against it.

-}
response : String -> String -> Outcome -> Http.Response String
response endpoint savedBody outcome =
    case outcome of
        Saved ->
            Http.GoodStatus_
                { url = endpoint
                , statusCode = 200
                , statusText = "OK"
                , headers = Dict.empty
                }
                savedBody

        ServerRefused ->
            Http.BadStatus_
                { url = endpoint
                , statusCode = 500
                , statusText = "Internal Server Error"
                , headers = Dict.empty
                }
                "{\"error\":\"something broke\"}"

        SessionRejected ->
            Http.BadStatus_
                { url = endpoint
                , statusCode = 401
                , statusText = "Unauthorized"
                , headers = Dict.empty
                }
                "{\"error\":\"unauthorized\"}"
