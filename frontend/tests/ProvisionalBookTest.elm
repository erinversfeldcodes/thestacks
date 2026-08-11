module ProvisionalBookTest exposing (suite)

{-| A book whose ISBN nothing has identified yet must read as unidentified.

The server's stand-in title for such a book is the string `"ISBN 978…"`. Rendered
where a title goes it reads as a book actually NAMED after a number, and the
reader cannot tell a bug from a rare book from a lookup still in flight.

Two things are under test, and the second matters as much as the first:

1.  the treatment fires, and is driven by `verificationSource` — never by whether
    the title happens to start with `"ISBN "`. The title is a guess about the
    state; the field IS the state, and the guess is wrong in both directions.
2.  it INFORMS and stops. A provisional book is a legal state — the ISBN gate
    passed and only the catalogue lookup is outstanding — so nothing may be
    disabled or skipped because of it (standing owner ruling).

-}

import Expect
import Fuzz exposing (Fuzzer)
import Html.Attributes
import Page.BookDetail as BookDetail
import Page.Upload as Upload exposing (UploadStep(..))
import Test exposing (Test, describe, fuzz2, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Types.Book exposing (Book, Edition, VisibilityTier(..), displayTitle, isProvisional, isUnidentified)
import Types.RemoteData exposing (RemoteData(..))


provisionalIsbn : String
provisionalIsbn =
    "9780743273565"


{-| Exactly what `Moderation`'s barcode fast path writes: a placeholder title,
no cover, no author, and `verification_source = "barcode_unverified"`.
-}
provisionalEdition : Edition
provisionalEdition =
    { id = "edition-provisional"
    , isbn = provisionalIsbn
    , formatLabel = Nothing
    , coverImageUrl = Nothing
    , pageCount = Nothing
    , publisher = Nothing
    , publicationYear = Nothing
    , isPrimary = True
    , verificationSource = "barcode_unverified"
    }


provisionalBook : Book
provisionalBook =
    { id = "book-provisional"
    , title = "ISBN " ++ provisionalIsbn
    , author = Nothing
    , description = Nothing
    , editions = [ provisionalEdition ]
    , primaryEdition = Just provisionalEdition
    , editionCount = 1
    , subjects = []
    , visibilityTier = Public
    }


identifiedEdition : Edition
identifiedEdition =
    { provisionalEdition
        | id = "edition-identified"
        , verificationSource = "open_library"
    }


identifiedBook : Book
identifiedBook =
    { provisionalBook
        | id = "book-identified"
        , title = "The Great Gatsby"
        , editions = [ identifiedEdition ]
        , primaryEdition = Just identifiedEdition
    }


{-| The case a title heuristic gets wrong in the direction that matters most:
Open Library HAS identified this ISBN, and enrichment has already replaced the
placeholder — but the row's provenance is what says so, and a
`String.startsWith "ISBN "` test would agree with us here purely by luck while
silently losing every book it was written to catch.
-}
enrichedAfterBarcodeBook : Book
enrichedAfterBarcodeBook =
    { provisionalBook
        | id = "book-enriched"
        , title = "Pride and Prejudice"
        , editions = [ identifiedEdition ]
        , primaryEdition = Just identifiedEdition
    }


{-| A real, Open Library-identified book whose real title starts with "ISBN ".
A title heuristic calls this reader's fully identified book unidentified.
-}
realBookTitledIsbn : Book
realBookTitledIsbn =
    { identifiedBook
        | id = "book-real-isbn-title"
        , title = "ISBN 9780262561754 and Other Numbers"
    }


{-| The direction that actually bites, and the one the issue names.

Nothing external has confirmed this ISBN — it IS provisional — but its title is
not `"ISBN …"`. That combination is reachable today:
`Books.attrs_from_resolved/2` writes `"Unknown Title"` when the resolver answered
without one, and `verification_source_from/1` says `"barcode_unverified"` when
that answer carried no Open Library or Google Books id. A
`String.startsWith "ISBN "` driver finds nothing here, and the reader is left
with a book called "Unknown Title" and no explanation — the heuristic failing
silently, in the population it exists to serve.

-}
provisionalWithoutIsbnTitle : Book
provisionalWithoutIsbnTitle =
    { provisionalBook
        | id = "book-provisional-unknown-title"
        , title = "Unknown Title"
    }


bookDetailModelFor : Book -> BookDetail.Model
bookDetailModelFor book =
    let
        ( base, _ ) =
            BookDetail.init book.id Nothing Nothing
    in
    { base | book = Success book }


reportedRow : Book
reportedRow =
    let
        ed =
            { provisionalEdition
                | id = "edition-1q84"
                , isbn = "9780099448792"
            }
    in
    { provisionalBook
        | id = "book-1q84"
        , title = "1Q84"
        , editions = [ ed ]
        , primaryEdition = Just ed
    }


{-| A book carrying `title` and `verificationSource`, everything else held
constant, so the two axes of the invariant vary alone.
-}
bookWith : String -> String -> Book
bookWith title verificationSource =
    let
        ed =
            { provisionalEdition | verificationSource = verificationSource }
    in
    { provisionalBook
        | title = title
        , editions = [ ed ]
        , primaryEdition = Just ed
    }


{-| The stand-ins the SERVER mints when nothing told it what the book is called
— `Moderation.derive_title/3`'s `"ISBN <isbn>"` and
`Books.attrs_from_resolved/2`'s `"Unknown Title"`, plus an absent title.

Restated here rather than imported from `Types.Book`. Asking the production
predicate would prove only that the view calls whatever the predicate says;
naming the strings independently means widening the predicate — teaching it to
call some other title a non-title — reddens this instead of silently agreeing
with itself.

-}
isServerStandIn : String -> Bool
isServerStandIn title =
    (String.trim title == "")
        || (title == "ISBN " ++ provisionalIsbn)
        || (title == "Unknown Title")


{-| Titles that are names. Deliberately includes the shapes a prefix heuristic
gets wrong in both directions, and arbitrary strings besides.
-}
realTitleFuzzer : Fuzzer String
realTitleFuzzer =
    Fuzz.filter (not << isServerStandIn)
        (Fuzz.oneOf
            [ Fuzz.map String.trim (Fuzz.stringOfLengthBetween 1 40)
            , Fuzz.oneOfValues
                [ "1Q84"
                , "ISBN 9780262561754 and Other Numbers"
                , "ISBN"
                , "ISBN 9780000000000"
                , "Unknown Titles"
                , "The Great Gatsby"
                , "Not yet"
                ]
            ]
        )


{-| Every value the CHECK constraint on `op.book_editions.verification_source`
allows. The invariant must hold across all three — a title is a title whoever
did or did not confirm the ISBN beside it.
-}
verificationSourceFuzzer : Fuzzer String
verificationSourceFuzzer =
    Fuzz.oneOfValues [ "open_library", "google_books", "barcode_unverified" ]


standInTitleFuzzer : Fuzzer String
standInTitleFuzzer =
    Fuzz.oneOfValues
        [ ""
        , "   "
        , "ISBN " ++ provisionalIsbn
        , "Unknown Title"
        ]


noticeSelector : Selector.Selector
noticeSelector =
    Selector.attribute (Html.Attributes.attribute "data-testid" "book-provisional-notice")


titleSelector : Selector.Selector
titleSelector =
    Selector.attribute (Html.Attributes.attribute "data-testid" "book-title")


uploadNoticeSelector : Selector.Selector
uploadNoticeSelector =
    Selector.attribute (Html.Attributes.attribute "data-testid" "upload-provisional-notice")


{-| The upload flow reaches the same population and had the same defect.

Found by probe: pointing `Page.Upload`'s two call sites back at `isProvisional`
reddened NOTHING, because every Upload fixture in this file pairs
`barcode_unverified` with a stand-in title. `Books.confirm/2` returns a book
whose resolver supplied a title but no Open Library or Google Books id — the
206-of-206 shape — and on that book the completion card said "This book added to
Library" while holding its name, and printed "the title and cover will fill in
shortly" beside the title it had.

-}
uploadInvariantSuite : Test
uploadInvariantSuite =
    describe "— the upload flow may not wait for a title it already has"
        [ test "the verify step names the book and does not promise a title it is showing" <|
            \_ ->
                Upload.view { init_ | step = Verifying reportedRow } (Just "token") Types.RemoteData.NotAsked
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.has [ Selector.text "1Q84" ]
                        , Query.hasNot [ uploadNoticeSelector ]
                        ]
        , test "the shelf picker quotes the title rather than saying 'This book'" <|
            \_ ->
                Upload.view { init_ | step = ChoosingShelf reportedRow } (Just "token") Types.RemoteData.NotAsked
                    |> Query.fromHtml
                    |> Query.has [ Selector.text "Add \"1Q84\" to a shelf" ]
        , test "the completion card quotes the title rather than saying 'This book'" <|
            \_ ->
                Upload.view { init_ | step = Complete reportedRow "library" } (Just "token") Types.RemoteData.NotAsked
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.has [ Selector.text "\"1Q84\" added to Library" ]
                        , Query.hasNot [ uploadNoticeSelector ]
                        ]
        ]


invariantSuite : Test
invariantSuite =
    describe "— the page may never deny a title it is holding"
        [ test "the row from the preview: 1Q84, barcode_unverified, real title" <|
            \_ ->
                BookDetail.view (bookDetailModelFor reportedRow)
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.find [ titleSelector ] >> Query.has [ Selector.exactText "1Q84" ]
                        , Query.hasNot [ noticeSelector ]
                        ]
        , test "a real book named 'ISBN …' is still safe once provenance no longer decides alone" <|
            \_ ->
                BookDetail.view (bookDetailModelFor (bookWith "ISBN 9780262561754 and Other Numbers" "barcode_unverified"))
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.find [ titleSelector ]
                            >> Query.has [ Selector.exactText "ISBN 9780262561754 and Other Numbers" ]
                        , Query.hasNot [ noticeSelector ]
                        ]
        , fuzz2 realTitleFuzzer verificationSourceFuzzer "a book whose title is a name shows it, and the page never says it cannot" <|
            \title verificationSource ->
                BookDetail.view (bookDetailModelFor (bookWith title verificationSource))
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.find [ titleSelector ] >> Query.has [ Selector.exactText title ]
                        , Query.hasNot [ noticeSelector ]
                        ]
        , fuzz2 standInTitleFuzzer (Fuzz.constant "barcode_unverified") "a book with no name still says so, whatever stand-in the server wrote (#344 holds)" <|
            \title verificationSource ->
                BookDetail.view (bookDetailModelFor (bookWith title verificationSource))
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.find [ titleSelector ] >> Query.has [ Selector.exactText "Not yet identified" ]
                        , Query.find [ noticeSelector ] >> Query.has [ Selector.text provisionalIsbn ]
                        ]
        , test "a catalogue that answered without a title is not accused of never answering" <|
            \_ ->
                BookDetail.view (bookDetailModelFor (bookWith "Unknown Title" "open_library"))
                    |> Query.fromHtml
                    |> Query.hasNot [ noticeSelector ]
        , fuzz2 realTitleFuzzer verificationSourceFuzzer "the two claims stay separable: provenance is still readable on its own" <|
            \title verificationSource ->
                Expect.all
                    [ \b -> isProvisional b |> Expect.equal (verificationSource == "barcode_unverified")
                    , \b -> isUnidentified b |> Expect.equal False
                    ]
                    (bookWith title verificationSource)
        ]


suite : Test
suite =
    describe "Provisional books"
        [ describe "isProvisional is driven by verificationSource, not the title"
            [ test "a barcode-only book is provisional" <|
                \_ ->
                    isProvisional provisionalBook |> Expect.equal True
            , test "an Open Library-identified book is not" <|
                \_ ->
                    isProvisional identifiedBook |> Expect.equal False
            , test "a book enriched AFTER arriving by barcode is no longer provisional" <|
                \_ ->
                    isProvisional enrichedAfterBarcodeBook |> Expect.equal False
            , test "a real book actually titled 'ISBN …' is NOT treated as provisional" <|
                \_ ->
                    Expect.all
                        [ \b -> isProvisional b |> Expect.equal False
                        , \b -> displayTitle b |> Expect.equal "ISBN 9780262561754 and Other Numbers"
                        ]
                        realBookTitledIsbn
            , test "a provisional book whose title is NOT 'ISBN …' is still caught" <|
                \_ ->
                    Expect.all
                        [ \b -> isProvisional b |> Expect.equal True
                        , \b -> displayTitle b |> Expect.equal "Not yet identified"
                        ]
                        provisionalWithoutIsbnTitle
            , test "a book with no primary edition is not claimed to be provisional" <|
                \_ ->
                    isProvisional { provisionalBook | primaryEdition = Nothing }
                        |> Expect.equal False
            ]
        , describe "displayTitle"
            [ test "a provisional book is not shown wearing its ISBN as a name" <|
                \_ ->
                    Expect.all
                        [ \b -> displayTitle b |> Expect.notEqual b.title
                        , \b -> displayTitle b |> Expect.equal "Not yet identified"
                        ]
                        provisionalBook
            , test "an identified book shows its own title untouched" <|
                \_ ->
                    displayTitle identifiedBook |> Expect.equal "The Great Gatsby"
            ]
        , describe "upload verify step"
            [ test "renders the provisional notice, naming the ISBN as an ISBN" <|
                \_ ->
                    Upload.view { init_ | step = Verifying provisionalBook } (Just "token") Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Query.find [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-provisional-notice") ]
                        |> Query.has [ Selector.text provisionalIsbn ]
            , test "does not print the placeholder title as the book's name" <|
                \_ ->
                    Upload.view { init_ | step = Verifying provisionalBook } (Just "token") Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Query.hasNot [ Selector.text ("ISBN " ++ provisionalIsbn) ]
            , test "an identified book gets no notice" <|
                \_ ->
                    Upload.view { init_ | step = Verifying identifiedBook } (Just "token") Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Query.hasNot
                            [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-provisional-notice") ]
            , test "INFORMS ONLY: both confirm and reject stay on screen and enabled" <|
                \_ ->
                    Upload.view { init_ | step = Verifying provisionalBook } (Just "token") Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.find
                                [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-confirm-btn") ]
                                >> Query.hasNot [ Selector.disabled True ]
                            , Query.find
                                [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-reject-btn") ]
                                >> Query.hasNot [ Selector.disabled True ]
                            ]
            ]
        , describe "upload shelf picker"
            [ test "offers every shelf for a provisional book" <|
                \_ ->
                    Upload.view { init_ | step = ChoosingShelf provisionalBook } (Just "token") Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Query.findAll [ Selector.class "upload-shelf-picker__shelf" ]
                        |> Query.count (Expect.equal 5)
            , test "the heading does not quote a status as if it were a title" <|
                \_ ->
                    Upload.view { init_ | step = ChoosingShelf provisionalBook } (Just "token") Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "Add This book to a shelf" ]
            , test "an identified book still gets its title quoted in the heading" <|
                \_ ->
                    Upload.view { init_ | step = ChoosingShelf identifiedBook } (Just "token") Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "Add \"The Great Gatsby\" to a shelf" ]
            ]
        , describe "upload completion card"
            [ test "confirms the placement happened and explains the missing title" <|
                \_ ->
                    Upload.view { init_ | step = Complete provisionalBook "library" } (Just "token") Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.has [ Selector.text "This book added to Library" ]
                            , Query.find
                                [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-provisional-notice") ]
                                >> Query.has [ Selector.text provisionalIsbn ]
                            ]
            , test "an identified book keeps the quoted-title heading" <|
                \_ ->
                    Upload.view { init_ | step = Complete identifiedBook "library" } (Just "token") Types.RemoteData.NotAsked
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "\"The Great Gatsby\" added to Library" ]
            ]
        , describe "book detail page"
            [ test "the title element says unidentified rather than showing the ISBN" <|
                \_ ->
                    BookDetail.view (bookDetailModelFor provisionalBook)
                        |> Query.fromHtml
                        |> Query.find
                            [ Selector.attribute (Html.Attributes.attribute "data-testid" "book-title") ]
                        |> Query.has [ Selector.text "Not yet identified" ]
            , test "the notice names the ISBN and says the book is still theirs" <|
                \_ ->
                    BookDetail.view (bookDetailModelFor provisionalBook)
                        |> Query.fromHtml
                        |> Query.find
                            [ Selector.attribute (Html.Attributes.attribute "data-testid" "book-provisional-notice") ]
                        |> Query.has [ Selector.text provisionalIsbn ]
            , test "an identified book's detail page is untouched" <|
                \_ ->
                    BookDetail.view (bookDetailModelFor identifiedBook)
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.find
                                [ Selector.attribute (Html.Attributes.attribute "data-testid" "book-title") ]
                                >> Query.has [ Selector.text "The Great Gatsby" ]
                            , Query.hasNot
                                [ Selector.attribute (Html.Attributes.attribute "data-testid" "book-provisional-notice") ]
                            ]
            ]
        , invariantSuite
        , uploadInvariantSuite
        ]


init_ : Upload.Model
init_ =
    Upload.init
