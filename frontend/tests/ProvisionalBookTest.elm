module ProvisionalBookTest exposing (suite)

{-| A book whose ISBN nothing has identified yet must read as unidentified
(#344).

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
import Html.Attributes
import Page.BookDetail as BookDetail
import Page.Upload as Upload exposing (UploadStep(..))
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Types.Book exposing (Book, Edition, VisibilityTier(..), displayTitle, isProvisional)
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


suite : Test
suite =
    describe "Provisional books (#344)"
        [ describe "isProvisional is driven by verificationSource, not the title"
            [ test "a barcode-only book is provisional" <|
                \_ ->
                    isProvisional provisionalBook |> Expect.equal True
            , test "an Open Library-identified book is not" <|
                \_ ->
                    isProvisional identifiedBook |> Expect.equal False
            , test "a book enriched AFTER arriving by barcode is no longer provisional" <|
                \_ ->
                    -- The title changed and so did the provenance. A title
                    -- heuristic would also pass this one — and would then fail
                    -- every case where the two disagree, which is the population
                    -- the treatment exists for.
                    isProvisional enrichedAfterBarcodeBook |> Expect.equal False
            , test "a real book actually titled 'ISBN …' is NOT treated as provisional" <|
                \_ ->
                    -- False-positive direction: a title heuristic would tell this
                    -- reader their identified book is unidentified, and would
                    -- replace its real title with a status.
                    Expect.all
                        [ \b -> isProvisional b |> Expect.equal False
                        , \b -> displayTitle b |> Expect.equal "ISBN 9780262561754 and Other Numbers"
                        ]
                        realBookTitledIsbn
            , test "a provisional book whose title is NOT 'ISBN …' is still caught" <|
                \_ ->
                    -- False-negative direction, and the one that matters: this is
                    -- the population a title heuristic silently loses.
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
                    Upload.view { init_ | step = Verifying provisionalBook } (Just "token")
                        |> Query.fromHtml
                        |> Query.find [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-provisional-notice") ]
                        |> Query.has [ Selector.text provisionalIsbn ]
            , test "does not print the placeholder title as the book's name" <|
                \_ ->
                    Upload.view { init_ | step = Verifying provisionalBook } (Just "token")
                        |> Query.fromHtml
                        |> Query.hasNot [ Selector.text ("ISBN " ++ provisionalIsbn) ]
            , test "an identified book gets no notice" <|
                \_ ->
                    Upload.view { init_ | step = Verifying identifiedBook } (Just "token")
                        |> Query.fromHtml
                        |> Query.hasNot
                            [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-provisional-notice") ]
            , test "INFORMS ONLY: both confirm and reject stay on screen and enabled" <|
                \_ ->
                    -- The whole point of the ruling. A provisional book is one
                    -- the reader may shelve; the notice is a sentence, not a gate.
                    Upload.view { init_ | step = Verifying provisionalBook } (Just "token")
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
                    -- Five bookshelves, none withheld because the lookup is late.
                    Upload.view { init_ | step = ChoosingShelf provisionalBook } (Just "token")
                        |> Query.fromHtml
                        |> Query.findAll [ Selector.class "upload-shelf-picker__shelf" ]
                        |> Query.count (Expect.equal 5)
            , test "the heading does not quote a status as if it were a title" <|
                \_ ->
                    Upload.view { init_ | step = ChoosingShelf provisionalBook } (Just "token")
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "Add This book to a shelf" ]
            , test "an identified book still gets its title quoted in the heading" <|
                \_ ->
                    Upload.view { init_ | step = ChoosingShelf identifiedBook } (Just "token")
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "Add \"The Great Gatsby\" to a shelf" ]
            ]
        , describe "upload completion card"
            [ test "confirms the placement happened and explains the missing title" <|
                \_ ->
                    Upload.view { init_ | step = Complete provisionalBook "library" } (Just "token")
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.has [ Selector.text "This book added to Library" ]
                            , Query.find
                                [ Selector.attribute (Html.Attributes.attribute "data-testid" "upload-provisional-notice") ]
                                >> Query.has [ Selector.text provisionalIsbn ]
                            ]
            , test "an identified book keeps the quoted-title heading" <|
                \_ ->
                    Upload.view { init_ | step = Complete identifiedBook "library" } (Just "token")
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
        ]


init_ : Upload.Model
init_ =
    Upload.init
