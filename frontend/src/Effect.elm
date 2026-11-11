module Effect exposing
    ( Effect(..), RequestPlan, authed, batch, none, perform, public, sleepThen
    , map
    )

{-| What an `update` asks the runtime to do, described as data instead of as an
opaque `Cmd`.

`elm-program-test` cannot run a real `Http.request`, so a page whose update
returns `Cmd` leaves its harness no choice but to decide a second time, by hand,
which request each Msg fires. The two decisions then each pass their own tests
while disagreeing with each other — blanking `Page.BookDetail`'s formats
dispatch, and swapping `Page.Upload`'s duplicate-book callback for its
identified-book one, each left the WHOLE Elm suite green. A page that returns
its effects as data has exactly one decision, and the harness reads it rather
than guessing it.

`Custom` is the escape hatch for effects with no request in them — a file
picker, a focus task, navigation. The harness has never simulated those and
still does not; but a request smuggled inside one is invisible to it, so
anything HTTP belongs in `Request`.

There are two ways to make a request, and the difference between them is what a
401 means. `authed` carries a credential the endpoint requires, so a 401 is the
session ending and the constructor will not build without a msg for it.
`public` carries one only if the viewer happens to have it, so a 401 is the
server's answer and belongs to the handler that asked.

@docs Effect, RequestPlan, authed, batch, none, perform, public, sleepThen

-}

import Api
import Api.Url
import Http
import Process
import Task


{-| An effect, as data.
-}
type Effect msg
    = None
    | Batch (List (Effect msg))
    | Request (RequestPlan msg)
    | Sleep Float msg
    | Custom (Cmd msg)


{-| One request: what to send (`Api.RequestSpec`), whose credentials to send it
with, and how its response becomes a Msg.

The response mapping is a plain function rather than an `Http.Expect` because
`Http.Expect` and `SimulatedEffect.Http.Expect` are different opaque types —
neither runtime can accept the other's. A `Http.Response String -> msg` is what
both can wrap.

-}
type alias RequestPlan msg =
    { spec : Api.RequestSpec
    , token : Maybe Api.Credentials
    , proof : Maybe String
    , onResponse : Http.Response String -> msg
    }


{-| No effect.
-}
none : Effect msg
none =
    None


{-| Several effects at once.
-}
batch : List (Effect msg) -> Effect msg
batch =
    Batch


{-| A request carrying the reader's credentials, and the handler for the one
failure every such request can suffer: the session is gone.

⛔ THE RECORD IS THE GATE, and it is the same gate `Api.authed` holds. With a
bare token and a single callback, a 401 was just another `Err` and noticing it
was opt-in — which is how three settings forms came to render "something went
wrong" against a dead session. `onExpired` cannot be omitted, defaulted or
inferred, so a call site that ignores expiry does not compile.

⚠️ Not a `Maybe`, deliberately. The mistake this prevents is FORGETTING, and an
optional field is forgettable twice over: once by the hurried caller who passes
`Nothing`, and once by the reviewer for whom `Nothing` looks like a decision.

⚖️ Use `public` instead when the endpoint answers an anonymous reader. There a
401 is the server's answer to the request, not the end of a session, and the
handler that asked the question is the one that must hear it — see
`Api.interceptExpiry`, which both authenticated paths share and no public one
reaches.

⚠️ `scripts/check-session-expiry-coverage.sh` reads THIS FUNCTION'S NAME to
decide which pages send an authenticated request, so call it here rather than
wrapping it in a per-page helper — the same note `Api.authedHeaders` carries,
for the same reason. A page whose plans are built through a local alias drops
out of that gate's population without anything reporting it.

-}
authed :
    Api.RequestSpec
    -> Api.Credentials
    -> { onExpired : msg, onResponse : Http.Response String -> msg }
    -> Effect msg
authed spec token handlers =
    -- ⚠️ No plan-level proof needed: a signed-in reader's proof travels inside
    -- their credentials. `Api.planHeaders` resolves which source to use.
    --
    -- ⛔ The 401 is resolved HERE, into the plan's single response mapping,
    -- rather than being carried as a second field for each runtime to branch on.
    -- `Effect.perform` and `TestHelpers.simulateEffect` are two interpreters of
    -- the same plan, and this module exists because two interpreters deciding
    -- the same thing separately is how a request's dispatch drifted while both
    -- sides stayed green. The expiry decision is not given the chance.
    Request
        { spec = spec
        , token = Just token
        , proof = Nothing
        , onResponse = Api.interceptExpiry handlers.onExpired handlers.onResponse
        }


{-| A request sent without credentials, or with them only if the viewer happens
to have them — the optional-auth endpoints, where the server answers an
anonymous reader too.

⛔ NO EXPIRY OBLIGATION HERE, and that is the difference between this and
`authed` rather than an oversight. A 401 from an endpoint that serves anonymous
readers does not mean a session ended: `POST /api/auth/login` is performed
without a session by definition, and its 401 is "wrong password" — copy the
reader needs to see on the form they are standing in front of. Routing it to the
session-expiry interceptor would bounce a visitor who was never signed in.

⚠️ So a 401 on a public plan reaches `onResponse` like any other status, and the
page handling it decides what it means. If a request MUST carry a credential,
that is `authed`'s job and the obligation comes with it; reaching for `public`
with a token in hand to avoid naming an expiry msg moves an endpoint down the
ladder, not sideways.

-}
public : Api.RequestSpec -> Maybe Api.Credentials -> Maybe String -> (Http.Response String -> msg) -> Effect msg
public spec maybeToken proof onResponse =
    -- ⛔ The proof is a SEPARATE argument here, and that is the fix for a real
    -- defect: a signed-out visitor has no credentials, so a plan that could
    -- only find a proof inside one sent none — and `POST /api/auth/login` is
    -- performed by definition without a session. Found by driving the deployed
    -- preview; 2208 unit tests passed throughout.
    Request { spec = spec, token = maybeToken, proof = proof, onResponse = onResponse }


{-| Wait, then send a Msg — a debounce, a toast that stops being offered.

Modelled rather than left to `Custom` because a program test drives these with
`ProgramTest.advanceTime`, and a delay it cannot see is a delay that never
fires.

-}
sleepThen : Float -> msg -> Effect msg
sleepThen =
    Sleep


{-| Re-label a child's effects as the parent's.

⛔ **THIS IS WHAT LETS THE SEAM REACH A PAGE THAT DELEGATES.** A page holding a
child component wraps the child's `Cmd` with `Cmd.map`, which works — and which,
once the page returns `Effect`, would force the child's effects into `Custom`.
⚠️ That is the worst available outcome: `Custom` is for effects with **no
request in them**, so burying a child's request there hides it from the harness
while looking like progress. `Custom (Cmd.map …)` is the shape to refuse.

⚖️ Mapping preserves the plan AS DATA all the way up, so a parent's
`ProgramTest` can read a request its child built — the module's opening claim,
applied one level down.

-}
map : (a -> b) -> Effect a -> Effect b
map f effect =
    case effect of
        None ->
            None

        Batch effects ->
            Batch (List.map (map f) effects)

        Request plan ->
            Request
                { spec = plan.spec
                , token = plan.token
                , proof = plan.proof
                , onResponse = plan.onResponse >> f
                }

        Sleep ms msg ->
            Sleep ms (f msg)

        Custom cmd ->
            Custom (Cmd.map f cmd)


{-| Run an effect for real. `TestHelpers.simulateEffect` is the other
interpreter; between them they are the only two places that turn one of these
into something a runtime executes.
-}
perform : Effect msg -> Cmd msg
perform effect =
    case effect of
        None ->
            Cmd.none

        Batch effects ->
            Cmd.batch (List.map perform effects)

        Request plan ->
            Http.request
                { method = plan.spec.method
                , headers = Api.planHeaders plan.spec.method plan.token plan.proof
                , url = Api.Url.toString plan.spec.url
                , body = Api.specHttpBody plan.spec
                , expect = expectResponse plan.onResponse
                , timeout = Api.specTimeout plan.spec
                , tracker = Nothing
                }

        Sleep millis msg ->
            Process.sleep millis |> Task.perform (\_ -> msg)

        Custom cmd ->
            cmd


{-| `Http.expectStringResponse` with the resolving already done: the plan's
mapping is total, so there is no failure branch left for `elm/http` to report.
-}
expectResponse : (Http.Response String -> msg) -> Http.Expect msg
expectResponse onResponse =
    Http.expectStringResponse
        (\result ->
            case result of
                Ok msg ->
                    msg

                Err impossible ->
                    never impossible
        )
        (Ok << onResponse)
