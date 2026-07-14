module Page.Settings.Privacy exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

import Api
import Html exposing (Html, button, div, h1, h2, input, label, option, p, select, text)
import Html.Attributes exposing (attribute, class, disabled, for, id, placeholder, selected, type_, value)
import Html.Events exposing (onClick, onInput)
import Http
import Types.RemoteData exposing (RemoteData(..))


type alias Model =
    { profileVisibility : String
    , shelfVisibilities : List ShelfVisibility
    , savingProfile : RemoteData Http.Error ()
    , savingShelf : RemoteData Http.Error ()
    , exporting : RemoteData Http.Error ()
    , deleteRequested : Bool
    , deleteConfirmation : String
    , deleting : RemoteData Http.Error ()
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
    }


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
            -- Back out of the danger zone entirely, discarding what was typed.
            -- Ignored while a request is in flight (the input/button are locked).
            if isDeleting model.deleting then
                ( model, Cmd.none, NoOut )

            else
                ( { model | deleteRequested = False, deleteConfirmation = "", deleting = NotAsked }
                , Cmd.none
                , NoOut
                )

        UserTypesDeleteConfirmation typed ->
            -- Ignore edits while a deletion is in flight: clearing `deleting`
            -- here would re-enable the submit button and let a second DELETE
            -- fire. The single-flight invariant lives in the handler, not the
            -- view alone.
            if isDeleting model.deleting then
                ( model, Cmd.none, NoOut )

            else
                ( { model | deleteConfirmation = typed, deleting = NotAsked }, Cmd.none, NoOut )

        UserClicksDeleteAccount ->
            -- Fire only on an exact confirmation AND when no request is already
            -- in flight — a real single-flight guard in the handler, not just a
            -- disabled attribute in the view.
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
                    -- Queued server-side. Confirm to the user, then hand off to
                    -- Main to clear the session and show the farewell.
                    ( { model | deleting = Success () }, Cmd.none, AccountDeleted )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | deleting = Failure err }, Cmd.none, NoOut )


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
                    , option [ value "platform", selected (model.profileVisibility == "platform") ] [ text "Discoverable" ]
                    ]
                ]
            , div [ class "settings-actions" ]
                [ viewSaveButton model.savingProfile SaveProfileVisibility "Save Profile Visibility"
                ]
            , viewFeedback model.savingProfile
            ]
        , div [ class "settings-section" ]
            [ h2 [ class "settings-section__title" ] [ text "Shelf Visibility" ]
            , p [ class "settings-section__desc" ]
                [ text "Override visibility per shelf. Each shelf's visibility is capped by your profile visibility (the ceiling rule)." ]
            , div [ class "privacy__shelves" ]
                (List.map viewShelfRow model.shelfVisibilities)
            , viewFeedback model.savingShelf
            ]
        , viewExportSection model.exporting
        , viewDangerZone model
        ]


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


viewShelfRow : ShelfVisibility -> Html Msg
viewShelfRow sv =
    div [ class "privacy__shelf-row" ]
        [ div [ class "form-field" ]
            [ label [ class "form-field__label" ] [ text sv.label ]
            , select
                [ class "form-field__select"
                , onInput (SetShelfVisibility sv.name)
                ]
                [ option [ value "owner", selected (sv.visibility == "owner") ] [ text "Only me" ]
                , option [ value "group", selected (sv.visibility == "group") ] [ text "Group" ]
                , option [ value "platform", selected (sv.visibility == "platform") ] [ text "Platform" ]
                ]
            ]
        , button
            [ class "btn btn--small btn--secondary"
            , onClick (SaveShelfVisibility sv.name)
            ]
            [ text "Save" ]
        ]


viewSaveButton : RemoteData Http.Error () -> Msg -> String -> Html Msg
viewSaveButton saving onClickMsg labelText =
    case saving of
        Loading ->
            button [ class "btn btn--primary btn--disabled", disabled True ]
                [ text "Saving..." ]

        Success _ ->
            button [ class "btn btn--primary" ]
                [ text "Saved!" ]

        _ ->
            button [ class "btn btn--primary", onClick onClickMsg ]
                [ text labelText ]


viewFeedback : RemoteData Http.Error () -> Html Msg
viewFeedback saving =
    case saving of
        Success _ ->
            p [ class "success" ] [ text "Visibility updated." ]

        Failure _ ->
            p [ class "error" ] [ text "Could not save. Please try again." ]

        _ ->
            text ""
