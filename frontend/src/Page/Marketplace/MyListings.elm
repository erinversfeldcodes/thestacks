module Page.Marketplace.MyListings exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

{-| My listings page.

Shows all of the current user's marketplace listings with status badges
and action buttons. Draft listings can be activated, active listings
can be deactivated or marked as sold.

-}

import Api
import Html exposing (Html, a, button, div, h1, h3, p, span, text)
import Html.Attributes exposing (class, href)
import Html.Events exposing (onClick)
import Http
import Navigation.Route as Route
import Types.Listing exposing (Listing, ListingStatus(..), ListingsResponse, conditionLabel, statusLabel)
import Types.RemoteData exposing (RemoteData(..))


type alias Model =
    { listings : RemoteData Http.Error ListingsResponse
    , actionState : RemoteData Http.Error ()
    }


type Msg
    = ListingsReceived (Result Http.Error ListingsResponse)
    | ActivateListing String
    | DeactivateListing String
    | MarkSold String
    | ListingUpdated String (Result Http.Error Listing)


type OutMsg
    = NoOut
    | SessionExpired


init : Maybe String -> ( Model, Cmd Msg )
init maybeToken =
    case maybeToken of
        Just token ->
            ( { listings = Loading, actionState = NotAsked }
            , Api.getMyListings token ListingsReceived
            )

        Nothing ->
            ( { listings = NotAsked, actionState = NotAsked }
            , Cmd.none
            )


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg, OutMsg )
update msg model maybeToken =
    case msg of
        ListingsReceived result ->
            case result of
                Ok response ->
                    ( { model | listings = Success response }, Cmd.none, NoOut )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | listings = Failure err }, Cmd.none, NoOut )

        ActivateListing listingId ->
            case maybeToken of
                Just token ->
                    ( { model | actionState = Loading }
                    , Api.activateListing listingId token (ListingUpdated listingId)
                    , NoOut
                    )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        DeactivateListing listingId ->
            case maybeToken of
                Just token ->
                    ( { model | actionState = Loading }
                    , Api.deactivateListing listingId token (ListingUpdated listingId)
                    , NoOut
                    )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        MarkSold listingId ->
            case maybeToken of
                Just token ->
                    ( { model | actionState = Loading }
                    , Api.soldListing listingId token (ListingUpdated listingId)
                    , NoOut
                    )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        ListingUpdated listingId result ->
            case result of
                Ok updatedListing ->
                    ( { model
                        | listings = updateListingInResponse listingId updatedListing model.listings
                        , actionState = NotAsked
                      }
                    , Cmd.none
                    , NoOut
                    )

                Err err ->
                    if Api.isUnauthorized err then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( { model | actionState = Failure Http.NetworkError }, Cmd.none, NoOut )



-- VIEW


view : Model -> Html Msg
view model =
    div [ class "page page--marketplace-mine" ]
        [ h1 [ class "page__title" ] [ text "My Listings" ]
        , div [ class "marketplace-mine__actions" ]
            [ a [ href (Route.toPath Route.MarketplaceCreate), class "btn btn--primary" ]
                [ text "Create Listing" ]
            ]
        , viewActionError model
        , viewContent model
        ]


viewActionError : Model -> Html Msg
viewActionError model =
    case model.actionState of
        Failure _ ->
            p [ class "error" ] [ text "Action failed. Please try again." ]

        _ ->
            text ""


viewContent : Model -> Html Msg
viewContent model =
    case model.listings of
        NotAsked ->
            text ""

        Loading ->
            div [ class "loading" ] [ text "Loading your listings..." ]

        Failure _ ->
            p [ class "error" ] [ text "Failed to load your listings. Please try again." ]

        Success response ->
            if List.isEmpty response.listings then
                div [ class "marketplace-mine__empty" ]
                    [ p [] [ text "You haven't created any listings yet." ]
                    , a [ href (Route.toPath Route.MarketplaceCreate), class "btn btn--secondary" ]
                        [ text "Create your first listing" ]
                    ]

            else
                div [ class "marketplace-mine__list" ]
                    (List.map viewListingRow response.listings)


viewListingRow : Listing -> Html Msg
viewListingRow listing =
    let
        bookTitle =
            listing.book
                |> Maybe.map .title
                |> Maybe.withDefault "Untitled"
    in
    div [ class "marketplace-mine__row" ]
        [ div [ class "marketplace-mine__row-info" ]
            [ h3 [ class "marketplace-mine__row-title" ]
                [ a [ href (Route.toPath (Route.MarketplaceDetail listing.id)) ]
                    [ text bookTitle ]
                ]
            , span [ class ("marketplace__status-badge marketplace__status-badge--" ++ statusCssClass listing.status) ]
                [ text (statusLabel listing.status) ]
            , span [ class "marketplace-mine__row-condition" ]
                [ text (conditionLabel listing.condition) ]
            , viewRowPrice listing
            ]
        , div [ class "marketplace-mine__row-actions" ]
            (viewListingActions listing)
        ]


viewRowPrice : Listing -> Html Msg
viewRowPrice listing =
    case listing.priceZar of
        Just price ->
            span [ class "marketplace__price" ]
                [ text ("R " ++ String.fromInt price) ]

        Nothing ->
            span [ class "marketplace__price marketplace__price--offer" ]
                [ text "Offers" ]


viewListingActions : Listing -> List (Html Msg)
viewListingActions listing =
    case listing.status of
        Draft ->
            [ button
                [ class "btn btn--primary btn--sm"
                , onClick (ActivateListing listing.id)
                ]
                [ text "Activate" ]
            ]

        Active ->
            [ button
                [ class "btn btn--secondary btn--sm"
                , onClick (DeactivateListing listing.id)
                ]
                [ text "Deactivate" ]
            , button
                [ class "btn btn--primary btn--sm"
                , onClick (MarkSold listing.id)
                ]
                [ text "Mark Sold" ]
            ]

        Sold ->
            []

        Expired ->
            []

        Removed ->
            []



-- HELPERS


statusCssClass : ListingStatus -> String
statusCssClass status =
    case status of
        Draft ->
            "draft"

        Active ->
            "active"

        Sold ->
            "sold"

        Expired ->
            "expired"

        Removed ->
            "removed"


updateListingInResponse : String -> Listing -> RemoteData Http.Error ListingsResponse -> RemoteData Http.Error ListingsResponse
updateListingInResponse listingId updatedListing remoteResponse =
    case remoteResponse of
        Success response ->
            Success
                { response
                    | listings =
                        List.map
                            (\l ->
                                if l.id == listingId then
                                    updatedListing

                                else
                                    l
                            )
                            response.listings
                }

        other ->
            other
