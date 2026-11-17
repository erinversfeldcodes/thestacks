module Util.RelativeTimeTest exposing (suite)

import Expect
import Test exposing (Test, describe, test)
import Time
import Util.RelativeTime as RelativeTime


{-| 2000-01-01T00:00:00Z in epoch milliseconds — the anchor these cases offset
from. 946684800 is the well-known Unix timestamp for that instant.
-}
y2k : Int
y2k =
    946684800000


suite : Test
suite =
    describe "Util.RelativeTime"
        [ describe "isoToMillis — one fixed ISO-8601 UTC shape, parsed by hand"
            [ test "the Unix epoch is zero" <|
                \_ ->
                    RelativeTime.isoToMillis "1970-01-01T00:00:00Z"
                        |> Expect.equal (Just 0)
            , test "2000-01-01 matches the known Unix timestamp (leap-year arithmetic)" <|
                \_ ->
                    RelativeTime.isoToMillis "2000-01-01T00:00:00Z"
                        |> Expect.equal (Just y2k)
            , test "parses microsecond fractional seconds as the API sends them" <|
                \_ ->
                    RelativeTime.isoToMillis "2000-01-01T00:00:01.568626Z"
                        |> Expect.equal (Just (y2k + 1000))
            , test "a string with no date/time separator is Nothing" <|
                \_ ->
                    RelativeTime.isoToMillis "not a date"
                        |> Expect.equal Nothing
            ]
        , describe "relative — human phrasing against the reader's clock"
            [ test "under a minute reads 'just now'" <|
                \_ ->
                    RelativeTime.relative (Time.millisToPosix (y2k + 30 * 1000)) "2000-01-01T00:00:00Z"
                        |> Expect.equal "just now"
            , test "exactly one minute is singular" <|
                \_ ->
                    RelativeTime.relative (Time.millisToPosix (y2k + 60 * 1000)) "2000-01-01T00:00:00Z"
                        |> Expect.equal "1 minute ago"
            , test "two minutes is plural" <|
                \_ ->
                    RelativeTime.relative (Time.millisToPosix (y2k + 120 * 1000)) "2000-01-01T00:00:00Z"
                        |> Expect.equal "2 minutes ago"
            , test "hours" <|
                \_ ->
                    RelativeTime.relative (Time.millisToPosix (y2k + 3 * 3600 * 1000)) "2000-01-01T00:00:00Z"
                        |> Expect.equal "3 hours ago"
            , test "days" <|
                \_ ->
                    RelativeTime.relative (Time.millisToPosix (y2k + 2 * 86400 * 1000)) "2000-01-01T00:00:00Z"
                        |> Expect.equal "2 days ago"
            , test "an unparseable timestamp falls back to the date portion, never the raw datetime" <|
                \_ ->
                    RelativeTime.relative (Time.millisToPosix y2k) "2026-11-17 17:22:42"
                        |> Expect.equal "2026-11-17"
            ]
        ]
