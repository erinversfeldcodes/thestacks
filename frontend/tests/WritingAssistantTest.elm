module WritingAssistantTest exposing (suite)

import Components.WritingAssistant as WritingAssistant
import Expect
import Page.Settings.Consent as Consent
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Types.RemoteData exposing (RemoteData(..))


suite : Test
suite =
    describe "Writing assistant"
        [ describe "Consent page — writing assistant toggle"
            [ test "ToggleWritingAssistant flips writingAssistantConsent" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update Consent.ToggleWritingAssistant (Consent.init { analytics = False, writingAssistant = False }) Nothing
                    in
                    model.writingAssistantConsent |> Expect.equal True
            , test "ToggleWritingAssistant with a token saves immediately (Loading)" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update Consent.ToggleWritingAssistant (Consent.init { analytics = False, writingAssistant = False }) (Just "tok")
                    in
                    Expect.all
                        [ \m -> m.writingAssistantConsent |> Expect.equal True
                        , \m -> m.saving |> Expect.equal Loading
                        ]
                        model
            , test "SaveWritingAssistantCompleted Ok sets saving to Success" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Consent.update (Consent.SaveWritingAssistantCompleted (Ok ()))
                                (Consent.init { analytics = False, writingAssistant = False })
                                (Just "tok")
                    in
                    model.saving |> Expect.equal (Success ())
            , test "the OFF description is the exact required copy" <|
                \_ ->
                    Consent.writingAssistantOffDescription
                        |> Expect.equal
                            "Your shelf and writing history are used to personalise writing suggestions. Disabling this turns off the writing assistant and deletes your session history and embeddings."
            , test "the Consent view renders the OFF description when consent is off" <|
                \_ ->
                    Consent.view (Consent.init { analytics = False, writingAssistant = False })
                        |> Query.fromHtml
                        |> Query.has [ Selector.text Consent.writingAssistantOffDescription ]
            ]
        , describe "Under-construction widget"
            [ test "shows the coming-soon placeholder when consent is granted" <|
                \_ ->
                    WritingAssistant.view { hasConsent = True }
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "Writing assistant — coming soon" ]
            , test "shows an enable-in-settings prompt when consent is off" <|
                \_ ->
                    WritingAssistant.view { hasConsent = False }
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "Enable it in Settings › Privacy." ]
            , test "does NOT show the coming-soon placeholder when consent is off" <|
                \_ ->
                    WritingAssistant.view { hasConsent = False }
                        |> Query.fromHtml
                        |> Query.hasNot [ Selector.text "Writing assistant — coming soon" ]
            ]
        ]
