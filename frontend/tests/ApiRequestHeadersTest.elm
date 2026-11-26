module ApiRequestHeadersTest exposing (suite)

{-| The one derivation of a request's headers, and the credential it must refuse
to attach.

⛔ **Why this file exists.** `Api.elm` derived the `Authorization` header in 70
independent places, and `frontend/src/` held a 71st in a page module. Two of
those derivations were "shared" — `authedHeaders` for mandatory auth and
`authHeaders` for optional — and between them they covered 12 of 71 call sites.

So a header policy applied to the shared helper applied to a sixth of requests,
which is the project's recorded shape: **the completeness of a header policy is
a fact about its callers, not about the function holding it.** This builder
exists to make the seam the only path.

⛔ **THE CROSS-ORIGIN CASES ARE GONE, AND SO IS THEIR SUBJECT.** This file's
note used to open "the security-relevant case is `CrossOrigin`, and it is not
symmetrical with `SameOrigin`" — the asymmetry being that `CrossOrigin` +
`Session` is the _unlikely_ mistake, while `SameOrigin` beside a foreign URL is
the likely one and was never catchable here.

`Api.Destination` has been deleted: it had no `CrossOrigin` inhabitant left
once the upload PUT turned out to be same-origin, and a decision every call site
must state where one answer is always right is a ritual that made the wrong
answer expressible. So the cases asserting what `CrossOrigin` does are not
weakened — they have no subject.

⚠️ **The property is still guarded, by a script and not yet by the type.** "A
credential never reaches another origin" is held by
`scripts/check-credential-origin.sh`, which requires every `RequestSpec` URL to
lead with a literal path. `Api.Url` — whose constructor cannot build a URL that
leaves our origin — takes over only when `RequestSpec.url` becomes a
`SameOriginUrl`. Until then that gate stays.

-}

import Api
import Expect
import Test exposing (Test, describe, test)
import TestHelpers


suite : Test
suite =
    describe "Api.requestHeaders — the single header derivation"
        [ describe "same-origin requests carry the credential they were given"
            [ test "a Session credential becomes a bearer header" <|
                \() ->
                    Api.requestHeaders "GET" (Api.Session (TestHelpers.creds "tok-abc"))
                        |> Expect.equal [ ( "Authorization", "Bearer tok-abc" ) ]
            , test "an Optional credential that is present becomes the same header" <|
                \() ->
                    Api.requestHeaders "GET" (Api.Optional (Just (TestHelpers.creds "tok-abc")))
                        |> Expect.equal [ ( "Authorization", "Bearer tok-abc" ) ]

            -- ⚠️ `Optional Nothing` and `NoCredential Nothing` both yield no header, and
            -- they are kept as DISTINCT constructors rather than collapsed.
            --
            -- ⛔ NOT for the reason this comment used to give. It said the two
            -- must stay separately nameable because a gate reads the call site
            -- to tell a mandatorily-authenticated endpoint from an
            -- optionally-authenticated one. That is true of `Session` versus
            -- `Optional`, and FALSE of this pair: the gate puts `Optional` and
            -- `NoCredential Nothing` in the same class and cannot distinguish them —
            -- its own suite asserts both classify as not-mandatory.
            --
            -- ⚖️ The reason that survives checking is a DOMAIN one, stated where
            -- the type is declared. `Optional` means the endpoint accepts a
            -- credential when the reader holds one; `NoCredential Nothing` means it
            -- never takes one. Collapsing them makes an endpoint that REFUSES
            -- credentials indistinguishable from one that merely LACKS them —
            -- and `Optional Nothing` cannot even be written at a call site with
            -- no `Maybe` in scope, which is every unauthenticated endpoint.
            --
            -- ⚠️ Recorded at this length because the false version was replaced
            -- in `Api.elm` and left standing here, which is the stale-sibling
            -- shape this project keeps paying for: one justification, three
            -- homes, corrected in one of them.
            , test "an Optional credential that is absent carries nothing" <|
                \() ->
                    Api.requestHeaders "GET" (Api.Optional Nothing)
                        |> Expect.equal []
            , test "NoCredential Nothing carries nothing" <|
                \() ->
                    Api.requestHeaders "GET" (Api.NoCredential Nothing)
                        |> Expect.equal []
            ]

        -- ⛔ THE CROSS-ORIGIN BLOCK WAS HERE, AND IT WENT WITH ITS SUBJECT.
        --
        -- Four cases asserted that no credential constructor could produce a
        -- header at a cross origin, one of them enumerating every constructor
        -- so a new one could not slip past. They were good tests. They are gone
        -- because `Api.Destination` is gone: with no `CrossOrigin` value there
        -- is no call to make, and a test of an unconstructable state is not a
        -- weaker guarantee — it is no statement at all.
        --
        -- ⚠️ WHAT HOLDS THE PROPERTY NOW, AND IT IS NOT YET THE TYPE. "A
        -- credential never reaches another origin" is held today by
        -- `scripts/check-credential-origin.sh`, which parses every
        -- `RequestSpec` builder and requires each URL to lead with a literal
        -- path; it is unchanged and still passing. `Api.Url` replaces it only
        -- once `RequestSpec.url` is a `SameOriginUrl`. Until then the type is
        -- proven but not load-bearing, and that gate is what must not be
        -- deleted.
        , describe "the double-submit proof rides with the credential"
            -- ⛔ THE OMISSION IS AS LOAD-BEARING AS THE INCLUSION. A token sent
            -- on every read trains the server to see the header everywhere, and
            -- the first thing anyone does with a header that is always present
            -- is stop checking it where it matters.
            [ test "a write carries the CSRF token" <|
                \() ->
                    Api.requestHeaders "POST" (Api.Session (Api.credentials "tok" (Just "csrf-abc")))
                        |> Expect.equal
                            [ ( "Authorization", "Bearer tok" )
                            , ( "X-CSRF-Token", "csrf-abc" )
                            ]
            , test "a read does not" <|
                \() ->
                    Api.requestHeaders "GET" (Api.Session (Api.credentials "tok" (Just "csrf-abc")))
                        |> Expect.equal [ ( "Authorization", "Bearer tok" ) ]

            -- ⚠️ Every unsafe verb, enumerated rather than sampled: the rule is
            -- about EFFECT, and a list that covered only POST would let a
            -- `DELETE` ship unproven the first time one was added.
            , test "every state-changing verb carries it" <|
                \() ->
                    [ "POST", "PUT", "PATCH", "DELETE" ]
                        |> List.map
                            (\verb ->
                                Api.requestHeaders verb (Api.Session (Api.credentials "tok" (Just "c")))
                                    |> List.member ( "X-CSRF-Token", "c" )
                            )
                        |> Expect.equal [ True, True, True, True ]

            -- ⚠️ And every safe one, for the same reason in reverse. `HEAD` and
            -- `OPTIONS` are here because the rule is about effect, not about
            -- which verbs this client happens to send today.
            , test "no safe verb carries it" <|
                \() ->
                    [ "GET", "HEAD", "OPTIONS" ]
                        |> List.map
                            (\verb ->
                                Api.requestHeaders verb (Api.Session (Api.credentials "tok" (Just "c")))
                                    |> List.member ( "X-CSRF-Token", "c" )
                            )
                        |> Expect.equal [ False, False, False ]

            -- ⛔ ABSENT, NOT EMPTY. The server has to tell "this client has no
            -- proof" from "this client proved nothing"; an empty-string header
            -- would compare equal to an empty cookie and pass a careless check.
            , test "a write with no CSRF token sends no header at all" <|
                \() ->
                    Api.requestHeaders "POST" (Api.Session (Api.credentials "tok" Nothing))
                        |> Expect.equal [ ( "Authorization", "Bearer tok" ) ]

            -- ⚠️ The origin decision still wins. A cross-origin write must carry
            -- ⚠️ The cross-origin case that sat here — "carries neither the
            -- credential nor the proof", because sending the CSRF token to a
            -- third party hands them the value the scheme rests on — went with
            -- `Api.Destination`. See the note at the top of this file.
            -- ⚠️ The verb is matched case-insensitively, because a method is a
            -- string and nothing stops a call site writing "post".
            , test "a lowercase verb is still recognised as unsafe" <|
                \() ->
                    Api.requestHeaders "post" (Api.Session (Api.credentials "tok" (Just "c")))
                        |> List.member ( "X-CSRF-Token", "c" )
                        |> Expect.equal True
            ]
        , describe "NoCredential carries a proof too, which is what broke the admin gate"
            -- ⛔ THE SECOND HALF OF A DEFECT I FIXED ONCE AND LEFT HALF-DONE.
            -- The proof was reachable only through `Credentials`, so an endpoint
            -- declaring `NoCredential` had none. Fixed for the PLAN path first
            -- (`Effect.public` → `planHeaders`) and NOT for the direct
            -- `Http.request` sites — and `adminLogin`, `adminVerifyMfa`,
            -- `resetPassword` and `requestListingRemoval` are exactly those.
            --
            -- ⚠️ Found by the E2E suite against an enforcing stack: the admin
            -- gate answered "Could not reach the server", which is how the SPA
            -- renders a 403. Driven directly, the server said
            -- `absent_header`. ⚖️ The reason it was missed twice is the same
            -- both times — I measured which `Effect.public` sites were writes
            -- and never asked the same question of the direct ones.
            [ test "a sessionless write declaring NoCredential sends the proof" <|
                \() ->
                    Api.requestHeaders "POST" (Api.NoCredential (Just "proof-abc"))
                        |> Expect.equal [ ( "X-CSRF-Token", "proof-abc" ) ]
            , test "and carries no credential, which is the point of the constructor" <|
                \() ->
                    Api.requestHeaders "POST" (Api.NoCredential (Just "p"))
                        |> List.map Tuple.first
                        |> Expect.equal [ "X-CSRF-Token" ]

            -- ⚠️ A READ declaring NoCredential still sends nothing: the public
            -- catalogue and the transparency metrics pass `Nothing` by design,
            -- and a safe method carries no proof regardless.
            , test "a sessionless READ sends nothing" <|
                \() ->
                    Api.requestHeaders "GET" (Api.NoCredential (Just "p"))
                        |> Expect.equal []

            -- ⚠️ Likewise the "proof must never leave our origin" case: with no
            -- `CrossOrigin` to pass, there is no call to make.
            ]
        , describe "a write with NO session still proves itself"
            -- ⛔ THE DEFECT THIS WAS WRITTEN FOR, and it shipped through 2208
            -- passing tests. The proof began as a field of `Credentials`, which
            -- exists only when there is a bearer — so a signed-OUT visitor had
            -- no way to reach one, and `POST /api/auth/login` is a write
            -- performed by definition without a session.
            --
            -- ⚖️ Found by DRIVING the deployed client, not by reading code: the
            -- real login POST sent `content-type` and nothing else. Every unit
            -- test passed because each one builds a `Credentials` in order to
            -- ask its question — the case with no credential at all is the one
            -- no test thought to build. That is what this describe block is.
            [ test "a sessionless write carries the proof" <|
                \() ->
                    Api.planHeaders "POST" Nothing (Just "proof-abc")
                        |> List.length
                        |> Expect.equal 1
            , test "a sessionless READ carries nothing" <|
                \() ->
                    Api.planHeaders "GET" Nothing (Just "proof-abc")
                        |> Expect.equal []
            , test "a sessionless write with no proof available carries nothing" <|
                \() ->
                    Api.planHeaders "POST" Nothing Nothing
                        |> Expect.equal []

            -- ⚠️ And the resolver's precedence: a reader WITH a session uses
            -- the proof inside their credentials, so a cookie that rotated
            -- since boot does not make consecutive requests disagree.
            , test "a session's own proof wins over the plan's" <|
                \() ->
                    Api.planHeaders "POST" (Just (Api.credentials "tok" (Just "from-session"))) (Just "from-plan")
                        |> List.length
                        |> Expect.equal 2
            ]
        , describe "a session the SPA holds no bearer for"
            -- ⛔ THIS IS THE NORMAL STATE AFTER A RELOAD, and it was
            -- unrepresentable until `cookieSession` existed. The session cookie
            -- is HttpOnly, so JavaScript cannot read it, and `GET
            -- /api/auth/me` answers with the account rather than a token — so a
            -- reader who refreshes the page is genuinely signed in while the
            -- SPA has no bearer to show for it.
            --
            -- ⚖️ What must happen on the wire: NO `Authorization` header, and
            -- the proof still sent. The cookie authenticates the request and
            -- the proof shows it came from a document on our origin. These two
            -- cases are the whole contract.
            [ test "sends the proof and no Authorization header" <|
                \() ->
                    Api.cookieSession (Just "proof")
                        |> (\creds ->
                                Api.requestHeaders "POST" (Api.Session creds)
                           )
                        |> Expect.equal [ ( "X-CSRF-Token", "proof" ) ]

            -- ⚠️ An empty `Bearer ` would be a credential that cannot work sent
            -- as though it could, which is the failure this repository has paid
            -- for in other shapes. The header must be ABSENT, not blank.
            , test "the absent bearer is absent, not an empty Bearer" <|
                \() ->
                    Api.cookieSession (Just "proof")
                        |> (\creds ->
                                Api.requestHeaders "POST" (Api.Session creds)
                           )
                        |> List.map Tuple.first
                        |> Expect.equal [ "X-CSRF-Token" ]
            , -- ⚠️ The third case here used to read the credential back with
              -- `Api.bearerOf` and assert `Nothing`. That accessor is deleted:
              -- its one production caller was the upload stream's `?token=`
              -- URL, and with the stream on the cookie there was nothing left
              -- for it to serve. What it asserted is covered by the two cases
              -- above, which ask the question that matters — what reaches the
              -- wire — rather than whether an accessor agrees with a
              -- constructor.
              test "a cookie-only credential sends NOTHING on a safe method" <|
                \() ->
                    -- ⛔ The empty list is the correct answer and it is worth
                    -- pinning: no `Authorization` because there is no bearer,
                    -- and no proof either because the proof is attached only to
                    -- unsafe methods. A GET must never be refused for failing to
                    -- prove itself, and a harness that added the header here
                    -- would diverge from a browser on the majority of requests.
                    Api.requestHeaders "GET" (Api.Session (Api.cookieSession (Just "proof")))
                        |> Expect.equal []
            ]
        , describe "a refresh replaces the bearer and keeps the proof"
            -- ⛔ THE SILENT-LOSS CASE. A token refresh that rebuilt the whole
            -- credential from the refresh response would drop the CSRF token,
            -- and every subsequent write would stop proving itself — with
            -- nothing failing until enforcement lands, and then everything
            -- failing at once.
            --
            -- ⚖️ The proof is a property of the BROWSING CONTEXT, not of the
            -- session: it comes from a cookie the document can read, and a new
            -- access token does not change which document is asking.
            [ test "the bearer changes" <|
                \() ->
                    Api.credentials "old-bearer" (Just "proof")
                        |> Api.withBearer "new-bearer"
                        |> (\creds -> Api.requestHeaders "GET" (Api.Session creds))
                        |> Expect.equal [ ( "Authorization", "Bearer new-bearer" ) ]
            , test "and the proof is still sent on a write" <|
                \() ->
                    Api.credentials "old-bearer" (Just "proof")
                        |> Api.withBearer "new-bearer"
                        |> (\creds ->
                                Api.requestHeaders "POST" (Api.Session creds)
                           )
                        |> Expect.equal
                            [ ( "Authorization", "Bearer new-bearer" )
                            , ( "X-CSRF-Token", "proof" )
                            ]

            -- ⚠️ And an absent proof stays absent: `withBearer` must not invent
            -- one, or a page that never received a cookie would start claiming
            -- to prove something.
            , test "an absent proof is not conjured" <|
                \() ->
                    Api.credentials "old" Nothing
                        |> Api.withBearer "new"
                        |> (\creds ->
                                Api.requestHeaders "POST" (Api.Session creds)
                           )
                        |> Expect.equal [ ( "Authorization", "Bearer new" ) ]
            ]
        , describe "the derivation is data, so both runtimes convert one value"
            -- ⛔ The headers are returned as `( String, String )` pairs rather
            -- than as `Http.Header`, because `Http.Header` and
            -- `SimulatedEffect.Http.Header` are different opaque types — the
            -- same constraint `Effect.elm` records about `Http.Expect`.
            --
            -- ⚠️ That is what removes the two-derivation defect: production and
            -- the program-test harness each `List.map` this list into their own
            -- header type, so they cannot disagree about WHICH headers a request
            -- carries. They could previously, because each built its own from
            -- the same `Maybe String`.
            [ test "the header name and value are inspectable without a runtime" <|
                \() ->
                    Api.requestHeaders "GET" (Api.Session (TestHelpers.creds "tok-abc"))
                        |> List.map Tuple.first
                        |> Expect.equal [ "Authorization" ]
            ]
        ]
