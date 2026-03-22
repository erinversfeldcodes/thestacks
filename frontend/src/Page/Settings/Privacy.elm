module Page.Settings.Privacy exposing
    ( Model
    , Msg
    , init
    , update
    , view
    )

import Api
import Html exposing (Html, button, div, h1, h2, label, option, p, select, text)
import Html.Attributes exposing (class, disabled, selected, value)
import Html.Events exposing (onClick, onInput)
import Http
import Types.RemoteData exposing (RemoteData(..))


type alias Model =
    { profileVisibility : String
    , shelfVisibilities : List ShelfVisibility
    , savingProfile : RemoteData Http.Error ()
    , savingShelf : RemoteData Http.Error ()
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
    }


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg )
update msg model maybeToken =
    case msg of
        SetProfileVisibility val ->
            ( { model | profileVisibility = val, savingProfile = NotAsked }, Cmd.none )

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
            ( { model | shelfVisibilities = updated, savingShelf = NotAsked }, Cmd.none )

        SaveProfileVisibility ->
            case maybeToken of
                Just token ->
                    ( { model | savingProfile = Loading }
                    , Api.updateProfileVisibility model.profileVisibility token SaveProfileVisibilityCompleted
                    )

                Nothing ->
                    ( model, Cmd.none )

        SaveProfileVisibilityCompleted result ->
            case result of
                Ok _ ->
                    ( { model | savingProfile = Success () }, Cmd.none )

                Err err ->
                    ( { model | savingProfile = Failure err }, Cmd.none )

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
                    )

                Nothing ->
                    ( model, Cmd.none )

        SaveShelfVisibilityCompleted result ->
            case result of
                Ok _ ->
                    ( { model | savingShelf = Success () }, Cmd.none )

                Err err ->
                    ( { model | savingShelf = Failure err }, Cmd.none )


view : Model -> Html Msg
view model =
    div [ class "page page--settings" ]
        [ h1 [ class "page__title" ] [ text "Privacy" ]
        , div [ class "settings-section" ]
            [ h2 [ class "settings-section__title" ] [ text "Profile Visibility" ]
            , p [ class "settings-section__desc" ]
                [ text "Control who can discover your profile." ]
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
            ]
        ]


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
