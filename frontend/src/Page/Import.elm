module Page.Import exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , Phase
    , init
    , pollSeconds
    , update
    , view
    )

{-| Goodreads library import (US-1.1.9): choose the export CSV, watch the
shelving job's counters climb, read the per-row report.

The page's honesty rules:

  - Progress is the SERVER's `processed_count`, polled — the client never
    animates a number it does not hold.
  - The report never hides a row: every row that did not shelve appears with
    the server's own `reason`, because "your library imported ✨" with 40
    silently missing books is the lie this report exists to prevent.
  - A refusal (not a Goodreads file, one already running, too large) is copy
    specific to its cause — the server discriminates them by status code.

-}

import Api exposing (ImportError(..), ImportRow, LibraryImport)
import File exposing (File)
import File.Select as Select
import Html exposing (Html, button, div, h1, h2, p, span, table, tbody, td, text, th, thead, tr)
import Html.Attributes exposing (class)
import Html.Events exposing (onClick)
import Http
import Types.RemoteData exposing (RemoteData(..))
import Util.TestId exposing (testId)


{-| How often the page asks the server where the job is. Main's subscription
interval MUST match this (same contract as `Upload.tickSeconds`).
-}
pollSeconds : Int
pollSeconds =
    2


type Phase
    = Choosing (Maybe ImportError)
    | Uploading
    | Watching LibraryImport
    | Done LibraryImport (RemoteData Http.Error (List ImportRow))


type alias Model =
    { phase : Phase }


init : Model
init =
    { phase = Choosing Nothing }


type Msg
    = PickFile
    | FileChosen File
    | GotCreated (Result ImportError LibraryImport)
    | PollTick
    | GotImport (Result Http.Error LibraryImport)
    | GotRows (Result Http.Error (List ImportRow))


type OutMsg
    = NoOut
    | SessionExpired


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg, OutMsg )
update msg model maybeToken =
    case msg of
        PickFile ->
            ( model, Select.file [ "text/csv" ] FileChosen, NoOut )

        FileChosen file ->
            case maybeToken of
                Just token ->
                    ( { model | phase = Uploading }
                    , Api.createGoodreadsImport token file GotCreated
                    , NoOut
                    )

                Nothing ->
                    ( model, Cmd.none, SessionExpired )

        GotCreated (Ok libraryImport) ->
            ( { model | phase = Watching libraryImport }, Cmd.none, NoOut )

        GotCreated (Err importError) ->
            case importError of
                ImportRequestFailed err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | phase = Choosing (Just importError) }, Cmd.none, NoOut )

                _ ->
                    ( { model | phase = Choosing (Just importError) }, Cmd.none, NoOut )

        PollTick ->
            case ( model.phase, maybeToken ) of
                ( Watching libraryImport, Just token ) ->
                    ( model, Api.getImport token libraryImport.id GotImport, NoOut )

                _ ->
                    ( model, Cmd.none, NoOut )

        GotImport (Ok libraryImport) ->
            if terminal libraryImport then
                ( { model | phase = Done libraryImport Loading }
                , case maybeToken of
                    Just token ->
                        Api.getImportRows token libraryImport.id GotRows

                    Nothing ->
                        Cmd.none
                , NoOut
                )

            else
                ( { model | phase = Watching libraryImport }, Cmd.none, NoOut )

        GotImport (Err err) ->
            if Api.isUnauthorized err then
                ( model, Cmd.none, SessionExpired )

            else
                ( model, Cmd.none, NoOut )

        GotRows (Ok rows) ->
            case model.phase of
                Done libraryImport _ ->
                    ( { model | phase = Done libraryImport (Success rows) }, Cmd.none, NoOut )

                _ ->
                    ( model, Cmd.none, NoOut )

        GotRows (Err err) ->
            case model.phase of
                Done libraryImport _ ->
                    ( { model | phase = Done libraryImport (Failure err) }, Cmd.none, NoOut )

                _ ->
                    ( model, Cmd.none, NoOut )


terminal : LibraryImport -> Bool
terminal libraryImport =
    libraryImport.status == "complete" || libraryImport.status == "failed"


view : Model -> Html Msg
view model =
    div [ class "import-page", testId "import-page" ]
        [ h1 [ class "import__title" ] [ text "Import your Goodreads library" ]
        , case model.phase of
            Choosing maybeError ->
                viewChooser maybeError

            Uploading ->
                div [ class "import__uploading", testId "import-uploading" ]
                    [ p [] [ text "Reading your export…" ] ]

            Watching libraryImport ->
                viewProgress libraryImport

            Done libraryImport rows ->
                viewReport libraryImport rows
        ]


viewChooser : Maybe ImportError -> Html Msg
viewChooser maybeError =
    div [ class "import__chooser" ]
        [ p [ class "import__lead" ]
            [ text "Bring your shelves with you. Export your library from Goodreads (My Books → Import and export → Export Library) and hand the CSV to the stacks. Read books join your Library, current reads your Reading Pile, and your to-read list becomes Antilibrary or Wish List depending on whether you own the book." ]
        , p [ class "import__lead import__lead--gate" ]
            [ text "Every book passes the same ISBN verification as one added by hand — rows without a verifiable ISBN are reported back to you, never invented." ]
        , case maybeError of
            Just importError ->
                p [ class "import__error", testId "import-error" ]
                    [ text (errorCopy importError) ]

            Nothing ->
                text ""
        , button
            [ class "import__choose-button"
            , testId "import-choose-file"
            , onClick PickFile
            ]
            [ text "Choose your Goodreads export" ]
        ]


errorCopy : ImportError -> String
errorCopy importError =
    case importError of
        ImportInProgress ->
            "An import is already running — one at a time, so the two can't argue over your shelves. Check back when it finishes."

        ImportFileTooLarge ->
            "That file is larger than any Goodreads export we've seen (10 MB). Is it the right one?"

        ImportUnrecognised ->
            "That doesn't look like a Goodreads export — we need the CSV from My Books → Import and export → Export Library, with its Title, Author and ISBN13 columns."

        ImportRequestFailed _ ->
            "The upload didn't get through. Your file is fine — try again in a moment."


viewProgress : LibraryImport -> Html Msg
viewProgress libraryImport =
    div [ class "import__progress", testId "import-progress" ]
        [ h2 [ class "import__subtitle" ] [ text "Shelving…" ]
        , p [ class "import__progress-count", testId "import-progress-count" ]
            [ text
                (String.fromInt libraryImport.processedCount
                    ++ " of "
                    ++ String.fromInt libraryImport.rowCount
                    ++ " rows"
                )
            ]
        , p [ class "import__progress-note" ]
            [ text "Each ISBN is being verified against Open Library and Google Books. You can leave — the import carries on without you." ]
        ]


viewReport : LibraryImport -> RemoteData Http.Error (List ImportRow) -> Html Msg
viewReport libraryImport rows =
    div [ class "import__report", testId "import-report" ]
        [ h2 [ class "import__subtitle" ]
            [ text
                (if libraryImport.status == "failed" then
                    "The import stopped early"

                 else
                    "Your shelves are in"
                )
            ]
        , if libraryImport.status == "failed" then
            p [ class "import__error", testId "import-failed-note" ]
                [ text "The book databases stopped answering partway through. Everything shelved so far is safe; a fresh upload will skip what's already in and pick up the rest." ]

          else
            text ""
        , viewCounts libraryImport
        , viewRows rows
        ]


viewCounts : LibraryImport -> Html Msg
viewCounts libraryImport =
    div [ class "import__counts", testId "import-counts" ]
        [ countCell "import-count-shelved" "shelved" libraryImport.shelvedCount
        , countCell "import-count-duplicate" "already on your shelves" libraryImport.duplicateCount
        , countCell "import-count-unverified" "couldn't be verified" libraryImport.unverifiedCount
        , countCell "import-count-unreadable" "couldn't be read" libraryImport.unreadableCount
        ]


countCell : String -> String -> Int -> Html Msg
countCell id label count =
    div [ class "import__count", testId id ]
        [ span [ class "import__count-number" ] [ text (String.fromInt count) ]
        , span [ class "import__count-label" ] [ text label ]
        ]


viewRows : RemoteData Http.Error (List ImportRow) -> Html Msg
viewRows rows =
    case rows of
        Success rowList ->
            let
                reportable =
                    List.filter (\row -> row.outcome /= Just "shelved") rowList
            in
            if List.isEmpty reportable then
                p [ class "import__all-shelved", testId "import-all-shelved" ]
                    [ text "Every row made it onto a shelf." ]

            else
                div [ class "import__rows-wrap" ]
                    [ h2 [ class "import__subtitle" ] [ text "Rows that need you" ]
                    , table [ class "import__rows", testId "import-rows" ]
                        [ thead []
                            [ tr []
                                [ th [] [ text "Row" ]
                                , th [] [ text "Title" ]
                                , th [] [ text "What happened" ]
                                ]
                            ]
                        , tbody [] (List.map viewRow reportable)
                        ]
                    ]

        Loading ->
            p [ class "import__rows-loading" ] [ text "Fetching the report…" ]

        Failure _ ->
            p [ class "import__error" ]
                [ text "The report didn't load — refresh to try again. Your shelves are unaffected." ]

        NotAsked ->
            text ""


viewRow : ImportRow -> Html Msg
viewRow row =
    tr [ class "import__row", testId "import-report-row" ]
        [ td [ class "import__row-number" ] [ text (String.fromInt row.rowNumber) ]
        , td [ class "import__row-title" ]
            [ text
                (if String.isEmpty row.title then
                    "(untitled row)"

                 else
                    row.title
                )
            ]
        , td [ class "import__row-reason" ]
            [ text (Maybe.withDefault "unprocessed" row.reason) ]
        ]
