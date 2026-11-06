module RefusalTokenTest exposing (suite)

{-| One answer to "what does this 401 mean?", read from the signal that can
carry it.

⛔ WHY THIS EXISTS. The app classified a 401 in two places that disagreed. Boot's
`Api.refusalFrom` read the server's reason token and was three-valued. Every
authenticated request's `Api.interceptExpiry` read `metadata.statusCode == 401`
and nothing else — re-making, eight days later, a decision that had been settled
on the grounds that the client CANNOT make it: the session cookie is `HttpOnly`,
so the page cannot see whether the browser sent one, and the server already
classified the rejection and was throwing the classification away.

⚖️ WHAT IS ASSERTED. Three things, and the third is the one a single-path test
could not state:

1.  `Api.refusalToken` reads the token, with three outcomes.
2.  Boot's mapping of those outcomes is unchanged.
3.  The two paths' verdicts AGREE on the only question they both answer — "is
    this 401 evidence about the session at all?" — over the same table of
    bodies. That is the parity the issue is about, and it fails if either path
    is changed alone.

⚠️ The two paths deliberately map the readable outcomes DIFFERENTLY, and that is
not a disagreement. Boot asks "is this browser signed in?", where a first-time
visitor is one of the answers. A request built by `Api.authed` carries a
credential by construction, so there is no first-time visitor to mistake: any
readable refusal is the credential not being accepted. The parity below is
therefore stated over the question they share, not over their outputs.

-}

import Api
import Dict
import Expect
import Http
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "what a 401 means, decided once"
        [ describe "the server's reason token, read"
            [ aRefusedSessionIsNamed
            , anotherKnownTokenIsNamed
            , theMixedTransportTokenIsNamed
            , anEmptyBodyIsUnreadable
            , aProxyErrorPageIsUnreadable
            , aJsonBodyWithNoReasonIsUnreadable
            ]
        , describe "boot's reading of those three outcomes"
            [ bootCallsARefusedSessionRefused
            , bootCallsAnotherReasonNoSession
            , bootCallsAnUnreadableReasonUnavailable
            ]
        , describe "both request paths answer the shared question the same way"
            [ theTwoPathsAgreeOnEveryBody
            ]
        ]



-- THE TOKEN


aRefusedSessionIsNamed : Test
aRefusedSessionIsNamed =
    test "refusal_session_expired: the one token that names a refused session" <|
        \() ->
            Api.refusalToken "{\"error\":\"session_expired\"}"
                |> Expect.equal Api.SessionWasRefused


{-| `AdminAuthPipeline` answers `unauthorized`; `AuthErrorHandler` answers
Guardian's own type when no cookie was rejected.
-}
anotherKnownTokenIsNamed : Test
anotherKnownTokenIsNamed =
    test "refusal_unauthenticated: a reason we can read, naming something else" <|
        \() ->
            Api.refusalToken "{\"error\":\"unauthenticated\"}"
                |> Expect.equal Api.AnotherReason


{-| ⚠️ THE MIXED-TRANSPORT CASE. A refused session cookie sent alongside a
bearer reaches `VerifyHeader`'s error first, and an earlier `AuthErrorHandler`
reported that as `invalid_token` rather than `session_expired` — keyed on
Guardian's type instead of on the rejection. The server now reads the rejection
flag, so the token is `session_expired` again; this pins what the CLIENT does if
it ever is not, which is the half of the case the client owns. `AnotherReason`,
and `interceptExpiry` routes it to expiry, so the reader is not told to retry
against a session that is gone.
-}
theMixedTransportTokenIsNamed : Test
theMixedTransportTokenIsNamed =
    test "refusal_invalid_token: a refused bearer is a readable reason" <|
        \() ->
            Api.refusalToken "{\"error\":\"invalid_token\"}"
                |> Expect.equal Api.AnotherReason


anEmptyBodyIsUnreadable : Test
anEmptyBodyIsUnreadable =
    test "refusal_empty_body: nothing to read is not an answer" <|
        \() ->
            Api.refusalToken ""
                |> Expect.equal Api.ReasonUnreadable


{-| ⛔ The case the third outcome exists for: a 401 that did not come from the
application at all.
-}
aProxyErrorPageIsUnreadable : Test
aProxyErrorPageIsUnreadable =
    test "refusal_proxy_html: a gateway's error page is not evidence about the session" <|
        \() ->
            Api.refusalToken "<html><body><h1>401 Authorization Required</h1></body></html>"
                |> Expect.equal Api.ReasonUnreadable


{-| Valid JSON is not the same as a reason. An error shape that changed under us
reads exactly like a proxy page from here, and must be treated the same way.
-}
aJsonBodyWithNoReasonIsUnreadable : Test
aJsonBodyWithNoReasonIsUnreadable =
    test "refusal_json_without_a_reason: well-formed is not readable" <|
        \() ->
            Api.refusalToken "{\"detail\":\"nope\"}"
                |> Expect.equal Api.ReasonUnreadable



-- BOOT'S READING


bootCallsARefusedSessionRefused : Test
bootCallsARefusedSessionRefused =
    test "boot_session_expired_is_a_refusal: the reader is owed an explanation" <|
        \() ->
            Api.refusalFrom "{\"error\":\"session_expired\"}"
                |> Expect.equal Api.SessionRefused


bootCallsAnotherReasonNoSession : Test
bootCallsAnotherReasonNoSession =
    test "boot_unauthenticated_is_no_session: a first-time visitor is told nothing" <|
        \() ->
            Api.refusalFrom "{\"error\":\"unauthenticated\"}"
                |> Expect.equal Api.NoSession


bootCallsAnUnreadableReasonUnavailable : Test
bootCallsAnUnreadableReasonUnavailable =
    test "boot_unreadable_is_unavailable: we asked and could not read the answer" <|
        \() ->
            Api.refusalFrom "<html>401</html>"
                |> Expect.equal (Api.IdentityUnavailable Api.Unreadable)



-- THE PARITY


{-| Stands in for the two destinations an authenticated request's 401 has.
-}
type Routed
    = ToExpiry
    | ToTheHandler


{-| Where `interceptExpiry` sends a 401 carrying this body, driven through the
real function with a real `Http.Response`.
-}
routedBy : String -> Routed
routedBy body =
    Api.interceptExpiry ToExpiry
        (\_ -> ToTheHandler)
        (Http.BadStatus_
            { url = "/api/auth/me"
            , statusCode = 401
            , statusText = "Unauthorized"
            , headers = Dict.empty
            }
            body
        )


{-| Whether BOOT read this body as evidence about the session: both 401 answers
are, `IdentityUnavailable` is not.
-}
bootTreatedAsEvidence : String -> Routed
bootTreatedAsEvidence body =
    case Api.refusalFrom body of
        Api.SessionRefused ->
            ToExpiry

        Api.NoSession ->
            ToExpiry

        Api.IdentityUnavailable _ ->
            ToTheHandler

        Api.IdentityKnown _ ->
            -- `refusalFrom` only ever reads a 401, so this cannot arise. Named
            -- rather than defaulted, so a future constructor is a compile error
            -- here instead of a silent reclassification.
            ToTheHandler


{-| ⛔ THE CLAIM THE ISSUE IS ABOUT. For every body, the two request paths agree
on whether this 401 says anything about the session — because they read the same
function to find out. Changing one path's matcher and not the other's reds this.

⚖️ The table includes the two readable shapes AND the three unreadable ones, so
the agreement is not an artefact of only ever being asked about one.

⚠️ Every cell is pinned rather than filtered down to the disagreements. A test
that asserts "the disagreements are empty" also passes when nothing was compared
— and the whole point here is that the comparison happened over a table with
both answers in it.

-}
theTwoPathsAgreeOnEveryBody : Test
theTwoPathsAgreeOnEveryBody =
    test "the_two_401_paths_agree: one classification, read from one place" <|
        \() ->
            [ "{\"error\":\"session_expired\"}"
            , "{\"error\":\"unauthenticated\"}"
            , "{\"error\":\"invalid_token\"}"
            , "{\"error\":\"unauthorized\"}"
            , ""
            , "<html><body>401</body></html>"
            , "{\"detail\":\"nope\"}"
            ]
                |> List.map (\body -> ( routedBy body, bootTreatedAsEvidence body ))
                |> Expect.equalLists
                    [ ( ToExpiry, ToExpiry )
                    , ( ToExpiry, ToExpiry )
                    , ( ToExpiry, ToExpiry )
                    , ( ToExpiry, ToExpiry )
                    , ( ToTheHandler, ToTheHandler )
                    , ( ToTheHandler, ToTheHandler )
                    , ( ToTheHandler, ToTheHandler )
                    ]
