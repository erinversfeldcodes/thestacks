module Page.Settings.Profile exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , initWithEffect
    , initWithToken
    , seedFromSession
    , update
    , view
    )

{-| Settings → Profile: the reader's own account, as an editable form.

**This page owns account freshness.** Nothing else in the app asks the server
who the reader is. `Main` reconstructs `auth.user` from the `stacks-auth` blob
in localStorage, which carries only what a login response put there — id,
email, display name, handle, role — and hard-codes the rest to `Nothing`;
`app.js` fetches `/api/config` for server feature flags and nothing else. So
the blob is a credential cache, not a record of the account: it has no country,
no city, no website, and it never learns that any of them changed. Seeding this
form from it and calling the result "your profile" is how a saved location came
back blank on the next visit.

`initWithToken` therefore asks `GET /api/auth/me` when the page opens and
hydrates the form from the answer. The blob still seeds the fields first, so
the form is filled the instant it renders instead of flashing empty — but it is
a placeholder with no authority, and the response replaces it. If a wider
surface later needs fresh account data, that fetch belongs in `Main` and this
page should read it from there; two independent fetchers would be two answers
to one question.

-}

import Api
import Components.SaveButton as SaveButton
import Effect exposing (Effect)
import Html exposing (Html, a, div, h1, h2, input, label, p, strong, text)
import Html.Attributes exposing (class, href, placeholder, type_, value)
import Html.Events exposing (onInput)
import Http
import Navigation.Route as Route
import Set exposing (Set)
import Types.RemoteData exposing (RemoteData(..))
import Types.User exposing (User)


type alias Model =
    { displayName : String
    , handle : String
    , initialHandle : String
    , email : String
    , initialEmail : String
    , currentPassword : String
    , currentPasswordError : Maybe String
    , websiteUrl : String
    , countryCode : String
    , city : String
    , savingProfile : RemoteData Api.ProfileError ()
    , savingLocation : RemoteData Http.Error ()
    , account : RemoteData Http.Error ()
    , touched : Set String
    , pendingEmail : Maybe String
    }


type Msg
    = SetDisplayName String
    | SetHandle String
    | SetEmail String
    | SetCurrentPassword String
    | SetWebsiteUrl String
    | SetCountryCode String
    | SetCity String
    | SaveProfile
    | SaveProfileCompleted (Result Api.ProfileError Api.ProfileSaved)
    | SaveLocation
    | SaveLocationCompleted (Result Http.Error ())
    | AccountReceived (Result Http.Error Api.Account)
    | SessionExpiryDetected


{-| `SessionExpired` bubbles to `Main.handleSessionExpiry`.

Until this page had no `OutMsg`, so an expired session came back as
`ProfileRequestFailed (BadStatus 401)` and rendered "Could not save profile.
Please try again." — over a form still holding the reader's current password,
typed in to authorise an email change that can no longer happen.

`IdentityChanged` carries the account's identity as the server settled it, so
the app can refresh the stored session. The nav renders `displayName` out of
that stored blob, and nothing rewrote the blob after a save — so a reader who
renamed themselves kept seeing the old name in the corner of every page until
they signed out and back in.

-}
type OutMsg
    = NoOut
    | SessionExpired
    | IdentityChanged { displayName : String, handle : String }


{-| The form as the stored session can describe it — an instant placeholder,
not the account.

Deliberately not called `init`: on every sibling page `init` is the whole way in,
and here it would be the bug this module exists to fix, one keystroke from the
right answer. `initWithToken` is the way in. This is kept exported for the tests
and the flows with no network, under a name that says what it is worth.

-}
seedFromSession : User -> Model
seedFromSession user =
    { displayName = user.displayName
    , handle = user.handle
    , initialHandle = user.handle
    , email = user.email
    , initialEmail = user.email
    , currentPassword = ""
    , currentPasswordError = Nothing
    , websiteUrl = ""
    , countryCode = Maybe.withDefault "" user.countryCode
    , city = Maybe.withDefault "" user.city
    , savingProfile = NotAsked
    , savingLocation = NotAsked
    , account = NotAsked
    , pendingEmail = Nothing
    , touched = Set.empty
    }


{-| How `Main` opens the page: seed from the blob, then ask the server.

`Loading` renders nothing of its own — the placeholder fields are already there
and usable, and a spinner over a filled form would be a worse answer than the
one it hides. Only `Failure` speaks up, because then the fields on screen are
the blob's and the reader deserves to know that.

-}
initWithToken : Maybe String -> User -> ( Model, Cmd Msg )
initWithToken maybeToken user =
    let
        ( model, effect ) =
            initWithEffect maybeToken user
    in
    ( model, Effect.perform effect )


{-| `initWithToken`, with its effect as data.

The one place that decides whether the page asks the server anything — so the
program test runs the request the page actually makes, rather than a harness's
second guess at it. Given only a `Cmd`, a hydration deleted from here would
leave that harness, and the whole suite, green. The save paths below still
return `Cmd`; they were not the thing at risk.

-}
initWithEffect : Maybe String -> User -> ( Model, Effect Msg )
initWithEffect maybeToken user =
    let
        seeded =
            seedFromSession user
    in
    case maybeToken of
        Just token ->
            ( { seeded | account = Loading }
            , Effect.authed Api.getAccountRequest
                token
                (Api.resolveJson Api.accountDecoder >> AccountReceived)
            )

        Nothing ->
            ( seeded, Effect.none )


{-| Replace the placeholder values with the server's, and rebaseline the
email/handle comparisons against them — a baseline left on the blob's email
would read the server's own address as a change and demand a password for it.

Skipped once the reader has typed: a response that lands after the first
keystroke would delete what they wrote, and a fetch that eats an edit is worse
than the stale field it was sent to fix.

-}
hydrate : Api.Account -> Model -> Model
hydrate account model =
    let
        -- A typed edit outranks the fetch for THAT field only.
        --
        -- This used to be a single `edited` flag that skipped hydration
        -- wholesale, which quietly re-created the data loss this module exists
        -- to prevent: one keystroke anywhere before the response landed left
        -- every other field holding the boot blob — and the blob carries no
        -- website at all (`websiteUrl = ""`) and a stale handle, country and
        -- city. `AccountReceived` then set `account = Success ()` regardless, so
        -- `savable` unlocked both Save buttons over those blanks and the reader
        -- wrote them across values they had never seen.
        --
        -- Per-field means the reader keeps exactly what they typed and the
        -- server fills everything else, so no save can carry an unseen blank.
        keep field serverValue current =
            if Set.member field model.touched then
                current

            else
                serverValue

        newHandle =
            keep "handle" account.handle model.handle

        newEmail =
            keep "email" account.email model.email
    in
    { model
        | displayName = keep "displayName" account.displayName model.displayName
        , handle = newHandle
        , initialHandle = account.handle
        , email = newEmail
        , initialEmail = account.email
        , websiteUrl = keep "websiteUrl" account.websiteUrl model.websiteUrl
        , countryCode = keep "countryCode" account.countryCode model.countryCode
        , city = keep "city" account.city model.city

        -- Whether a change is waiting on confirmation is server truth with no
        -- local rival — the panel always follows the account.
        , pendingEmail = account.pendingEmail
    }


{-| May this form write? Only once it has read what it would be writing over.

Both saves post the whole form, and the placeholder carries no website and no
location at all — so a save made before the account arrives, or after the read
failed, writes those blanks over values the reader never saw and did not
intend to clear. The `Failure` branch is the sharp one: the page says the fields
may be stale and would then let the reader save the stale ones.

-}
savable : Model -> Bool
savable model =
    case model.account of
        Success _ ->
            True

        _ ->
            False


{-| The email is only a _change_ when it differs from the stored value, compared
the way the server compares it (trimmed + case-insensitive — see
`Accounts.email_change?/2`). Only a real change requires the current password.
-}
emailChanged : Model -> Bool
emailChanged model =
    normaliseEmail model.email /= normaliseEmail model.initialEmail


normaliseEmail : String -> String
normaliseEmail =
    String.trim >> String.toLower


{-| The handle is only a _change_ when the field differs from the stored value.
An untouched field is never sent — for a session that carries no handle locally
the field renders empty, and sending `""` would write NULL over the real handle
(NOT NULL column → server 500). A genuine edit is sent and server-validated.
-}
handleChanged : Model -> Bool
handleChanged model =
    model.handle /= model.initialHandle


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg, OutMsg )
update msg model maybeToken =
    case msg of
        SetDisplayName val ->
            ( { model | displayName = val, savingProfile = NotAsked, touched = Set.insert "displayName" model.touched }, Cmd.none, NoOut )

        SetHandle val ->
            ( { model | handle = val, savingProfile = NotAsked, touched = Set.insert "handle" model.touched }, Cmd.none, NoOut )

        SetEmail val ->
            ( { model | email = val, currentPasswordError = Nothing, savingProfile = NotAsked, touched = Set.insert "email" model.touched }, Cmd.none, NoOut )

        SetCurrentPassword val ->
            ( { model | currentPassword = val, currentPasswordError = Nothing, savingProfile = NotAsked, touched = Set.insert "currentPassword" model.touched }, Cmd.none, NoOut )

        SetWebsiteUrl val ->
            ( { model | websiteUrl = val, savingProfile = NotAsked, touched = Set.insert "websiteUrl" model.touched }, Cmd.none, NoOut )

        SetCountryCode val ->
            ( { model | countryCode = val, savingLocation = NotAsked, touched = Set.insert "countryCode" model.touched }, Cmd.none, NoOut )

        SetCity val ->
            ( { model | city = val, savingLocation = NotAsked, touched = Set.insert "city" model.touched }, Cmd.none, NoOut )

        SaveProfile ->
            if emailChanged model && String.isEmpty (String.trim model.currentPassword) then
                ( { model | currentPasswordError = Just "Please enter your current password to change your email." }
                , Cmd.none
                , NoOut
                )

            else
                case maybeToken of
                    Just token ->
                        ( { model | savingProfile = Loading, currentPasswordError = Nothing }
                        , Api.updateProfile
                            { displayName = model.displayName
                            , email = model.email
                            , websiteUrl = model.websiteUrl
                            , handle = model.handle
                            , currentPassword = model.currentPassword
                            , emailChanged = emailChanged model
                            , handleChanged = handleChanged model
                            }
                            (Api.authed token
                                { onExpired = SessionExpiryDetected
                                , onResult = SaveProfileCompleted
                                }
                            )
                        , NoOut
                        )

                    Nothing ->
                        ( model, Cmd.none, NoOut )

        SaveProfileCompleted result ->
            case result of
                Ok saved ->
                    let
                        settledHandle =
                            if saved.handle == "" then
                                model.handle

                            else
                                saved.handle

                        -- The email field snaps back to the address the account
                        -- ANSWERS on. Leaving the typed address in place would
                        -- show a settled change that has not happened, and the
                        -- pending panel below would contradict the field above it.
                        settledEmail =
                            if saved.email == "" then
                                model.initialEmail

                            else
                                saved.email
                    in
                    ( { model
                        | savingProfile = Success ()
                        , email = settledEmail
                        , initialEmail = settledEmail
                        , pendingEmail = saved.pendingEmail
                        , currentPassword = ""
                        , currentPasswordError = Nothing
                        , handle = settledHandle
                        , initialHandle = settledHandle
                      }
                    , Cmd.none
                    , IdentityChanged
                        { displayName = model.displayName, handle = settledHandle }
                    )

                Err err ->
                    ( { model | savingProfile = Failure err }, Cmd.none, NoOut )

        SaveLocation ->
            case maybeToken of
                Just token ->
                    ( { model | savingLocation = Loading }
                    , Api.updateLocation
                        { countryCode = model.countryCode, city = model.city }
                        (Api.authed token
                            { onExpired = SessionExpiryDetected
                            , onResult = SaveLocationCompleted
                            }
                        )
                    , NoOut
                    )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        SaveLocationCompleted result ->
            case result of
                Ok _ ->
                    ( { model | savingLocation = Success () }, Cmd.none, NoOut )

                Err err ->
                    ( { model | savingLocation = Failure err }, Cmd.none, NoOut )

        AccountReceived (Ok account) ->
            ( hydrate account { model | account = Success () }, Cmd.none, NoOut )

        AccountReceived (Err err) ->
            if Api.isUnauthorized err then
                ( model, Cmd.none, SessionExpired )

            else
                ( { model | account = Failure err }, Cmd.none, NoOut )

        SessionExpiryDetected ->
            ( model, Cmd.none, SessionExpired )


view : Model -> Html Msg
view model =
    div [ class "page page--settings" ]
        [ h1 [ class "page__title" ] [ text "Profile" ]
        , viewAccountLoadFailure model.account
        , div [ class "settings-section" ]
            [ h2 [ class "settings-section__title" ] [ text "Personal Information" ]
            , div [ class "form-field" ]
                [ label [ class "form-field__label" ] [ text "Display Name" ]
                , input
                    [ type_ "text"
                    , class "form-field__input"
                    , value model.displayName
                    , onInput SetDisplayName
                    , placeholder "Your display name"
                    ]
                    []
                ]
            , div [ class "form-field" ]
                [ label [ class "form-field__label" ] [ text "Handle" ]
                , input
                    [ type_ "text"
                    , class "form-field__input"
                    , value model.handle
                    , onInput SetHandle
                    , placeholder "your_handle"
                    ]
                    []
                , p [ class "form-field__hint" ]
                    (viewHandleHint model.handle)
                , viewHandleError model.savingProfile
                ]
            , div [ class "form-field" ]
                [ label [ class "form-field__label" ] [ text "Email" ]
                , input
                    [ type_ "text"
                    , class "form-field__input"
                    , value model.email
                    , onInput SetEmail
                    , placeholder "your@email.com"
                    ]
                    []
                ]
            , viewCurrentPasswordField model
            , viewPendingEmail model
            , div [ class "form-field" ]
                [ label [ class "form-field__label" ] [ text "Website URL" ]
                , input
                    [ type_ "text"
                    , class "form-field__input"
                    , value model.websiteUrl
                    , onInput SetWebsiteUrl
                    , placeholder "https://example.com"
                    ]
                    []
                ]
            , div [ class "settings-actions" ]
                [ SaveButton.primaryWhenReady (savable model) model.savingProfile SaveProfile "Save Profile"
                ]
            , viewProfileFeedback model.savingProfile
            ]
        , div [ class "settings-section" ]
            [ h2 [ class "settings-section__title" ] [ text "Location" ]
            , div [ class "form-field" ]
                [ label [ class "form-field__label" ] [ text "Country Code" ]
                , input
                    [ type_ "text"
                    , class "form-field__input"
                    , value model.countryCode
                    , onInput SetCountryCode
                    , placeholder "US, GB, ZA, etc."
                    ]
                    []
                ]
            , div [ class "form-field" ]
                [ label [ class "form-field__label" ] [ text "City" ]
                , input
                    [ type_ "text"
                    , class "form-field__input"
                    , value model.city
                    , onInput SetCity
                    , placeholder "Your city"
                    ]
                    []
                ]
            , div [ class "settings-actions" ]
                [ SaveButton.primaryWhenReady (savable model) model.savingLocation SaveLocation "Save Location"
                ]
            , viewFeedback model.savingLocation "Location saved." "Could not save location. Please try again."
            ]
        ]


{-| Said only when the account could not be read. The fields below are then the
stored session's values, which carry no location and no website at all — so
staying quiet would present a form the reader has every reason to read as their
saved profile, and no way to tell apart from one.
-}
viewAccountLoadFailure : RemoteData Http.Error () -> Html Msg
viewAccountLoadFailure account =
    case account of
        Failure _ ->
            p [ class "error" ]
                [ text "We could not read your saved profile from the library, so these fields may be out of date. Reload the page to try again." ]

        _ ->
            text ""


{-| A change in flight, stated with both addresses and the consequence. Server
truth only — the panel renders from what `/api/auth/me` (or a save's answer)
said, never from what was typed.
-}
viewPendingEmail : Model -> Html Msg
viewPendingEmail model =
    case model.pendingEmail of
        Just pending ->
            div [ class "pending-email" ]
                [ p [ class "pending-email__lede" ]
                    [ text "Waiting on "
                    , strong [] [ text pending ]
                    ]
                , p [ class "pending-email__detail" ]
                    [ text ("We sent a confirmation link there, and a link to undo this change to " ++ model.initialEmail ++ ". Your account still uses " ++ model.initialEmail ++ " until the new address confirms itself.") ]
                , p [ class "pending-email__detail" ]
                    [ text "If neither is used within seven days, you'll be signed out until an address is confirmed — the undo link will still work." ]
                ]

        Nothing ->
            text ""


{-| The current-password prompt only appears once the email field actually
differs from the stored value — an ordinary profile edit never sees it. When a
save is blocked for a missing password, the inline error renders beneath it.
-}
viewCurrentPasswordField : Model -> Html Msg
viewCurrentPasswordField model =
    if emailChanged model then
        div [ class "form-field" ]
            [ label [ class "form-field__label" ] [ text "Current Password" ]
            , input
                [ type_ "password"
                , class "form-field__input"
                , value model.currentPassword
                , onInput SetCurrentPassword
                , placeholder "Confirm your current password"
                ]
                []
            , p [ class "form-field__hint" ]
                [ text "Confirm your current password to change your email address." ]
            , case model.currentPasswordError of
                Just message ->
                    p [ class "form-field__error" ] [ text message ]

                Nothing ->
                    text ""
            ]

    else
        text ""


viewFeedback : RemoteData Http.Error () -> String -> String -> Html Msg
viewFeedback saving successText errorText =
    case saving of
        Success _ ->
            p [ class "success" ] [ text successText ]

        Failure _ ->
            p [ class "error" ] [ text errorText ]

        _ ->
            text ""


{-| Profile-save feedback. A validation failure renders inline under the
offending field (see `viewHandleError`), so the section-level banner stays
quiet for those — it only speaks up for success or a non-validation error.
-}
viewProfileFeedback : RemoteData Api.ProfileError () -> Html Msg
viewProfileFeedback saving =
    case saving of
        Success _ ->
            p [ class "success" ] [ text "Profile saved." ]

        Failure (Api.ProfileValidationFailed _) ->
            text ""

        Failure (Api.ProfileRequestFailed err) ->
            p [ class "error" ] [ text (profileRequestErrorText err) ]

        _ ->
            text ""


{-| A non-validation profile save failure. A wrong current password on an email
change comes back as a 422 with `{"error": "invalid_current_password"}` (no
`errors` map, so `expectProfile` classifies it as a request failure, not a field
validation) — surface the same copy the Password page uses. The endpoint can
also return 503 with a `retry-after` when Argon2 is under backpressure (an email
change hashes the current password), so that case gets its own "try again
shortly" copy; anything else is a generic save error.
-}
profileRequestErrorText : Http.Error -> String
profileRequestErrorText err =
    case err of
        Http.BadStatus 422 ->
            "Current password is incorrect."

        Http.BadStatus 503 ->
            "The server is busy right now. Please try again in a moment."

        _ ->
            "Could not save profile. Please try again."


{-| Surface a handle-specific 422 error under the handle input, mapped to the
user-facing copy from
-}
viewHandleError : RemoteData Api.ProfileError () -> Html Msg
viewHandleError saving =
    case handleErrorMessage saving of
        Just message ->
            p [ class "form-field__error" ] [ text message ]

        Nothing ->
            text ""


handleErrorMessage : RemoteData Api.ProfileError () -> Maybe String
handleErrorMessage saving =
    case saving of
        Failure (Api.ProfileValidationFailed errors) ->
            errors
                |> List.filter (\( field, _ ) -> field == "handle")
                |> List.head
                |> Maybe.andThen (\( _, messages ) -> List.head messages)
                |> Maybe.map handleErrorCopy

        _ ->
            Nothing


{-| The live public-address hint under the handle field. Shows the full address
once a handle is present, and gentle guidance while the field is empty.

The address is a real link once there is a handle to link to. This is the only
route to your OWN public profile anywhere in the app — every other link to a
profile is a link to somebody ELSE's, so without this a reader cannot see what
their profile looks like to other people without hand-typing the URL.

-}
viewHandleHint : String -> List (Html msg)
viewHandleHint handle =
    let
        trimmed =
            String.trim handle
    in
    if trimmed == "" then
        [ text "Choose a handle — others will find you at thestacks.app/u/your_handle" ]

    else
        [ text "Your public profile lives at "
        , a
            [ href (Route.toPath (Route.Profile trimmed))
            , class "form-field__hint-link"
            ]
            [ text ("thestacks.app/u/" ++ trimmed) ]
        ]


handleErrorCopy : String -> String
handleErrorCopy raw =
    if String.contains "taken" raw then
        "That handle is already taken."

    else if String.contains "reserved" raw then
        "That handle is reserved."

    else
        "Handle must be 3–30 characters: lowercase letters, numbers, underscores."
