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
        , test "a 422 refusal names the Goodreads export, not the reader's mistake" <|
            \_ ->
                viewAfter [ ImportPage.GotCreated (Err ImportUnrecognised) ]
                    |> Query.find [ Selector.attribute (Html.Attributes.attribute "data-testid" "import-error") ]
                    |> Query.has [ Selector.text "doesn't look like a Goodreads export" ]
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
                viewAfter
                    [ ImportPage.GotCreated (Ok runningImport)
                    , ImportPage.GotImport (Ok finishedImport)
                    , ImportPage.GotRows (Ok [ shelvedRow ])
                    ]
                    |> Query.has [ Selector.attribute (Html.Attributes.attribute "data-testid" "import-all-shelved") ]
        , test "a failed import owns the stop — with everything-so-far-is-safe copy" <|
            \_ ->
                viewAfter
                    [ ImportPage.GotCreated (Ok runningImport)
                    , ImportPage.GotImport (Ok { finishedImport | status = "failed" })
                    ]
                    |> Query.has [ Selector.attribute (Html.Attributes.attribute "data-testid" "import-failed-note") ]
        ]
