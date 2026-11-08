module Page.SeamEffectTest exposing (suite)

{-| Requests from two more modules that the harness could not see before.

⛔ **EACH OF THESE EXISTS BECAUSE EXPORTING A SEAM WITHOUT A CONSUMER IS NOT
PROGRESS.** `Page.Feedback` and `Page.Catalogue` build request plans and used to
call `Effect.perform` on them inside `update`/`init`, so the plans never escaped
and `TestHelpers.simulateEffect` had nothing to read.

⚖️ `elm-review` refuses an export nothing consumes, which turns out to be the
right pressure: it means an exported `*WithEffect` is one some test actually
drives, and `scripts/check-effect-seam.sh` counts only exported seams for the
same reason. A seam the module keeps to itself is unreachable, and counting it
would credit progress no test can use.

-}

import Api
import Api.Url
import Effect
import Expect
import Page.Catalogue as Catalogue
import Page.Feedback as Feedback
import Test exposing (Test, describe, test)
import TestHelpers
import Types.RemoteData exposing (RemoteData(..))


{-| Every request a plan tree holds, walking `Batch`.

⚠️ Recursing matters: a module that groups its effects would otherwise report
none, and every assertion below would be vacuously true of an empty list.

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


sendingFeedback : Maybe Api.Credentials -> Effect.Effect Feedback.Msg
sendingFeedback maybeToken =
    let
        drafted =
            { message = "the spine widths look wrong"
            , pageContext = "/bookshelves"
            , sending = NotAsked
            }

        ( _, effect, _ ) =
            Feedback.updateWithEffect Feedback.SendClicked drafted maybeToken
    in
    effect


suite : Test
suite =
    describe "two more modules, read as data"
        [ describe "Page.Feedback"
            [ test "sending feedback posts it" <|
                \() ->
                    sendingFeedback (Just (TestHelpers.creds "tok"))
                        |> plansIn
                        |> List.map (\spec -> ( spec.method, Api.Url.toString spec.url ))
                        |> Expect.equal [ ( "POST", "/api/feedback" ) ]

            -- ⚖️ Not redundant: a module that built its plan regardless of
            -- session would pass the case above while sending a write the
            -- server can only refuse.
            , test "a reader with no session sends nothing" <|
                \() ->
                    sendingFeedback Nothing
                        |> plansIn
                        |> Expect.equal []
            ]
        , describe "Page.Catalogue"
            [ test "opening the catalogue asks for it" <|
                \() ->
                    Catalogue.initWithEffect Nothing
                        |> Tuple.second
                        |> plansIn
                        |> List.map .method
                        |> List.all ((==) "GET")
                        |> Expect.equal True

            -- ⛔ ANTI-VACUITY for the case above: `List.all` is true of an
            -- empty list, so without this a module that asked for nothing at
            -- all would pass it.
            , test "and it asks for something" <|
                \() ->
                    Catalogue.initWithEffect Nothing
                        |> Tuple.second
                        |> plansIn
                        |> List.isEmpty
                        |> Expect.equal False
            ]
        ]
