module Page.Settings.ProfileTest exposing (suite)

{-| #212 — the Settings → Profile handle input.

Drives `Page.Settings.Profile.update` through the handle edit + save lifecycle
and asserts the view: the field echoes edits, a successful save reflects the
server-normalised (lowercased) handle, and a 422 renders the mapped US-10.5.1
copy under the field (taken / reserved / bad format).

-}

import Api
import Html.Attributes as Attr
import Http
import Page.Settings.Profile as Profile exposing (Msg(..))
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
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
    Profile.init sampleUser


{-| Apply one message with no token needed (SetHandle / SaveProfileCompleted
never dispatch a command).
-}
apply : Msg -> Profile.Model -> Profile.Model
apply msg model =
    Profile.update msg model Nothing |> Tuple.first


handleInputValue : Profile.Model -> Query.Single Msg
handleInputValue model =
    Profile.view model
        |> Query.fromHtml
        |> Query.findAll [ Selector.attribute (Attr.attribute "placeholder" "your_handle") ]
        |> Query.first


validationFailure : List ( String, List String ) -> Result Api.ProfileError String
validationFailure errors =
    Err (Api.ProfileValidationFailed errors)


suite : Test
suite =
    describe "Page.Settings.Profile — handle (#212)"
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
                    |> apply (SaveProfileCompleted (Ok "adalovelace"))
                    |> handleInputValue
                    |> Query.has [ Selector.attribute (Attr.value "adalovelace") ]
        , test "a successful save shows the saved confirmation" <|
            \_ ->
                initialModel
                    |> apply (SaveProfileCompleted (Ok "ada"))
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
        ]
