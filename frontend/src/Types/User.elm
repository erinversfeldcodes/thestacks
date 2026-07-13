module Types.User exposing
    ( AuthToken
    , User
    )


type alias AuthToken =
    String


type alias User =
    { id : String
    , email : String
    , displayName : String
    , role : String
    , countryCode : Maybe String
    , city : Maybe String
    , consentWritingAssistant : Bool
    }
