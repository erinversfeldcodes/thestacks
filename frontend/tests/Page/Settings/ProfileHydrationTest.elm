module Page.Settings.ProfileHydrationTest exposing (suite)

{-| Program tests for Settings → Profile hydrating from the server.

The page opens with the stored login blob in its fields — which carries a
display name and an email and nothing else, no country, no city, no website.
These drive the real `initWithEffect` through the simulated runtime and assert
that what the reader ends up looking at is the account the server holds, not
the blob that seeded the form.

The blob values here differ from the server's in every field the server also
answers — three of them wrong, three of them (website, country, city) absent,
because the blob has no way to carry those at all. Either way no assertion below
can pass on a coincidence.

-}

import Effect
import Expect
import Html.Attributes as Attr
import Http
import Json.Encode as Encode
import Page.Settings.Profile as Profile exposing (Msg(..))
import ProgramTest exposing (ProgramDefinition, SimulatedEffect)
import SimulatedEffect.Cmd
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import TestHelpers
import Types.RemoteData exposing (RemoteData(..))
import Types.User exposing (User)


suite : Test
suite =
    describe "Page.Settings.Profile — account hydration (ProgramTest)"
        [ blobSeedsTheFormBeforeTheAnswer
        , responseWinsOverBlob
        , responseRebaselinesTheEmailComparison
        , anEditIsNotClobbered
        , typingOneFieldDoesNotBlankTheRest
        , failureSaysSoRatherThanLying
        , savesAreShutUntilTheAccountArrives
        , savesStayShutAfterAFailedRead
        , anonymousAsksNothing
        ]


{-| What `stacks-auth` in localStorage can reconstruct: identity, and nothing
about the account. Every value here is stale relative to `serverJson`.
-}
blobUser : User
blobUser =
    { id = "user-1"
    , email = "old@example.com"
    , displayName = "Old Name"
    , handle = "old_handle"
    , role = "user"
    , countryCode = Nothing
    , city = Nothing
    , consentAnalytics = False
    , consentWritingAssistant = False
    }


{-| The `GET /api/auth/me` body, in the shape `ProtoJSON.user/1` serialises.
-}
serverJson : String
serverJson =
    Encode.encode 0
        (Encode.object
            [ ( "user"
              , Encode.object
                    [ ( "id", Encode.string "user-1" )
                    , ( "email", Encode.string "ada@example.com" )
                    , ( "display_name", Encode.string "Ada Lovelace" )
                    , ( "handle", Encode.string "ada" )
                    , ( "role", Encode.string "user" )
                    , ( "country_code", Encode.string "GB" )
                    , ( "city", Encode.string "London" )
                    , ( "website_url", Encode.string "https://ada.dev" )
                    ]
              )
            ]
        )


start : ProgramTest.ProgramTest Profile.Model Profile.Msg (SimulatedEffect Profile.Msg)
start =
    ProgramTest.start () (program (Just "test-token"))


{-| The page's own `initWithEffect`, run in the simulated runtime — so a
hydration removed from production is a hydration removed from this test.

`update`'s `Cmd` is discarded, which is right for the hydration lifecycle these
tests drive: nothing in it dispatches a follow-up request. ⚠️ The save paths DO,
and this harness would see none of it — a test here that clicks Save Profile
would silently observe no request at all. Give the page an `updateWithEffect`
before adding one.

-}
program : Maybe String -> ProgramDefinition () Profile.Model Profile.Msg (SimulatedEffect Profile.Msg)
program maybeToken =
    ProgramTest.createElement
        { init =
            \() ->
                Profile.initWithEffect maybeToken blobUser
                    |> Tuple.mapSecond TestHelpers.simulateEffect
        , update =
            \msg model ->
                let
                    ( newModel, _, _ ) =
                        Profile.update msg model maybeToken
                in
                ( newModel, SimulatedEffect.Cmd.none )
        , view = Profile.view
        }
        |> ProgramTest.withSimulatedEffects identity


{-| A field's rendered value, found by the placeholder its label sits above.
-}
fieldValue : String -> Profile.Model -> Query.Single Msg
fieldValue placeholder model =
    Profile.view model
        |> Query.fromHtml
        |> Query.findAll [ Selector.attribute (Attr.attribute "placeholder" placeholder) ]
        |> Query.first


blobSeedsTheFormBeforeTheAnswer : Test
blobSeedsTheFormBeforeTheAnswer =
    test "the form is filled from the stored session before the server answers" <|
        \() ->
            start
                |> ProgramTest.expectViewHas
                    [ Selector.attribute (Attr.value "Old Name") ]


responseWinsOverBlob : Test
responseWinsOverBlob =
    test "the server's account replaces the stored session's values in every field" <|
        \() ->
            start
                |> ProgramTest.simulateHttpOk "GET" "/api/auth/me" serverJson
                |> ProgramTest.expectModel
                    (\model ->
                        Expect.all
                            [ \m -> m.displayName |> Expect.equal "Ada Lovelace"
                            , \m -> m.handle |> Expect.equal "ada"
                            , \m -> m.email |> Expect.equal "ada@example.com"
                            , \m -> m.websiteUrl |> Expect.equal "https://ada.dev"
                            , \m -> m.countryCode |> Expect.equal "GB"
                            , \m -> m.city |> Expect.equal "London"

                            -- The baselines the change-detection compares
                            -- against move too, or an untouched field reads as
                            -- edited: a handle rebaselined on the blob's value
                            -- is sent on the next save and overwrites the real
                            -- one.
                            , \m -> m.initialHandle |> Expect.equal "ada"
                            , \m -> m.initialEmail |> Expect.equal "ada@example.com"
                            , \m ->
                                fieldValue "Your city" m
                                    |> Query.has [ Selector.attribute (Attr.value "London") ]
                            , \m ->
                                fieldValue "US, GB, ZA, etc." m
                                    |> Query.has [ Selector.attribute (Attr.value "GB") ]
                            ]
                            model
                    )


{-| The absence half of this is satisfied by the pre-state too — the blob's email
equals its own baseline, so the prompt is hidden before hydration as well. So the
presence half comes first: edit away from the SERVER's email and the prompt must
appear, which proves the baseline moved. Only then does its absence mean the
server's own address is not being read as a change.
-}
responseRebaselinesTheEmailComparison : Test
responseRebaselinesTheEmailComparison =
    test "the server's email becomes the baseline, so it is not read as a change" <|
        \() ->
            start
                |> ProgramTest.simulateHttpOk "GET" "/api/auth/me" serverJson
                |> ProgramTest.ensureViewHasNot [ currentPasswordPrompt ]
                |> ProgramTest.update (SetEmail "someone-else@example.com")
                |> ProgramTest.ensureViewHas [ currentPasswordPrompt ]
                |> ProgramTest.update (SetEmail "ada@example.com")
                |> ProgramTest.expectViewHasNot [ currentPasswordPrompt ]


currentPasswordPrompt : Selector.Selector
currentPasswordPrompt =
    Selector.attribute (Attr.attribute "placeholder" "Confirm your current password")


anEditIsNotClobbered : Test
anEditIsNotClobbered =
    test "a value typed before the answer arrives survives it" <|
        \() ->
            start
                |> ProgramTest.update (SetCity "Edinburgh")
                |> ProgramTest.simulateHttpOk "GET" "/api/auth/me" serverJson
                |> ProgramTest.expectModel
                    (\model -> model.city |> Expect.equal "Edinburgh")


typingOneFieldDoesNotBlankTheRest : Test
typingOneFieldDoesNotBlankTheRest =
    test "typing in one field still lets the server fill the others" <|
        \() ->
            -- The reader types a city before the account lands. Every OTHER
            -- field must still take the server's value.
            --
            -- This is the data-loss path: hydration used to be all-or-nothing on
            -- a single `edited` flag, so one keystroke left the whole form on the
            -- boot blob — which carries NO website at all — while
            -- `AccountReceived` unlocked both Save buttons anyway. Saving then
            -- wrote `websiteUrl = ""` and a stale handle over values the reader
            -- had never seen. The website is the sharp assertion: the blob cannot
            -- carry one, so `""` here means the blank would have been saved.
            start
                |> ProgramTest.update (SetCity "Edinburgh")
                |> ProgramTest.simulateHttpOk "GET" "/api/auth/me" serverJson
                |> ProgramTest.expectModel
                    (\model ->
                        Expect.all
                            [ \m -> m.city |> Expect.equal "Edinburgh"
                            , \m -> m.websiteUrl |> Expect.notEqual ""
                            , \m -> m.websiteUrl |> Expect.equal "https://ada.dev"
                            , \m -> m.handle |> Expect.equal "ada"
                            , \m -> m.countryCode |> Expect.equal "GB"
                            ]
                            model
                    )


failureSaysSoRatherThanLying : Test
failureSaysSoRatherThanLying =
    test "a failed read says the fields may be stale instead of presenting them as the account" <|
        \() ->
            start
                |> ProgramTest.simulateHttpResponse "GET" "/api/auth/me" Http.NetworkError_
                |> ProgramTest.expectViewHas
                    [ Selector.text "We could not read your saved profile from the library, so these fields may be out of date. Reload the page to try again." ]


{-| The form posts every field, and the placeholder has no website and no
location in it — so a save landed before the account arrives writes those blanks
over values the reader never saw. Both buttons are shut until the page has read
what a save would overwrite.
-}
savesAreShutUntilTheAccountArrives : Test
savesAreShutUntilTheAccountArrives =
    test "both saves are disabled while the account read is still in flight" <|
        \() ->
            start
                |> ProgramTest.expectView
                    (Query.findAll [ Selector.tag "button", Selector.disabled True ]
                        >> Query.count (Expect.equal 2)
                    )


{-| The louder half of the same rule: after a failed read the page says the
fields may be stale, and saying that while offering to save them would be the
page contradicting itself in the same breath.
-}
savesStayShutAfterAFailedRead : Test
savesStayShutAfterAFailedRead =
    test "both saves stay disabled after the account read fails" <|
        \() ->
            start
                |> ProgramTest.simulateHttpResponse "GET" "/api/auth/me" Http.NetworkError_
                |> ProgramTest.expectView
                    (Query.findAll [ Selector.tag "button", Selector.disabled True ]
                        >> Query.count (Expect.equal 2)
                    )


anonymousAsksNothing : Test
anonymousAsksNothing =
    test "with no token the page asks for nothing and stays NotAsked" <|
        \() ->
            let
                ( model, effect ) =
                    Profile.initWithEffect Nothing blobUser

                asked =
                    case effect of
                        Effect.None ->
                            False

                        _ ->
                            True
            in
            Expect.all
                [ \_ -> model.account |> Expect.equal NotAsked
                , \_ -> asked |> Expect.equal False
                ]
                ()
