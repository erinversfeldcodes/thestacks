module Page.Marketplace.CreateListing exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

{-| Create listing page.

Allows the user to create a new marketplace listing by selecting one
of their placements, choosing condition, pricing mode, price, contact
info, and a description. On success shows the draft listing with an
Activate button.

-}

import Api
import Html exposing (Html, button, div, h1, h2, input, label, option, p, select, span, text, textarea)
import Html.Attributes exposing (attribute, class, disabled, for, id, name, placeholder, selected, type_, value)
import Html.Events exposing (onClick, onInput)
import Http
import Navigation.Route as Route
import Types.Listing exposing (Condition(..), Listing, PricingMode(..), conditionLabel, conditionToString, statusLabel)
import Types.Placement exposing (Placement)
import Types.RemoteData exposing (RemoteData(..))


type alias Model =
    { placements : RemoteData Http.Error (List Placement)
    , selectedPlacementId : Maybe String
    , condition : Condition
    , pricingMode : PricingMode
    , priceInput : String
    , contactInfo : String
    , description : String
    , submitState : RemoteData Http.Error Listing
    , createdListing : Maybe Listing
    }


type Msg
    = PlacementsReceived (Result Http.Error (List Placement))
    | PlacementSelected String
    | ConditionSelected String
    | PricingModeSelected String
    | PriceChanged String
    | ContactInfoChanged String
    | DescriptionChanged String
    | SubmitListing
    | ListingCreated (Result Http.Error Listing)
    | ActivateListing String
    | ListingActivated (Result Http.Error Listing)


type OutMsg
    = NoOut
    | NavigateTo Route.Route


init : Maybe String -> ( Model, Cmd Msg )
init maybeToken =
    let
        ( placementsState, cmd ) =
            case maybeToken of
                Just token ->
                    ( Loading, Api.getMyPlacements token PlacementsReceived )

                Nothing ->
                    ( NotAsked, Cmd.none )
    in
    ( { placements = placementsState
      , selectedPlacementId = Nothing
      , condition = Good
      , pricingMode = Fixed
      , priceInput = ""
      , contactInfo = ""
      , description = ""
      , submitState = NotAsked
      , createdListing = Nothing
      }
    , cmd
    )


update : Msg -> Model -> Maybe String -> ( Model, Cmd Msg, OutMsg )
update msg model maybeToken =
    case msg of
        PlacementsReceived result ->
            case result of
                Ok placements ->
                    ( { model | placements = Success placements }, Cmd.none, NoOut )

                Err err ->
                    ( { model | placements = Failure err }, Cmd.none, NoOut )

        PlacementSelected placementId ->
            ( { model
                | selectedPlacementId =
                    if String.isEmpty placementId then
                        Nothing

                    else
                        Just placementId
              }
            , Cmd.none
            , NoOut
            )

        ConditionSelected condStr ->
            ( { model | condition = parseCondition condStr }, Cmd.none, NoOut )

        PricingModeSelected modeStr ->
            ( { model | pricingMode = parsePricingMode modeStr }, Cmd.none, NoOut )

        PriceChanged priceStr ->
            ( { model | priceInput = priceStr }, Cmd.none, NoOut )

        ContactInfoChanged info ->
            ( { model | contactInfo = info }, Cmd.none, NoOut )

        DescriptionChanged desc ->
            ( { model | description = desc }, Cmd.none, NoOut )

        SubmitListing ->
            case ( maybeToken, model.selectedPlacementId ) of
                ( Just token, Just placementId ) ->
                    let
                        params =
                            { placementId = placementId
                            , condition = conditionToString model.condition
                            , pricingMode = pricingModeToString model.pricingMode
                            , priceZar = String.toInt model.priceInput
                            , contactInfo = model.contactInfo
                            , description = model.description
                            }
                    in
                    ( { model | submitState = Loading }
                    , Api.createListing params token ListingCreated
                    , NoOut
                    )

                _ ->
                    ( model, Cmd.none, NoOut )

        ListingCreated result ->
            case result of
                Ok listing ->
                    ( { model | submitState = Success listing, createdListing = Just listing }
                    , Cmd.none
                    , NoOut
                    )

                Err err ->
                    ( { model | submitState = Failure err }, Cmd.none, NoOut )

        ActivateListing listingId ->
            case maybeToken of
                Just token ->
                    ( { model | submitState = Loading }
                    , Api.activateListing listingId token ListingActivated
                    , NoOut
                    )

                Nothing ->
                    ( model, Cmd.none, NoOut )

        ListingActivated result ->
            case result of
                Ok listing ->
                    ( { model | createdListing = Just listing, submitState = Success listing }
                    , Cmd.none
                    , NavigateTo Route.MarketplaceMyListings
                    )

                Err err ->
                    ( { model | submitState = Failure err }, Cmd.none, NoOut )



-- VIEW


view : Model -> Html Msg
view model =
    div [ class "page page--marketplace-create" ]
        [ h1 [ class "page__title" ] [ text "Create Listing" ]
        , case model.createdListing of
            Just listing ->
                viewCreatedListing listing

            Nothing ->
                viewForm model
        ]


viewCreatedListing : Listing -> Html Msg
viewCreatedListing listing =
    div [ class "marketplace-create__success" ]
        [ h2 [ class "marketplace-create__success-title" ] [ text "Listing Created" ]
        , p [ class "marketplace-create__success-info" ]
            [ text "Your listing has been created as a draft." ]
        , div [ class "marketplace-create__success-details" ]
            [ p []
                [ text "Status: "
                , span [ class ("marketplace__status-badge marketplace__status-badge--" ++ statusCssClass listing.status) ]
                    [ text (statusLabel listing.status) ]
                ]
            , p []
                [ text "Condition: "
                , text (conditionLabel listing.condition)
                ]
            , viewListingPrice listing
            ]
        , case listing.status of
            Types.Listing.Draft ->
                button
                    [ class "btn btn--primary"
                    , onClick (ActivateListing listing.id)
                    ]
                    [ text "Activate" ]

            _ ->
                text ""
        ]


viewForm : Model -> Html Msg
viewForm model =
    div [ class "marketplace-create__form" ]
        [ viewPlacementSelector model
        , viewConditionSelector model
        , viewPricingSelector model
        , viewContactInput model
        , viewDescriptionInput model
        , viewSubmitButton model
        , viewFormError model
        ]


viewPlacementSelector : Model -> Html Msg
viewPlacementSelector model =
    div [ class "form-group" ]
        [ label [ for "placement-select", class "form-label" ] [ text "Book to list" ]
        , case model.placements of
            Loading ->
                p [ class "loading" ] [ text "Loading your books..." ]

            Failure _ ->
                p [ class "error" ] [ text "Failed to load your books." ]

            Success placements ->
                if List.isEmpty placements then
                    p [ class "marketplace-create__no-books" ]
                        [ text "You have no books to list. Add books to your collection first." ]

                else
                    select
                        [ id "placement-select"
                        , class "form-input"
                        , onInput PlacementSelected
                        ]
                        (option [ value "", selected (model.selectedPlacementId == Nothing) ] [ text "Select a book..." ]
                            :: List.map viewPlacementOption placements
                        )

            NotAsked ->
                text ""
        ]


viewPlacementOption : Placement -> Html Msg
viewPlacementOption placement =
    let
        bookTitle =
            placement.book
                |> Maybe.map .title
                |> Maybe.withDefault "Untitled"

        shelfName =
            placement.bookshelfName
                |> Maybe.withDefault ""
    in
    option [ value placement.id ]
        [ text (bookTitle ++ " (" ++ shelfName ++ ")") ]


viewConditionSelector : Model -> Html Msg
viewConditionSelector model =
    div [ class "form-group" ]
        [ label [ class "form-label" ] [ text "Condition" ]
        , div [ class "marketplace-create__radio-group" ]
            (List.map
                (\cond ->
                    label [ class "marketplace-create__radio-label" ]
                        [ input
                            [ type_ "radio"
                            , name "condition"
                            , value (conditionToString cond)
                            , Html.Attributes.checked (model.condition == cond)
                            , onInput ConditionSelected
                            ]
                            []
                        , text (" " ++ conditionLabel cond)
                        ]
                )
                [ New, LikeNew, Good, Fair, Poor ]
            )
        ]


viewPricingSelector : Model -> Html Msg
viewPricingSelector model =
    div [ class "form-group" ]
        [ label [ class "form-label" ] [ text "Pricing" ]
        , div [ class "marketplace-create__radio-group" ]
            [ label [ class "marketplace-create__radio-label" ]
                [ input
                    [ type_ "radio"
                    , name "pricing_mode"
                    , value "fixed"
                    , Html.Attributes.checked (model.pricingMode == Fixed)
                    , onInput PricingModeSelected
                    ]
                    []
                , text " Fixed price"
                ]
            , label [ class "marketplace-create__radio-label" ]
                [ input
                    [ type_ "radio"
                    , name "pricing_mode"
                    , value "offer"
                    , Html.Attributes.checked (model.pricingMode == Offer)
                    , onInput PricingModeSelected
                    ]
                    []
                , text " Open to offers"
                ]
            ]
        , if model.pricingMode == Fixed then
            div [ class "form-group" ]
                [ label [ for "price-input", class "form-label" ] [ text "Price (ZAR)" ]
                , input
                    [ id "price-input"
                    , type_ "number"
                    , class "form-input"
                    , placeholder "e.g. 150"
                    , value model.priceInput
                    , onInput PriceChanged
                    , Html.Attributes.min "0"
                    ]
                    []
                ]

          else
            text ""
        ]


viewContactInput : Model -> Html Msg
viewContactInput model =
    div [ class "form-group" ]
        [ label [ for "contact-input", class "form-label" ] [ text "Contact info (email, phone, or WhatsApp)" ]
        , input
            [ id "contact-input"
            , type_ "text"
            , class "form-input"
            , placeholder "e.g. hello@example.com or +27..."
            , value model.contactInfo
            , onInput ContactInfoChanged
            ]
            []
        ]


viewDescriptionInput : Model -> Html Msg
viewDescriptionInput model =
    div [ class "form-group" ]
        [ label [ for "description-input", class "form-label" ] [ text "Description (optional)" ]
        , textarea
            [ id "description-input"
            , class "form-input form-input--textarea"
            , placeholder "Any additional details about the book or sale..."
            , value model.description
            , onInput DescriptionChanged
            ]
            []
        ]


viewSubmitButton : Model -> Html Msg
viewSubmitButton model =
    let
        isValid =
            model.selectedPlacementId /= Nothing && not (String.isEmpty model.contactInfo)

        isSubmitting =
            model.submitState == Loading
    in
    button
        [ class "btn btn--primary"
        , disabled (not isValid || isSubmitting)
        , onClick SubmitListing
        ]
        [ if isSubmitting then
            text "Creating..."

          else
            text "Create Listing"
        ]


viewFormError : Model -> Html Msg
viewFormError model =
    case model.submitState of
        Failure _ ->
            p [ class "error" ] [ text "Failed to create listing. Please try again." ]

        _ ->
            text ""


viewListingPrice : Listing -> Html Msg
viewListingPrice listing =
    case listing.priceZar of
        Just price ->
            p [] [ text ("Price: R " ++ String.fromInt price) ]

        Nothing ->
            p [] [ text "Price: Open to offers" ]



-- HELPERS


parseCondition : String -> Condition
parseCondition str =
    case str of
        "new" ->
            New

        "like_new" ->
            LikeNew

        "good" ->
            Good

        "fair" ->
            Fair

        "poor" ->
            Poor

        _ ->
            Good


parsePricingMode : String -> PricingMode
parsePricingMode str =
    case str of
        "fixed" ->
            Fixed

        "offer" ->
            Offer

        _ ->
            Fixed


pricingModeToString : PricingMode -> String
pricingModeToString mode =
    case mode of
        Fixed ->
            "fixed"

        Offer ->
            "offer"


statusCssClass : Types.Listing.ListingStatus -> String
statusCssClass status =
    case status of
        Types.Listing.Draft ->
            "draft"

        Types.Listing.Active ->
            "active"

        Types.Listing.Sold ->
            "sold"

        Types.Listing.Expired ->
            "expired"

        Types.Listing.Removed ->
            "removed"
