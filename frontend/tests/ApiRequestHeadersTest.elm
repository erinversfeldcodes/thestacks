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

⚠️ **The security-relevant case is `CrossOrigin`, and it is not symmetrical with
the others.** Exactly one request in the file leaves our origin — `putFileToR2`,
a `PUT` to a presigned object-storage URL — and a header-carried bearer token has
**no `SameSite` equivalent** to stop a blind derivation attaching it there. (The
cookie transport is not implicated: `SameSite=Lax` already blocks the cookie
cross-site with no code involved.) So the origin decision has to win over the
credential, and that precedence is what the cases below pin.

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
                    Api.requestHeaders "GET" Api.SameOrigin (Api.Session (TestHelpers.creds "tok-abc"))
                        |> Expect.equal [ ( "Authorization", "Bearer tok-abc" ) ]
            , test "an Optional credential that is present becomes the same header" <|
                \() ->
                    Api.requestHeaders "GET" Api.SameOrigin (Api.Optional (Just (TestHelpers.creds "tok-abc")))
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
                    Api.requestHeaders "GET" Api.SameOrigin (Api.Optional Nothing)
                        |> Expect.equal []
            , test "NoCredential Nothing carries nothing" <|
                \() ->
                    Api.requestHeaders "GET" Api.SameOrigin (Api.NoCredential Nothing)
                        |> Expect.equal []
            ]
        , describe "a cross-origin request never carries a credential"
            -- ⛔ THE CASE THIS BUILDER EXISTS FOR. A caller passing `Session` to
            -- an external URL is the mistake the required argument prevents, and
            -- this asserts the builder refuses it rather than trusting callers
            -- to pass the right credential. The origin decision wins.
            [ test "even when handed a Session credential" <|
                \() ->
                    Api.requestHeaders "GET" Api.CrossOrigin (Api.Session (TestHelpers.creds "tok-abc"))
                        |> Expect.equal []
            , test "even when handed a present Optional credential" <|
                \() ->
                    Api.requestHeaders "GET" Api.CrossOrigin (Api.Optional (Just (TestHelpers.creds "tok-abc")))
                        |> Expect.equal []
            , test "and trivially when handed none" <|
                \() ->
                    Api.requestHeaders "GET" Api.CrossOrigin (Api.NoCredential Nothing)
                        |> Expect.equal []

            -- ⚠️ Stated as its own case because it is the property, not an
            -- example: NO credential value produces a header at a cross origin.
            -- If a future constructor is added and this list is not extended,
            -- that is the gap — so the assertion enumerates every constructor.
            , test "no credential constructor can produce a cross-origin header" <|
                \() ->
                    [ Api.Session (TestHelpers.creds "tok-abc")
                    , Api.Optional (Just (TestHelpers.creds "tok-abc"))
                    , Api.Optional Nothing
                    , Api.NoCredential Nothing
                    ]
                        |> List.map (Api.requestHeaders "GET" Api.CrossOrigin)
                        |> Expect.equal [ [], [], [], [] ]
            ]
        , describe "the double-submit proof rides with the credential"
            -- ⛔ THE OMISSION IS AS LOAD-BEARING AS THE INCLUSION. A token sent
            -- on every read trains the server to see the header everywhere, and
            -- the first thing anyone does with a header that is always present
            -- is stop checking it where it matters.
            [ test "a write carries the CSRF token" <|
                \() ->
                    Api.requestHeaders "POST" Api.SameOrigin (Api.Session (Api.credentials "tok" (Just "csrf-abc")))
                        |> Expect.equal
                            [ ( "Authorization", "Bearer tok" )
                            , ( "X-CSRF-Token", "csrf-abc" )
                            ]
            , test "a read does not" <|
                \() ->
                    Api.requestHeaders "GET" Api.SameOrigin (Api.Session (Api.credentials "tok" (Just "csrf-abc")))
                        |> Expect.equal [ ( "Authorization", "Bearer tok" ) ]

            -- ⚠️ Every unsafe verb, enumerated rather than sampled: the rule is
            -- about EFFECT, and a list that covered only POST would let a
            -- `DELETE` ship unproven the first time one was added.
            , test "every state-changing verb carries it" <|
                \() ->
                    [ "POST", "PUT", "PATCH", "DELETE" ]
                        |> List.map
                            (\verb ->
                                Api.requestHeaders verb Api.SameOrigin (Api.Session (Api.credentials "tok" (Just "c")))
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
                                Api.requestHeaders verb Api.SameOrigin (Api.Session (Api.credentials "tok" (Just "c")))
                                    |> List.member ( "X-CSRF-Token", "c" )
                            )
                        |> Expect.equal [ False, False, False ]

            -- ⛔ ABSENT, NOT EMPTY. The server has to tell "this client has no
            -- proof" from "this client proved nothing"; an empty-string header
            -- would compare equal to an empty cookie and pass a careless check.
            , test "a write with no CSRF token sends no header at all" <|
                \() ->
                    Api.requestHeaders "POST" Api.SameOrigin (Api.Session (Api.credentials "tok" Nothing))
                        |> Expect.equal [ ( "Authorization", "Bearer tok" ) ]

            -- ⚠️ The origin decision still wins. A cross-origin write must carry
            -- neither the credential nor the proof — sending the CSRF token to a
            -- third party would hand them the value the scheme rests on.
            , test "a cross-origin write carries neither" <|
                \() ->
                    Api.requestHeaders "POST" Api.CrossOrigin (Api.Session (Api.credentials "tok" (Just "c")))
                        |> Expect.equal []

            -- ⚠️ The verb is matched case-insensitively, because a method is a
            -- string and nothing stops a call site writing "post".
            , test "a lowercase verb is still recognised as unsafe" <|
                \() ->
                    Api.requestHeaders "post" Api.SameOrigin (Api.Session (Api.credentials "tok" (Just "c")))
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
                    Api.requestHeaders "POST" Api.SameOrigin (Api.NoCredential (Just "proof-abc"))
                        |> Expect.equal [ ( "X-CSRF-Token", "proof-abc" ) ]
            , test "and carries no credential, which is the point of the constructor" <|
                \() ->
                    Api.requestHeaders "POST" Api.SameOrigin (Api.NoCredential (Just "p"))
                        |> List.map Tuple.first
                        |> Expect.equal [ "X-CSRF-Token" ]

            -- ⚠️ A READ declaring NoCredential still sends nothing: the public
            -- catalogue and the transparency metrics pass `Nothing` by design,
            -- and a safe method carries no proof regardless.
            , test "a sessionless READ sends nothing" <|
                \() ->
                    Api.requestHeaders "GET" Api.SameOrigin (Api.NoCredential (Just "p"))
                        |> Expect.equal []

            -- ⛔ And the origin decision still wins: the proof must never leave
            -- our origin, or a third party is handed the value the whole scheme
            -- rests on.
            , test "a cross-origin write sends nothing, proof or not" <|
                \() ->
                    Api.requestHeaders "POST" Api.CrossOrigin (Api.NoCredential (Just "p"))
                        |> Expect.equal []
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
                        |> Api.bearerOf
                        |> Expect.equal "new-bearer"
            , test "and the proof is still sent on a write" <|
                \() ->
                    Api.credentials "old-bearer" (Just "proof")
                        |> Api.withBearer "new-bearer"
                        |> (\creds ->
                                Api.requestHeaders "POST" Api.SameOrigin (Api.Session creds)
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
                                Api.requestHeaders "POST" Api.SameOrigin (Api.Session creds)
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
                    Api.requestHeaders "GET" Api.SameOrigin (Api.Session (TestHelpers.creds "tok-abc"))
                        |> List.map Tuple.first
                        |> Expect.equal [ "Authorization" ]
            ]
        ]
