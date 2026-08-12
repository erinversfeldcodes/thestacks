module Components.UserMenu exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , SettingsLink
    , init
    , update
    , view
    )

import Html exposing (Html, button, div, li, text, ul)
import Html.Attributes exposing (attribute, class, style)
import Html.Events exposing (onClick)
import Types.User exposing (User)
import Util.TestId exposing (testId)


type alias Model =
    { open : Bool
    }


{-| One destination in the account menu's settings family (TR-1). The
account menu used to reach exactly one settings page (Profile); it now folds
over a list of these so the whole family is reachable from nav. Paths are opaque
strings here — the caller (Main) owns `Route`, so there is one source of truth
for where each item points.
-}
type alias SettingsLink =
    { label : String
    , path : String
    }


type Msg
    = Toggle
    | Close
    | NavigateClicked String
    | SignOutClicked


type OutMsg
    = NoOut
    | NavigateTo String
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

        NavigateClicked path ->
            ( { model | open = False }, NavigateTo path )

        SignOutClicked ->
            ( { model | open = False }, SignOut )


view : User -> List SettingsLink -> Model -> Html Msg
view user links model =
    div
        [ class "user-menu"
        , attribute "aria-label" "User menu"
        ]
        [ button
            [ class "user-menu__trigger app-nav__link app-nav__user"
            , testId "user-menu"
            , onClick Toggle
            , attribute "aria-expanded" (boolToString model.open)
            , attribute "aria-haspopup" "true"
            ]
            [ text user.displayName ]
        , if model.open then
            viewDropdown links

          else
            text ""
        ]


viewDropdown : List SettingsLink -> Html Msg
viewDropdown links =
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
            , testId "user-menu-dropdown"
            , style "z-index" "1000"
            ]
            (List.map viewSettingsLink links
                ++ [ li []
                        [ button
                            [ class "app-nav__dropdown-link app-nav__logout"
                            , onClick SignOutClicked
                            ]
                            [ text "Sign Out" ]
                        ]
                   ]
            )
        ]


viewSettingsLink : SettingsLink -> Html Msg
viewSettingsLink link =
    li []
        [ button
            [ class "app-nav__dropdown-link"
            , onClick (NavigateClicked link.path)
            ]
            [ text link.label ]
        ]


boolToString : Bool -> String
boolToString b =
    if b then
        "true"

    else
        "false"
