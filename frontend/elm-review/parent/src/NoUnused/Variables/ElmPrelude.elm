module NoUnused.Variables.ElmPrelude exposing (elmPrelude)

import Dict exposing (Dict)


elmPrelude :
    Dict
        (List String)
        { exposes : List String
        , alias : Maybe (List String)
        }
elmPrelude =
    Dict.fromList
        [ ( [ "Basics" ], { exposes = [], alias = Nothing } )
        , ( [ "List" ], { exposes = [ "List", "::" ], alias = Nothing } )
        , ( [ "Maybe" ], { exposes = [ "Maybe" ], alias = Nothing } )
        , ( [ "Result" ], { exposes = [ "Result" ], alias = Nothing } )
        , ( [ "String" ], { exposes = [ "String" ], alias = Nothing } )
        , ( [ "Char" ], { exposes = [ "Char" ], alias = Nothing } )
        , ( [ "Tuple" ], { exposes = [], alias = Nothing } )
        , ( [ "Debug" ], { exposes = [], alias = Nothing } )
        , ( [ "Platform" ], { exposes = [ "Program" ], alias = Nothing } )
        , ( [ "Platform", "Cmd" ], { exposes = [ "Cmd" ], alias = Just [ "Cmd" ] } )
        , ( [ "Platform", "Sub" ], { exposes = [ "Sub" ], alias = Just [ "Sub" ] } )
        ]
