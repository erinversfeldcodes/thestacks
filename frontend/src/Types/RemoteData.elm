module Types.RemoteData exposing
    ( RemoteData(..)
    , fromResult
    , map
    , withDefault
    )


type RemoteData e a
    = NotAsked
    | Loading
    | Failure e
    | Success a


map : (a -> b) -> RemoteData e a -> RemoteData e b
map f remoteData =
    case remoteData of
        NotAsked ->
            NotAsked

        Loading ->
            Loading

        Failure e ->
            Failure e

        Success a ->
            Success (f a)


withDefault : a -> RemoteData e a -> a
withDefault default remoteData =
    case remoteData of
        NotAsked ->
            default

        Loading ->
            default

        Failure _ ->
            default

        Success a ->
            a


fromResult : Result e a -> RemoteData e a
fromResult result =
    case result of
        Err e ->
            Failure e

        Ok a ->
            Success a
