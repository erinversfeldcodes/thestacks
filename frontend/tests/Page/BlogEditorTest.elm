module Page.BlogEditorTest exposing (suite)

import Expect
import Http
import Page.Blog.Editor as Editor exposing (Mode(..), Msg(..))
import Test exposing (Test, describe, test)
import Types.BlogPost exposing (Visibility(..))
import Types.RemoteData exposing (RemoteData(..))


token : Maybe String
token =
    Just "tok"


newModel : Editor.Model
newModel =
    Tuple.first (Editor.init New token)


suite : Test
suite =
    describe "Page.Blog.Editor"
        [ describe "init"
            [ test "New mode defaults visibility to Owner" <|
                \_ ->
                    newModel.visibility |> Expect.equal Owner
            , test "New mode leaves saving as NotAsked" <|
                \_ ->
                    newModel.saving |> Expect.equal NotAsked
            ]
        , describe "SetVisibility parsing"
            [ test "\"owner\" parses to Owner" <|
                \_ ->
                    parseVisibility "owner" |> Expect.equal Owner
            , test "\"group\" parses to Group" <|
                \_ ->
                    parseVisibility "group" |> Expect.equal Group
            , test "\"platform\" parses to Platform" <|
                \_ ->
                    parseVisibility "platform" |> Expect.equal Platform
            , test "an unknown value falls back to Owner" <|
                \_ ->
                    parseVisibility "nonsense" |> Expect.equal Owner
            , test "SetVisibility resets saving to NotAsked" <|
                \_ ->
                    let
                        saved =
                            { newModel | saving = Success () }

                        ( model, _, _ ) =
                            Editor.update (SetVisibility "group") saved token
                    in
                    model.saving |> Expect.equal NotAsked
            ]
        , describe "SaveDraft"
            [ test "with a token sets saving to Loading" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Editor.update SaveDraft newModel token
                    in
                    model.saving |> Expect.equal Loading
            , test "without a token is a no-op" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Editor.update SaveDraft newModel Nothing
                    in
                    model.saving |> Expect.equal NotAsked
            , test "SaveCompleted Ok sets saving to Success" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Editor.update (SaveCompleted (Ok "post-123")) newModel token
                    in
                    model.saving |> Expect.equal (Success ())
            , test "SaveCompleted Ok in New mode transitions to Edit mode" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Editor.update (SaveCompleted (Ok "post-123")) newModel token
                    in
                    model.mode |> Expect.equal (Edit "post-123")
            , test "SaveCompleted Err sets saving to Failure" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Editor.update (SaveCompleted (Err (Http.BadStatus 500))) newModel token
                    in
                    isFailure model.saving |> Expect.equal True
            ]
        , describe "Publish"
            [ test "with a token sets both publishing and saving to Loading" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Editor.update Publish newModel token
                    in
                    ( model.publishing, model.saving )
                        |> Expect.equal ( Loading, Loading )
            , test "without a token is a no-op" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Editor.update Publish newModel Nothing
                    in
                    model.publishing |> Expect.equal NotAsked
            , test "PublishCompleted Ok sets publishing to Success" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Editor.update (PublishCompleted (Ok ())) newModel token
                    in
                    model.publishing |> Expect.equal (Success ())
            , test "PublishCompleted Err sets publishing to Failure" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Editor.update (PublishCompleted (Err (Http.BadStatus 500))) newModel token
                    in
                    isFailure model.publishing |> Expect.equal True
            ]
        ]


parseVisibility : String -> Visibility
parseVisibility raw =
    let
        ( model, _, _ ) =
            Editor.update (SetVisibility raw) newModel token
    in
    model.visibility


isFailure : RemoteData Http.Error () -> Bool
isFailure rd =
    case rd of
        Failure _ ->
            True

        _ ->
            False
