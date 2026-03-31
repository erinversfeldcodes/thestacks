module Page.ThirdSpacesProgramTest exposing (suite)

{-| Program tests for Page.ThirdSpaces using elm-program-test.

These tests exercise the ThirdSpaces page lifecycle through
simulated user interactions and HTTP responses.

-}

import Json.Decode as Decode
import Json.Encode as Encode
import Page.ThirdSpaces as ThirdSpaces exposing (ThirdSpace)
import ProgramTest exposing (ProgramDefinition, SimulatedEffect)
import SimulatedEffect.Cmd
import SimulatedEffect.Http
import Test exposing (Test, describe, test)
import Test.Html.Selector as Selector


suite : Test
suite =
    describe "Page.ThirdSpaces (ProgramTest)"
        [ showsLoadingState
        , loadsAndDisplaysSpaces
        , showsEmptyState
        , clickSpaceSelectsIt
        , selectedSpaceShowsDetail
        , selectedSpaceShowsEvents
        , closeDetailHidesOverlay
        ]



-- PROGRAM TEST HARNESS


thirdSpacesProgram : Maybe String -> ProgramDefinition () ThirdSpaces.Model ThirdSpaces.Msg (SimulatedEffect ThirdSpaces.Msg)
thirdSpacesProgram maybeToken =
    ProgramTest.createElement
        { init =
            \() ->
                let
                    ( model, _ ) =
                        ThirdSpaces.init maybeToken
                in
                ( model, thirdSpacesInitEffects maybeToken )
        , update =
            \msg model ->
                let
                    ( newModel, _, _ ) =
                        ThirdSpaces.update msg model
                in
                ( newModel, SimulatedEffect.Cmd.none )
        , view = ThirdSpaces.view
        }
        |> ProgramTest.withSimulatedEffects identity


thirdSpacesInitEffects : Maybe String -> SimulatedEffect ThirdSpaces.Msg
thirdSpacesInitEffects maybeToken =
    case maybeToken of
        Just token ->
            SimulatedEffect.Http.request
                { method = "GET"
                , headers = [ SimulatedEffect.Http.header "Authorization" ("Bearer " ++ token) ]
                , url = "/api/third-spaces"
                , body = SimulatedEffect.Http.emptyBody
                , expect = SimulatedEffect.Http.expectJson ThirdSpaces.SpacesLoaded thirdSpacesResponseDecoder
                , timeout = Nothing
                , tracker = Nothing
                }

        Nothing ->
            SimulatedEffect.Cmd.none


thirdSpacesResponseDecoder : Decode.Decoder (List ThirdSpace)
thirdSpacesResponseDecoder =
    Decode.field "third_spaces" (Decode.list thirdSpaceDecoder)


thirdSpaceDecoder : Decode.Decoder ThirdSpace
thirdSpaceDecoder =
    Decode.map8 ThirdSpace
        (Decode.field "id" Decode.string)
        (Decode.field "name" Decode.string)
        (Decode.field "type" Decode.string)
        (Decode.field "city" Decode.string)
        (Decode.field "country_code" Decode.string)
        (Decode.field "website_url" Decode.string)
        (Decode.field "verified" Decode.bool)
        (Decode.field "upcoming_events" (Decode.list thirdSpaceEventDecoder))


thirdSpaceEventDecoder : Decode.Decoder ThirdSpaces.ThirdSpaceEvent
thirdSpaceEventDecoder =
    Decode.map4 ThirdSpaces.ThirdSpaceEvent
        (Decode.field "id" Decode.string)
        (Decode.field "title" Decode.string)
        (Decode.field "event_date" Decode.string)
        (Decode.maybe (Decode.field "ends_at" Decode.string))


startThirdSpaces : ProgramTest.ProgramTest ThirdSpaces.Model ThirdSpaces.Msg (SimulatedEffect ThirdSpaces.Msg)
startThirdSpaces =
    ProgramTest.start () (thirdSpacesProgram (Just "test-token"))



-- JSON HELPERS


sampleSpacesJson : String
sampleSpacesJson =
    Encode.encode 0
        (Encode.object
            [ ( "third_spaces"
              , Encode.list identity
                    [ spaceJson "space-1" "Readers Cafe" "cafe" "Cape Town" "ZA" True [ eventJson "event-1" "Book Launch" ]
                    , spaceJson "space-2" "Corner Books" "bookshop" "Stellenbosch" "ZA" False []
                    ]
              )
            ]
        )


emptySpacesJson : String
emptySpacesJson =
    Encode.encode 0
        (Encode.object
            [ ( "third_spaces", Encode.list identity [] ) ]
        )


spaceJson : String -> String -> String -> String -> String -> Bool -> List Encode.Value -> Encode.Value
spaceJson id name type_ city countryCode verified events =
    Encode.object
        [ ( "id", Encode.string id )
        , ( "name", Encode.string name )
        , ( "type", Encode.string type_ )
        , ( "city", Encode.string city )
        , ( "country_code", Encode.string countryCode )
        , ( "website_url", Encode.string ("https://" ++ String.toLower (String.replace " " "" name) ++ ".example.com") )
        , ( "verified", Encode.bool verified )
        , ( "upcoming_events", Encode.list identity events )
        ]


eventJson : String -> String -> Encode.Value
eventJson id title =
    Encode.object
        [ ( "id", Encode.string id )
        , ( "title", Encode.string title )
        , ( "event_date", Encode.string "2026-04-15T18:00:00Z" )
        , ( "ends_at", Encode.string "2026-04-15T21:00:00Z" )
        ]



-- TESTS


showsLoadingState : Test
showsLoadingState =
    test "loading_state: before API response, shows loading message" <|
        \() ->
            startThirdSpaces
                |> ProgramTest.expectViewHas
                    [ Selector.text "Loading spaces..." ]


loadsAndDisplaysSpaces : Test
loadsAndDisplaysSpaces =
    test "load_spaces: API responds with spaces -> names are rendered" <|
        \() ->
            startThirdSpaces
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/third-spaces"
                    sampleSpacesJson
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Readers Cafe" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "Corner Books" ]


showsEmptyState : Test
showsEmptyState =
    test "empty_state: API responds with empty list -> shows empty message" <|
        \() ->
            startThirdSpaces
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/third-spaces"
                    emptySpacesJson
                |> ProgramTest.expectViewHas
                    [ Selector.text "No third spaces found in your area yet." ]


clickSpaceSelectsIt : Test
clickSpaceSelectsIt =
    test "click_space: clicking a space card opens the detail panel" <|
        \() ->
            startThirdSpaces
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/third-spaces"
                    sampleSpacesJson
                |> ProgramTest.clickButton "Readers Cafe"
                |> ProgramTest.expectViewHas
                    [ Selector.class "third-spaces__detail" ]


selectedSpaceShowsDetail : Test
selectedSpaceShowsDetail =
    test "selected_detail: when a space is selected, its details are visible" <|
        \() ->
            startThirdSpaces
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/third-spaces"
                    sampleSpacesJson
                |> ProgramTest.clickButton "Readers Cafe"
                |> ProgramTest.ensureViewHas
                    [ Selector.text "Readers Cafe" ]
                |> ProgramTest.expectViewHas
                    [ Selector.text "Cape Town" ]


selectedSpaceShowsEvents : Test
selectedSpaceShowsEvents =
    test "selected_events: when a space is selected, upcoming events are listed" <|
        \() ->
            startThirdSpaces
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/third-spaces"
                    sampleSpacesJson
                |> ProgramTest.clickButton "Readers Cafe"
                |> ProgramTest.expectViewHas
                    [ Selector.text "Book Launch" ]


closeDetailHidesOverlay : Test
closeDetailHidesOverlay =
    test "close_detail: closing the detail panel hides it" <|
        \() ->
            startThirdSpaces
                |> ProgramTest.simulateHttpOk "GET"
                    "/api/third-spaces"
                    sampleSpacesJson
                |> ProgramTest.clickButton "Readers Cafe"
                |> ProgramTest.ensureViewHas
                    [ Selector.class "third-spaces__detail" ]
                |> ProgramTest.clickButton "Close"
                |> ProgramTest.expectViewHasNot
                    [ Selector.class "third-spaces__detail" ]
