module Util.FailureCopy exposing (rateLimited, saveFailure, waitPhrase)

{-| The sentences the app says when something did not work (Issue #374).


## Why these live together

Four surfaces — the login card, the upload page and the settings forms — each
reach the same handful of failures, and each had written its own sentence for
them. The sentences did not agree, and two of them were not true. A shared
vocabulary is the small half of the win; the large half is that the rule they
all have to obey is written down once, next to the words, where the next person
adding a branch will read it.


## ⛔ The rule

**Never name a cause the response did not carry.**

`Page.Login` mapped every unhandled status onto "Invalid email or password", so
a 502 from a restarting node told readers their credentials were wrong. They
retype details that are correct, fail again, and conclude the account is gone.
The message was not merely unhelpful — it sent the reader to fix the one thing
that was not broken.

The same shape is why `rateLimited` takes a `Maybe Int` and not an `Int` with a
default. `retry-after` is a header; a caller that could not read it knows only
that it must wait, and the copy for that case says exactly that and no more.
Hard-coding "60 seconds" to make the sentence nicer would still read "60
seconds" the day `StacksWeb.Plugs.RateLimiter` is retuned, and nothing would
fail.

The unknown branch of every function here says the failure is unknown. That is
not an apology for missing detail; it is the detail.

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
the page's `onExpired` handler before any resolver sees the response (#361), so
a 401 can never reach here, and a branch for it would be dead code that looked
like coverage.

-}
saveFailure : String -> Http.Error -> String
saveFailure subject err =
    case err of
        Http.BadStatus 422 ->
            -- The reader did not type these values — settings forms send
            -- toggles and picks — so a rejection means this page and the server
            -- disagree about what is on offer, which a reload settles.
            "The library would not accept that change to " ++ subject ++ ". Reload the page and try again."

        Http.BadStatus 429 ->
            -- No `retry-after` available: these endpoints are authenticated and
            -- go through `Api.authedExpect`, which hands the caller an
            -- `Http.Error` with the headers already discarded.
            rateLimited Nothing

        Http.BadStatus 503 ->
            "The library is briefly overloaded. Please try again in a few seconds."

        Http.NetworkError ->
            "The library is unreachable, so " ++ subject ++ " were not saved. Check your connection, then try again."

        Http.Timeout ->
            -- Deliberately does NOT claim the change was lost. A request that
            -- timed out may well have been applied; the honest report is that
            -- we stopped waiting for the answer, and where to look for it.
            "The library took too long to answer, so we cannot say whether " ++ subject ++ " were saved. Reload the page to see."

        _ ->
            "We could not save " ++ subject ++ ", and we cannot say why. Please try again."
