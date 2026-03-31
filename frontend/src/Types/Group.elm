module Types.Group exposing (Group, GroupInvitation, groupDecoder, groupInvitationDecoder)

import Json.Decode as Decode exposing (Decoder)


type alias Group =
    { id : String
    , name : String
    , type_ : String
    , visibility : String
    , ownerId : String
    }


type alias GroupInvitation =
    { id : String
    , groupId : String
    , invitedUserId : String
    , invitedById : String
    , status : String
    }


groupDecoder : Decoder Group
groupDecoder =
    Decode.map5 Group
        (Decode.field "id" Decode.string)
        (Decode.field "name" Decode.string)
        (Decode.field "type" Decode.string)
        (Decode.field "visibility" Decode.string)
        (Decode.field "owner_id" Decode.string)


groupInvitationDecoder : Decoder GroupInvitation
groupInvitationDecoder =
    Decode.map5 GroupInvitation
        (Decode.field "id" Decode.string)
        (Decode.field "group_id" Decode.string)
        (Decode.field "invited_user_id" Decode.string)
        (Decode.field "invited_by_id" Decode.string)
        (Decode.field "status" Decode.string)
