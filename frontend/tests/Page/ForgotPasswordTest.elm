module Page.ForgotPasswordTest exposing (suite)

import Expect
import Http
import Page.ForgotPassword as ForgotPassword exposing (Msg(..))
import Test exposing (Test, describe, test)
import Types.RemoteData exposing (RemoteData(..))


update : Msg -> ForgotPassword.Model -> ForgotPassword.Model
update msg model =
    Tuple.first (ForgotPassword.update msg model)


suite : Test
suite =
    describe "Page.ForgotPassword"
        [ test "starts NotAsked" <|
            \_ ->
                ForgotPassword.init.submitting |> Expect.equal NotAsked
        , test "submitting a non-empty email moves to Loading" <|
            \_ ->
                ForgotPassword.init
                    |> update (SetEmail "reader@example.com")
                    |> update Submit
                    |> .submitting
                    |> Expect.equal Loading
        , test "submitting a blank email is a no-op (stays NotAsked)" <|
            \_ ->
                ForgotPassword.init
                    |> update (SetEmail "   ")
                    |> update Submit
                    |> .submitting
                    |> Expect.equal NotAsked
        , test "a successful response shows success" <|
            \_ ->
                ForgotPassword.init
                    |> update (SetEmail "reader@example.com")
                    |> update Submit
                    |> update (Completed (Ok ()))
                    |> .submitting
                    |> Expect.equal (Success ())
        , test "a transport error shows failure" <|
            \_ ->
                ForgotPassword.init
                    |> update (SetEmail "reader@example.com")
                    |> update Submit
                    |> update (Completed (Err Http.NetworkError))
                    |> .submitting
                    |> Expect.equal (Failure Http.NetworkError)
        ]
