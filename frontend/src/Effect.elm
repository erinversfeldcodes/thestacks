module Effect exposing (Effect(..), RequestPlan, authed, batch, none, perform, public, sleepThen)

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

@docs Effect, RequestPlan, authed, batch, none, perform, public, sleepThen

-}

import Api
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
    , token : Maybe String
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


{-| A request carrying the reader's credentials.
-}
authed : Api.RequestSpec -> String -> (Http.Response String -> msg) -> Effect msg
authed spec token onResponse =
    Request { spec = spec, token = Just token, onResponse = onResponse }


{-| A request sent without credentials, or with them only if the viewer happens
to have them — the optional-auth endpoints, where the server answers an
anonymous reader too.
-}
public : Api.RequestSpec -> Maybe String -> (Http.Response String -> msg) -> Effect msg
public spec maybeToken onResponse =
    Request { spec = spec, token = maybeToken, onResponse = onResponse }


{-| Wait, then send a Msg — a debounce, a toast that stops being offered.

Modelled rather than left to `Custom` because a program test drives these with
`ProgramTest.advanceTime`, and a delay it cannot see is a delay that never
fires.

-}
sleepThen : Float -> msg -> Effect msg
sleepThen =
    Sleep


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
                , headers = Api.authHeaders plan.token
                , url = plan.spec.url
                , body = Api.specHttpBody plan.spec
                , expect = expectResponse plan.onResponse
                , timeout = Api.standardTimeout
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
