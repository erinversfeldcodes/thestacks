module Page.ListingRemoval exposing
    ( Model
    , Msg(..)
    , init
    , update
    , validate
    , view
    )

{-| "Is this your business?" — the form a business owner uses to have their listing
removed (US-2.5.3, campaign G6).

Deliberately unauthenticated: the story says removal "does not require account creation",
because a shop owner who never asked to be listed should not have to sign up in order to
leave. That is also why the contact address matters — submission alone cannot be evidence
of ownership, so an address on the listing's own domain is applied at once and anything
else waits for a human.

The two outcomes are shown differently, and that is the point of the page rather than a
detail: telling someone their listing has been removed when it is still live would be a
worse failure than telling them it is pending.

-}

import Api exposing (RemovalOutcome(..))
import Html exposing (Html, a, button, div, form, h1, input, label, p, text, textarea)
import Html.Attributes exposing (class, disabled, for, href, id, placeholder, rows, type_, value)
import Html.Events exposing (onInput, onSubmit)
import Http
import Types.RemoteData exposing (RemoteData(..))
import Util.TestId exposing (testId)


type alias Model =
    { url : String
    , email : String
    , reason : String
    , submitting : RemoteData Http.Error RemovalOutcome
    }


type Msg
    = SetUrl String
    | SetEmail String
    | SetReason String
    | Submit
    | Completed (Result Http.Error RemovalOutcome)


init : Model
init =
    { url = ""
    , email = ""
    , reason = ""
    , submitting = NotAsked
    }


{-| A blocking validation error, or Nothing when the form may be submitted.

Kept minimal on purpose. The server is the authority on whether a URL matches a listing
and whether an address verifies, so validating those here would duplicate a rule and
drift from it. This only catches the two things a person can see is wrong before sending.

-}
validate : Model -> Maybe String
validate model =
    if String.trim model.url == "" then
        Just "Enter the web address of the listing you want removed."

    else if not (String.contains "@" model.email) then
        Just "Enter a contact email address so we can verify the request."

    else
        Nothing


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        SetUrl val ->
            ( { model | url = val }, Cmd.none )

        SetEmail val ->
            ( { model | email = val }, Cmd.none )

        SetReason val ->
            ( { model | reason = val }, Cmd.none )

        Submit ->
            case validate model of
                Just _ ->
                    -- `view` already shows the message; re-submitting must not clear it or
                    -- fire a request the server would only reject.
                    ( model, Cmd.none )

                Nothing ->
                    ( { model | submitting = Loading }
                    , Api.requestListingRemoval
                        { url = String.trim model.url
                        , email = String.trim model.email
                        , reason = String.trim model.reason
                        }
                        Completed
                    )

        Completed (Ok outcome) ->
            ( { model | submitting = Success outcome }, Cmd.none )

        Completed (Err err) ->
            ( { model | submitting = Failure err }, Cmd.none )


view : Model -> Html Msg
view model =
    div [ class "listing-removal" ]
        [ h1 [] [ text "Is this your business?" ]
        , case model.submitting of
            Success outcome ->
                viewOutcome outcome

            _ ->
                viewForm model
        ]


{-| What the requester is told, and it differs by outcome on purpose.
-}
viewOutcome : RemovalOutcome -> Html Msg
viewOutcome outcome =
    case outcome of
        Removed ->
            div [ class "listing-removal__done", testId "removal-removed" ]
                [ p [ class "listing-removal__lede" ]
                    [ text "Your listing has been removed." ]
                , p []
                    [ text
                        ("Because you wrote from an address on the same domain as the "
                            ++ "listing, we could act on it straight away. It will not be "
                            ++ "added again."
                        )
                    ]
                ]

        PendingReview ->
            div [ class "listing-removal__pending", testId "removal-pending" ]
                [ p [ class "listing-removal__lede" ]
                    [ text "Your request has been received." ]

                -- ⚠️ Says plainly that the listing is still up. A business owner who
                -- believes it is gone and finds it later has been misled, which is worse
                -- than being told there is a wait.
                , p []
                    [ text
                        ("Your contact address is not on the listing's domain, so we check "
                            ++ "these by hand before removing anything. The listing is "
                            ++ "still visible until then."
                        )
                    ]
                ]


viewForm : Model -> Html Msg
viewForm model =
    let
        problem =
            validate model

        isSubmitting =
            model.submitting == Loading
    in
    form [ class "listing-removal__form", onSubmit Submit ]
        [ p [ class "listing-removal__intro" ]
            [ text
                ("We list bookshops and places to read that we find publicly. If one of "
                    ++ "them is yours and you would rather it were not here, tell us and we "
                    ++ "will take it down — no account needed."
                )
            ]
        , div [ class "listing-removal__field" ]
            [ label [ for "removal-url" ] [ text "The listing's web address" ]
            , input
                [ id "removal-url"
                , type_ "url"
                , class "listing-removal__input"
                , placeholder "https://yourshop.example"
                , value model.url
                , onInput SetUrl
                , testId "removal-url"
                ]
                []
            ]
        , div [ class "listing-removal__field" ]
            [ label [ for "removal-email" ] [ text "Your email address" ]
            , input
                [ id "removal-email"
                , type_ "email"
                , class "listing-removal__input"
                , placeholder "you@yourshop.example"
                , value model.email
                , onInput SetEmail
                , testId "removal-email"
                ]
                []

            -- Explains *why* the address is asked for. Without this the field reads as
            -- data collection rather than the thing that decides how fast this goes.
            , p [ class "listing-removal__hint" ]
                [ text
                    ("An address at the same domain as the listing lets us act "
                        ++ "immediately. Any other address still works, it just waits for "
                        ++ "one of us to check it."
                    )
                ]
            ]
        , div [ class "listing-removal__field" ]
            [ label [ for "removal-reason" ] [ text "Anything you want to add (optional)" ]
            , textarea
                [ id "removal-reason"
                , class "listing-removal__textarea"
                , rows 3
                , value model.reason
                , onInput SetReason
                , testId "removal-reason"
                ]
                []
            ]
        , viewProblem problem model.submitting
        , button
            [ type_ "submit"
            , class "listing-removal__submit"
            , disabled (problem /= Nothing || isSubmitting)
            , testId "removal-submit"
            ]
            [ text
                (if isSubmitting then
                    "Sending…"

                 else
                    "Request removal"
                )
            ]
        , p [ class "listing-removal__alt" ]
            [ text "Would rather be listed properly? "
            , a [ href "/about" ] [ text "Get in touch about becoming a partner." ]
            ]
        ]


{-| Shows a validation problem, or a server error, but never both — a person can only act
on one thing at a time, and the validation problem is the one they can fix.
-}
viewProblem : Maybe String -> RemoteData Http.Error RemovalOutcome -> Html Msg
viewProblem problem submitting =
    case ( problem, submitting ) of
        ( Just message, _ ) ->
            p [ class "listing-removal__error", testId "removal-validation" ] [ text message ]

        ( Nothing, Failure err ) ->
            p [ class "listing-removal__error", testId "removal-error" ]
                [ text (errorMessage err) ]

        _ ->
            text ""


{-| Server errors in the requester's terms, not the protocol's.
-}
errorMessage : Http.Error -> String
errorMessage err =
    case err of
        Http.BadStatus 404 ->
            "We could not find a listing at that address. Check it, or paste the link to the page you saw."

        Http.BadStatus 422 ->
            "That email address does not look valid."

        _ ->
            "Something went wrong sending your request. Please try again."
