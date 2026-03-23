module Components.UserMenu exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

import Html exposing (Html, button, div, li, text, ul)
import Html.Attributes exposing (attribute, class, style)
import Html.Events exposing (onClick)
import Types.User exposing (User)


type alias Model =
    { open : Bool
    }


type Msg
    = Toggle
    | Close
    | SettingsClicked
    | SignOutClicked


type OutMsg
    = NoOut
    | NavigateToSettings
    | SignOut


init : Model
init =
    { open = False }


update : Msg -> Model -> ( Model, OutMsg )
update msg model =
    case msg of
        Toggle ->
            ( { model | open = not model.open }, NoOut )

        Close ->
            ( { model | open = False }, NoOut )

        SettingsClicked ->
            ( { model | open = False }, NavigateToSettings )

        SignOutClicked ->
            ( { model | open = False }, SignOut )


view : User -> Model -> Html Msg
view user model =
    div
        [ class "user-menu"
        , attribute "aria-label" "User menu"
        ]
        [ button
            [ class "user-menu__trigger app-nav__link app-nav__user"
            , onClick Toggle
            , attribute "aria-expanded" (boolToString model.open)
            , attribute "aria-haspopup" "true"
            ]
            [ text user.displayName ]
        , if model.open then
            viewDropdown

          else
            text ""
        ]


viewDropdown : Html Msg
viewDropdown =
    div []
        [ -- Invisible full-screen backdrop to catch clicks outside the dropdown
          div
            [ class "user-menu__backdrop"
            , style "position" "fixed"
            , style "top" "0"
            , style "left" "0"
            , style "width" "100vw"
            , style "height" "100vh"
            , style "z-index" "999"
            , onClick Close
            ]
            []
        , ul
            [ class "user-menu__dropdown app-nav__dropdown-menu"
            , style "position" "relative"
            , style "z-index" "1000"
            ]
            [ li []
                [ button
                    [ class "app-nav__dropdown-link"
                    , onClick SettingsClicked
                    ]
                    [ text "Settings" ]
                ]
            , li []
                [ button
                    [ class "app-nav__dropdown-link app-nav__logout"
                    , onClick SignOutClicked
                    ]
                    [ text "Sign Out" ]
                ]
            ]
        ]


boolToString : Bool -> String
boolToString b =
    if b then
        "true"

    else
        "false"
