module Components.BlockUserModalEffectTest exposing (suite)

{-| What the block modal actually asks the server for.

⛔ **THIS TEST COULD NOT HAVE BEEN WRITTEN BEFORE THE SEAM.** `BlockUserModal`
built its request plan and called `Effect.perform` on it inside `update`, so the
plan never escaped the module. `TestHelpers.simulateEffect` can only read an
`Effect` that escapes — which meant the request this component sends was exactly
as opaque to the harness as the raw `Http.request` it replaced, and nothing in
2276 tests asserted it.

⚖️ That was true of 25 of 42 plan-building modules. The claim `Effect`'s
docstring makes — "A page that returns its effects as data has exactly one
decision, and the harness reads it rather than guessing it" — held for 17 of
them, and this file is the first evidence that it now holds for one more.

⚠️ Reading the plan as DATA is the point, rather than driving a `ProgramTest`
and asserting on a simulated response: the thing that was missing is the ability
to see the request at all.

-}

import Api
import Api.Url
import Components.BlockUserModal as BlockUserModal
import Effect
import Expect
import Test exposing (Test, describe, test)
import TestHelpers


{-| The plan a Msg produces, or `Nothing` when it produces no request.

⚠️ Walks `Batch` so a plan wrapped in one is still found — otherwise this helper
would report "no request" for a module that merely groups its effects, which is
the sort of false negative that makes a test look like coverage.

-}
planFrom : Effect.Effect msg -> Maybe Api.RequestSpec
planFrom effect =
    case effect of
        Effect.Request plan ->
            Just plan.spec

        Effect.Batch effects ->
            List.filterMap planFrom effects |> List.head

        _ ->
            Nothing


blockEffect : Maybe Api.Credentials -> Effect.Effect BlockUserModal.Msg
blockEffect maybeToken =
    let
        ( _, effect, _ ) =
            BlockUserModal.updateWithEffect
                BlockUserModal.BlockConfirmed
                (BlockUserModal.init { userId = "reader-77", displayName = "A Reader" })
                maybeToken
    in
    effect


suite : Test
suite =
    describe "BlockUserModal, read as data"
        [ test "confirming a block asks the server to block that reader" <|
            \() ->
                blockEffect (Just (TestHelpers.creds "tok"))
                    |> planFrom
                    |> Maybe.map (.url >> Api.Url.toString)
                    |> Expect.equal (Just "/api/users/reader-77/block")

        -- ⛔ ANTI-VACUITY, and it is the half that makes the case above mean
        -- something. If `updateWithEffect` returned `Effect.None` for every
        -- input, `planFrom` would answer `Nothing` and the assertion would be
        -- about a helper rather than about the component.
        , test "and it is a POST, not a read" <|
            \() ->
                blockEffect (Just (TestHelpers.creds "tok"))
                    |> planFrom
                    |> Maybe.map .method
                    |> Expect.equal (Just "POST")

        -- ⚖️ The signed-out case is not redundant: a component that built its
        -- plan unconditionally would pass both assertions above while sending a
        -- credential-less write the server can only refuse.
        , test "a viewer with no session sends nothing at all" <|
            \() ->
                blockEffect Nothing
                    |> planFrom
                    |> Expect.equal Nothing
        ]
