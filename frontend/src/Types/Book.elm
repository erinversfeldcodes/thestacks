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


{-| True when nothing outside The Stacks has confirmed this ISBN: the gate
passed (clean barcode, good check digit) but neither OL nor GB is
recorded against the edition. Pure provenance — driven by
`verificationSource`, never by whether the title looks odd; a book can
be provisional with a real title and vice versa.
-}
isProvisional : Book -> Bool
isProvisional bk =
    case bk.primaryEdition of
        Just ed ->
            ed.verificationSource == "barcode_unverified"

        Nothing ->
            False


{-| True when `title` is a name rather than a server stand-in. There are
exactly two stand-ins, both server-written: `"ISBN <isbn>"` (barcode
fast path skipped the lookup) and `"Unknown Title"` (resolver answered
without one); absent decodes to `""`. Matching is exact — a real book
titled with an ISBN-like name stays a name.
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
DIFFERENT claim from `isProvisional`, and 370 is the bill for conflating
them: provisional says no provider confirmed the ISBN; this says we
don't know what the book IS. All 206 staging editions were honestly
provisional while holding real titles — rendering them all as pending
lookups was the bug.
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
