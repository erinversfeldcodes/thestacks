module Components.SaveButton exposing (Config, Variant(..), primary, view)

{-| The save button every form in the app was writing out by hand.


## Why this is one component

Six modules each cased a `RemoteData` save state into a button, and five of them
made the same three decisions: disabled and "Saving…" while in flight, a
past-tense label on success, the action label otherwise. Promoting the shape is
the small half of the win. The large half is that all six copies carried the same
bug, and a bug in six places is fixed once here.


## The bug they all carried

    Success _ ->
        button [ class "btn btn--primary" ] [ text "Saved!" ]

No `onClick`. No `disabled`. So after a successful save the button is a
full-contrast, focusable, keyboard-activatable primary button that **does
nothing** — it looks exactly like the button that saves, and clicking it is a
silent no-op. Whether that matters depended entirely on whether the page's edit
messages happened to reset the state back to `NotAsked`. `Settings.Profile` and
`Settings.Privacy` do. `Settings.Consent` does not, and the consequence was that
a reader could not change their analytics-consent choice a second time without
reloading the page: they flipped the toggle, the button still said "Saved!", and
their new choice was never sent.

So the `Success` branch here keeps its `onClick`. A save button is never a dead
end — pressing it always means "save what is on screen now", whatever it last
said. The page-level fix (an edit returns the state to `NotAsked`, so the label
stops claiming the current values are saved) belongs to the page and is done
there; this makes the _component_ incapable of rendering an inert live-looking
control regardless.


## Why `Config` and not four positional arguments

Five of the six call sites want the defaults (`primary` below covers them in one
line). The two blog-editor buttons want their own verbs — "Save Draft" →
"Draft saved!", "Publish" → "Published!" — and those cannot be derived from the
action label. Naming the three labels beats a `Maybe String` triple.

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
saves through `RemoteData Api.ProfileError ()` and everything else through
`RemoteData Http.Error ()`. The button never inspects the error — the page
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


view : Config e msg -> Html msg
view config =
    case config.state of
        Loading ->
            -- Genuinely disabled, not merely dressed as it. `Settings.Consent`
            -- wrote the `btn--disabled` class without the attribute, so its
            -- in-flight button was still focusable and still announced as
            -- enabled; it only failed to do anything because it had no handler.
            button
                [ busyClass config.variant, disabled True ]
                [ text config.busyLabel ]

        Success _ ->
            -- Still clickable. See the module doc: this branch used to be inert.
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
`btn--disabled` from the gate at this call site — the #356 blind spot, entered
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
