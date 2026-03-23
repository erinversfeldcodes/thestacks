module Util.TestId exposing (testId)

import Html
import Html.Attributes


testId : String -> Html.Attribute msg
testId id =
    Html.Attributes.attribute "data-testid" id
