module Types.Book exposing
    ( Author
    , Book
    , Edition
    , VisibilityTier(..)
    , authorName
    , bookCoverImageUrl
    , bookDecoder
    , bookIsbn
    , bookPageCount
    , bookPublicationYear
    , displayTitle
    , fromProtoBook
    , fromProtoEdition
    , isProvisional
    , isUnidentified
    )

import Json.Decode as Decode exposing (Decoder)
import Stacks.Common.V1.Book as Proto
import Types.ProtoHelpers exposing (emptyToNothing, zeroToNothing)


type alias Author =
    { id : String
    , name : String
    , bio : Maybe String
    , website : Maybe String
    }


type VisibilityTier
    = Public
    | AgeGated
    | Unlisted
    | Private


type alias Edition =
    { id : String
    , isbn : String
    , formatLabel : Maybe String
    , coverImageUrl : Maybe String
    , pageCount : Maybe Int
    , publisher : Maybe String
    , publicationYear : Maybe Int
    , isPrimary : Bool
    , verificationSource : String
    }


type alias Book =
    { id : String
    , title : String
    , author : Maybe Author
    , description : Maybe String
    , editions : List Edition
    , primaryEdition : Maybe Edition
    , editionCount : Int
    , subjects : List String
    , visibilityTier : VisibilityTier
    }


fromProtoVisibility : Proto.VisibilityTier -> VisibilityTier
fromProtoVisibility pv =
    case pv of
        Proto.VisibilityTierPublic ->
            Public

        Proto.VisibilityTierAgeGated ->
            AgeGated

        Proto.VisibilityTierUnlisted ->
            Unlisted

        Proto.VisibilityTierPrivate ->
            Private

        Proto.VisibilityTierUnspecified ->
            Public


fromProtoAuthor : Proto.Author -> Author
fromProtoAuthor pa =
    { id = pa.id
    , name = pa.name
    , bio = emptyToNothing pa.bio
    , website = emptyToNothing pa.websiteUrl
    }


fromProtoEdition : Proto.Edition -> Edition
fromProtoEdition pe =
    { id = pe.id
    , isbn = pe.isbn
    , formatLabel = emptyToNothing pe.formatLabel
    , coverImageUrl = emptyToNothing pe.coverImageUrl
    , pageCount = zeroToNothing pe.pageCount
    , publisher = emptyToNothing pe.publisher
    , publicationYear = zeroToNothing pe.publicationYear
    , isPrimary = pe.isPrimary
    , verificationSource = pe.verificationSource
    }


fromProtoBook : Proto.Book -> Book
fromProtoBook pb =
    { id = pb.id
    , title = pb.title
    , author =
        if pb.author.id == "" && pb.author.name == "" then
            Nothing

        else
            Just (fromProtoAuthor pb.author)
    , description = emptyToNothing pb.description
    , editions = List.map fromProtoEdition pb.editions
    , primaryEdition =
        if pb.primaryEdition.id == "" && pb.primaryEdition.isbn == "" then
            Nothing

        else
            Just (fromProtoEdition pb.primaryEdition)
    , editionCount = pb.editionCount
    , subjects = pb.subjects
    , visibilityTier = fromProtoVisibility pb.visibilityTier
    }


{-| Returns the author's name, or "Unknown Author" when author is nil.
-}
authorName : Book -> String
authorName bk =
    case bk.author of
        Just a ->
            a.name

        Nothing ->
            "Unknown Author"


{-| ISBN from the primary edition, or empty string.
-}
bookIsbn : Book -> String
bookIsbn bk =
    case bk.primaryEdition of
        Just ed ->
            ed.isbn

        Nothing ->
            ""


{-| Cover image URL from the primary edition.
-}
bookCoverImageUrl : Book -> Maybe String
bookCoverImageUrl bk =
    bk.primaryEdition |> Maybe.andThen .coverImageUrl


{-| Page count from the primary edition.
-}
bookPageCount : Book -> Maybe Int
bookPageCount bk =
    bk.primaryEdition |> Maybe.andThen .pageCount


{-| Publication year from the primary edition.
-}
bookPublicationYear : Book -> Maybe Int
bookPublicationYear bk =
    bk.primaryEdition |> Maybe.andThen .publicationYear


{-| True when nothing outside The Stacks has yet confirmed this book's ISBN.

The ISBN gate has still passed — a barcode decoded cleanly and its EAN-13 check
digit is good — but neither Open Library nor Google Books has been recorded
against this edition. This is provenance and nothing else: it is a fact about
where the ISBN's confirmation came from, not about what The Stacks knows of the
book.

Driven by `verificationSource`, never by whether the title happens to start with
`"ISBN "` (#344). The title is a guess about the provenance; this field IS the
provenance. The guess is wrong in both directions: a real book could be titled
`ISBN` and, worse, the moment enrichment succeeds the title changes and a title
test quietly stops finding anything — which is exactly the population it most
needs to find.

This is a legitimate state, not an error, and nothing in the UI may block on it.

⚠️ This does NOT mean "we do not know what this book is" — see `isUnidentified`,
which is the question the screen actually asks, and #370 for what it cost to
answer one with the other.

-}
isProvisional : Book -> Bool
isProvisional bk =
    case bk.primaryEdition of
        Just ed ->
            ed.verificationSource == "barcode_unverified"

        Nothing ->
            False


{-| True when `title` is a name rather than one of the stand-ins the server
mints for itself when nothing told it what the book is called.

There are exactly two stand-ins, and the server writes both:
`Moderation.derive_title/3` writes `"ISBN <isbn>"` when the barcode fast path
deliberately skipped the catalogue lookup, and `Books.attrs_from_resolved/2`
writes `"Unknown Title"` when a resolver answered without one. An absent title
decodes to `""`.

Matched by EQUALITY against this row's own ISBN, never by prefix.
`String.startsWith "ISBN "` is the heuristic #344 rejected and it would call a
real book named `"ISBN 9780262561754 and Other Numbers"` nameless; the full
placeholder is the word `ISBN` and this edition's ISBN and nothing else, so a
title that says anything more cannot collide with it.

Deliberately NOT exposed. `ProvisionalBookTest` restates these three strings
rather than importing this, so that widening the rule reddens the test instead
of the test agreeing with whatever the rule has become.

-}
hasKnownTitle : Book -> Bool
hasKnownTitle bk =
    let
        title =
            String.trim bk.title
    in
    (title /= "")
        && (title /= "ISBN " ++ bookIsbn bk)
        && (title /= "Unknown Title")


{-| True when The Stacks holds no name for this book — only a number.

`isProvisional` and this are DIFFERENT claims, and #370 is the bill for
conflating them. `isProvisional` says _no provider has confirmed this ISBN_;
this says _we do not know what this book is_. Every edition in the
staging-derived database carries `barcode_unverified` — 206 of 206, honestly, as
none of them were provider-verified — while holding a real title. So the first
was true of all of them and the second of none, and the book detail page told
the reader it could not show a title it was printing two lines above, beside the
author, year and page count it also held.

Both conjuncts are required because the notice this drives makes both claims at
once: _we have the barcode, we have not matched it to a catalogue record, and so
we cannot show a title_. A sentence that asserts two things may only be shown
when both are true.

The fix is here and not in the data: relabelling those rows `open_library` would
assert a verification that never happened — the same untruth pointing the other
way.

-}
isUnidentified : Book -> Bool
isUnidentified bk =
    isProvisional bk && not (hasKnownTitle bk)


{-| What to call this book on screen.

A book we cannot name has only a number, and showing that number where a title
goes tells the reader something false — they cannot tell a bug from a rare book
from a lookup still in flight. Say the true thing instead; the ISBN is still
shown beside it, as an ISBN.

Keyed off `isUnidentified`, never `isProvisional`: a book whose title we hold
shows that title, whatever a provider did or did not confirm about its ISBN.

-}
displayTitle : Book -> String
displayTitle bk =
    if isUnidentified bk then
        "Not yet identified"

    else
        bk.title


bookDecoder : Decoder Book
bookDecoder =
    Decode.map fromProtoBook Proto.decodeBook
