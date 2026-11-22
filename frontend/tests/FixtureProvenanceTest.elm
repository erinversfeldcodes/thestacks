module FixtureProvenanceTest exposing (suite)

{-| Fixture provenance, made a gate for the reading-status enum.

A test fixture's string value for an enum-typed field must be one the SERVER can
actually emit — otherwise the fixture decodes to a code path the server can never
produce, and the test proves nothing about the real system. The vocabulary for
`reading_status` is fixed by the DB CHECK constraint on
`op.bookshelf_placements.reading_status`: `to_read`, `reading`, `completed`,
`abandoned`. "finished" is the LABEL the UI shows for `completed`, not a wire
value, and a fixture that used it parsed to `Nothing` while reading like a real
Finished case.

This turns that convention into a gate: every value the server can emit must
parse to a `Just`, and an invented value must not — so a fixture that reaches for
one is caught here rather than passing green against an impossible payload.

-}

import Expect
import Test exposing (Test, describe, test)
import Types.Placement as Placement


{-| The reading-status vocabulary the server can emit, mirroring the DB CHECK
constraint on op.bookshelf\_placements.reading\_status.
-}
serverReadingStatuses : List String
serverReadingStatuses =
    [ "to_read", "reading", "completed", "abandoned" ]


suite : Test
suite =
    describe "fixture provenance: reading_status enum"
        [ test "every reading_status the server can emit parses to a Just" <|
            \_ ->
                serverReadingStatuses
                    |> List.filter (\s -> Placement.parseReadingStatus s == Nothing)
                    |> Expect.equalLists []
        , test "an invented reading_status does not parse, so a fixture reaching for one is caught" <|
            \_ ->
                Placement.parseReadingStatus "finished"
                    |> Expect.equal Nothing
        ]
