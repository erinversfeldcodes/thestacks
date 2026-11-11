module Api.Url exposing
    ( SameOriginUrl
    , path, toString
    )

{-| A URL that cannot leave our origin, enforced by construction.

⛔ **WHY THIS IS A MODULE AND NOT A TYPE IN `Api`.** Opacity is per-module: a
custom type whose constructor is unexposed is still transparent inside the
module that declares it. Every request builder lives in `Api`, so a
`SameOriginUrl` declared there would be exactly as bypassable as the convention
it replaces — `SameOriginUrl ("https://" ++ host)` would compile. Here, the
constructor is unreachable from `Api`, and `path` is the only way to obtain one.

⚖️ **What this replaces.** `Api.Destination` was declared by the caller rather
than derived from the URL, so `requestHeaders SameOrigin (Session token)` at a
foreign URL attached the reader's bearer token. Two script gates related the
declaration to the URL text beside it. A compile error beats a CI gate: it needs
no population floor, no comment-stripping pass, and no corpus walk, and it
cannot be satisfied by a file the gate forgot to read.


# The type

@docs SameOriginUrl


# Building one

@docs path, toString

-}

import Url
import Url.Builder exposing (QueryParameter)


{-| An absolute path on our own origin. Opaque: the only constructor is
[`path`](#path).
-}
type SameOriginUrl
    = SameOriginUrl String


{-| Build a URL from path segments and query parameters.

⛔ **THIS DOES NOT USE `Url.Builder.absolute`, AND THAT IS THE WHOLE POINT.**
Its body is

    absolute pathSegments params =
        "/" ++ String.join "/" pathSegments ++ toQuery params

and `percentEncode` is applied only to query keys and values — never to path
segments. So `absolute [ "/evil.test" ] []` yields `//evil.test`, a
protocol-relative URL that browsers resolve against the current scheme and send
to another host; `absolute [ "", "evil.test" ]` does the same. Building this
type on it would reproduce, _inside the type meant to close the hole_, the exact
defect that made the gate's rule unsound.

So each segment is percent-encoded here. `/` becomes `%2F` and stays one
segment, which means the result always begins with exactly one `/` and can name
no host, whatever a caller passes.

⛔ **AND EMPTY SEGMENTS ARE DROPPED, WHICH ENCODING ALONE DOES NOT HANDLE.** The
first version of this function only encoded, and its own test caught the hole:
`percentEncode ""` is `""`, so `path [ "", "evil.test" ]` joined to
`"/evil.test"` and the leading `"/"` made it `"//evil.test"` — the very escape
this type exists to prevent, surviving inside the replacement. There is nothing
to encode in an empty string, so it has to go.

⚠️ A segment is encoded, not rejected. A caller passing `"a/b"` gets one
segment spelled `a%2Fb` rather than two — the request will 404 rather than
silently reaching a path nobody intended, and no input can escape the origin.

-}
path : List String -> List QueryParameter -> SameOriginUrl
path segments params =
    SameOriginUrl
        ("/"
            ++ String.join "/"
                (segments
                    |> List.filter (not << String.isEmpty)
                    |> List.map Url.percentEncode
                )
            ++ Url.Builder.toQuery params
        )


{-| The URL as a string, for handing to `Http.request`.

⚠️ One-way by design: there is no `fromString`. A string can leave this type but
cannot enter it, which is what keeps the guarantee.

-}
toString : SameOriginUrl -> String
toString (SameOriginUrl url) =
    url
