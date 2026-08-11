module Page.Settings.Privacy exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , initWithToken
    , update
    , view
    )

import Api
import Components.SaveButton as SaveButton
import Html exposing (Html, button, div, h1, h2, input, label, option, p, select, span, text)
import Html.Attributes exposing (attribute, class, disabled, for, id, placeholder, selected, type_, value)
import Html.Events exposing (onClick, onInput)
import Http
import Page.Settings.Consent as Consent
import Types.RemoteData exposing (RemoteData(..))
import Types.Visibility as Visibility
import Util.FailureCopy as FailureCopy
import Util.TestId exposing (testId)


type alias Model =
    { profileVisibility : String
    , shelfVisibilities : List ShelfVisibility
    , savingProfile : RemoteData Http.Error ()
    , savingShelf : RemoteData Http.Error ()
    , exporting : RemoteData Http.Error ()
    , deleteRequested : Bool
    , deleteConfirmation : String
    , deleting : RemoteData Http.Error ()
    , blockedUsers : RemoteData Http.Error (List Api.BlockedUser)
    , blockedTotal : Int
    , blockedPage : Int
    , loadingMore : Bool
    , unblocking : Maybe String
    , unblockError : Bool
    , consent : Consent.Model
    }


type alias ShelfVisibility =
    { name : String
    , label : String
    , visibility : String
    }


type Msg
    = SetProfileVisibility String
    | SetShelfVisibility String String
    | SaveProfileVisibility
    | SaveProfileVisibilityCompleted (Result Http.Error ())
    | SaveShelfVisibility String
    | SaveShelfVisibilityCompleted (Result Http.Error ())
    | UserClicksExport
    | GotExportResponse (Result Http.Error ())
    | UserClicksDeleteMyData
    | UserCancelsDelete
    | UserTypesDeleteConfirmation String
    | UserClicksDeleteAccount
    | GotDeleteResponse (Result Http.Error ())
    | GotPrivacySettings (Result Http.Error Api.PrivacySettings)
    | GotBlockedUsers (Result Http.Error Api.BlockedUsersResponse)
    | LoadMoreBlocked
    | UserClicksUnblock String
    | GotUnblockResponse String (Result Http.Error ())
    | ConsentMsg Consent.Msg


type OutMsg
    = NoOut
    | SessionExpired
    | AccountDeleted


{-| The literal a user must type to arm the destructive account-deletion action.
The confirmation text must equal this EXACTLY (case-sensitive, no surrounding
whitespace) before the submit button is enabled.
-}
deleteConfirmationPhrase : String
deleteConfirmationPhrase =
    "DELETE"


{-| True only when the typed confirmation exactly matches the required phrase.
-}
deleteConfirmed : String -> Bool
deleteConfirmed typed =
    typed == deleteConfirmationPhrase


{-| True while an account-deletion request is in flight. The single-flight guard
depends on this so a second DELETE can never be fired mid-request.
-}
isDeleting : RemoteData Http.Error () -> Bool
isDeleting deleting =
    case deleting of
        Loading ->
            True

        _ ->
            False


defaultShelves : List ShelfVisibility
defaultShelves =
    [ { name = "library", label = "Library", visibility = "platform" }
    , { name = "antilibrary", label = "Antilibrary", visibility = "platform" }
    , { name = "wishlist", label = "Wish List", visibility = "platform" }
    , { name = "reading_pile", label = "Reading Pile", visibility = "platform" }
    , { name = "looking_for_home", label = "Looking for a Home", visibility = "platform" }
    ]


{-| Overlay the persisted per-shelf visibilities from the server onto the fixed
set of named shelves, preserving each shelf's human label and full ordering. A
shelf the user has never customised keeps its default visibility.
-}
seedShelves : List Api.ShelfVisibilitySetting -> List ShelfVisibility
seedShelves saved =
    List.map
        (\sv ->
            case List.filter (\s -> s.name == sv.name) saved of
                match :: _ ->
                    { sv | visibility = match.visibility }

                [] ->
                    sv
        )
        defaultShelves


init : Model
init =
    { profileVisibility = "owner"
    , shelfVisibilities = defaultShelves
    , savingProfile = NotAsked
    , savingShelf = NotAsked
    , exporting = NotAsked
    , deleteRequested = False
    , deleteConfirmation = ""
    , deleting = NotAsked
    , blockedUsers = NotAsked
    , blockedTotal = 0
    , blockedPage = 1
    , loadingMore = False
    , unblocking = Nothing
    , unblockError = False
    , consent = Consent.init { analytics = False, writingAssistant = False }
    }


{-| Entry point used by `Main` when the Privacy page opens: seeds the model and,
when authenticated, kicks off the blocked-users fetch. `consentSeed` reflects the
signed-in user's current consent so the folded-in toggles open showing reality
(same seeding the standalone consent page used to do). The bare `init` is kept
for tests and flows that don't need the network.
-}
initWithToken : Maybe String -> { analytics : Bool, writingAssistant : Bool } -> ( Model, Cmd Msg )
initWithToken maybeToken consentSeed =
    let
        seeded =
            { init | consent = Consent.init consentSeed }
    in
    case maybeToken of
        Just token ->
            ( { seeded | blockedUsers = Loading }
            , Cmd.batch
                [ Api.getPrivacySettings token GotPrivacySettings
                , Api.listBlockedUsers token 1 GotBlockedUsers
                ]
            )

        Nothing ->
            ( seeded, Cmd.none )


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg, OutMsg )
update msg model maybeToken =
    case msg of
        SetProfileVisibility val ->
            ( { model | profileVisibility = val, savingProfile = NotAsked }, Cmd.none, NoOut )

        SetShelfVisibility shelfName val ->
            let
                updated =
                    List.map
                        (\sv ->
                            if sv.name == shelfName then
                                { sv | visibility = val }

                            else
                                sv
                        )
                        model.shelfVisibilities
            in
            ( { model | shelfVisibilities = updated, savingShelf = NotAsked }, Cmd.none, NoOut )

        SaveProfileVisibility ->
            case maybeToken of
                Just token ->
                    ( { model | savingProfile = Loading }
                    , Api.updateProfileVisibility model.profileVisibility token SaveProfileVisibilityCompleted
                    , NoOut
                    )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        SaveProfileVisibilityCompleted result ->
            case result of
                Ok _ ->
                    ( { model | savingProfile = Success () }, Cmd.none, NoOut )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | savingProfile = Failure err }, Cmd.none, NoOut )

        SaveShelfVisibility shelfName ->
            case maybeToken of
                Just token ->
                    let
                        vis =
                            model.shelfVisibilities
                                |> List.filter (\sv -> sv.name == shelfName)
                                |> List.head
                                |> Maybe.map .visibility
                                |> Maybe.withDefault "platform"
                    in
                    ( { model | savingShelf = Loading }
                    , Api.updateShelfVisibility shelfName vis token SaveShelfVisibilityCompleted
                    , NoOut
                    )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        SaveShelfVisibilityCompleted result ->
            case result of
                Ok _ ->
                    ( { model | savingShelf = Success () }, Cmd.none, NoOut )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | savingShelf = Failure err }, Cmd.none, NoOut )

        UserClicksExport ->
            case maybeToken of
                Just token ->
                    ( { model | exporting = Loading }
                    , Api.requestExport token GotExportResponse
                    , NoOut
                    )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        GotExportResponse result ->
            case result of
                Ok _ ->
                    ( { model | exporting = Success () }, Cmd.none, NoOut )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | exporting = Failure err }, Cmd.none, NoOut )

        UserClicksDeleteMyData ->
            ( { model | deleteRequested = True }, Cmd.none, NoOut )

        UserCancelsDelete ->
            if isDeleting model.deleting then
                ( model, Cmd.none, NoOut )

            else
                ( { model | deleteRequested = False, deleteConfirmation = "", deleting = NotAsked }
                , Cmd.none
                , NoOut
                )

        UserTypesDeleteConfirmation typed ->
            if isDeleting model.deleting then
                ( model, Cmd.none, NoOut )

            else
                ( { model | deleteConfirmation = typed, deleting = NotAsked }, Cmd.none, NoOut )

        UserClicksDeleteAccount ->
            if deleteConfirmed model.deleteConfirmation && not (isDeleting model.deleting) then
                case maybeToken of
                    Just token ->
                        ( { model | deleting = Loading }
                        , Api.deleteAccount token GotDeleteResponse
                        , NoOut
                        )

                    Nothing ->
                        ( model, Cmd.none, NoOut )

            else
                ( model, Cmd.none, NoOut )

        GotDeleteResponse result ->
            case result of
                Ok _ ->
                    ( { model | deleting = Success () }, Cmd.none, AccountDeleted )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | deleting = Failure err }, Cmd.none, NoOut )

        GotPrivacySettings result ->
            case result of
                Ok settings ->
                    ( { model
                        | profileVisibility = settings.profileVisibility
                        , shelfVisibilities = seedShelves settings.shelves

                        -- #367: hydrate consent from the SERVER, overwriting the
                        -- login-blob seed. The blob is written only at login /
                        -- token renewal, so a consent change made in a prior
                        -- session (or on another device) left the toggles showing
                        -- a stale value until now. This init fetch is the source
                        -- of truth for what the toggles display.
                        , consent =
                            Consent.init
                                { analytics = settings.consentAnalytics
                                , writingAssistant = settings.consentWritingAssistant
                                }
                      }
                    , Cmd.none
                    , NoOut
                    )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( model, Cmd.none, NoOut )

        GotBlockedUsers result ->
            case result of
                Ok response ->
                    let
                        merged =
                            case model.blockedUsers of
                                Success existing ->
                                    if response.page > 1 then
                                        existing ++ response.blockedUsers

                                    else
                                        response.blockedUsers

                                _ ->
                                    response.blockedUsers
                    in
                    ( { model
                        | blockedUsers = Success merged
                        , blockedTotal = response.total
                        , blockedPage = response.page
                        , loadingMore = False
                      }
                    , Cmd.none
                    , NoOut
                    )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | blockedUsers = Failure err, loadingMore = False }, Cmd.none, NoOut )

        LoadMoreBlocked ->
            case maybeToken of
                Just token ->
                    ( { model | loadingMore = True }
                    , Api.listBlockedUsers token (model.blockedPage + 1) GotBlockedUsers
                    , NoOut
                    )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        UserClicksUnblock userId ->
            case maybeToken of
                Just token ->
                    ( { model | unblocking = Just userId, unblockError = False }
                    , Api.unblockUser userId token (GotUnblockResponse userId)
                    , NoOut
                    )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        GotUnblockResponse userId result ->
            case result of
                Ok _ ->
                    let
                        remaining =
                            case model.blockedUsers of
                                Success users ->
                                    Success (List.filter (\u -> u.id /= userId) users)

                                other ->
                                    other
                    in
                    ( { model | blockedUsers = remaining, unblocking = Nothing, unblockError = False }, Cmd.none, NoOut )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | unblocking = Nothing, unblockError = True }, Cmd.none, NoOut )

        ConsentMsg subMsg ->
            let
                ( newConsent, subCmd, consentOut ) =
                    Consent.update subMsg model.consent maybeToken

                out =
                    case consentOut of
                        Consent.NoOut ->
                            NoOut

                        Consent.SessionExpired ->
                            SessionExpired
            in
            ( { model | consent = newConsent }, Cmd.map ConsentMsg subCmd, out )


view : Model -> Html Msg
view model =
    div [ class "page page--settings" ]
        [ h1 [ class "page__title" ] [ text "Privacy" ]
        , div [ class "settings-section" ]
            [ h2 [ class "settings-section__title" ] [ text "Profile Visibility" ]
            , p [ class "settings-section__desc" ]
                [ text "Control who can discover your profile." ]
            , p [ class "settings-section__note" ]
                [ text "Your profile and content will never appear in search engine results." ]
            , div [ class "form-field" ]
                [ label [ class "form-field__label" ] [ text "Profile" ]
                , select
                    [ class "form-field__select"
                    , onInput SetProfileVisibility
                    ]
                    [ option [ value "owner", selected (model.profileVisibility == "owner") ] [ text "Only me" ]
                    , option [ value "platform", selected (model.profileVisibility == "platform") ] [ text "Members (signed-in users)" ]
                    , option [ value "public", selected (model.profileVisibility == "public") ] [ text "Anyone with the link" ]
                    ]
                ]
            , div [ class "settings-actions" ]
                [ SaveButton.primary model.savingProfile SaveProfileVisibility "Save Profile Visibility"
                ]
            , viewFeedback model.savingProfile
            ]
        , div [ class "settings-section" ]
            [ h2 [ class "settings-section__title" ] [ text "Shelf Visibility" ]
            , p [ class "settings-section__desc" ]
                [ text "Override visibility per shelf. Each shelf's visibility is capped by your profile visibility (the ceiling rule)." ]
            , div [ class "privacy__shelves" ]
                (List.map (viewShelfRow model.profileVisibility) model.shelfVisibilities)
            , viewFeedback model.savingShelf
            ]
        , viewConsentSection model.consent
        , viewExportSection model.exporting
        , viewBlockedUsersSection model
        , viewDangerZone model
        ]


viewBlockedUsersSection : Model -> Html Msg
viewBlockedUsersSection model =
    div [ class "settings-section", testId "blocked-users-section" ]
        [ h2 [ class "settings-section__title" ] [ text "Blocked Users" ]
        , p [ class "settings-section__desc" ]
            [ text "Readers you've blocked can't see your content, and you won't see theirs. Unblock anyone to restore that." ]
        , case model.blockedUsers of
            NotAsked ->
                text ""

            Loading ->
                p [ class "loading" ] [ text "Loading your blocked list…" ]

            Failure _ ->
                p [ class "error" ] [ text "We couldn't load your blocked list. Please try again." ]

            Success [] ->
                p [ class "privacy__blocked-empty" ] [ text "You haven't blocked anyone." ]

            Success users ->
                div []
                    [ div [ class "privacy__blocked-list" ]
                        (List.map (viewBlockedRow model.unblocking) users)
                    , viewLoadMore model users
                    ]
        , if model.unblockError then
            p [ attribute "aria-live" "assertive", class "error" ]
                [ text "We couldn't unblock that reader. Please try again." ]

          else
            text ""
        ]


{-| "Load more" affordance for readers who've blocked more than one page (20)
of others. Shown only while fewer readers are loaded than the server's total.
-}
viewLoadMore : Model -> List Api.BlockedUser -> Html Msg
viewLoadMore model users =
    if List.length users < model.blockedTotal then
        div [ class "privacy__blocked-load-more" ]
            [ button
                [ class "btn btn--small btn--secondary"
                , disabled model.loadingMore
                , onClick LoadMoreBlocked
                ]
                [ text
                    (if model.loadingMore then
                        "Loading…"

                     else
                        "Load more"
                    )
                ]
            ]

    else
        text ""


viewBlockedRow : Maybe String -> Api.BlockedUser -> Html Msg
viewBlockedRow unblocking user =
    let
        inFlight =
            unblocking == Just user.id
    in
    div [ class "blocked-user privacy__blocked-row" ]
        [ span [ class "blocked-user__name" ] [ text user.displayName ]
        , button
            [ class "btn btn--small btn--secondary blocked-user__unblock"
            , disabled inFlight
            , onClick (UserClicksUnblock user.id)
            ]
            [ text
                (if inFlight then
                    "Unblocking…"

                 else
                    "Unblock"
                )
            ]
        ]


{-| The consent controls, folded in from the former /settings/consent page
(#318 TR-4). `Consent.viewSection` renders exactly the toggles the standalone
page showed; its messages are mapped up through `ConsentMsg` and delegated
straight back to `Consent.update`, so the recorded consent is unchanged.
-}
viewConsentSection : Consent.Model -> Html Msg
viewConsentSection consent =
    Html.map ConsentMsg (Consent.viewSection consent)


viewExportSection : RemoteData Http.Error () -> Html Msg
viewExportSection exporting =
    div [ class "settings-section" ]
        [ h2 [ class "settings-section__title" ] [ text "Your Data" ]
        , p [ class "settings-section__desc" ]
            [ text "Request a copy of your personal data — including your shelves, reading history, notes, and preferences. We'll email you when it's ready to download." ]
        , div [ class "settings-actions" ]
            [ viewExportButton exporting ]
        , viewExportFeedback exporting
        ]


viewExportButton : RemoteData Http.Error () -> Html Msg
viewExportButton exporting =
    case exporting of
        Loading ->
            button [ class "btn btn--primary btn--disabled", disabled True ]
                [ text "Preparing your export…" ]

        _ ->
            button [ class "btn btn--primary", onClick UserClicksExport ]
                [ text "Export My Data" ]


viewExportFeedback : RemoteData Http.Error () -> Html Msg
viewExportFeedback exporting =
    case exporting of
        Success _ ->
            p [ class "success" ] [ text "Export queued. We'll email you when it's ready." ]

        Failure _ ->
            p [ class "error" ] [ text "We couldn't queue your export. Please try again." ]

        _ ->
            text ""


{-| The destructive account-deletion flow. Kept visually distinct ("Danger
Zone") and gated behind an explicit reveal plus a type-to-confirm guard.
-}
viewDangerZone : Model -> Html Msg
viewDangerZone model =
    div [ class "settings-section settings-section--danger" ]
        [ h2 [ class "settings-section__title" ] [ text "Danger Zone" ]
        , p [ class "settings-section__desc" ]
            [ text "This will permanently delete all your data from The Stacks — your shelves, reading history, notes, and preferences. Analytics data will be anonymised. This cannot be undone." ]
        , if model.deleteRequested then
            viewDeleteConfirm model.deleteConfirmation model.deleting

          else
            div [ class "settings-actions" ]
                [ button
                    [ class "btn btn--danger"
                    , onClick UserClicksDeleteMyData
                    ]
                    [ text "Delete My Data" ]
                ]
        ]


viewDeleteConfirm : String -> RemoteData Http.Error () -> Html Msg
viewDeleteConfirm confirmation deleting =
    let
        loading =
            isDeleting deleting

        confirmed =
            deleteConfirmed confirmation
    in
    div [ class "privacy__delete-confirm" ]
        [ div [ class "form-field" ]
            [ label [ class "form-field__label", for "delete-confirmation" ]
                [ text "Type DELETE to confirm" ]
            , input
                [ id "delete-confirmation"
                , class "form-field__input"
                , type_ "text"
                , value confirmation
                , placeholder "DELETE"
                , disabled loading
                , onInput UserTypesDeleteConfirmation
                ]
                []
            ]
        , if not confirmed && not loading then
            p [ class "privacy__delete-hint" ]
                [ text "Enter DELETE above to enable this button." ]

          else
            text ""
        , div [ class "settings-actions" ]
            [ viewDeleteButton confirmed deleting
            , button
                [ class "btn btn--secondary"
                , disabled loading
                , onClick UserCancelsDelete
                ]
                [ text "Cancel" ]
            ]
        , viewDeleteFeedback deleting
        ]


viewDeleteButton : Bool -> RemoteData Http.Error () -> Html Msg
viewDeleteButton confirmed deleting =
    case deleting of
        Loading ->
            button [ class "btn btn--danger btn--disabled", disabled True ]
                [ text "Queuing account deletion…" ]

        _ ->
            button
                [ class
                    (if confirmed then
                        "btn btn--danger"

                     else
                        "btn btn--danger btn--disabled"
                    )
                , disabled (not confirmed)
                , onClick UserClicksDeleteAccount
                ]
                [ text "Delete My Data" ]


viewDeleteFeedback : RemoteData Http.Error () -> Html Msg
viewDeleteFeedback deleting =
    case deleting of
        Success _ ->
            p [ attribute "aria-live" "polite", class "success" ]
                [ text "Account deletion has been queued. Signing you out…" ]

        Failure _ ->
            p [ attribute "aria-live" "assertive", class "error" ]
                [ text "We couldn't queue your account deletion. Please try again." ]

        _ ->
            text ""


{-| A shelf may not be _more exposed_ than the profile ceiling (the server returns
422 otherwise). Exposure ladder: owner < group < platform < public. A shelf option
is greyed when its exposure exceeds the profile's — so an `owner` profile greys
everything but owner, a `platform` (Members) profile greys `public`, and a `public`
profile greys nothing. Single-sourced from `Types.Visibility.rank`.
-}
shelfOptionExceedsCeiling : String -> String -> Bool
shelfOptionExceedsCeiling profileVisibility optionValue =
    visibilityExposure optionValue > visibilityExposure profileVisibility


visibilityExposure : String -> Int
visibilityExposure v =
    Visibility.fromString v
        |> Maybe.map Visibility.rank
        |> Maybe.withDefault 0


viewShelfRow : String -> ShelfVisibility -> Html Msg
viewShelfRow profileVisibility sv =
    let
        shelfOption optionValue optionLabel =
            option
                [ value optionValue
                , selected (sv.visibility == optionValue)
                , disabled (shelfOptionExceedsCeiling profileVisibility optionValue)
                ]
                [ text optionLabel ]
    in
    div [ class "privacy__shelf-row" ]
        [ div [ class "form-field" ]
            [ label [ class "form-field__label" ] [ text sv.label ]
            , select
                [ class "form-field__select"
                , onInput (SetShelfVisibility sv.name)
                ]
                [ shelfOption "owner" "Only me"
                , shelfOption "group" "Group"
                , shelfOption "platform" "Members"
                , shelfOption "public" "Anyone with the link"
                ]
            ]
        , button
            [ class "btn btn--small btn--secondary"
            , onClick (SaveShelfVisibility sv.name)
            ]
            [ text "Save" ]
        ]


{-| ⛔ "Could not save. Please try again." was the answer to every failure here,
including the one this page documents four functions above (Issue #374).

`shelfOptionExceedsCeiling` explains that the server answers **422** when a shelf
is set more exposed than the profile ceiling — a rule the reader can satisfy, and
the only failure on this form they can do anything about. It was being reported
with the same six words as a dropped connection, and "please try again" is the
one instruction guaranteed not to work: the same request fails the same way
forever until the ceiling moves.

-}
viewFeedback : RemoteData Http.Error () -> Html Msg
viewFeedback saving =
    case saving of
        Success _ ->
            p [ class "success" ] [ text "Visibility updated." ]

        Failure (Http.BadStatus 422) ->
            p [ class "error" ]
                [ text "A shelf cannot be more visible than your profile. Raise your profile's visibility first, or choose a narrower setting for the shelf." ]

        Failure err ->
            p [ class "error" ] [ text (FailureCopy.saveFailure "that visibility setting" err) ]

        _ ->
            text ""
