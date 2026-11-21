module MainEffectTest exposing (suite)

{-| Main's own first request — the boot identity resolve — read as data through
the effects seam, the way a converted page's requests are. Before this, Main
performed its own requests in place, so no harness could see them: the plan
escaped as a `Cmd` the moment it was built. `resolveIdentityEffect` returns the
plan instead, and `resolveIdentity` performs it once.
-}

import Api
import Api.Url
import Effect
import Expect
import Main
import Test exposing (Test, describe, test)


{-| Every request a plan tree holds, walking `Batch` — the same reader the
page-level `SeamEffectTest` uses. Recursing matters: a grouped effect would
otherwise report none and every assertion below would be vacuously true of an
empty list.
-}
plansIn : Effect.Effect msg -> List Api.RequestSpec
plansIn effect =
    case effect of
        Effect.Request plan ->
            [ plan.spec ]

        Effect.Batch effects ->
            List.concatMap plansIn effects

        _ ->
            []


suite : Test
suite =
    describe "Main reads its own requests as data"
        [ test "the boot identity resolve is a readable GET /api/auth/me plan" <|
            \() ->
                Main.resolveIdentityEffect (Just "the-proof")
                    |> plansIn
                    |> List.map (\spec -> ( spec.method, Api.Url.toString spec.url ))
                    |> Expect.equal [ ( "GET", "/api/auth/me" ) ]

        -- ⚖️ Anti-vacuity: `plansIn` returns [] for a plan-free effect, so the
        -- exact-match above is a real constraint on Main's request rather than a
        -- vacuous truth over an empty list.
        , test "a plan-free effect yields no requests, so plansIn can be empty" <|
            \() ->
                plansIn Effect.none
                    |> Expect.equal []
        ]
