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
import Page.Settings.Profile as Profile
import Test exposing (Test, describe, test)
import TestHelpers
import Types.RemoteData exposing (RemoteData(..))
import Types.User exposing (User)


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


{-| A reader whose account the settings page is editing.
-}
aReader : User
aReader =
    { id = "user-1"
    , email = "reader@example.com"
    , displayName = "A Reader"
    , handle = "a_reader"
    , role = "user"
    , countryCode = Nothing
    , city = Nothing
    , consentAnalytics = False
    , consentWritingAssistant = False
    }


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
        , describe "Page.Settings.Profile"
            -- ⛔ This module was HALF converted, and the gate's first version
            -- credited it as done: it exported `initWithEffect` while `update`
            -- still performed two plans of its own. A name check cannot tell
            -- that from the finished state, which is why the gate now asks
            -- whether every perform sits in a thin wrapper.
            [ test "saving a profile sends one write, through the seam" <|
                \() ->
                    let
                        ( model, _ ) =
                            Profile.initWithEffect
                                (Just (TestHelpers.creds "tok"))
                                aReader

                        ( _, effect, _ ) =
                            Profile.updateWithEffect
                                Profile.SaveProfile
                                model
                                (Just (TestHelpers.creds "tok"))
                    in
                    plansIn effect
                        |> List.map .method
                        |> Expect.equal [ "PUT" ]
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
