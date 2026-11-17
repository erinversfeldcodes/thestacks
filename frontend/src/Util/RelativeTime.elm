module Util.RelativeTime exposing (isoToMillis, relative)

{-| Relative-time bylines: render a stored UTC timestamp as "2 minutes ago"
against the reader's current clock, so a post's age reads in human terms rather
than as a raw ISO-8601 string.

The timestamp arrives as a String (the API sends `inserted_at` as ISO-8601 UTC,
e.g. `2026-11-17T17:22:42.568626Z`); there is no date library in the frontend, so
`isoToMillis` parses that one fixed shape by hand. Anything it cannot parse falls
back to the date portion rather than showing a broken relative phrase.

-}

import Time
import Util.Plural as Plural


{-| A stored ISO-8601 UTC timestamp rendered relative to `now`. Falls back to the
`YYYY-MM-DD` date portion when the timestamp cannot be parsed, so the byline is
always at worst a plain date and never a raw datetime or an empty string.
-}
relative : Time.Posix -> String -> String
relative now iso =
    case isoToMillis iso of
        Just millis ->
            phrase (Time.posixToMillis now - millis)

        Nothing ->
            String.left 10 iso


phrase : Int -> String
phrase deltaMillis =
    let
        seconds =
            deltaMillis // 1000
    in
    if seconds < 60 then
        "just now"

    else if seconds < 3600 then
        Plural.unit (seconds // 60) "minute" ++ " ago"

    else if seconds < 86400 then
        Plural.unit (seconds // 3600) "hour" ++ " ago"

    else if seconds < 2592000 then
        Plural.unit (seconds // 86400) "day" ++ " ago"

    else if seconds < 31536000 then
        Plural.unit (seconds // 2592000) "month" ++ " ago"

    else
        Plural.unit (seconds // 31536000) "year" ++ " ago"


{-| Epoch milliseconds for an ISO-8601 UTC timestamp of the shape
`YYYY-MM-DDTHH:MM:SS[.ffffff]Z`. `Nothing` for anything else (a timezone offset
other than `Z`, a missing field) — the caller shows the date instead. Only valid
for timestamps at or after the Unix epoch, which every stored row is.
-}
isoToMillis : String -> Maybe Int
isoToMillis iso =
    case String.split "T" iso of
        [ datePart, timePart ] ->
            Maybe.map2
                (\days secondsInDay -> (days * 86400 + secondsInDay) * 1000)
                (daysFromDate datePart)
                (secondsFromTime timePart)

        _ ->
            Nothing


daysFromDate : String -> Maybe Int
daysFromDate s =
    case String.split "-" s of
        [ y, m, d ] ->
            Maybe.map3 daysSinceEpoch (String.toInt y) (String.toInt m) (String.toInt d)

        _ ->
            Nothing


daysSinceEpoch : Int -> Int -> Int -> Int
daysSinceEpoch year month day =
    let
        yearDays =
            List.range 1970 (year - 1)
                |> List.map daysInYear
                |> List.sum

        monthDays =
            monthLengths year
                |> List.take (month - 1)
                |> List.sum
    in
    yearDays + monthDays + (day - 1)


secondsFromTime : String -> Maybe Int
secondsFromTime s =
    let
        core =
            s
                |> String.replace "Z" ""
                |> String.split "."
                |> List.head
                |> Maybe.withDefault ""
    in
    case String.split ":" core of
        [ h, mn, sec ] ->
            Maybe.map3 (\hh mm ss -> (hh * 3600) + (mm * 60) + ss)
                (String.toInt h)
                (String.toInt mn)
                (String.toInt sec)

        _ ->
            Nothing


isLeap : Int -> Bool
isLeap y =
    (modBy 4 y == 0 && modBy 100 y /= 0) || modBy 400 y == 0


daysInYear : Int -> Int
daysInYear y =
    if isLeap y then
        366

    else
        365


monthLengths : Int -> List Int
monthLengths y =
    [ 31
    , if isLeap y then
        29

      else
        28
    , 31
    , 30
    , 31
    , 30
    , 31
    , 31
    , 30
    , 31
    , 30
    , 31
    ]
