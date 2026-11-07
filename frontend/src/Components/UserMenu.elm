module Components.UserMenu exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , SettingsLink
    , init
    , update
    , view
    )

import Html exposing (Html, button, div, li, span, text, ul)
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


{-| The account menu, which also carries whether a sign-out is still unconfirmed.

⛔ `sessionStillLive` IS THE SECOND HALF OF THE STALLED-SIGN-OUT FIX, and the
more important half. The banner that reports it is `position: sticky` now, so it
survives scrolling — but this is where a reader looks for anything about their
account, and it survives SPA navigation by construction because the chrome is
not re-rendered per route.

⚖️ Both, not one: the banner is what a reader sees without looking, and the menu
is what they find when they go looking. A banner alone is missable; a menu entry
alone would never be seen by someone who does not already suspect a problem.

-}
view : User -> List SettingsLink -> Bool -> Model -> Html Msg
view user links sessionStillLive model =
    div
        [ class "user-menu"
        , attribute "aria-label" "User menu"
        ]
        [ button
            [ class
                (if sessionStillLive then
                    "user-menu__trigger user-menu__trigger--session-live app-nav__link app-nav__user"

                 else
                    "user-menu__trigger app-nav__link app-nav__user"
                )
            , testId "user-menu"
            , onClick Toggle
            , attribute "aria-expanded" (boolToString model.open)
            , attribute "aria-haspopup" "true"
            ]
            [ text user.displayName
            , if sessionStillLive then
                -- ⚠️ The marker is not a bare dot. A coloured dot alone says
                -- "something" and is invisible to a screen reader; this carries
                -- its meaning in text that is visually hidden but announced.
                span
                    [ class "user-menu__session-marker"
                    , testId "user-menu-session-marker"
                    , attribute "aria-hidden" "true"
                    ]
                    [ text "•" ]

              else
                text ""
            , if sessionStillLive then
                span [ class "visually-hidden" ]
                    [ text " — still signed in on this device" ]

              else
                text ""
            ]
        , if model.open then
            viewDropdown links sessionStillLive

          else
            text ""
        ]


viewDropdown : List SettingsLink -> Bool -> Html Msg
viewDropdown links sessionStillLive =
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
            (sessionNotice sessionStillLive
                ++ List.map viewSettingsLink links
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


{-| The unconfirmed-sign-out notice, at the TOP of the menu.

⚖️ First rather than next to "Sign Out", though that is where it is acted on. A
reader who opens this menu after a failed sign-out is looking for the state of
their account, and the thing they need to know should not be below the links they
were not looking for.

⛔ It states what is true rather than what went wrong. "Your last sign-out did
not reach us" is a fact about the request; "you are still signed in on this
device" is the fact about the reader, and it is the one that matters.

-}
sessionNotice : Bool -> List (Html Msg)
sessionNotice sessionStillLive =
    if sessionStillLive then
        [ li [ class "user-menu__session-notice", testId "user-menu-session-notice" ]
            [ text "Still signed in on this device — your last sign-out did not reach us." ]
        ]

    else
        []


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
