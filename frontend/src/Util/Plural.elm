module Util.Plural exposing (books)

{-| Count-aware English labels.

The recurring bug this exists to kill is "1 books" — a label built as
`String.fromInt n ++ " books"` reads correctly for every count except one, and
one is the count a brand-new reader's first shelf almost always has. Screen
readers announce the shelf label verbatim, so the grammatical slip is heard, not
just seen (TR-6).

One function, one source of truth, so a second surface cannot drift back to the
naive concatenation.

-}


{-| A book count as a human label: `books 1 == "1 book"`, `books 2 == "2 books"`,
`books 0 == "0 books"`.
-}
books : Int -> String
books count =
    if count == 1 then
        "1 book"

    else
        String.fromInt count ++ " books"
