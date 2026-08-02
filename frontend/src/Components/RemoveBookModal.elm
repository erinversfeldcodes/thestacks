module Components.RemoveBookModal exposing
    ( cancelButtonId
    , confirmButtonId
    , removeBookModal
    )

import Html exposing (Html, button, div, h2, p, text)
import Html.Attributes exposing (attribute, class, id)
import Html.Events exposing (onClick, preventDefaultOn)
import Json.Decode as Decode
import Util.TestId exposing (testId)


{-| DOM id of the "Keep It" (cancel) button — the safe default focused on open
and the first element in the modal's two-button focus trap.
-}
cancelButtonId : String
cancelButtonId =
    "remove-book-cancel"


{-| DOM id of the "Remove" (confirm) button — the last element in the trap.
-}
confirmButtonId : String
confirmButtonId =
    "remove-book-confirm"


{-| DOM id of the modal heading, referenced by the dialog's `aria-labelledby`.
-}
titleId : String
titleId =
    "remove-book-title"


removeBookModal :
    { bookTitle : String
    , onConfirm : msg
    , onCancel : msg
    , onWrapToFirst : msg
    , onWrapToLast : msg
    }
    -> Html msg
removeBookModal config =
    div [ class "modal-overlay", testId "remove-book-modal" ]
        [ div
            [ class "modal"
            , attribute "role" "dialog"
            , attribute "aria-modal" "true"
            , attribute "aria-labelledby" titleId

            -- Two-element focus trap keeps keyboard focus on the destructive
            -- dialog's two buttons while it is open.
            , preventDefaultOn "keydown" (trapKeydownDecoder config.onWrapToFirst config.onWrapToLast)
            ]
            [ h2 [ class "modal__title", id titleId ] [ text "Remove Book" ]
            , p [ class "modal__message" ]
                -- ⚠️ This said "This cannot be undone." until #375, when it stopped
                -- being true: the shelf the reader lands on offers an Undo for a
                -- few seconds. Copy that overstates the stakes is not harmlessly
                -- cautious — it is the sentence that makes someone abandon a
                -- correction they were entitled to make. The window is named
                -- rather than promised open-endedly, because it closes.
                [ text
                    ("Are you sure you want to remove \""
                        ++ config.bookTitle
                        ++ "\" from your collection? You'll have a few seconds to undo it."
                    )
                ]
            , div [ class "modal__actions" ]
                [ button
                    [ class "btn btn--secondary"
                    , id cancelButtonId
                    , onClick config.onCancel
                    ]
                    [ text "Keep It" ]
                , button
                    [ class "btn btn--danger"
                    , id confirmButtonId
                    , testId "remove-book-confirm"
                    , onClick config.onConfirm
                    ]
                    [ text "Remove" ]
                ]
            ]
        ]


{-| Trap Tab within the modal's two buttons: forward Tab off the last button
(Remove) wraps to the first (Keep It); Shift+Tab off the first wraps to the
last. Every other keydown fails the decoder, preserving native order and
applying no `preventDefault`.
-}
trapKeydownDecoder : msg -> msg -> Decode.Decoder ( msg, Bool )
trapKeydownDecoder onWrapToFirst onWrapToLast =
    Decode.map3 (trapDecision onWrapToFirst onWrapToLast)
        (Decode.field "key" Decode.string)
        (Decode.field "shiftKey" Decode.bool)
        (Decode.at [ "target", "id" ] Decode.string)
        |> Decode.andThen identity


trapDecision : msg -> msg -> String -> Bool -> String -> Decode.Decoder ( msg, Bool )
trapDecision onWrapToFirst onWrapToLast key shiftKey targetId =
    if key /= "Tab" then
        Decode.fail "remove-modal trap: not a Tab keydown"

    else if not shiftKey && targetId == confirmButtonId then
        Decode.succeed ( onWrapToFirst, True )

    else if shiftKey && targetId == cancelButtonId then
        Decode.succeed ( onWrapToLast, True )

    else
        Decode.fail "remove-modal trap: natural tab order"
