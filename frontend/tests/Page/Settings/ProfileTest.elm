module Page.Settings.ProfileTest exposing (suite)

{-| — the Settings → Profile handle input.

Drives `Page.Settings.Profile.update` through the handle edit + save lifecycle
and asserts the view: the field echoes edits, a successful save reflects the
server-normalised (lowercased) handle, and a 422 renders the mapped copy under the field (taken / reserved / bad format).

-}

import Api
import Expect
import Html.Attributes as Attr
import Http
import Json.Decode as Decode
import Page.Settings.Profile as Profile exposing (Msg(..))
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Types.RemoteData exposing (RemoteData(..))
import Types.User exposing (User)


sampleUser : User
sampleUser =
    { id = "user-1"
    , email = "ada@example.com"
    , displayName = "Ada"
    , handle = "ada"
    , role = "user"
    , countryCode = Nothing
    , city = Nothing
    , consentAnalytics = False
    , consentWritingAssistant = False
    }


initialModel : Profile.Model
initialModel =
    Profile.seedFromSession sampleUser


{-| A 200 from `PUT /api/settings/profile` with no change in flight: the account
answers on the address it already had.
-}
savedAs : String -> Api.ProfileSaved
savedAs handle =
    { handle = handle, email = "ada@example.com", pendingEmail = Nothing }


{-| The same 200 for an email change: the account's address has NOT moved, and a
second address is waiting to prove itself.
-}
pendingSave : Api.ProfileSaved
pendingSave =
    { handle = "ada", email = "ada@example.com", pendingEmail = Just "new@example.com" }


{-| The account as `/api/auth/me` reports it mid-change: address unmoved, a
second one waiting.
-}
accountPending : Api.Account
accountPending =
    { displayName = "Ada"
    , handle = "ada"
    , email = "ada@example.com"
    , websiteUrl = ""
    , countryCode = ""
    , city = ""
    , pendingEmail = Just "new@example.com"
    }


accountSettled : Api.Account
accountSettled =
    { accountPending | pendingEmail = Nothing }


{-| The model out of the page's `( Model, Cmd Msg, OutMsg)` triple. The page
gained an `OutMsg` in so a mid-form 401 can reach the global session-expiry
interceptor; the `OutMsg` itself is asserted in `Page.SessionExpiryPagesTest`.
-}
modelOf : ( Profile.Model, Cmd Msg, Profile.OutMsg ) -> Profile.Model
modelOf ( model, _, _ ) =
    model


{-| Apply one message with no token needed (SetHandle / SaveProfileCompleted
never dispatch a command).
-}
apply : Msg -> Profile.Model -> Profile.Model
apply msg model =
    Profile.update msg model Nothing |> modelOf


handleInputValue : Profile.Model -> Query.Single Msg
handleInputValue model =
    Profile.view model
        |> Query.fromHtml
        |> Query.findAll [ Selector.attribute (Attr.attribute "placeholder" "your_handle") ]
        |> Query.first


validationFailure : List ( String, List String ) -> Result Api.ProfileError Api.ProfileSaved
validationFailure errors =
    Err (Api.ProfileValidationFailed errors)


{-| Apply one message with a token present, keeping the resulting model — used
by the save-dispatch and email-change paths that only fire with a token.
-}
applyWithToken : Msg -> Profile.Model -> Profile.Model
applyWithToken msg model =
    Profile.update msg model (Just "test-token") |> modelOf


currentPasswordPlaceholder : Selector.Selector
currentPasswordPlaceholder =
    Selector.attribute (Attr.attribute "placeholder" "Confirm your current password")


type alias ProfileBody =
    { displayName : String
    , email : String
    , websiteUrl : String
    , handle : String
    , currentPassword : String
    , emailChanged : Bool
    , handleChanged : Bool
    }


{-| Decode one field out of an encoded profile body.
-}
bodyField : String -> ProfileBody -> Result Decode.Error String
bodyField key body =
    Api.encodeProfileBody body
        |> Decode.decodeValue (Decode.field key Decode.string)


unchangedBody : ProfileBody
unchangedBody =
    { displayName = "Ada"
    , email = "ada@example.com"
    , websiteUrl = ""
    , handle = "ada"
    , currentPassword = ""
    , emailChanged = False
    , handleChanged = False
    }


changedBody : ProfileBody
changedBody =
    { unchangedBody | email = "new@example.com", currentPassword = "hunter2", emailChanged = True }


suite : Test
suite =
    describe "Page.Settings.Profile — handle"
        [ test "seeds the handle field from the current user" <|
            \_ ->
                handleInputValue initialModel
                    |> Query.has [ Selector.attribute (Attr.value "ada") ]
        , test "SetHandle updates the field value" <|
            \_ ->
                initialModel
                    |> apply (SetHandle "ada_lovelace")
                    |> handleInputValue
                    |> Query.has [ Selector.attribute (Attr.value "ada_lovelace") ]
        , test "a successful save reflects the server-normalised (lowercased) handle" <|
            \_ ->
                initialModel
                    |> apply (SetHandle "AdaLovelace")
                    |> apply (SaveProfileCompleted (Ok (savedAs "adalovelace")))
                    |> handleInputValue
                    |> Query.has [ Selector.attribute (Attr.value "adalovelace") ]
        , test "a successful save shows the saved confirmation" <|
            \_ ->
                initialModel
                    |> apply (SaveProfileCompleted (Ok (savedAs "ada")))
                    |> Profile.view
                    |> Query.fromHtml
                    |> Query.has [ Selector.text "Profile saved." ]
        , test "a taken handle renders the taken copy under the field" <|
            \_ ->
                initialModel
                    |> apply (SaveProfileCompleted (validationFailure [ ( "handle", [ "has already been taken" ] ) ]))
                    |> Profile.view
                    |> Query.fromHtml
                    |> Query.has [ Selector.text "That handle is already taken." ]
        , test "a reserved handle renders the reserved copy under the field" <|
            \_ ->
                initialModel
                    |> apply (SaveProfileCompleted (validationFailure [ ( "handle", [ "is reserved" ] ) ]))
                    |> Profile.view
                    |> Query.fromHtml
                    |> Query.has [ Selector.text "That handle is reserved." ]
        , test "a malformed handle renders the format copy under the field" <|
            \_ ->
                initialModel
                    |> apply
                        (SaveProfileCompleted
                            (validationFailure
                                [ ( "handle", [ "must be 3-30 characters: lowercase letters, numbers, underscores" ] ) ]
                            )
                        )
                    |> Profile.view
                    |> Query.fromHtml
                    |> Query.has [ Selector.text "Handle must be 3–30 characters: lowercase letters, numbers, underscores." ]
        , test "a validation failure suppresses the generic section-level error banner" <|
            \_ ->
                initialModel
                    |> apply (SaveProfileCompleted (validationFailure [ ( "handle", [ "is reserved" ] ) ]))
                    |> Profile.view
                    |> Query.fromHtml
                    |> Query.hasNot [ Selector.text "Could not save profile. Please try again." ]
        , test "a 503 (server busy) renders the retry-shortly copy, not the generic error" <|
            \_ ->
                initialModel
                    |> apply (SaveProfileCompleted (Err (Api.ProfileRequestFailed (Http.BadStatus 503))))
                    |> Profile.view
                    |> Query.fromHtml
                    |> Query.has [ Selector.text "The server is busy right now. Please try again in a moment." ]
        , test "a non-503 request failure renders the generic save error" <|
            \_ ->
                initialModel
                    |> apply (SaveProfileCompleted (Err (Api.ProfileRequestFailed Http.NetworkError)))
                    |> Profile.view
                    |> Query.fromHtml
                    |> Query.has [ Selector.text "Could not save profile. Please try again." ]
        , describe "email change (CG-1, )"
            [ test "an unchanged email omits both email and current_password from the payload" <|
                \_ ->
                    Expect.all
                        [ \_ -> bodyField "email" unchangedBody |> Expect.err
                        , \_ -> bodyField "current_password" unchangedBody |> Expect.err
                        , \_ -> bodyField "display_name" unchangedBody |> Expect.equal (Ok "Ada")
                        , \_ -> bodyField "website_url" unchangedBody |> Expect.equal (Ok "")
                        ]
                        ()
            , test "a changed email includes email and current_password in the payload" <|
                \_ ->
                    Expect.all
                        [ \_ -> bodyField "email" changedBody |> Expect.equal (Ok "new@example.com")
                        , \_ -> bodyField "current_password" changedBody |> Expect.equal (Ok "hunter2")
                        ]
                        ()
            , test "the current-password field is hidden while the email is unchanged" <|
                \_ ->
                    initialModel
                        |> Profile.view
                        |> Query.fromHtml
                        |> Query.hasNot [ currentPasswordPlaceholder ]
            , test "editing the email reveals the current-password field" <|
                \_ ->
                    initialModel
                        |> apply (SetEmail "new@example.com")
                        |> Profile.view
                        |> Query.fromHtml
                        |> Query.has [ currentPasswordPlaceholder ]
            , test "saving a changed email with an empty current password is blocked with an inline message" <|
                \_ ->
                    let
                        blocked =
                            initialModel
                                |> apply (SetEmail "new@example.com")
                                |> applyWithToken SaveProfile
                    in
                    Expect.all
                        [ \_ -> blocked.savingProfile |> Expect.equal NotAsked
                        , \_ ->
                            blocked
                                |> Profile.view
                                |> Query.fromHtml
                                |> Query.has [ Selector.text "Please enter your current password to change your email." ]
                        ]
                        ()
            , test "saving a changed email with a current password dispatches the save (Loading)" <|
                \_ ->
                    initialModel
                        |> apply (SetEmail "new@example.com")
                        |> apply (SetCurrentPassword "hunter2")
                        |> applyWithToken SaveProfile
                        |> .savingProfile
                        |> Expect.equal Loading
            , test "a 422 (wrong current password) renders the specific error copy" <|
                \_ ->
                    initialModel
                        |> apply (SaveProfileCompleted (Err (Api.ProfileRequestFailed (Http.BadStatus 422))))
                        |> Profile.view
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "Current password is incorrect." ]
            ]
        , describe "a change in flight"
            [ test "the email field snaps back to the address the account still answers on" <|
                \_ ->
                    let
                        after =
                            initialModel
                                |> apply (SetEmail "new@example.com")
                                |> apply (SetCurrentPassword "hunter2")
                                |> applyWithToken SaveProfile
                                |> apply (SaveProfileCompleted (Ok pendingSave))
                    in
                    Expect.all
                        [ \_ -> after.email |> Expect.equal "ada@example.com"
                        , \_ -> after.initialEmail |> Expect.equal "ada@example.com"
                        , \_ -> after.pendingEmail |> Expect.equal (Just "new@example.com")
                        ]
                        ()
            , test "the panel names the address being waited on and the one holding the undo link" <|
                \_ ->
                    initialModel
                        |> apply (SaveProfileCompleted (Ok pendingSave))
                        |> Profile.view
                        |> Query.fromHtml
                        |> Expect.all
                            [ Query.has [ Selector.text "new@example.com" ]
                            , Query.has [ Selector.class "pending-email" ]
                            , Query.has [ Selector.text "We sent a confirmation link there, and a link to undo this change to ada@example.com. Your account still uses ada@example.com until the new address confirms itself." ]
                            ]
            , test "the panel warns that ignoring both letters signs you out" <|
                \_ ->
                    initialModel
                        |> apply (SaveProfileCompleted (Ok pendingSave))
                        |> Profile.view
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "If neither is used within seven days, you'll be signed out until an address is confirmed — the undo link will still work." ]
            , test "no panel when nothing is pending" <|
                \_ ->
                    initialModel
                        |> Profile.view
                        |> Query.fromHtml
                        |> Query.hasNot [ Selector.class "pending-email" ]
            , test "the account record answers the panel on load, so a reload does not lose it" <|
                \_ ->
                    initialModel
                        |> apply (AccountReceived (Ok accountPending))
                        |> Profile.view
                        |> Query.fromHtml
                        |> Query.has [ Selector.class "pending-email" ]
            , test "a settled change clears the panel" <|
                \_ ->
                    initialModel
                        |> apply (AccountReceived (Ok accountPending))
                        |> apply (AccountReceived (Ok accountSettled))
                        |> Profile.view
                        |> Query.fromHtml
                        |> Query.hasNot [ Selector.class "pending-email" ]
            , test "an unreadable account record claims no pending change rather than inventing one" <|
                \_ ->
                    initialModel
                        |> apply (AccountReceived (Err Http.NetworkError))
                        |> .pendingEmail
                        |> Expect.equal Nothing
            ]
        , describe "handle omission (CG-1 follow-up — NOT NULL handle 500)"
            [ test "an unchanged real handle is omitted from the payload" <|
                \_ ->
                    bodyField "handle" unchangedBody |> Expect.err
            , test "an unchanged empty handle (injected session) is omitted, not sent as \"\"" <|
                \_ ->
                    bodyField "handle" { unchangedBody | handle = "" } |> Expect.err
            , test "an edited handle is included in the payload" <|
                \_ ->
                    bodyField "handle" { unchangedBody | handle = "adalovelace", handleChanged = True }
                        |> Expect.equal (Ok "adalovelace")
            , test "init baselines initialHandle so an untouched real handle is unchanged" <|
                \_ ->
                    let
                        model =
                            Profile.seedFromSession sampleUser
                    in
                    model.handle |> Expect.equal model.initialHandle
            , test "init baselines initialHandle for a handle-less (injected) session" <|
                \_ ->
                    let
                        model =
                            Profile.seedFromSession { sampleUser | handle = "" }
                    in
                    Expect.all
                        [ \_ -> model.handle |> Expect.equal ""
                        , \_ -> model.handle |> Expect.equal model.initialHandle
                        ]
                        ()
            , test "editing the handle diverges it from the baseline (a real change)" <|
                \_ ->
                    let
                        model =
                            apply (SetHandle "adalovelace") initialModel
                    in
                    model.handle |> Expect.notEqual model.initialHandle
            , test "a successful save rebaselines initialHandle to the settled value" <|
                \_ ->
                    let
                        saved =
                            initialModel
                                |> apply (SetHandle "AdaLovelace")
                                |> apply (SaveProfileCompleted (Ok (savedAs "adalovelace")))
                    in
                    Expect.all
                        [ \_ -> saved.handle |> Expect.equal "adalovelace"
                        , \_ -> saved.initialHandle |> Expect.equal "adalovelace"
                        ]
                        ()
            ]
        , describe "personal-info setters"
            [ test "SetDisplayName updates the field and clears a prior save result" <|
                \_ ->
                    let
                        edited =
                            initialModel
                                |> apply (SaveProfileCompleted (Ok (savedAs "ada")))
                                |> apply (SetDisplayName "Ada Lovelace")
                    in
                    Expect.all
                        [ \_ -> edited.displayName |> Expect.equal "Ada Lovelace"
                        , \_ -> edited.savingProfile |> Expect.equal NotAsked
                        ]
                        ()
            , test "SetEmail updates the field" <|
                \_ ->
                    initialModel
                        |> apply (SetEmail "grace@example.com")
                        |> .email
                        |> Expect.equal "grace@example.com"
            , test "SetWebsiteUrl updates the field and clears a prior save result" <|
                \_ ->
                    let
                        edited =
                            initialModel
                                |> apply (SaveProfileCompleted (Ok (savedAs "ada")))
                                |> apply (SetWebsiteUrl "https://ada.dev")
                    in
                    Expect.all
                        [ \_ -> edited.websiteUrl |> Expect.equal "https://ada.dev"
                        , \_ -> edited.savingProfile |> Expect.equal NotAsked
                        ]
                        ()
            ]
        , describe "location"
            [ test "SetCountryCode updates the field and clears a prior save result" <|
                \_ ->
                    let
                        edited =
                            initialModel
                                |> applyWithToken SaveLocation
                                |> apply (SaveLocationCompleted (Ok ()))
                                |> apply (SetCountryCode "GB")
                    in
                    Expect.all
                        [ \_ -> edited.countryCode |> Expect.equal "GB"
                        , \_ -> edited.savingLocation |> Expect.equal NotAsked
                        ]
                        ()
            , test "SetCity updates the field and clears a prior save result" <|
                \_ ->
                    let
                        edited =
                            initialModel
                                |> applyWithToken SaveLocation
                                |> apply (SaveLocationCompleted (Ok ()))
                                |> apply (SetCity "London")
                    in
                    Expect.all
                        [ \_ -> edited.city |> Expect.equal "London"
                        , \_ -> edited.savingLocation |> Expect.equal NotAsked
                        ]
                        ()
            , test "SaveLocation with a token dispatches the save (Loading)" <|
                \_ ->
                    initialModel
                        |> apply (SetCountryCode "GB")
                        |> applyWithToken SaveLocation
                        |> .savingLocation
                        |> Expect.equal Loading
            , test "SaveLocation without a token is a no-op" <|
                \_ ->
                    initialModel
                        |> apply (SetCountryCode "GB")
                        |> apply SaveLocation
                        |> .savingLocation
                        |> Expect.equal NotAsked
            , test "a successful location save reports success and renders the saved copy" <|
                \_ ->
                    let
                        saved =
                            initialModel
                                |> applyWithToken SaveLocation
                                |> apply (SaveLocationCompleted (Ok ()))
                    in
                    Expect.all
                        [ \_ -> saved.savingLocation |> Expect.equal (Success ())
                        , \_ ->
                            saved
                                |> Profile.view
                                |> Query.fromHtml
                                |> Query.has [ Selector.text "Location saved." ]
                        ]
                        ()
            , test "a failed location save renders the failure copy" <|
                \_ ->
                    initialModel
                        |> applyWithToken SaveLocation
                        |> apply (SaveLocationCompleted (Err Http.NetworkError))
                        |> Profile.view
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "Could not save location. Please try again." ]
            ]
        ]
