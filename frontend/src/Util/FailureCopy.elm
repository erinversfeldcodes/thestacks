module Util.FailureCopy exposing (rateLimited, saveFailure, waitPhrase)

{-| The sentences the app says when something did not work. Four
surfaces reached the same failures and each wrote its own sentence —
they disagreed, and two were untrue. The vocabulary lives together with
its rule: name only what the response proves, blame credentials only on
a 401, and never name a control the surface doesn't render.
-}

import Http


{-| The rate limiter's answer, in the library's voice.

Consistent with the 423 account-lockout copy in `Page.Login` — both are "wait,
then try again" — and, like it, the unnumbered form names no interval at all
rather than an invented one.

-}
rateLimited : Maybe Int -> String
rateLimited retryAfter =
    case retryAfter of
        Just seconds ->
            "Too many attempts from here just now. Please wait "
                ++ waitPhrase seconds
                ++ " before trying again."

        Nothing ->
            "Too many attempts from here just now. Please wait a little while before trying again."


{-| A whole number of seconds as a phrase a reader can act on.

Minutes round **up** (`61` → "2 minutes"), because the error a rounded number
can make is sending the reader back before the limiter will have them, and being
early is the failure that repeats. Rounding down would produce a second 429 and
teach the reader the message is not to be trusted.

-}
waitPhrase : Int -> String
waitPhrase seconds =
    if seconds <= 1 then
        "a second"

    else if seconds < 60 then
        String.fromInt seconds ++ " seconds"

    else if seconds == 60 then
        "a minute"

    else
        String.fromInt ((seconds + 59) // 60) ++ " minutes"


{-| Why a settings form did not save, named for the thing that did not save.

`subject` is a noun phrase in the reader's possessive — "your notification
preferences" — so the sentences read as English rather than as a template.

The 401 leg is deliberately absent: `Api.Authed` diverts an expired session to
the page's `onExpired` handler before any resolver sees the response, so
a 401 can never reach here, and a branch for it would be dead code that looked
like coverage.

-}
saveFailure : String -> Http.Error -> String
saveFailure subject err =
    case err of
        Http.BadStatus 422 ->
            "The library would not accept that change to " ++ subject ++ ". Reload the page and try again."

        Http.BadStatus 429 ->
            rateLimited Nothing

        Http.BadStatus 503 ->
            "The library is briefly overloaded. Please try again in a few seconds."

        Http.NetworkError ->
            "The library is unreachable, so " ++ subject ++ " were not saved. Check your connection, then try again."

        Http.Timeout ->
            "The library took too long to answer, so we cannot say whether " ++ subject ++ " were saved. Reload the page to see."

        _ ->
            "We could not save " ++ subject ++ ", and we cannot say why. Please try again."
