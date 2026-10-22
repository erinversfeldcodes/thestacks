module ProgressSaveContract exposing (Classification, ExpectedOut(..), classifications, errorSelector, expectedOut, fixtureDecodes, label, refusedResponse, reportsAnError, response)

{-| How a reading-progress save is CLASSIFIED, written once and driven against
every host that owns a progress card.

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
host maps over `classifications` rather than listing them. That is deliberate: a
behaviour cannot be added to one host and forgotten in the other, and `label`
and `response` below stop compiling until the new variant is described.


## This is a CLASSIFICATION, not the outcome space

⛔ The three constructors below are the branches a host's save handler
DISCRIMINATES, and they were previously named and documented as the outcomes a
save can end in. That was wrong, and the real outcome space is FIVE shapes:
`Api.progressResponseToResult` also produces `ProgressValidationFailed` for a
422 carrying `{errors:…}`, and `BadBody` for a **200 whose body does not
decode**.

⚠️ That last one is the shape that breaks an outcome-space reading: it is a 200
for which an error must appear on screen, so `Succeeded`/`Refused` has nowhere
to put it. And it is driven by no test anywhere — every success path in both
hosts passes a well-formed body.

⚖️ Deliberately NOT expanded to five. Partitioning by classification branch is
what made this table discriminate so cleanly on the real defect, and adding two
rarely-hit shapes would dilute the cases that caught it. The honest fix is the
name: this says which branches exist, not which outcomes do.

-}

import Api
import Components.PlacementCard as PlacementCard
import Dict
import Expect
import Html.Attributes
import Http
import Test exposing (Test, test)
import Test.Html.Selector as Selector


{-| The branches a progress-save handler discriminates.

`SessionRejected` is the case that was missing. It is not a variant of
`Refused`: `Api.isUnauthorized` is 401-only and routes to the deferred
session-expiry net, which may ADOPT a token another tab refreshed and cancel the
logout — so the page is still on screen afterwards, which is precisely when a
stuck in-flight flag becomes permanent rather than invisible behind a redirect.

⛔ OPAQUE ON PURPOSE, and `elm-review` is what noticed it had become possible.
The constructors used to be exposed because each host pattern-matched on them to
decide its own `expectedOut`. Now that the decision lives here, nothing outside
needs them — and keeping them hidden is what stops a host re-acquiring a
per-page judgement about which classification means what. A host can enumerate
`classifications` and ask this module questions; it cannot branch on them.

⚠️ This repository's standing rule is to distrust `elm-review --fix` narrowing
an export, because it will narrow `Msg(..)` back to `Msg` whenever no test
consumes it and that silently undoes a deliberate widening. This narrowing is
the opposite case: the consumer was deliberately REMOVED, so the narrowing
records the improvement rather than erasing one.

-}
type Classification
    = Succeeded
    | Refused
    | SessionRejected


{-| Every classification, in the order a host should report them.
-}
classifications : List Classification
classifications =
    [ Succeeded, Refused, SessionRejected ]


{-| The test name fragment for a classification.
-}
label : Classification -> String
label classification =
    case classification of
        Succeeded ->
            "a save the server accepted"

        Refused ->
            "a save the server refused with a 500"

        SessionRejected ->
            "a save refused with a 401 because the session expired"


{-| The HTTP response for a classification.

`savedBody` is the host's own success payload, because each host's placement has
a different id and the response has to decode against it.

-}
response : String -> String -> Classification -> Http.Response String
response endpoint savedBody classification =
    case classification of
        Succeeded ->
            Http.GoodStatus_
                { url = endpoint
                , statusCode = 200
                , statusText = "OK"
                , headers = Dict.empty
                }
                savedBody

        Refused ->
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


{-| The server-refused response, without exposing which constructor it is.

⛔ `Classification` is OPAQUE, so a host cannot name `Refused` — which is the
constraint that keeps a host from re-acquiring a per-page judgement about which
classification means what. A host that needs a specific response therefore asks
for it by name here rather than constructing it.

⚠️ Same principle as `fixtureDecodes`: move the thing that needs the type to
where the type is visible, rather than widening the type.

-}
refusedResponse : String -> String -> Http.Response String
refusedResponse endpoint savedBody =
    response endpoint savedBody Refused


{-| Whether the host must have an error on screen after this classification.

⛔ "Not stuck" and "says why" are different claims, and asserting only the first
let the minimal wrong fix through: settle the in-flight flag, surface nothing,
and the reader gets a re-enabled Save button with a save that silently vanished.
`ensureViewHasNot "Saving…"` says nothing at all about the message.

Both hosts render their failure through a `progress-error` test id — `ReadingPile`
via `viewSaveState`, `BookDetail` via `viewProgressSaveState` — so this is a
claim a shared table can make about either of them.

⛔ DERIVED FROM `Api`, NOT WRITTEN DOWN. This used to be a hand-maintained
`Classification -> Bool` table, and it was the one field here encoding a
JUDGEMENT rather than data. The failure mode is specific: when such a judgement
is wrong for ONE host the assertion fails loudly for whichever host is right,
but when it is wrong and ALL hosts agree with it, nothing fails — and
convergence across hosts is the exact class this table exists to catch. So the
table could catch hosts disagreeing with each other and could never catch
itself.

⚖️ Deriving it makes the claim behavioural: _the host surfaces an error exactly
when `Api` says the response is an error_. There is nothing to keep in sync, and
a classification added later gets the right answer without anyone deciding —
including the undecodable 200 described above, which a hand-written table would
have got wrong, because it is a 200 that must report an error.

⚠️ `SessionRejected` reports an error like any other failure, and that now falls
out of the derivation rather than being asserted: the save did not happen, and
the session hand-off may be CANCELLED a tick later when another tab's token is
adopted — so a reader who stays on the page must be told, not left to infer it
from a button that went quiet.

-}
reportsAnError : String -> String -> Classification -> Bool
reportsAnError endpoint savedBody classification =
    case Api.progressResponseToResult (response endpoint savedBody classification) of
        Err _ ->
            True

        Ok _ ->
            False


{-| The out-message a host must emit, named independently of any host's type.

⛔ THE HOST-INDEPENDENT EXPECTATION BELONGS HERE, and leaving it per-host was a
real hole rather than a tidiness point. Each host used to carry its own
`expectedOut : Classification -> OutMsg`, so the table fixed which CASES exist
while each host decided what it owed in them — and a host that stopped emitting
its session-expiry message could be made green by editing its own fixture, with
the compiler's blessing. `SessionRejected` producing a session expiry is not a
per-page judgement.

⚠️ `OutMsg` is genuinely per-host (`BookDetail.OutMsg` and
`ReadingPile.OutMsg` are different types), so what is shared is the DECISION and
what stays local is only the spelling: each host maps these two constructors to
its own. That is a one-line translation the compiler checks exhaustively, rather
than a three-case fixture it can quietly disagree with.

-}
type ExpectedOut
    = NoOutMsg
    | SessionExpiryOut


expectedOut : Classification -> ExpectedOut
expectedOut classification =
    case classification of
        Succeeded ->
            NoOutMsg

        Refused ->
            NoOutMsg

        SessionRejected ->
            SessionExpiryOut


{-| The selector every host renders its save failure through.

⛔ THE LAST HAND-MAINTAINED SHARED CONSTANT, and it was duplicated four times
across the two hosts — a pair that has diverged four times in four review
rounds. A shared claim spelled separately in each host is a claim each host can
drift out of silently, which is the whole reason this module exists.

`ReadingPile` renders it via `viewSaveState`, `BookDetail` via
`viewProgressSaveState`, both as `data-testid` carrying
`PlacementCard.progressErrorId` — the one authority for that string.

-}
errorSelector : Selector.Selector
errorSelector =
    Selector.attribute
        (Html.Attributes.attribute "data-testid" PlacementCard.progressErrorId)


{-| `Succeeded` must be the error-free classification, for THIS host's fixture.

⛔ AN IDENTITY CLAIM, WHERE THE HOSTS COULD ONLY MAKE A CARDINALITY ONE. Each
host used to assert "exactly one classification is error-free", which is
equivalent to what it is named for only because of a property of the OTHER two
fixtures — `Refused` (500) and `SessionRejected` (401) are `Err` under any body.
A host cannot do better, because `Classification`'s constructors are opaque so
it cannot name `Succeeded`. This module can, so the claim belongs here and is
exact rather than a proxy.

⚠️ That is the second instance of the abstraction we chose constraining the
assertion we could write; the first was `expectedOut`, where `OutMsg` not being
derivable set the floor on how far that hole could close. Worth noticing as a
pattern rather than twice as a surprise: opacity buys a guarantee and spends
some expressiveness, and the right response is to move the assertion to where
the type is visible — not to widen the type.

⛔ WHAT IT CATCHES, measured. Rename one key in a host's success body so it stops
decoding and every other case in that host still passes — the whole suite green
at 2180/0 — because `reportsAnError Succeeded` flips to `True`, the host
genuinely renders its error so the presence check passes, `expectedOut Succeeded`
is `NoOutMsg` and a non-401 failure emits no out-message, and the in-flight flag
settles either way. That host's `Succeeded` case silently becomes a second copy
of its `Refused` case, still named "a save the server accepted".

⚠️ Reachable BECAUSE `progressDecoder` is deliberately fail-loud: a server field
rename stops both hosts' bodies decoding at once, so both success cases become
refusal cases together and nothing else in either host notices.

⚖️ The general form: **deriving an expectation moves the trust to the
derivation's inputs, so every input needs its own assertion.** `savedBody` is
supplied by each host — the least-examined party — and had none.

-}
fixtureDecodes : String -> String -> Test
fixtureDecodes endpoint savedBody =
    -- ⚖️ TWO NAMED TESTS, NOT ONE WITH TWO CLAIMS. They were a single
    -- `Expect.all`, and a reviewer pointed out the cost: the test was named for
    -- the identity half, so a COLLAPSE one layer down would red a test saying
    -- "this host's success fixture decodes" — pointing at the wrong cause.
    -- "Reds by name" has been this campaign's evidence standard in every probe,
    -- so a name pointing at the wrong cause is a real cost, and the lambdas were
    -- already independent claims over `()`.
    --
    -- IDENTITY — `Succeeded` specifically must be error-free. A host cannot
    -- assert this: `Classification`'s constructors are opaque, so it could only
    -- ever assert the cardinality and rely on a property of the OTHER two
    -- fixtures to make them equivalent.
    --
    -- CARDINALITY — exactly one classification is error-free. Identity alone
    -- loses collapse detection: a mapping returning `Ok` for everything would
    -- satisfy the identity claim while measuring nothing, and collapse is
    -- fixture-INDEPENDENT.
    Test.describe "the derivation holds for this host"
        [ test "this host's success fixture decodes, so Succeeded is not a second Refused" <|
            \() ->
                reportsAnError endpoint savedBody Succeeded
                    |> Expect.equal False
        , test "exactly one classification is error-free, so the derivation cannot collapse" <|
            \() ->
                classifications
                    |> List.filter
                        (\c -> not (reportsAnError endpoint savedBody c))
                    |> List.length
                    |> Expect.equal 1
        ]
