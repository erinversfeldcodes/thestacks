module Util.LabelTest exposing (suite)

import Expect
import Test exposing (Test, describe, test)
import Util.Label as Label


suite : Test
suite =
    describe "Util.Label.humanize"
        [ test "turns a snake_case enum atom into a phrase" <|
            \_ ->
                Label.humanize "pending_review"
                    |> Expect.equal "Pending review"
        , test "capitalises a single-word status" <|
            \_ ->
                Label.humanize "healthy"
                    |> Expect.equal "Healthy"
        , test "replaces every underscore, not just the first" <|
            \_ ->
                Label.humanize "awaiting_second_factor"
                    |> Expect.equal "Awaiting second factor"
        , test "leaves an empty string unchanged" <|
            \_ ->
                Label.humanize ""
                    |> Expect.equal ""
        ]
