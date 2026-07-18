module Page.ResetPasswordTest exposing (suite)

import Expect
import Http
import Page.ResetPassword as ResetPassword exposing (Msg(..))
import Test exposing (Test, describe, test)
import Types.RemoteData exposing (RemoteData(..))


update : Msg -> ResetPassword.Model -> ResetPassword.Model
update msg model =
    Tuple.first (ResetPassword.update msg model)


{-| A model with a valid, matching 8+ char password ready to submit.
-}
validModel : ResetPassword.Model
validModel =
    ResetPassword.init "tok-123"
        |> update (SetPassword "new-password")
        |> update (SetConfirmPassword "new-password")


suite : Test
suite =
    describe "Page.ResetPassword"
        [ test "init carries the token from the URL" <|
            \_ ->
                (ResetPassword.init "tok-123").token |> Expect.equal "tok-123"
        , test "submitting a valid, matching password moves to Loading" <|
            \_ ->
                validModel
                    |> update Submit
                    |> .submitting
                    |> Expect.equal Loading
        , test "a too-short password blocks submit (stays NotAsked)" <|
            \_ ->
                ResetPassword.init "tok-123"
                    |> update (SetPassword "short")
                    |> update (SetConfirmPassword "short")
                    |> update Submit
                    |> .submitting
                    |> Expect.equal NotAsked
        , test "a mismatched confirmation blocks submit (stays NotAsked)" <|
            \_ ->
                ResetPassword.init "tok-123"
                    |> update (SetPassword "new-password")
                    |> update (SetConfirmPassword "different-one")
                    |> update Submit
                    |> .submitting
                    |> Expect.equal NotAsked
        , test "a successful reset shows success" <|
            \_ ->
                validModel
                    |> update Submit
                    |> update (Completed (Ok ()))
                    |> .submitting
                    |> Expect.equal (Success ())
        , test "an expired/invalid token (400) shows failure" <|
            \_ ->
                validModel
                    |> update Submit
                    |> update (Completed (Err (Http.BadStatus 400)))
                    |> .submitting
                    |> Expect.equal (Failure (Http.BadStatus 400))
        ]
