module Components.RSSLink exposing (Model, Msg, init, update, view)

import Html exposing (Html, button, div, input, p, span, text)
import Html.Attributes exposing (class, readonly, value)
import Html.Events exposing (onClick)


type alias Model =
    { showUrl : Bool
    }


type Msg
    = ToggleUrl


init : Model
init =
    { showUrl = False }


update : Msg -> Model -> Model
update msg model =
    case msg of
        ToggleUrl ->
            { model | showUrl = not model.showUrl }


{-| Render an RSS link for a bookshelf. Only renders when visibility is "platform".
-}
view : { visibility : String, userId : String, bookshelfName : String } -> Model -> Html Msg
view config model =
    if config.visibility /= "platform" then
        text ""

    else
        let
            feedUrl =
                "/api/feeds/" ++ config.userId ++ "/" ++ config.bookshelfName
        in
        div [ class "rss-link" ]
            [ button [ class "rss-link__button", onClick ToggleUrl ]
                [ span [ class "rss-link__icon" ] [ text "RSS" ]
                ]
            , if model.showUrl then
                div [ class "rss-link__popover" ]
                    [ p [ class "rss-link__help" ]
                        [ text "Subscribe in your RSS reader:" ]
                    , input
                        [ class "rss-link__url"
                        , value feedUrl
                        , readonly True
                        ]
                        []
                    ]

              else
                text ""
            ]
