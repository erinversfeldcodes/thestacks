module Page.SettingsPrivacyTest exposing (suite)

import Api
import Expect
import Html.Attributes
import Http
import Page.Settings.Consent as Consent
import Page.Settings.Privacy as Privacy exposing (Msg(..), OutMsg(..))
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Types.RemoteData exposing (RemoteData(..))


{-| No token means Save messages short-circuit; most tests supply one.
-}
token : Maybe String
token =
    Just "tok"


suite : Test
suite =
    describe "Page.Settings.Privacy"
        [ describe "init (US-10.1.1)"
            [ test "profileVisibility defaults to owner" <|
                \_ ->
                    Privacy.init.profileVisibility
                        |> Expect.equal "owner"
            , test "seeds five shelf-visibility rows" <|
                \_ ->
                    List.length Privacy.init.shelfVisibilities
                        |> Expect.equal 5
            , test "savingProfile starts NotAsked" <|
                \_ ->
                    Privacy.init.savingProfile
                        |> Expect.equal NotAsked
            , test "savingShelf starts NotAsked" <|
                \_ ->
                    Privacy.init.savingShelf
                        |> Expect.equal NotAsked
            ]
        , describe "profile visibility (US-10.1.1)"
            [ test "SetProfileVisibility updates the local value" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Privacy.update (SetProfileVisibility "platform") Privacy.init token
                    in
                    model.profileVisibility |> Expect.equal "platform"
            , test "SetProfileVisibility resets savingProfile to NotAsked" <|
                \_ ->
                    let
                        saved =
                            { init0 | savingProfile = Success () }

                        ( model, _, _ ) =
                            Privacy.update (SetProfileVisibility "platform") saved token
                    in
                    model.savingProfile |> Expect.equal NotAsked
            , test "SaveProfileVisibility with a token sets savingProfile to Loading" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Privacy.update SaveProfileVisibility Privacy.init token
                    in
                    model.savingProfile |> Expect.equal Loading
            , test "SaveProfileVisibility without a token is a no-op" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Privacy.update SaveProfileVisibility Privacy.init Nothing
                    in
                    model.savingProfile |> Expect.equal NotAsked
            , test "SaveProfileVisibilityCompleted Ok sets savingProfile to Success" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Privacy.update (SaveProfileVisibilityCompleted (Ok ())) init0 token
                    in
                    model.savingProfile |> Expect.equal (Success ())
            , test "SaveProfileVisibilityCompleted Err sets savingProfile to Failure" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Privacy.update (SaveProfileVisibilityCompleted (Err (Http.BadStatus 500))) init0 token
                    in
                    isFailure model.savingProfile |> Expect.equal True
            , test "profile Success renders the confirmation feedback" <|
                \_ ->
                    { init0 | savingProfile = Success () }
                        |> Privacy.view
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "Visibility updated." ]
            ]
        , describe "shelf visibility (US-10.2.1)"
            [ test "SetShelfVisibility updates only the matching shelf" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Privacy.update (SetShelfVisibility "library" "owner") Privacy.init token

                        libraryVis =
                            model.shelfVisibilities
                                |> List.filter (\sv -> sv.name == "library")
                                |> List.head
                                |> Maybe.map .visibility
                    in
                    libraryVis |> Expect.equal (Just "owner")
            , test "SetShelfVisibility leaves other shelves untouched" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Privacy.update (SetShelfVisibility "library" "owner") Privacy.init token

                        antilibraryVis =
                            model.shelfVisibilities
                                |> List.filter (\sv -> sv.name == "antilibrary")
                                |> List.head
                                |> Maybe.map .visibility
                    in
                    antilibraryVis |> Expect.equal (Just "platform")
            , test "SetShelfVisibility resets savingShelf to NotAsked" <|
                \_ ->
                    let
                        saved =
                            { init0 | savingShelf = Success () }

                        ( model, _, _ ) =
                            Privacy.update (SetShelfVisibility "library" "owner") saved token
                    in
                    model.savingShelf |> Expect.equal NotAsked
            , test "SaveShelfVisibility with a token sets savingShelf to Loading" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Privacy.update (SaveShelfVisibility "library") Privacy.init token
                    in
                    model.savingShelf |> Expect.equal Loading
            , test "SaveShelfVisibility without a token is a no-op" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Privacy.update (SaveShelfVisibility "library") Privacy.init Nothing
                    in
                    model.savingShelf |> Expect.equal NotAsked
            , test "SaveShelfVisibilityCompleted Ok sets savingShelf to Success" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Privacy.update (SaveShelfVisibilityCompleted (Ok ())) init0 token
                    in
                    model.savingShelf |> Expect.equal (Success ())
            , test "SaveShelfVisibilityCompleted Err sets savingShelf to Failure" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Privacy.update (SaveShelfVisibilityCompleted (Err (Http.BadStatus 500))) init0 token
                    in
                    isFailure model.savingShelf |> Expect.equal True
            , test "shelf Success renders the saved-confirmation feedback (build a)" <|
                \_ ->
                    { init0 | savingShelf = Success () }
                        |> Privacy.view
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "Visibility updated." ]
            , test "shelf Failure renders the error feedback (build a)" <|
                \_ ->
                    { init0 | savingShelf = Failure (Http.BadStatus 500) }
                        |> Privacy.view
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "and we cannot say why" ]
            , -- ⛔ #374. The 422 here is the ceiling rule this module documents
              -- in `shelfOptionExceedsCeiling` — the ONE failure on this form a
              -- reader can act on — and it was reported with the same six words
              -- as a dropped connection ("Could not save. Please try again."),
              -- which for this cause is advice that can never work.
              test "a 422 names the ceiling rule rather than saying 'try again'" <|
                \_ ->
                    { init0 | savingShelf = Failure (Http.BadStatus 422) }
                        |> Privacy.view
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "A shelf cannot be more visible than your profile." ]
            ]
        , describe "search-engine privacy (US-10.4.1, build b)"
            [ test "renders the informational search-engine text" <|
                \_ ->
                    Privacy.init
                        |> Privacy.view
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "never appear in search engine results" ]
            ]
        , describe "loading saved visibility (FE-1)"
            [ test "GotPrivacySettings Ok seeds the profile visibility from the payload" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Privacy.update
                                (GotPrivacySettings (Ok samplePrivacySettings))
                                Privacy.init
                                token
                    in
                    -- Persisted "platform" is reflected, not the hardcoded "owner" default.
                    model.profileVisibility |> Expect.equal "platform"
            , test "GotPrivacySettings Ok seeds shelf rows from the payload" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Privacy.update
                                (GotPrivacySettings (Ok samplePrivacySettings))
                                Privacy.init
                                token

                        wishlistVis =
                            model.shelfVisibilities
                                |> List.filter (\sv -> sv.name == "wishlist")
                                |> List.head
                                |> Maybe.map .visibility
                    in
                    -- Default is "platform"; the payload persists "owner".
                    wishlistVis |> Expect.equal (Just "owner")
            , test "GotPrivacySettings Ok keeps default label + full shelf set" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Privacy.update
                                (GotPrivacySettings (Ok samplePrivacySettings))
                                Privacy.init
                                token
                    in
                    List.length model.shelfVisibilities |> Expect.equal 5
            , test "GotPrivacySettings Ok hydrates consent from the server, not the stale login blob (#367)" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Privacy.update
                                (GotPrivacySettings (Ok samplePrivacySettings))
                                Privacy.init
                                token
                    in
                    -- Privacy.init defaults consent to False/False; the payload
                    -- says analytics = True. The init fetch is the source of
                    -- truth, so the toggle must reflect the server value — this is
                    -- the read-after-write staleness #367 fixes.
                    model.consent.analyticsConsent |> Expect.equal True
            ]
        , describe "consent folded into Privacy (#318 TR-4)"
            [ test "the consent toggles now render within the Privacy page" <|
                \_ ->
                    -- ORACLE for the fold: before TR-4 these toggles lived on a
                    -- separate /settings/consent page and were absent here.
                    Privacy.init
                        |> Privacy.view
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.has
                                [ Selector.attribute
                                    (Html.Attributes.attribute "data-testid" "analytics-consent-toggle")
                                ]
                            , Query.has
                                [ Selector.attribute
                                    (Html.Attributes.attribute "data-testid" "writing-assistant-consent-toggle")
                                ]
                            , Query.has [ Selector.text "Writing assistant" ]
                            ]
            , test "initWithToken seeds the folded-in consent from the user's state" <|
                \_ ->
                    let
                        ( model, _ ) =
                            Privacy.initWithToken (Just "tok")
                                { analytics = True, writingAssistant = True }
                    in
                    Expect.all
                        [ \m -> m.consent.analyticsConsent |> Expect.equal True
                        , \m -> m.consent.writingAssistantConsent |> Expect.equal True
                        ]
                        model
            , test "ConsentMsg delegates to Consent.update (flips analytics consent)" <|
                \_ ->
                    let
                        ( model, _, _ ) =
                            Privacy.update (ConsentMsg Consent.ToggleAnalytics) init0 token
                    in
                    model.consent.analyticsConsent |> Expect.equal True
            , test "a consent 401 surfaces as Privacy.SessionExpired (single expiry path)" <|
                \_ ->
                    let
                        ( _, _, out ) =
                            Privacy.update
                                (ConsentMsg (Consent.SaveCompleted (Err (Http.BadStatus 401))))
                                init0
                                token
                    in
                    out |> Expect.equal SessionExpired
            ]
        , describe "shelf ceiling greying (FE-2)"
            [ test "an owner profile greys shelf options above the ceiling" <|
                \_ ->
                    -- The "group" option is shelf-only (no such option in the
                    -- profile select), so this isolates the shelf-row greying.
                    { init0 | profileVisibility = "owner" }
                        |> Privacy.view
                        |> Query.fromHtml
                        |> Query.findAll [ Selector.attribute (Html.Attributes.value "group") ]
                        |> Query.each (Query.has [ Selector.disabled True ])
            , test "a platform profile leaves shelf options enabled" <|
                \_ ->
                    { init0 | profileVisibility = "platform" }
                        |> Privacy.view
                        |> Query.fromHtml
                        |> Query.findAll [ Selector.attribute (Html.Attributes.value "group") ]
                        |> Query.each (Query.has [ Selector.disabled False ])
            ]
        ]


samplePrivacySettings : Api.PrivacySettings
samplePrivacySettings =
    { profileVisibility = "platform"
    , shelves =
        [ { name = "library", visibility = "platform" }
        , { name = "wishlist", visibility = "owner" }
        ]
    , consentAnalytics = True
    , consentWritingAssistant = False
    }


init0 : Privacy.Model
init0 =
    Privacy.init


isFailure : RemoteData Http.Error () -> Bool
isFailure rd =
    case rd of
        Failure _ ->
            True

        _ ->
            False
