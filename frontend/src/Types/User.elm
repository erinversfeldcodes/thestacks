module Types.User exposing
    ( AuthToken
    , User
    , userDecoder
    )

import Json.Decode as Decode exposing (Decoder)


type alias AuthToken =
    String


type alias User =
    { id : String
    , email : String
    , displayName : String
    , role : String
    }


userDecoder : Decoder User
userDecoder =
    Decode.map4 User
        (Decode.field "id" Decode.string)
        (Decode.field "email" Decode.string)
        (Decode.field "display_name" Decode.string)
        (Decode.field "role" Decode.string)
