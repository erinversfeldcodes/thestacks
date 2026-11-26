module Page.UploadExpiryTest exposing (suite)

{-| The expiry obligation, driven through a real page at a request that routed
nothing before it.

⛔ WHY THIS PAGE AND THIS REQUEST. `Page.Upload` makes nine authenticated
requests, and four of them — the commit, the book read, the rejected
identification and the adults-only mark — handed their failures to a result
handler that never asked whether the status was a 401. So an expired session
turned into "we couldn't identify that" copy on a page that could not have
identified anything, and no test noticed, because there was nothing to notice:
the page's own handler was doing exactly what it said.

⚖️ That is what makes this the discriminating subject. On every other page the
result handler ALSO routes a 401, so removing the plan's interception changes
nothing observable and a test there cannot fail. Here it changes the outcome
from "identification failed" to "the session ended", which is the difference
between telling the reader to try again and telling them the truth.

⚠️ The page is seeded into the state a reader reaches after a photograph has
been identified, because getting there for real needs a file picker and a live
progress stream that no simulated runtime can produce. Everything after the
click is the page's own: its `updateWithEffect`, its `Effect.authed` plan, and
the interpreter that `EffectHeaderParityTest` pins to production's.

-}

import Api
import Dict
import Expect
import Html.Attributes
import Http
import Page.Upload as Upload exposing (Msg(..))
import ProgramTest
import Test exposing (Test, describe, test)
import Test.Html.Selector as Selector
import TestHelpers
import Types.Book exposing (Book)
import Types.RemoteData exposing (RemoteData(..))


suite : Test
suite =
    describe "an expired session on an upload's authenticated request"
        [ aRejectedIdentificationThatExpiresReportsTheSession
        , aRejectedIdentificationThatExpiresSaysNothingAboutIdentification
        , aRejectedIdentificationThatFailsOtherwiseStillReportsIdentification
        ]


token : Api.Credentials
token =
    TestHelpers.creds "test-token"


identifiedBook : Book
identifiedBook =
    TestHelpers.testBook


{-| A reader looking at the book their photograph was identified as, with the
image still held server-side — the state the "not my book" affordance belongs
to.
-}
verifying : Upload.Model
verifying =
    let
        base =
            Upload.init
    in
    { base
        | step = Upload.Verifying identifiedBook
        , uploadState = Success "img-1"
    }


rejectEndpoint : String
rejectEndpoint =
    "/api/upload/img-1/reject-identification"


{-| A refusal with the body the server actually sends.

⚠️ The reason token matters and this fixture used to omit it. `AuthErrorHandler`
answers `{"error": "session_expired"}` when a session was presented and refused,
and the 401's classification is made from that token rather than from the status
code — because the session cookie is `HttpOnly`, so only the server can say
whether one was sent. An empty body is not a 401 this app can receive; it is the
"we could not read the answer" case, which `RefusalTokenTest` covers.

-}
responseWith : Int -> Http.Response String
responseWith statusCode =
    Http.BadStatus_
        { url = rejectEndpoint
        , statusCode = statusCode
        , statusText = "Error"
        , headers = Dict.empty
        }
        "{\"error\":\"session_expired\"}"


rejectThen : Int -> ProgramTest.ProgramTest TestHelpers.UploadTestModel Upload.Msg (ProgramTest.SimulatedEffect Upload.Msg)
rejectThen statusCode =
    ProgramTest.start () (TestHelpers.uploadProgramFrom verifying (Just token))
        |> ProgramTest.update RejectIdentification
        |> ProgramTest.simulateHttpResponse "POST" rejectEndpoint (responseWith statusCode)


{-| ⛔ The claim: a 401 on this page's authenticated plan becomes the page's
session-expiry signal to `Main`. Before the plan demanded a msg for it, this
same response produced `NoOut`.
-}
aRejectedIdentificationThatExpiresReportsTheSession : Test
aRejectedIdentificationThatExpiresReportsTheSession =
    test "upload_reject_401_reports_the_session: a 401 while rejecting an identification ends the session" <|
        \() ->
            rejectThen 401
                |> ProgramTest.expectModel
                    (\model -> Expect.equal Upload.SessionExpired model.lastOut)


{-| And it must not ALSO tell the reader their photograph could not be
identified. The identification was fine; the session was not.

⚠️ An absence assertion is worth only as much as the proof that the thing can
be present, which is why the control below asserts the SAME card appears after
a 500. Without that pair this would pass against a page that never renders a
failure card at all.

-}
aRejectedIdentificationThatExpiresSaysNothingAboutIdentification : Test
aRejectedIdentificationThatExpiresSaysNothingAboutIdentification =
    test "upload_reject_401_blames_the_session_not_the_photo: no identification failure is shown" <|
        \() ->
            rejectThen 401
                |> ProgramTest.expectViewHasNot [ identificationFailureCard ]


{-| ⚖️ The control, and the reason the two tests above say something. A 500 on
the same request still belongs to the page's own handler, which reports it as an
identification that did not come back — so the 401 case is not passing because
every failure now ends the session, and the absent card above is a card this
page does render.
-}
aRejectedIdentificationThatFailsOtherwiseStillReportsIdentification : Test
aRejectedIdentificationThatFailsOtherwiseStillReportsIdentification =
    test "upload_reject_500_stays_local: a server fault is still the page's own failure" <|
        \() ->
            rejectThen 500
                |> ProgramTest.ensureViewHas [ identificationFailureCard ]
                |> ProgramTest.expectModel
                    (\model -> Expect.equal Upload.NoOut model.lastOut)


{-| The failure card this page renders when an identification did not come
back, found by the test id it carries rather than by its copy.
-}
identificationFailureCard : Selector.Selector
identificationFailureCard =
    Selector.attribute (Html.Attributes.attribute "data-testid" "upload-error")
