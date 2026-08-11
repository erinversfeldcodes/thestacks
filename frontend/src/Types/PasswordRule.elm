module Types.PasswordRule exposing
    ( isLongEnough
    , minLength
    , requirementHint
    , tooShort
    , tooShortFor
    )

{-| The password-length rule and the sentence stating it — one number, one
sentence. It was ten places and five wordings: three enforcement sites
each wrote `8`, and the reader was told the rule seven more times in
five different phrasings. `minLength` and `statement` are the only
source; enforcement and copy cannot disagree again.
-}


{-| The minimum length, matching `Stacks.Accounts`' `validate_length(:password,
min: 8, …)` on every password changeset. If this moves, the server moves too —
they are two systems, so this cannot be a shared constant, but it can at least
be ONE constant on this side.
-}
minLength : Int
minLength =
    8


{-| True when the password satisfies the rule. Every client-side gate asks this
rather than counting characters itself.
-}
isLongEnough : String -> Bool
isLongEnough password =
    String.length password >= minLength


{-| The rule as an input placeholder or inline hint — a requirement, not a
failure, so it is phrased as one: "At least 8 characters".
-}
requirementHint : String
requirementHint =
    "At least " ++ String.fromInt minLength ++ " characters"


{-| The rule as a validation failure about a named field.

    tooShortFor "New password" --> "New password must be at least 8 characters."

-}
tooShortFor : String -> String
tooShortFor subject =
    subject ++ " must be at least " ++ String.fromInt minLength ++ " characters."


{-| The rule as a validation failure about _the_ password — the unqualified case,
used wherever there is only one password field on screen.
-}
tooShort : String
tooShort =
    tooShortFor "Password"
