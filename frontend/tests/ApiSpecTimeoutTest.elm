module ApiSpecTimeoutTest exposing (suite)

{-| How long a request may hang, and why it is decided by what the request carries.

⛔ WHAT THIS GUARDS, AND WHAT IT CANNOT. `Api.putUploadBytes` used to set
`uploadTimeout` — two minutes — where every other request used `standardTimeout`,
fifteen seconds. When the upload moved onto a plan, `Effect.perform` hardcoded
the latter, which would have cut large uploads to an eighth of their time on a
slow connection. `Api.specTimeout` fixed that by deriving the timeout from the
body rather than from a field someone must remember to set.

⚠️ **THE FILE BRANCHES ARE UNREACHABLE FROM HERE.** `elm/file` declares
`type File = File` with a decoder and no constructor, so no test in this project
can build one, and `FileBody`/`MultipartFile` cannot be passed to `specTimeout`.
MEASURED: cutting `FileBody` back to `standardTimeout` left the whole suite —
2270 tests — green. That half is checked by `scripts/check-http-timeouts.sh`,
which reads the branches out of the source and fails if either stops returning
`uploadTimeout`.

⚖️ So these cases cover the half a unit test CAN reach, and they are not
redundant with the gate: the gate asserts the file branches are right, and these
assert the non-file branches have not drifted the other way. Giving every
ordinary request two minutes would leave a reader watching a stalled page eight
times longer than they should, and the gate says nothing about that.

-}

import Api
import Api.Url
import Expect
import Json.Encode as Encode
import Test exposing (Test, describe, test)


{-| A spec carrying the given body. Method and url are irrelevant — the claim is
entirely about the body.
-}
specWith : Api.RequestBody -> Api.RequestSpec
specWith body =
    { method = "POST"
    , url = Api.Url.path [ "api", "irrelevant" ] []
    , body = body
    }


suite : Test
suite =
    describe "Api.specTimeout"
        [ -- ⛔ ANTI-VACUITY, and it comes first because everything below rests on
          -- it. If `uploadTimeout` were ever edited to equal `standardTimeout`,
          -- every assertion here would still hold while the distinction they
          -- exist to protect had quietly evaporated.
          test "the two timeouts are actually different" <|
            \() ->
                Expect.notEqual Api.standardTimeout Api.uploadTimeout
        , describe "a request carrying no file gets the standard timeout"
            [ test "an empty body" <|
                \() ->
                    Api.specTimeout (specWith Api.NoBody)
                        |> Expect.equal Api.standardTimeout
            , test "a JSON body" <|
                \() ->
                    Api.specTimeout (specWith (Api.JsonBody (Encode.object [])))
                        |> Expect.equal Api.standardTimeout

            -- ⛔ THE DRIFT THAT WOULD HURT EVERY READER. The two-minute wait
            -- exists for bytes on a slow connection. Handing it to ordinary
            -- requests would leave someone staring at a stalled page for two
            -- minutes instead of fifteen seconds — a worse outcome than the
            -- regression that prompted `specTimeout`, and in the opposite
            -- direction, so it needs its own assertion rather than an
            -- `Expect.equal` that happens to exclude it.
            , test "a JSON body does NOT inherit the upload timeout" <|
                \() ->
                    Api.specTimeout (specWith (Api.JsonBody (Encode.object [])))
                        |> Expect.notEqual Api.uploadTimeout
            , test "an empty body does NOT inherit the upload timeout" <|
                \() ->
                    Api.specTimeout (specWith Api.NoBody)
                        |> Expect.notEqual Api.uploadTimeout
            ]
        ]
