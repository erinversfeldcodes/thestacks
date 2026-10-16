module Page.BookDetailWritingTest exposing (suite)

{-| The book detail's "My Writing" section, which was a stub sitting on live
data.

The defect is worth stating precisely, because it is the shape these tests
exist to prevent rather than the specific bug. Three layers were involved and
the MIDDLE one was missing:

1.  the server computed the viewer's posts about the book and serialised them,
2.  `Api.bookDetailResponseDecoder` silently dropped the field,
3.  `viewWritingSection` took no arguments at all, so nothing could reach it.

Every layer had a passing test. The controller test asserted `my_writing` was
in the payload; the view rendered its stub correctly. Only the COMPOSITION was
broken, and nothing tested the composition.

So the tests that matter here drive the whole seam: a real HTTP response goes
in at the top of the program and the assertions read the rendered document.
Calling `viewWritingSection` by hand would have passed against the stub —
the stub rendered fine. The decoder-level tests below it cover the cases the
view cannot distinguish (an absent key looks exactly like an empty list).

-}

import Api
import Expect
import Html.Attributes as Attr
import Json.Decode as Decode
import Page.BookDetail as BookDetail
import ProgramTest
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import TestHelpers
    exposing
        ( bookDetailProgram
        , simulateBookDetailResponseWithWriting
        , simulateBookDetailResponseWithWritingStates
        , testBook
        )


{-| The page as a signed-in reader sees it, with `posts` returned by the
server for this book.
-}
loadedFor :
    Maybe String
    -> List ( String, String, Maybe String )
    -> ProgramTest.ProgramTest BookDetail.Model BookDetail.Msg (ProgramTest.SimulatedEffect BookDetail.Msg)
loadedFor maybeToken posts =
    ProgramTest.start () (bookDetailProgram "book-test-001" maybeToken)
        |> ProgramTest.simulateHttpResponse "GET"
            "/api/books/book-test-001"
            (simulateBookDetailResponseWithWriting "book-test-001" testBook posts)


signedIn : List ( String, String, Maybe String ) -> ProgramTest.ProgramTest BookDetail.Model BookDetail.Msg (ProgramTest.SimulatedEffect BookDetail.Msg)
signedIn =
    loadedFor (Just "test-token")


{-| As `signedIn`, but each post's `publication_state` is given verbatim —
`Nothing` omits the key.

For the payloads the server should never send. `signedIn` derives the state the
way the controller does, so it cannot express "published with no date" or "no
state at all", and those are two of the view's four branches.

-}
withStates :
    List ( String, String, ( Maybe String, Maybe String ) )
    -> ProgramTest.ProgramTest BookDetail.Model BookDetail.Msg (ProgramTest.SimulatedEffect BookDetail.Msg)
withStates posts =
    ProgramTest.start () (bookDetailProgram "book-test-001" (Just "test-token"))
        |> ProgramTest.simulateHttpResponse "GET"
            "/api/books/book-test-001"
            (simulateBookDetailResponseWithWritingStates "book-test-001" testBook posts)


suite : Test
suite =
    describe "book detail — the viewer's own writing"
        [ describe "the server's posts reach the rendered page"
            [ test "a published post the server sent is rendered with its title and date" <|
                \() ->
                    -- ⚠️ THE anti-regression assertion, and the reason this
                    -- goes through the program rather than the view function.
                    -- Before the fix the decoder was a `map4` that never named
                    -- `my_writing`, and the section took no arguments: this
                    -- exact payload rendered the empty state. Elm decoders
                    -- ignore keys they do not name, so the drop was silent —
                    -- there was no error to notice at any layer.
                    signedIn [ ( "p1", "On Rereading", Just "2026-10-01T09:00:00Z" ) ]
                        |> ProgramTest.expectViewHas
                            [ Selector.text "On Rereading"
                            , Selector.text "2026-10-01"
                            ]
            , test "a post links to the post itself" <|
                \() ->
                    signedIn [ ( "p1", "On Rereading", Just "2026-10-01T09:00:00Z" ) ]
                        |> ProgramTest.expectView
                            (Query.find [ Selector.class "book-detail__writing-link" ]
                                >> Query.has [ Selector.attribute (Attr.href "/blog/p1") ]
                            )
            , test "a draft is labelled rather than rendered with a blank date" <|
                \() ->
                    -- `published_at DESC` is NULLS FIRST in Postgres, so drafts
                    -- sort to the TOP of this list. A blank date in the first
                    -- row would read as a rendering bug.
                    signedIn [ ( "p1", "Half-written", Nothing ) ]
                        |> ProgramTest.expectViewHas
                            [ Selector.text "Half-written"
                            , Selector.text "Draft"
                            ]
            , test "the Draft label comes from the stated state, not from the missing date" <|
                \() ->
                    -- The two agree on every payload the server produces, which
                    -- is exactly why this needs a payload it does not produce.
                    -- A post marked `published` with no date is a server
                    -- contradiction; labelling it "Draft" would hide a real
                    -- defect behind a plausible word, and would also mean the
                    -- view is still inferring from absence.
                    --
                    -- Anchored on the status element's CLASS, not on the word
                    -- "Draft". A prose absence is the weaker assertion twice
                    -- over: it also matches "Save Draft" or "Draft saved!"
                    -- appearing anywhere on the page, and it passes just as
                    -- happily against a page that rendered nothing at all. The
                    -- presence assertion on the title is what rules the second
                    -- out, and the class rules out the first.
                    withStates [ ( "p1", "On Rereading", ( Nothing, Just "published" ) ) ]
                        |> ProgramTest.ensureViewHas [ Selector.text "On Rereading" ]
                        |> ProgramTest.expectView
                            (Query.find [ Selector.class "book-detail__writing-entry" ]
                                >> Query.findAll [ Selector.class "book-detail__writing-draft" ]
                                >> Query.count (Expect.equal 0)
                            )
            , test "a post the server sent no state for says so rather than guessing" <|
                \() ->
                    -- An older server, or a response from a path this field has
                    -- not reached. Both guesses are wrong in a way the reader
                    -- cannot see, so the view makes neither.
                    withStates [ ( "p1", "Half-written", ( Nothing, Nothing ) ) ]
                        |> ProgramTest.ensureViewHas [ Selector.text "Half-written" ]
                        |> ProgramTest.expectViewHas [ Selector.text "Status unknown" ]
            , test "an unknown state still renders the date it was given" <|
                \() ->
                    -- The state being unrecognised is not a reason to withhold
                    -- a date the server did send. Paired with the case above so
                    -- "Status unknown" cannot become the answer to everything
                    -- the decoder does not recognise.
                    withStates
                        [ ( "p1"
                          , "On Rereading"
                          , ( Just "2026-10-01T09:00:00Z", Just "PUBLICATION_STATE_UNSPECIFIED" )
                          )
                        ]
                        |> ProgramTest.expectViewHas
                            [ Selector.text "On Rereading"
                            , Selector.text "2026-10-01"
                            ]
            , test "every post the server sent is rendered, not just the first" <|
                \() ->
                    -- A `List.head`-shaped bug renders one entry and looks
                    -- entirely correct in every single-post test above.
                    signedIn
                        [ ( "p1", "Half-written", Nothing )
                        , ( "p2", "On Rereading", Just "2026-10-01T09:00:00Z" )
                        ]
                        |> ProgramTest.expectView
                            (Query.findAll [ Selector.class "book-detail__writing-entry" ]
                                >> Query.count (Expect.equal 2)
                            )
            , test "with nothing written, the empty state says where writing comes from" <|
                \() ->
                    signedIn []
                        |> ProgramTest.expectViewHas
                            [ Selector.text "haven't written about this book yet" ]
            , test "the section offers no control, because it has nothing to invoke" <|
                \() ->
                    -- Associations are created by an asynchronous worker when a
                    -- post is published, so there is no action this page could
                    -- take. The stub carried an Add Post button that did
                    -- nothing when clicked.
                    --
                    -- Asserted as "no button in this section" rather than as
                    -- the absence of that label: the label is gone from the
                    -- source, so an assertion naming it could never go red
                    -- again, whereas this one fails the moment a control
                    -- reappears under any name.
                    -- ⚠️ Run against BOTH branches. The first version asserted
                    -- only over `signedIn []`, which renders a single `<p>` —
                    -- so the recorded planted-button probe proved falsifiability
                    -- for the empty state alone, and a control added to
                    -- `viewWritingEntry` would have stayed green. That is the
                    -- "a planted red proves only the case you thought of" shape
                    -- in miniature, and this file is the wrong place for it.
                    let
                        noButtonsIn program =
                            program
                                |> ProgramTest.expectView
                                    (Query.find [ Selector.class "book-detail__writing" ]
                                        >> Query.findAll [ Selector.tag "button" ]
                                        >> Query.count (Expect.equal 0)
                                    )
                    in
                    Expect.all
                        [ \() -> noButtonsIn (signedIn [])
                        , \() ->
                            noButtonsIn
                                (signedIn [ ( "p1", "On Rereading", Just "2026-10-01T09:00:00Z" ) ])
                        ]
                        ()
            , test "a signed-out reader sees no writing section at all" <|
                \() ->
                    -- The server sends [] to anonymous callers, so an empty
                    -- list alone cannot distinguish "signed out" from "written
                    -- nothing". Showing the heading to a signed-out reader
                    -- offers them a section that can never hold content.
                    --
                    -- ⚠️ The presence anchor is not decoration. A bare
                    -- assertion of absence is equally satisfied by a page that
                    -- rendered NOTHING — a failed decode, a crashed init, a
                    -- future refactor that loses the response — and would go on
                    -- passing while reporting the opposite of what it claims.
                    -- Asserting the book title first makes "the page loaded"
                    -- part of what this test proves.
                    loadedFor Nothing []
                        |> ProgramTest.ensureViewHas [ Selector.text "The Power of Habit" ]
                        |> ProgramTest.expectViewHasNot [ Selector.text "My Writing" ]
            ]
        , describe "decoder cases the view cannot distinguish"
            [ test "an absent my_writing key decodes as an empty list" <|
                \() ->
                    -- Renders identically to `"my_writing": []`, so only the
                    -- decoder can be asked. A strict `field` here would fail
                    -- the WHOLE response — including the book — on any payload
                    -- that predates the key.
                    """
                    { "book": { "id": "book-1", "title": "A Book", "subjects": [], "bisac_codes": [], "editions": [] }
                    , "placement": null
                    , "placements": []
                    }
                    """
                        |> Decode.decodeString Api.bookDetailResponseDecoder
                        |> Result.map .myWriting
                        |> Expect.equal (Ok [])
            , test "the other four fields still decode — widening did not displace them" <|
                \() ->
                    -- ⚠️ The FIXTURE is the load-bearing part, and the first
                    -- version of this test got it wrong in a way worth naming.
                    --
                    -- Its stated reason was "the arguments are positional, so a
                    -- mis-ordered field would compile". It would not: the five
                    -- `map5` arguments have five distinct types, so no
                    -- permutation type-checks. The compiler owns that.
                    --
                    -- What it actually asserted was weaker than it looked. Every
                    -- pre-existing field is a `oneOf [ field …, succeed
                    -- <default> ]`, so `placements == []` from `"placements": []`
                    -- is ALSO what a misnamed field produces, and the same for
                    -- `placement == Nothing` from `"placement": null`. Two of
                    -- three assertions could not fail, and the one field this
                    -- hand-rolled decoder exists for — `bookshelfVisibility`,
                    -- flattened out of the nested placement — was not asserted
                    -- at all, despite the name saying "four".
                    --
                    -- Non-degenerate values fix all of it: every fallback now
                    -- yields something different from the real decode.
                    """
                    { "book": { "id": "book-1", "title": "A Book", "subjects": [], "bisac_codes": [], "editions": [] }
                    , "placement": { "id": "pl-1", "bookshelf_name": "library", "formats": [], "bookshelf_visibility": "private" }
                    , "placements": [ { "id": "pl-1", "bookshelf_name": "library", "formats": [] } ]
                    , "my_writing": [ { "id": "p1", "title": "On Rereading", "published_at": null } ]
                    }
                    """
                        |> Decode.decodeString Api.bookDetailResponseDecoder
                        |> Result.map
                            (\response ->
                                { title = response.book.title
                                , placementId = Maybe.map .id response.placement
                                , placementCount = List.length response.placements
                                , ceiling = response.bookshelfVisibility
                                }
                            )
                        |> Expect.equal
                            (Ok
                                { title = "A Book"
                                , placementId = Just "pl-1"
                                , placementCount = 1
                                , ceiling = Just "private"
                                }
                            )
            ]
        ]
