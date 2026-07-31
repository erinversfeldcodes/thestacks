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

    -- Which catalogue confirmed this ISBN: "open_library", "google_books", or
    -- "barcode_unverified" for none of them yet. See `isProvisional`.
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



-- MAPPING FROM PROTO


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
digit is good — but Open Library and Google Books have not told us what the book
IS, so `title` is the `"ISBN 978…"` placeholder the server minted and the cover
and author are empty. Enrichment runs asynchronously and usually fills it in
within seconds.

Driven by `verificationSource`, never by whether the title happens to start with
`"ISBN "` (#344). The title is a guess about the state; this field IS the state.
The guess is wrong in both directions: a real book could be titled `ISBN` and,
worse, the moment enrichment succeeds the title changes and a title test quietly
stops finding anything — which is exactly the population it most needs to find.
The server rewrites `verificationSource` in the same transaction that writes the
real title, so the two never disagree.

This is a legitimate state, not an error, and nothing in the UI may block on it.

-}
isProvisional : Book -> Bool
isProvisional bk =
    case bk.primaryEdition of
        Just ed ->
            ed.verificationSource == "barcode_unverified"

        Nothing ->
            False


{-| What to call this book on screen.

A provisional book has no name yet, only a number, and showing that number where
a title goes tells the reader something false — they cannot tell a bug from a
rare book from a lookup still in flight. Say the true thing instead; the ISBN is
still shown beside it, as an ISBN.

-}
displayTitle : Book -> String
displayTitle bk =
    if isProvisional bk then
        "Not yet identified"

    else
        bk.title



-- DECODERS


bookDecoder : Decoder Book
bookDecoder =
    Decode.map fromProtoBook Proto.decodeBook
