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


suite : Test
suite =
    describe "Api.requestHeaders — the single header derivation"
        [ describe "same-origin requests carry the credential they were given"
            [ test "a Session credential becomes a bearer header" <|
                \() ->
                    Api.requestHeaders Api.SameOrigin (Api.Session "tok-abc")
                        |> Expect.equal [ ( "Authorization", "Bearer tok-abc" ) ]
            , test "an Optional credential that is present becomes the same header" <|
                \() ->
                    Api.requestHeaders Api.SameOrigin (Api.Optional (Just "tok-abc"))
                        |> Expect.equal [ ( "Authorization", "Bearer tok-abc" ) ]

            -- ⚠️ `Optional Nothing` and `NoCredential` both yield no header, and
            -- they are kept as DISTINCT constructors rather than collapsed. The
            -- difference is not in the output — it is that a gate reads the
            -- call site to tell a mandatorily-authenticated endpoint from an
            -- optionally-authenticated one, so the two must stay separately
            -- nameable even where they behave alike.
            , test "an Optional credential that is absent carries nothing" <|
                \() ->
                    Api.requestHeaders Api.SameOrigin (Api.Optional Nothing)
                        |> Expect.equal []
            , test "NoCredential carries nothing" <|
                \() ->
                    Api.requestHeaders Api.SameOrigin Api.NoCredential
                        |> Expect.equal []
            ]
        , describe "a cross-origin request never carries a credential"
            -- ⛔ THE CASE THIS BUILDER EXISTS FOR. A caller passing `Session` to
            -- an external URL is the mistake the required argument prevents, and
            -- this asserts the builder refuses it rather than trusting callers
            -- to pass the right credential. The origin decision wins.
            [ test "even when handed a Session credential" <|
                \() ->
                    Api.requestHeaders Api.CrossOrigin (Api.Session "tok-abc")
                        |> Expect.equal []
            , test "even when handed a present Optional credential" <|
                \() ->
                    Api.requestHeaders Api.CrossOrigin (Api.Optional (Just "tok-abc"))
                        |> Expect.equal []
            , test "and trivially when handed none" <|
                \() ->
                    Api.requestHeaders Api.CrossOrigin Api.NoCredential
                        |> Expect.equal []

            -- ⚠️ Stated as its own case because it is the property, not an
            -- example: NO credential value produces a header at a cross origin.
            -- If a future constructor is added and this list is not extended,
            -- that is the gap — so the assertion enumerates every constructor.
            , test "no credential constructor can produce a cross-origin header" <|
                \() ->
                    [ Api.Session "tok-abc"
                    , Api.Optional (Just "tok-abc")
                    , Api.Optional Nothing
                    , Api.NoCredential
                    ]
                        |> List.map (Api.requestHeaders Api.CrossOrigin)
                        |> Expect.equal [ [], [], [], [] ]
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
                    Api.requestHeaders Api.SameOrigin (Api.Session "tok-abc")
                        |> List.map Tuple.first
                        |> Expect.equal [ "Authorization" ]
            ]
        ]
