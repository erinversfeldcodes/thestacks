module ThirdSpacesTest exposing (suite)

{-| Unit tests for Page.ThirdSpaces.

These tests exercise init, update, and model state transitions
without simulated HTTP effects.

-}

import Expect
import Http
import Page.ThirdSpaces as ThirdSpaces exposing (Msg(..), ThirdSpace, ThirdSpaceEvent)
import Test exposing (Test, describe, test)
import Types.RemoteData exposing (RemoteData(..))


fakeEvent : ThirdSpaceEvent
fakeEvent =
    { id = "event-1"
    , title = "Book Launch"
    , eventDate = "2026-04-15T18:00:00Z"
    , endsAt = Just "2026-04-15T21:00:00Z"
    }


fakeSpace : ThirdSpace
fakeSpace =
    { id = "space-1"
    , name = "Readers Cafe"
    , type_ = "cafe"
    , city = "Cape Town"
    , countryCode = "ZA"
    , websiteUrl = "https://readerscafe.example.com"
    , verified = True
    , upcomingEvents = [ fakeEvent ]
    }


fakeSpace2 : ThirdSpace
fakeSpace2 =
    { id = "space-2"
    , name = "Corner Books"
    , type_ = "bookshop"
    , city = "Stellenbosch"
    , countryCode = "ZA"
    , websiteUrl = "https://cornerbooks.example.com"
    , verified = False
    , upcomingEvents = []
    }


thirdSpacesInit : ThirdSpaces.Model
thirdSpacesInit =
    let
        ( m, _ ) =
            ThirdSpaces.init (Just "test-token")
    in
    m


suite : Test
suite =
    describe "Page.ThirdSpaces"
        [ describe "init"
            [ test "starts in Loading state" <|
                \_ ->
                    thirdSpacesInit.spaces |> Expect.equal Loading
            , test "starts with no selected space" <|
                \_ ->
                    thirdSpacesInit.selectedSpace |> Expect.equal Nothing
            ]
        , describe "SpacesLoaded"
            [ test "Ok response sets spaces to Success" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            ThirdSpaces.update (SpacesLoaded (Ok [ fakeSpace, fakeSpace2 ])) thirdSpacesInit
                    in
                    model.spaces |> Expect.equal (Success [ fakeSpace, fakeSpace2 ])
            , test "Err response sets spaces to Failure" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            ThirdSpaces.update (SpacesLoaded (Err Http.NetworkError)) thirdSpacesInit
                    in
                    model.spaces |> Expect.equal (Failure Http.NetworkError)
            , test "Ok empty list sets spaces to Success with empty list" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            ThirdSpaces.update (SpacesLoaded (Ok [])) thirdSpacesInit
                    in
                    model.spaces |> Expect.equal (Success [])
            ]
        , describe "SelectSpace"
            [ test "sets selectedSpace to Just the space" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            ThirdSpaces.update (SelectSpace fakeSpace) thirdSpacesInit
                    in
                    model.selectedSpace |> Expect.equal (Just fakeSpace)
            ]
        , describe "CloseDetail"
            [ test "sets selectedSpace to Nothing" <|
                \_ ->
                    let
                        withSelected =
                            { thirdSpacesInit | selectedSpace = Just fakeSpace }

                        ( model, _, _ ) =
                            ThirdSpaces.update CloseDetail withSelected
                    in
                    model.selectedSpace |> Expect.equal Nothing
            ]
        ]
