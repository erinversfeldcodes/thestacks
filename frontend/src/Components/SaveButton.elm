module Components.SaveButton exposing (Config, Variant(..), primary, primaryWhenReady, view)

{-| The save button every form wrote out by hand: six modules cased a
`RemoteData` save state into a button, five made the same three
decisions, and all six shared the same bug — fixed once here. Disabled

  - "Saving…" in flight, past-tense label on success, action label
    otherwise; the success label decays back after `successDecayMs`.

-}

import Html exposing (Html, button, text)
import Html.Attributes exposing (class, disabled)
import Html.Events exposing (onClick)
import Types.RemoteData exposing (RemoteData(..))


{-| Which visual weight the button carries. `Primary` is the section's main
action; `Secondary` sits beside a primary one (the editor's "Save Draft" next to
"Publish").
-}
type Variant
    = Primary
    | Secondary


{-| `state` is polymorphic in its error type on purpose: `Settings.Profile`
saves through `RemoteData Api.ProfileError` and everything else through
`RemoteData Http.Error`. The button never inspects the error — the page
renders that itself, next to the field it belongs to.
-}
type alias Config e msg =
    { state : RemoteData e ()
    , onSave : msg
    , label : String
    , busyLabel : String
    , savedLabel : String
    , variant : Variant
    }


{-| The ordinary settings-form save button: primary weight, "Saving…" in flight,
"Saved!" afterwards.
-}
primary : RemoteData e () -> msg -> String -> Html msg
primary state onSave label =
    view
        { state = state
        , onSave = onSave
        , label = label
        , busyLabel = "Saving…"
        , savedLabel = "Saved!"
        , variant = Primary
        }


{-| `primary`, held shut until the form is allowed to save.

A form seeded with placeholder values can submit them before it has read what
they are placeholders _for_, and the save then writes the placeholder over the
real record. `ready` is the page's answer to "may this form write yet"; while it
is False the button takes the same disabled shape a save-in-flight does, so
"not yet" reads as one thing rather than two.

The label stays the action label, not the busy one — nothing is happening, and
saying "Saving…" when nothing is would be the wrong kind of quiet.

-}
primaryWhenReady : Bool -> RemoteData e () -> msg -> String -> Html msg
primaryWhenReady ready state onSave label =
    if ready then
        primary state onSave label

    else
        button [ busyClass Primary, disabled True ] [ text label ]


view : Config e msg -> Html msg
view config =
    case config.state of
        Loading ->
            button
                [ busyClass config.variant, disabled True ]
                [ text config.busyLabel ]

        Success _ ->
            button
                [ idleClass config.variant, onClick config.onSave ]
                [ text config.savedLabel ]

        _ ->
            button
                [ idleClass config.variant, onClick config.onSave ]
                [ text config.label ]


{-| ⚠️ Every class here is a whole `class "…"` literal, and the two functions are
spelled out rather than assembled with `++`.
`scripts/check-orphan-classes.sh` finds classes by matching `class "…"` in Elm
source, so composing one from a variant string would hide `btn--secondary` and
`btn--disabled` from the gate at this call site — the blind spot, entered
deliberately rather than by accident.
-}
idleClass : Variant -> Html.Attribute msg
idleClass variant =
    case variant of
        Primary ->
            class "btn btn--primary"

        Secondary ->
            class "btn btn--secondary"


busyClass : Variant -> Html.Attribute msg
busyClass variant =
    case variant of
        Primary ->
            class "btn btn--primary btn--disabled"

        Secondary ->
            class "btn btn--secondary btn--disabled"
