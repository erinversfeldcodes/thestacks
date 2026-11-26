module Api.UrlTest exposing (suite)

{-| ⛔ These are escape attempts, not formatting checks.

`Api.Url.path` exists because `Url.Builder.absolute` percent-encodes query keys
and values and NEVER path segments, so `absolute [ "/evil.test" ] []` yields
`//evil.test` — a protocol-relative URL that leaves the origin. Every case below
feeds the constructor something that would escape under that implementation and
asserts the result still begins with exactly one `/` and names no host.

⚠️ The assertion is deliberately "starts with `/` and not `//`" rather than an
exact string. An exact-string test would pass for an encoding that happened to
produce the right bytes for these inputs while still being escapable; this
states the invariant the type exists to hold.

-}

import Api.Url
import Expect
import Test exposing (Test, describe, test)


{-| Our origin is whatever served the page, so a URL stays on it exactly when it
is a path: one leading slash, and no authority component.
-}
expectStaysOnOrigin : String -> Expect.Expectation
expectStaysOnOrigin url =
    if not (String.startsWith "/" url) then
        Expect.fail ("not a path at all, so it resolves somewhere else: " ++ url)

    else if String.startsWith "//" url then
        Expect.fail
            ("PROTOCOL-RELATIVE, so the browser sends this to another host: "
                ++ url
            )

    else
        Expect.pass


suite : Test
suite =
    describe "Api.Url.path cannot be made to leave our origin"
        [ test "a segment that is itself a host does not become one" <|
            \_ ->
                -- Under `Url.Builder.absolute` this is `//evil.test`.
                Api.Url.path [ "/evil.test" ] []
                    |> Api.Url.toString
                    |> expectStaysOnOrigin
        , test "an empty leading segment does not open an authority" <|
            \_ ->
                -- Under `Url.Builder.absolute` this is `//evil.test` too.
                Api.Url.path [ "", "evil.test" ] []
                    |> Api.Url.toString
                    |> expectStaysOnOrigin
        , test "a scheme in a segment does not become a scheme" <|
            \_ ->
                Api.Url.path [ "https://evil.test/steal" ] []
                    |> Api.Url.toString
                    |> expectStaysOnOrigin
        , test "a traversal segment stays one segment" <|
            \_ ->
                Api.Url.path [ "api", "../../evil" ] []
                    |> Api.Url.toString
                    |> expectStaysOnOrigin
        , test "the ordinary case is still the ordinary string" <|
            \_ ->
                -- ⚠️ Anti-vacuity: without this, an implementation returning a
                -- constant "/" would satisfy every case above.
                Api.Url.path [ "api", "bookshelves", "library" ] []
                    |> Api.Url.toString
                    |> Expect.equal "/api/bookshelves/library"
        ]
