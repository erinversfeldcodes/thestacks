module ApiDecodersTest exposing (suite)

{-| The hand-written decoders in `Api`, against the shapes their servers
actually send.

Why these needed tests at all: the project's GENERATED decoders are
null-tolerant by construction (`oneOf [ field, succeed "" ]`), and these
hand-written ones dropped that tolerance without checking the server honours
it. One of them already cost a surface — a single Goodreads row with four NULL
columns made the entire import report permanently unloadable, because a list
decode fails whole. The same shape was latent in the import summary itself:
`op.library_imports.filename` is a nullable column and `libraryImportDecoder`
requires a string, so the server coalesces it.

Each decoder gets three cases: the populated shape, the server's nullable or
absent fields, and a field that must stay strict. The strict cases are the
point — a decoder with no required field tolerates a response that is not the
response at all.

-}

import Api
import Expect
import Json.Decode as Decode
import Test exposing (Test, describe, test)


expectDecodes : Decode.Decoder a -> String -> (a -> Expect.Expectation) -> Expect.Expectation
expectDecodes decoder json check =
    case Decode.decodeString decoder json of
        Ok value ->
            check value

        Err err ->
            Expect.fail (Decode.errorToString err)


expectFails : Decode.Decoder a -> String -> String -> Expect.Expectation
expectFails decoder json why =
    case Decode.decodeString decoder json of
        Ok _ ->
            Expect.fail why

        Err _ ->
            Expect.pass


suite : Test
suite =
    describe "hand-written Api decoders"
        [ describe "authorEventDecoder"
            [ test "decodes a dated event at a named store" <|
                \_ ->
                    expectDecodes Api.authorEventDecoder
                        """
                        { "id": "e1", "title": "An evening with the author",
                          "event_date": "2026-11-02T18:30:00Z",
                          "location": "Upstairs", "url": "https://shop.test/e1",
                          "store_name": "The Corner Shop" }
                        """
                        (\e -> Expect.equal (Just "The Corner Shop") e.storeName)
            , test "a dateless event still decodes — the shop's page has the details" <|
                \_ ->
                    -- `op.bookstore_events.event_date` is nullable by design: a
                    -- dateless event is listed last rather than dropped, so a
                    -- decoder that rejected one would drop the whole list.
                    expectDecodes Api.authorEventDecoder
                        """
                        { "id": "e2", "title": "Signing, date to be confirmed",
                          "event_date": null, "location": null, "url": null,
                          "store_name": null }
                        """
                        (\e -> Expect.equal Nothing e.eventDate)
            , test "an event with no title is a decode failure" <|
                \_ ->
                    -- The column is NOT NULL and the title is the whole render.
                    expectFails Api.authorEventDecoder
                        """{ "id": "e3", "event_date": null, "location": null,
                             "url": null, "store_name": null }"""
                        "title must stay required — an untitled event renders as nothing"
            ]
        , describe "libraryImportDecoder"
            [ test "decodes a finished import with its counts" <|
                \_ ->
                    expectDecodes Api.libraryImportDecoder
                        """
                        { "id": "i1", "status": "complete", "filename": "goodreads.csv",
                          "row_count": 10, "processed_count": 10, "shelved_count": 7,
                          "duplicate_count": 2, "unverified_count": 1,
                          "unreadable_count": 0 }
                        """
                        (\i -> Expect.equal ( "complete", 7 ) ( i.status, i.shelvedCount ))
            , test "a blank filename decodes — the column is nullable and the server coalesces" <|
                \_ ->
                    expectDecodes Api.libraryImportDecoder
                        """
                        { "id": "i2", "status": "enqueued", "filename": "",
                          "row_count": 0, "processed_count": 0, "shelved_count": 0,
                          "duplicate_count": 0, "unverified_count": 0,
                          "unreadable_count": 0 }
                        """
                        (\i -> Expect.equal "" i.filename)
            , test "a null filename is a decode failure, which is why the server coalesces it" <|
                \_ ->
                    -- This case documents the contract rather than asking for
                    -- tolerance: the fix belongs on the server, where the null
                    -- can be turned into the blank the page already renders.
                    expectFails Api.libraryImportDecoder
                        """
                        { "id": "i3", "status": "enqueued", "filename": null,
                          "row_count": 0, "processed_count": 0, "shelved_count": 0,
                          "duplicate_count": 0, "unverified_count": 0,
                          "unreadable_count": 0 }
                        """
                        "filename is typed as a String; if this starts passing the type changed"
            , test "a missing count is a decode failure" <|
                \_ ->
                    expectFails Api.libraryImportDecoder
                        """{ "id": "i4", "status": "complete", "filename": "x.csv",
                             "row_count": 1 }"""
                        "every count must be present — a missing one would render as a wrong total"
            ]
        , describe "inviteStatusDecoder"
            [ test "decodes a code bound to an address, without naming it" <|
                \_ ->
                    expectDecodes Api.inviteStatusDecoder
                        """{ "valid": true, "expires_at": "2026-11-13T00:00:00Z",
                             "email_bound": true }"""
                        (\s -> Expect.equal True s.emailBound)
            , test "a never-expiring code decodes with no expiry" <|
                \_ ->
                    -- A null `expires_at` means the invitation never expires,
                    -- which is a real state the admin API can create.
                    expectDecodes Api.inviteStatusDecoder
                        """{ "valid": true, "expires_at": null, "email_bound": false }"""
                        (\s -> Expect.equal Nothing s.expiresAt)
            , test "a missing email_bound is a decode failure" <|
                \_ ->
                    -- The form's copy depends on it: defaulting it to false
                    -- would promise any address can use a code reserved for one.
                    expectFails Api.inviteStatusDecoder
                        """{ "valid": true, "expires_at": null }"""
                        "email_bound must stay required — a default would mislead the reader"
            ]
        , describe "syndicationDecoder"
            [ test "decodes a syndication whose backlink has been recorded" <|
                \_ ->
                    expectDecodes Api.syndicationDecoder
                        """
                        { "id": "s1", "target": "substack", "method": "export",
                          "canonical_url": "https://stacks.test/blog/p1",
                          "syndicated_url": "https://writer.substack.com/p/post",
                          "created_at": "2026-08-18T09:30:00Z" }
                        """
                        (\s -> Expect.notEqual Nothing s.syndicatedUrl)
            , test "a syndication with no backlink yet decodes — that is the normal state" <|
                \_ ->
                    -- The input to record a backlink only appears against a
                    -- syndication that has none, so rejecting this shape would
                    -- hide the field that closes the loop.
                    expectDecodes Api.syndicationDecoder
                        """
                        { "id": "s2", "target": "substack", "method": "rss",
                          "canonical_url": "https://stacks.test/blog/p2",
                          "syndicated_url": null,
                          "created_at": "2026-08-18T09:30:00Z" }
                        """
                        (\s -> Expect.equal Nothing s.syndicatedUrl)
            , test "a syndication with no canonical url is a decode failure" <|
                \_ ->
                    -- The canonical url is the entire point of the record: it is
                    -- stored rather than derived so a host change cannot rewrite
                    -- what the third-party copy says.
                    expectFails Api.syndicationDecoder
                        """{ "id": "s3", "target": "substack", "method": "rss",
                             "syndicated_url": null,
                             "created_at": "2026-08-18T09:30:00Z" }"""
                        "canonical_url must stay required"
            ]
        , describe "adminInviteDecoder"
            [ test "decodes a redeemed invitation with its redeemer's handle" <|
                \_ ->
                    expectDecodes Api.adminInviteDecoder
                        """
                        { "id": "v1", "code_prefix": "STK-HJMQ", "note": "Mara from the group",
                          "invited_email": "mara@example.test", "max_uses": 1, "use_count": 1,
                          "expires_at": "2026-11-13T00:00:00Z", "revoked_at": null,
                          "redeemed_at": "2026-10-01T10:00:00Z",
                          "redeemed_by_handle": "mara" }
                        """
                        (\i -> Expect.equal (Just "mara") i.redeemedByHandle)
            , test "a fresh unbound invitation decodes with every optional field null" <|
                \_ ->
                    expectDecodes Api.adminInviteDecoder
                        """
                        { "id": "v2", "code_prefix": "STK-ZZZZ", "note": null,
                          "invited_email": null, "max_uses": 5, "use_count": 0,
                          "expires_at": null, "revoked_at": null, "redeemed_at": null,
                          "redeemed_by_handle": null }
                        """
                        (\i -> Expect.equal ( 5, 0 ) ( i.maxUses, i.useCount ))
            , test "a missing use_count is a decode failure" <|
                \_ ->
                    -- `use_count` against `max_uses` is how the list says a code
                    -- is spent; a default of zero would show a spent code as live.
                    expectFails Api.adminInviteDecoder
                        """
                        { "id": "v3", "code_prefix": "STK-ZZZZ", "note": null,
                          "invited_email": null, "max_uses": 5, "expires_at": null,
                          "revoked_at": null, "redeemed_at": null,
                          "redeemed_by_handle": null }
                        """
                        "use_count must stay required — a default would show a spent code as live"
            ]
        ]
