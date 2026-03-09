module Page.Settings.AgeVerification exposing
    ( Model
    , Msg(..)
    , init
    , update
    , view
    )

import Api
import Html exposing (Html, button, div, h1, h2, label, p, text)
import Html.Attributes exposing (class)
import Html.Events exposing (onClick)
import Http
import Types.RemoteData exposing (RemoteData(..))


type alias Model =
    { ageVerified : Bool
    , saving : RemoteData Http.Error ()
    , confirmModalOpen : Bool
    }


type Msg
    = ToggleRequested
    | ConfirmToggle
    | CancelToggle
    | SaveCompleted (Result Http.Error ())


init : Model
init =
    { ageVerified = False
    , saving = NotAsked
    , confirmModalOpen = False
    }


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg )
update msg model maybeToken =
    case msg of
        ToggleRequested ->
            ( { model | confirmModalOpen = True }, Cmd.none )

        ConfirmToggle ->
            let
                newValue =
                    not model.ageVerified
            in
            case maybeToken of
                Just token ->
                    ( { model | confirmModalOpen = False, saving = Loading }
                    , Api.updateAgeVerification newValue token SaveCompleted
                    )

                Nothing ->
                    ( { model | confirmModalOpen = False }, Cmd.none )

        CancelToggle ->
            ( { model | confirmModalOpen = False }, Cmd.none )

        SaveCompleted result ->
            case result of
                Ok _ ->
                    -- Flip the local state only after the server confirms it.
                    ( { model | ageVerified = not model.ageVerified, saving = Success () }, Cmd.none )

                Err err ->
                    ( { model | saving = Failure err }, Cmd.none )


view : Model -> Html Msg
view model =
    div [ class "page page--settings" ]
        [ h1 [ class "page__title" ] [ text "Age Verification" ]
        , div [ class "settings-section" ]
            [ h2 [ class "settings-section__title" ] [ text "I am 18 or older" ]
            , p [ class "settings-section__desc" ]
                [ text
                    "Some content on The Stacks is age-restricted. Please confirm you are 18 or older."
                ]
            , div [ class "toggle-row" ]
                [ label [ class "toggle-row__label" ]
                    [ text
                        (if model.ageVerified then
                            "Verified (18+)"

                         else
                            "Not verified"
                        )
                    ]
                , button
                    [ class
                        (if model.ageVerified then
                            "toggle toggle--on"

                         else
                            "toggle toggle--off"
                        )
                    , onClick ToggleRequested
                    ]
                    [ text
                        (if model.ageVerified then
                            "Verified"

                         else
                            "Verify"
                        )
                    ]
                ]
            ]
        , if model.confirmModalOpen then
            viewConfirmModal model

          else
            text ""
        , case model.saving of
            Failure _ ->
                p [ class "error" ]
                    [ text "Could not save. Please try again." ]

            _ ->
                text ""
        ]


viewConfirmModal : Model -> Html Msg
viewConfirmModal model =
    div [ class "modal-overlay" ]
        [ div [ class "modal" ]
            [ h2 [ class "modal__title" ] [ text "Confirm Age" ]
            , p [ class "modal__message" ]
                [ text
                    (if model.ageVerified then
                        "Are you sure you want to remove your age verification?"

                     else
                        "By confirming, you declare that you are 18 years of age or older."
                    )
                ]
            , div [ class "modal__actions" ]
                [ button
                    [ class "btn btn--secondary"
                    , onClick CancelToggle
                    ]
                    [ text "Cancel" ]
                , button
                    [ class "btn btn--primary"
                    , onClick ConfirmToggle
                    ]
                    [ text "Confirm" ]
                ]
            ]
        ]
