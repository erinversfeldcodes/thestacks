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
        [ sessionExpiryStillSettlesTheFlag
        , describe "init"
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


{-| ⛔ A 401 must settle the in-flight flag, not just hand off the session.

All three completion handlers here returned `model` untouched on a 401 while
their own `else` branch recorded a `Failure`, so an expired session left
`saving`, `publishing` or `loading` on `Loading` forever — a disabled button or a
spinner with no response ever coming.

⚠️ And `SessionExpired` does NOT guarantee the reader is taken away from it.
`Main.handleSessionExpiry` parks the logout and asks JS for the stored auth; if
another tab has refreshed the token, `adoptExternalAuth` returns `AdoptAuth` and
the logout is CANCELLED. The reader stays on this page, which is precisely when
the stuck flag stops being invisible.

⚠️ Each case asserts the IN-FLIGHT PRECONDITION first. Without that, "the flag
is no longer Loading" is satisfied by the `NotAsked` a fresh model already
carries, and the test would pass against the defect it exists to catch — which
is how the sibling hosts' 401 path went unnoticed while their 500 path was
covered.

⛔ And each asserts the EXACT settled value, not merely `notEqual Loading`.
`notEqual Loading` is satisfied by `NotAsked` and by `Success ()` too, so the
minimal wrong fix — settle the flag, surface nothing — passed all three cases
while leaving the reader a re-enabled button and a save that had silently
vanished. "Not stuck" and "says why" are different claims and the weaker one
was standing in for both.

-}
sessionExpiryStillSettlesTheFlag : Test
sessionExpiryStillSettlesTheFlag =
    describe "a 401 settles the in-flight flag and hands off the session"
        [ test "SaveCompleted" <|
            \_ ->
                let
                    ( inFlight, _, _ ) =
                        Editor.update SaveDraft newModel token

                    ( settled, _, out ) =
                        Editor.update (SaveCompleted (Err (Http.BadStatus 401))) inFlight token
                in
                Expect.all
                    [ \_ -> inFlight.saving |> Expect.equal Loading
                    , \_ -> settled.saving |> Expect.equal (Failure (Http.BadStatus 401))
                    , \_ -> out |> Expect.equal Editor.SessionExpired
                    ]
                    ()
        , test "PublishCompleted" <|
            \_ ->
                let
                    ( inFlight, _, _ ) =
                        Editor.update Publish newModel token

                    ( settled, _, out ) =
                        Editor.update (PublishCompleted (Err (Http.BadStatus 401))) inFlight token
                in
                Expect.all
                    [ \_ -> inFlight.publishing |> Expect.equal Loading
                    , \_ -> settled.publishing |> Expect.equal (Failure (Http.BadStatus 401))
                    , \_ -> out |> Expect.equal Editor.SessionExpired
                    ]
                    ()
        , test "PostLoaded" <|
            \_ ->
                let
                    inFlight =
                        Tuple.first (Editor.init (Edit "post-123") token)

                    ( settled, _, out ) =
                        Editor.update (PostLoaded (Err (Http.BadStatus 401))) inFlight token
                in
                Expect.all
                    [ \_ -> inFlight.loading |> Expect.equal Loading
                    , \_ -> settled.loading |> Expect.equal (Failure (Http.BadStatus 401))
                    , \_ -> out |> Expect.equal Editor.SessionExpired
                    ]
                    ()
        ]
