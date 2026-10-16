module Page.ImportTest exposing (suite)

{-| Page.Import: the phases the reader actually sees, driven
through `update` with server-shaped values — no reaching into the model.
-}

import Api exposing (ImportError(..), ImportRow, LibraryImport)
import Expect
import Html.Attributes
import Page.Import as ImportPage
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector


runningImport : LibraryImport
runningImport =
    { id = "imp-1"
    , status = "running"
    , filename = "goodreads_library_export.csv"
    , rowCount = 5
    , processedCount = 2
    , shelvedCount = 0
    , duplicateCount = 0
    , unverifiedCount = 0
    , unreadableCount = 0
    }


finishedImport : LibraryImport
finishedImport =
    { runningImport
        | status = "complete"
        , processedCount = 5
        , shelvedCount = 3
        , unverifiedCount = 2
    }


{-| An import that genuinely put every row on a shelf: the counts say so.
-}
allShelvedImport : LibraryImport
allShelvedImport =
    { runningImport
        | status = "complete"
        , processedCount = 5
        , shelvedCount = 5
    }


shelvedRow : ImportRow
shelvedRow =
    { rowNumber = 1
    , title = "1984"
    , author = "George Orwell"
    , isbn13 = "9780141036144"
    , goodreadsShelf = "read"
    , outcome = Just "shelved"
    , reason = Nothing
    }


unverifiedRow : ImportRow
unverifiedRow =
    { rowNumber = 5
    , title = "Self-Published Zine"
    , author = "Anonymous Author"
    , isbn13 = ""
    , goodreadsShelf = "read"
    , outcome = Just "unverified"
    , reason = Just "no valid ISBN in the export row — books cannot enter unverified"
    }


{-| Which refusal the chooser is rendering, read as a token rather than as prose.
-}
refusal : String -> Selector.Selector
refusal kind =
    Selector.attribute (Html.Attributes.attribute "data-refusal" kind)


{-| Drive a list of messages through update (token present) and render.
-}
viewAfter : List ImportPage.Msg -> Query.Single ImportPage.Msg
viewAfter msgs =
    List.foldl
        (\msg model ->
            let
                ( next, _, _ ) =
                    ImportPage.update msg model (Just "token")
            in
            next
        )
        ImportPage.init
        msgs
        |> ImportPage.view
        |> Query.fromHtml


suite : Test
suite =
    describe "Page.Import"
        [ test "starts on the chooser" <|
            \_ ->
                ImportPage.init
                    |> ImportPage.view
                    |> Query.fromHtml
                    |> Query.has [ Selector.attribute (Html.Attributes.attribute "data-testid" "import-choose-file") ]
        , test "an accepted upload shows the server's own progress numbers" <|
            \_ ->
                viewAfter [ ImportPage.GotCreated (Ok runningImport) ]
                    |> Query.find [ Selector.attribute (Html.Attributes.attribute "data-testid" "import-progress-count") ]
                    |> Query.has [ Selector.text "2 of 5 rows" ]
        , test "a 409 refusal reads as one-at-a-time, not as a generic failure" <|
            \_ ->
                viewAfter [ ImportPage.GotCreated (Err ImportInProgress) ]
                    |> Query.find [ Selector.attribute (Html.Attributes.attribute "data-testid" "import-error") ]
                    |> Query.has [ Selector.text "already running" ]
        , test "a wrong-format 422 names the Goodreads export AND the columns it found" <|
            \_ ->
                viewAfter
                    [ ImportPage.GotCreated
                        (Err (ImportUnrecognisedFormat [ "Book Id", "Shelf" ]))
                    ]
                    |> Query.find [ Selector.attribute (Html.Attributes.attribute "data-testid" "import-error") ]
                    |> Expect.all
                        [ Query.has [ Selector.text "doesn't look like a Goodreads export" ]

                        -- The server sends the headers it found; discarding them
                        -- left the reader with no way to tell WHICH file they
                        -- exported by mistake.
                        , Query.has [ Selector.text "Book Id, Shelf" ]
                        ]
        , test "an empty export is not reported as the wrong kind of file" <|
            \_ ->
                -- All four of these refusals used to be one. `no_rows` means the
                -- file WAS recognised as a Goodreads export, so telling the
                -- reader it isn't one sends them to re-export a correct file.
                viewAfter [ ImportPage.GotCreated (Err ImportNoRows) ]
                    |> Query.find [ Selector.attribute (Html.Attributes.attribute "data-testid" "import-error") ]
                    |> Expect.all
                        [ Query.has [ Selector.text "nothing under it" ]

                        -- Negated on the token, not on the other message's
                        -- wording: an absence asserted about prose becomes true
                        -- as soon as the prose is edited, and reports nothing.
                        , Query.has [ refusal "no-rows" ]
                        , Query.hasNot [ refusal "unrecognised-format" ]
                        ]
        , test "a truncated upload blames the transfer, not the reader's file" <|
            \_ ->
                viewAfter [ ImportPage.GotCreated (Err ImportUploadIncomplete) ]
                    |> Query.find [ Selector.attribute (Html.Attributes.attribute "data-testid" "import-error") ]
                    |> Expect.all
                        [ Query.has [ Selector.text "didn't arrive in one piece" ]
                        , Query.has [ refusal "upload-incomplete" ]
                        , Query.hasNot [ refusal "unrecognised-format" ]
                        ]
        , test "a terminal poll answer shows the four counts" <|
            \_ ->
                viewAfter
                    [ ImportPage.GotCreated (Ok runningImport)
                    , ImportPage.GotImport (Ok finishedImport)
                    ]
                    |> Query.find [ Selector.attribute (Html.Attributes.attribute "data-testid" "import-count-shelved") ]
                    |> Query.has [ Selector.text "3" ]
        , test "the report lists ONLY the rows that need the reader, with the server's reason" <|
            \_ ->
                viewAfter
                    [ ImportPage.GotCreated (Ok runningImport)
                    , ImportPage.GotImport (Ok finishedImport)
                    , ImportPage.GotRows (Ok [ shelvedRow, unverifiedRow ])
                    ]
                    |> Query.findAll [ Selector.attribute (Html.Attributes.attribute "data-testid" "import-report-row") ]
                    |> Query.count (Expect.equal 1)
        , test "the reported row carries the server's reason verbatim" <|
            \_ ->
                viewAfter
                    [ ImportPage.GotCreated (Ok runningImport)
                    , ImportPage.GotImport (Ok finishedImport)
                    , ImportPage.GotRows (Ok [ shelvedRow, unverifiedRow ])
                    ]
                    |> Query.find [ Selector.attribute (Html.Attributes.attribute "data-testid" "import-report-row") ]
                    |> Query.has [ Selector.text "no valid ISBN in the export row" ]
        , test "an all-shelved import says so instead of showing an empty table" <|
            \_ ->
                -- ⚠️ Uses `allShelvedImport`, not `finishedImport`. This case
                -- used to assert "every row made it onto a shelf" against an
                -- import whose own counts said two rows could not be verified —
                -- a fixture that contradicted itself, and the contradiction was
                -- the defect: the page took "no reportable rows in hand" to mean
                -- "nothing to report", which is false whenever the rows are
                -- merely GONE. An import that really shelved everything has the
                -- counts to match.
                viewAfter
                    [ ImportPage.GotCreated (Ok runningImport)
                    , ImportPage.GotImport (Ok allShelvedImport)
                    , ImportPage.GotRows (Ok [ shelvedRow ])
                    ]
                    |> Query.has [ Selector.attribute (Html.Attributes.attribute "data-testid" "import-all-shelved") ]
        , test "an import whose rows have expired says so, not that all was well" <|
            \_ ->
                -- Raw rows carry the reader's own notes and reviews, so they are
                -- deleted after 30 days while the counts survive as the durable
                -- summary. That arrives here as an empty list against non-zero
                -- counts, and claiming success for it is the one answer the
                -- counts on the same screen refute.
                viewAfter
                    [ ImportPage.GotCreated (Ok runningImport)
                    , ImportPage.GotImport (Ok finishedImport)
                    , ImportPage.GotRows (Ok [])
                    ]
                    |> Expect.all
                        [ Query.has [ Selector.attribute (Html.Attributes.attribute "data-testid" "import-rows-expired") ]
                        , Query.hasNot [ Selector.attribute (Html.Attributes.attribute "data-testid" "import-all-shelved") ]
                        , Query.has [ Selector.text "2 rows needed a look" ]
                        ]
        , test "a failed import owns the stop — with everything-so-far-is-safe copy" <|
            \_ ->
                viewAfter
                    [ ImportPage.GotCreated (Ok runningImport)
                    , ImportPage.GotImport (Ok { finishedImport | status = "failed" })
                    ]
                    |> Query.has [ Selector.attribute (Html.Attributes.attribute "data-testid" "import-failed-note") ]
        ]
