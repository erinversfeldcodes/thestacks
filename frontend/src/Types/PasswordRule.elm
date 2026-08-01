module Types.PasswordRule exposing
    ( isLongEnough
    , minLength
    , requirementHint
    , tooShort
    , tooShortFor
    )

{-| The password-length rule, and the sentence the reader is told it in.


## Why this exists

The rule is one number and one sentence. It was ten places and five sentences.

The number `8` was written out at three enforcement sites (`Page.Login`,
`Page.ResetPassword`, `Page.Settings.Password`), and the rule was stated to the
reader seven more times in **five different wordings**:

  - "Password must be at least 8 characters" — the register field hint, no full stop
  - "Password must be at least 8 characters." — the reset page, with one
  - "New password must be at least 8 characters." — the settings page
  - "At least 8 characters" — two input placeholders
  - "That password is too slight; please choose at least eight characters." —
    the register 422, on the **same form** as the first one, spelling the number
    as a word

The last pair is the clearest damage: a reader who typed a short password on the
register card saw the rule twice, phrased differently, with the number written
two different ways, and had to work out for themselves that these were the same
requirement and not two.

Nothing could catch that. No test compares two pieces of copy for agreement, and
a wording drifts silently the moment someone edits one site. So the wording is
here, built from `minLength`, and the number cannot be changed in one place and
missed in another.


## Why `tooShortFor` takes a subject

"Password" and "New password" are the same rule about different fields, and a
settings form that says "Password must be…" next to a _current_ password field
would be ambiguous about which one it means. The subject varies; the clause does
not.

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
