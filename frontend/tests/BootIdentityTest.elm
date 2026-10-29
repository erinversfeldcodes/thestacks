module BootIdentityTest exposing (suite)

{-| Boot asks the server who this browser is, and the three answers are three
different app states.

⛔ This file replaces `StoredAuthTest`, which tested the boot it supersedes: a
session read out of a `localStorage` blob, with its own three outcomes (nothing
stored / valid / would-not-decode). That boot could be wrong in a way this one
cannot — the blob was a COPY of the server's answer, so a role changed
server-side stayed stale in the copy until the reader signed out and in again.
It could also be wrong the other way: a reader with a live session cookie and no
blob was shown the sign-in card.

The two states worth guarding here are the ones a `Maybe` cannot hold apart:
**not told yet** is not **told there is nobody**, and **asked and got no answer**
is neither.

⚠️ What this file deliberately does NOT re-assert: that a boot session carries
no bearer and still carries the same-origin proof. That is one derivation and
`ApiRequestHeadersTest` owns it, including the `Api.cookieSession` cases. A
second copy here would be a second place for the answer to be written, which is
the shape this wave has been removing.

-}

import Api
import Expect
import Http
import Json.Decode as Decode
import Json.Encode as Encode
import Main
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Boot identity"
        [ describe "the three answers are three states"
            [ resolvingIsNotSignedOut
            , resolvingIsNotSignedIn
            , aSignedOutAnswerIsResolved
            , aFailedCheckIsResolvedButHoldsNoSession
            ]
        , describe "the identity decoder — a required role, and the fields that may be absent"
            [ anOwnerIsDecodedAsAnOwner
            , aRoleLessPayloadFailsRatherThanDefaulting
            , anAbsentIdFails
            , anAbsentEmailFails
            , anUnsetDisplayNameAndHandleDefault
            , aNullDisplayNameDefaults
            , aWrongTypedDisplayNameFails
            , absentConsentsAreFalse
            , nullConsentsAreFalse
            , aWrongTypedConsentFails
            , anErrorEnvelopeIsNotAnAccount
            ]
        ]



-- THE FIXTURE ----------------------------------------------------------------
-- ⛔ Derived from the SERVER, not from the decoder. `GET /api/auth/me` is
-- `AuthController.me/2`, which answers `%{user: ProtoJSON.user(user)}`;
-- `ProtoJSON.user/1` takes `@user_auth_fields`, which is `@user_core_fields`
-- (`:id`, `:email`, `:display_name`, `:role`, `:profile_visibility`,
-- `:age_verified`, `:consent_analytics`) plus `:handle`, `:country_code`,
-- `:city`, `:website_url`, `:onboarding_completed`, `:pending_email`,
-- `:pending_email_sent_at` and `:consent_writing_assistant`, and then adds
-- `:next_onboarding_step`. A fixture written from the decoder would prove only
-- that the decoder agrees with itself.


{-| The payload as the controller actually sends it, including the fields this
decoder does not read — so a decoder that got stricter than the endpoint would
fail here.
-}
serverPayload : List ( String, Encode.Value ) -> Encode.Value
serverPayload overrides =
    let
        base =
            [ ( "id", Encode.string "123e4567-e89b-12d3-a456-426614174000" )
            , ( "email", Encode.string "reader@stacks.dev" )
            , ( "display_name", Encode.string "A Reader" )
            , ( "role", Encode.string "user" )
            , ( "profile_visibility", Encode.string "private" )
            , ( "age_verified", Encode.bool False )
            , ( "consent_analytics", Encode.bool False )
            , ( "handle", Encode.string "a_reader" )
            , ( "country_code", Encode.string "ZA" )
            , ( "city", Encode.string "Cape Town" )
            , ( "website_url", Encode.string "" )
            , ( "onboarding_completed", Encode.bool True )
            , ( "pending_email", Encode.null )
            , ( "pending_email_sent_at", Encode.null )
            , ( "consent_writing_assistant", Encode.bool False )
            , ( "next_onboarding_step", Encode.null )
            ]

        overridden =
            List.filter (\( key, _ ) -> not (List.member key (List.map Tuple.first overrides))) base
    in
    Encode.object [ ( "user", Encode.object (overridden ++ overrides) ) ]


{-| The same payload with a field REMOVED rather than overridden — the case a
serializer allowlist edit, or a proxy, actually produces.
-}
withoutField : String -> Encode.Value
withoutField dropped =
    case Decode.decodeValue (Decode.field "user" (Decode.keyValuePairs Decode.value)) (serverPayload []) of
        Ok pairs ->
            Encode.object
                [ ( "user"
                  , Encode.object (List.filter (\( key, _ ) -> key /= dropped) pairs)
                  )
                ]

        Err _ ->
            Encode.object []


decode : Encode.Value -> Result Decode.Error Api.Identity
decode =
    Decode.decodeValue Api.identityDecoder



-- THE THREE ANSWERS ----------------------------------------------------------


{-| ⛔ The mutation probe's target. Collapse `Resolving` into `Anonymous` — the
one-line change a reader of this type is most likely to make — and this is the
case that reddens.
-}
resolvingIsNotSignedOut : Test
resolvingIsNotSignedOut =
    test "resolving_is_not_signed_out: a boot that has not been answered is not a signed-out boot" <|
        \() ->
            Main.authResolved Main.Resolving
                |> Expect.equal False


resolvingIsNotSignedIn : Test
resolvingIsNotSignedIn =
    test "resolving_has_no_session: nothing can be requested with an unanswered boot" <|
        \() ->
            Main.currentAuth Main.Resolving
                |> Expect.equal Nothing


{-| The paired control. Without it, `authResolved` could be `always False` and
the case above would still pass — leaving a reader who IS signed out looking at
a header that never offers them a way in.
-}
aSignedOutAnswerIsResolved : Test
aSignedOutAnswerIsResolved =
    test "anonymous_is_resolved: the server saying there is nobody IS an answer" <|
        \() ->
            Expect.all
                [ \() -> Main.authResolved Main.Anonymous |> Expect.equal True
                , \() -> Main.currentAuth Main.Anonymous |> Expect.equal Nothing
                ]
                ()


aFailedCheckIsResolvedButHoldsNoSession : Test
aFailedCheckIsResolvedButHoldsNoSession =
    test "unresolved_is_resolved_without_a_session: a check that failed stops waiting, and claims nothing" <|
        \() ->
            Expect.all
                [ \() -> Main.authResolved (Main.Unresolved Http.NetworkError) |> Expect.equal True
                , \() -> Main.currentAuth (Main.Unresolved Http.NetworkError) |> Expect.equal Nothing
                ]
                ()



-- THE DECODER ----------------------------------------------------------------


anOwnerIsDecodedAsAnOwner : Test
anOwnerIsDecodedAsAnOwner =
    test "owner_role_survives: the role the server sent is the role the app runs on" <|
        \() ->
            decode (serverPayload [ ( "role", Encode.string "owner" ) ])
                |> Result.map .role
                |> Expect.equal (Ok "owner")


{-| ⛔ THE case this decoder exists for. The decoder it replaces read an absent
role as `"user"`, so an owner whose `role` went missing en route was silently
demoted and nothing reported it.
-}
aRoleLessPayloadFailsRatherThanDefaulting : Test
aRoleLessPayloadFailsRatherThanDefaulting =
    test "absent_role_fails: a payload with no role is a broken answer, not a reader" <|
        \() ->
            decode (withoutField "role")
                |> Result.toMaybe
                |> Expect.equal Nothing


anAbsentIdFails : Test
anAbsentIdFails =
    test "absent_id_fails: there is no account without one" <|
        \() ->
            decode (withoutField "id")
                |> Result.toMaybe
                |> Expect.equal Nothing


anAbsentEmailFails : Test
anAbsentEmailFails =
    test "absent_email_fails: there is no account without one" <|
        \() ->
            decode (withoutField "email")
                |> Result.toMaybe
                |> Expect.equal Nothing


anUnsetDisplayNameAndHandleDefault : Test
anUnsetDisplayNameAndHandleDefault =
    test "absent_optional_strings_default: a reader who has set neither is not a malformed response" <|
        \() ->
            decode (withoutField "handle")
                |> Result.map .handle
                |> Expect.equal (Ok "")


aNullDisplayNameDefaults : Test
aNullDisplayNameDefaults =
    test "null_display_name_defaults: the column is nullable, so null is a real value" <|
        \() ->
            decode (serverPayload [ ( "display_name", Encode.null ) ])
                |> Result.map .displayName
                |> Expect.equal (Ok "")


{-| The control that keeps the two defaults above from being leniency. A field
the server sent as something unreadable must fail where it can be seen, not
resolve to `""` exactly as an unset one does.
-}
aWrongTypedDisplayNameFails : Test
aWrongTypedDisplayNameFails =
    test "wrong_typed_display_name_fails: absent and WRONG are different answers" <|
        \() ->
            decode (serverPayload [ ( "display_name", Encode.int 7 ) ])
                |> Result.toMaybe
                |> Expect.equal Nothing


absentConsentsAreFalse : Test
absentConsentsAreFalse =
    test "absent_consent_is_false: never consented and no flag sent are the same answer" <|
        \() ->
            decode (withoutField "consent_writing_assistant")
                |> Result.map .consentWritingAssistant
                |> Expect.equal (Ok False)


nullConsentsAreFalse : Test
nullConsentsAreFalse =
    test "null_consent_is_false: the column carries a default but no NOT NULL" <|
        \() ->
            decode (serverPayload [ ( "consent_analytics", Encode.null ) ])
                |> Result.map .consentAnalytics
                |> Expect.equal (Ok False)


{-| The control for the two above: reading an unreadable consent value as
`False` would quietly withdraw a consent the reader gave.
-}
aWrongTypedConsentFails : Test
aWrongTypedConsentFails =
    test "wrong_typed_consent_fails: a consent we cannot read is not a consent withdrawn" <|
        \() ->
            decode (serverPayload [ ( "consent_analytics", Encode.string "yes" ) ])
                |> Result.toMaybe
                |> Expect.equal Nothing


anErrorEnvelopeIsNotAnAccount : Test
anErrorEnvelopeIsNotAnAccount =
    test "error_envelope_is_not_an_account: a 200 carrying an error body does not sign anyone in" <|
        \() ->
            Decode.decodeValue Api.identityDecoder
                (Encode.object [ ( "error", Encode.string "unauthenticated" ) ])
                |> Result.toMaybe
                |> Expect.equal Nothing
