module Page.ThirdSpaces exposing
    ( Model
    , Msg(..)
    , OutMsg
    , ThirdSpace
    , ThirdSpaceEvent
    , init
    , update
    , view
    )

import Html exposing (Html, a, button, div, h3, li, p, text, ul)
import Html.Attributes exposing (class, href)
import Html.Events exposing (onClick)
import Http
import Json.Decode as Decode
import Navigation.Route as Route
import Types.RemoteData exposing (RemoteData(..))


type alias ThirdSpaceEvent =
    { id : String
    , title : String
    , eventDate : String
    , endsAt : Maybe String
    }


type alias ThirdSpace =
    { id : String
    , name : String
    , type_ : String
    , city : String
    , countryCode : String
    , websiteUrl : String
    , verified : Bool
    , upcomingEvents : List ThirdSpaceEvent
    }


type alias Model =
    { spaces : RemoteData Http.Error (List ThirdSpace)
    , selectedSpace : Maybe ThirdSpace
    }


type Msg
    = SpacesLoaded (Result Http.Error (List ThirdSpace))
    | SelectSpace ThirdSpace
    | CloseDetail


type OutMsg
    = NoOut


init : Maybe String -> ( Model, Cmd Msg )
init maybeToken =
    ( { spaces = Loading
      , selectedSpace = Nothing
      }
    , Http.request
        { method = "GET"
        , headers =
            case maybeToken of
                Just token ->
                    [ Http.header "Authorization" ("Bearer " ++ token) ]

                Nothing ->
                    []
        , url = "/api/third-spaces"
        , body = Http.emptyBody
        , expect = Http.expectJson SpacesLoaded thirdSpacesResponseDecoder
        , timeout = Nothing
        , tracker = Nothing
        }
    )


thirdSpacesResponseDecoder : Decode.Decoder (List ThirdSpace)
thirdSpacesResponseDecoder =
    Decode.field "third_spaces" (Decode.list thirdSpaceDecoder)


thirdSpaceDecoder : Decode.Decoder ThirdSpace
thirdSpaceDecoder =
    Decode.map8 ThirdSpace
        (Decode.field "id" Decode.string)
        (Decode.field "name" Decode.string)
        (Decode.field "type" Decode.string)
        (Decode.field "city" Decode.string)
        (Decode.field "country_code" Decode.string)
        (Decode.field "website_url" Decode.string)
        (Decode.field "verified" Decode.bool)
        (Decode.field "upcoming_events" (Decode.list thirdSpaceEventDecoder))


thirdSpaceEventDecoder : Decode.Decoder ThirdSpaceEvent
thirdSpaceEventDecoder =
    Decode.map4 ThirdSpaceEvent
        (Decode.field "id" Decode.string)
        (Decode.field "title" Decode.string)
        (Decode.field "event_date" Decode.string)
        (Decode.maybe (Decode.field "ends_at" Decode.string))


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        SpacesLoaded (Ok spaces) ->
            ( { model | spaces = Success spaces }, Cmd.none, NoOut )

        SpacesLoaded (Err e) ->
            ( { model | spaces = Failure e }, Cmd.none, NoOut )

        SelectSpace space ->
            ( { model | selectedSpace = Just space }, Cmd.none, NoOut )

        CloseDetail ->
            ( { model | selectedSpace = Nothing }, Cmd.none, NoOut )


view : Model -> Html Msg
view model =
    div [ class "page page--third-spaces" ]
        [ case model.spaces of
            NotAsked ->
                text ""

            Loading ->
                p [] [ text "Loading spaces..." ]

            Failure _ ->
                p [] [ text "Failed to load spaces." ]

            Success [] ->
                p [] [ text "No third spaces found in your area yet." ]

            Success spaces ->
                div [ class "third-spaces__list" ]
                    (List.map viewSpaceCard spaces)
        , case model.selectedSpace of
            Just space ->
                viewSpaceDetail space

            Nothing ->
                text ""
        ]


viewSpaceCard : ThirdSpace -> Html Msg
viewSpaceCard space =
    button [ class "third-spaces__card", onClick (SelectSpace space) ]
        [ text space.name ]


viewSpaceDetail : ThirdSpace -> Html Msg
viewSpaceDetail space =
    div [ class "third-spaces__detail" ]
        [ h3 [] [ text space.name ]
        , p [] [ text space.city ]
        , if List.isEmpty space.upcomingEvents then
            text ""

          else
            ul [ class "third-spaces__events" ]
                (List.map
                    (\event -> li [] [ text event.title ])
                    space.upcomingEvents
                )
        , button [ class "btn btn--ghost", onClick CloseDetail ] [ text "Close" ]

        -- US-2.5.3: "Every listing carries a discreet 'Is this your business?' link."
        -- Discreet is the specification, not a style preference — this is a listing the
        -- business never asked for, so the way out should be findable without being an
        -- apology plastered across the card.
        , a
            [ class "third-spaces__claim"
            , href (Route.toPath Route.ListingRemoval)
            ]
            [ text "Is this your business?" ]
        ]
