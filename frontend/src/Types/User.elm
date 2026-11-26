module Types.User exposing (User)


type alias User =
    { id : String
    , email : String
    , displayName : String
    , handle : String
    , role : String
    , countryCode : Maybe String
    , city : Maybe String
    , consentAnalytics : Bool
    , consentWritingAssistant : Bool
    }
