module Page.AdminInvitesTest exposing (suite)

{-| US-14.1.3 — the owner's invitation desk, and above all the SHOW-ONCE
property: the full code renders only from the create response, and the list
only ever shows a prefix.
-}

import Expect
import Html.Attributes
import Page.Admin.Invites as Invites
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Types.RemoteData exposing (RemoteData(..))


baseModel : Invites.Model
baseModel =
    Invites.init (Just "admin-token") |> Tuple.first


sample : { id : String, codePrefix : String, note : Maybe String, invitedEmail : Maybe String, maxUses : Int, useCount : Int, expiresAt : Maybe String, revokedAt : Maybe String, redeemedAt : Maybe String, redeemedByHandle : Maybe String }
sample =
    { id = "inv-1"
    , codePrefix = "STK-4F2A"
    , note = Just "Mara — book club"
    , invitedEmail = Nothing
    , maxUses = 1
    , useCount = 0
    , expiresAt = Nothing
    , revokedAt = Nothing
    , redeemedAt = Nothing
    , redeemedByHandle = Nothing
    }


suite : Test
suite =
    describe "Page.Admin.Invites (US-14.1.3)"
        [ test "the create form and empty list render" <|
            \_ ->
                Invites.view { baseModel | invites = Success [] }
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.has [ Selector.attribute (Html.Attributes.attribute "data-testid" "admin-invite-create") ]
                        , Query.has [ Selector.text "No invitations written yet." ]
                        , Query.hasNot [ Selector.attribute (Html.Attributes.attribute "data-testid" "admin-invite-code-reveal") ]
                        ]
        , test "a created code shows ONCE, with the only-time warning" <|
            \_ ->
                let
                    ( model, _, _ ) =
                        Invites.update
                            (Invites.CreateCompleted (Ok ( sample, "STK-4F2A-9C1D-XXXX" )))
                            { baseModel | invites = Success [] }
                            (Just "admin-token")
                in
                Invites.view model
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.has [ Selector.text "STK-4F2A-9C1D-XXXX" ]
                        , Query.has [ Selector.text "This is the only time the full code is shown. Copy it now — the platform keeps only a fingerprint." ]
                        ]
        , test "the list shows the prefix, never a full code" <|
            \_ ->
                Invites.view { baseModel | invites = Success [ sample ] }
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.has [ Selector.text "STK-4F2A-…" ]
                        , Query.hasNot [ Selector.text "STK-4F2A-9C1D-XXXX" ]
                        ]
        , test "a revoked invitation loses its Revoke button and shows the pill" <|
            \_ ->
                Invites.view
                    { baseModel | invites = Success [ { sample | revokedAt = Just "2026-08-10T00:00:00Z" } ] }
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.hasNot [ Selector.class "admin-invites__revoke" ]
                        , Query.has [ Selector.text "Revoked" ]
                        ]
        , test "a redeemed invitation names its taker" <|
            \_ ->
                Invites.view
                    { baseModel
                        | invites =
                            Success [ { sample | useCount = 1, redeemedByHandle = Just "mara" } ]
                    }
                    |> Query.fromHtml
                    |> Query.has [ Selector.text "Redeemed by @mara" ]
        ]
