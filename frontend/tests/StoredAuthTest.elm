module StoredAuthTest exposing (suite)

{-| A boot has three outcomes and the app must say which: nothing stored,
valid auth, or a blob that would not decode. The old `Maybe Auth`
folded the last two into `Nothing` — but the blob is written by
`saveAuth` and read by the same decoder, so a decode failure means
something rewrote it (half-write, old release, flat-vs-nested drift).
`CorruptAuth` clears the bad blob and says why instead of silently
signing out.
-}

import Expect
import Html.Attributes
import Json.Encode as Encode
import Main
import Page.Login as Login
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector


suite : Test
suite =
    describe "StoredAuth"
        [ describe "the three outcomes of a boot"
            [ noBlobIsACleanSignedOutBoot
            , validBlobSignsThemIn
            , nestedBlobIsCorrupt
            , partialBlobIsCorrupt
            , unreadableStorageIsCorrupt
            ]
        , describe "a corrupt credential never becomes a session"
            [ readerIsSignedOut ]
        , describe "the reader is told"
            [ corruptBlobReachesTheReader
            , corruptReasonSurvivesToThePage
            , cleanBootSaysNothing
            ]
        ]


{-| The exact shape `Main.encodeAuth` writes and `app.js` spreads into flags.
-}
validFlags : Encode.Value
validFlags =
    Encode.object
        [ ( "token", Encode.string "jwt-token" )
        , ( "userId", Encode.string "u1" )
        , ( "email", Encode.string "reader@stacks.dev" )
        , ( "displayName", Encode.string "A Reader" )
        , ( "handle", Encode.string "a_reader" )
        , ( "role", Encode.string "user" )
        , ( "ageGatingEnabled", Encode.bool False )
        ]


{-| The nested-blob mistake, verbatim: valid JSON, plausible content, and not the
shape `authDecoder` reads. This is the one that used to look exactly like being
signed out.
-}
nestedFlags : Encode.Value
nestedFlags =
    Encode.object
        [ ( "token", Encode.string "jwt-token" )
        , ( "user"
          , Encode.object
                [ ( "id", Encode.string "u1" )
                , ( "email", Encode.string "reader@stacks.dev" )
                , ( "displayName", Encode.string "A Reader" )
                ]
          )
        , ( "ageGatingEnabled", Encode.bool False )
        ]


{-| A half-written blob: the credential is there, the identity is not.
-}
partialFlags : Encode.Value
partialFlags =
    Encode.object
        [ ( "token", Encode.string "jwt-token" )
        , ( "ageGatingEnabled", Encode.bool False )
        ]


{-| What `app.js` sends when `localStorage` itself refused — private browsing,
storage disabled by policy — or when the blob would not `JSON.parse`. Elm never
sees the raw string, so this is the only way those two can be told apart from an
ordinary signed-out boot.
-}
unreadableFlags : Encode.Value
unreadableFlags =
    Encode.object
        [ ( "storedAuthUnreadable", Encode.string "SecurityError: localStorage is not available" )
        , ( "ageGatingEnabled", Encode.bool False )
        ]


emptyFlags : Encode.Value
emptyFlags =
    Encode.object [ ( "ageGatingEnabled", Encode.bool False ) ]


isCorrupt : Main.StoredAuth -> Bool
isCorrupt stored =
    case stored of
        Main.CorruptStoredAuth _ ->
            True

        _ ->
            False


noBlobIsACleanSignedOutBoot : Test
noBlobIsACleanSignedOutBoot =
    test "no_blob_is_clean: a reader who never signed in is not accused of a corrupt credential" <|
        \() ->
            Main.decodeFlags emptyFlags |> Expect.equal Main.NoStoredAuth


validBlobSignsThemIn : Test
validBlobSignsThemIn =
    test "valid_blob_signs_them_in: the shape saveAuth writes decodes back into a session" <|
        \() ->
            Main.decodeFlags validFlags
                |> Main.storedSession
                |> Maybe.map .token
                |> Expect.equal (Just "jwt-token")


nestedBlobIsCorrupt : Test
nestedBlobIsCorrupt =
    test "nested_blob_is_corrupt: the nested-under-user blob is named, not mistaken for signed-out" <|
        \() ->
            Expect.all
                [ \stored -> Expect.equal True (isCorrupt stored)
                , \stored -> Expect.notEqual Main.NoStoredAuth stored
                ]
                (Main.decodeFlags nestedFlags)


partialBlobIsCorrupt : Test
partialBlobIsCorrupt =
    test "partial_blob_is_corrupt: a token with no identity behind it is a fault, not an absence" <|
        \() ->
            Main.decodeFlags partialFlags |> isCorrupt |> Expect.equal True


unreadableStorageIsCorrupt : Test
unreadableStorageIsCorrupt =
    test "unreadable_storage_is_corrupt: what JS could not read at all is reported, not swallowed" <|
        \() ->
            Main.decodeFlags unreadableFlags
                |> Expect.equal
                    (Main.CorruptStoredAuth "SecurityError: localStorage is not available")


{-| Paired with `validBlobSignsThemIn` above: without that positive control this
would pass just as well if `storedSession` always answered `Nothing`.
-}
readerIsSignedOut : Test
readerIsSignedOut =
    test "corrupt_is_not_a_session: an unreadable credential authenticates nobody" <|
        \() ->
            [ nestedFlags, partialFlags, unreadableFlags ]
                |> List.map (Main.decodeFlags >> Main.storedSession)
                |> Expect.equalLists [ Nothing, Nothing, Nothing ]


{-| The whole chain a boot walks, minus only the `Nav.Key`: raw flags →
`decodeFlags` → `arrivalForBoot` → `Login.init` → rendered card.
-}
cardForFlags : Encode.Value -> Query.Single Login.Msg
cardForFlags flags =
    Main.decodeFlags flags
        |> Main.arrivalForBoot
        |> Login.init
        |> Login.view
        |> Query.fromHtml


unreadableCopy : String
unreadableCopy =
    "A saved sign-in was found here but could not be read, so you have been signed out. Please sign in again."


corruptBlobReachesTheReader : Test
corruptBlobReachesTheReader =
    test "corrupt_blob_reaches_the_reader: a nested blob at boot produces words on the login card" <|
        \() ->
            cardForFlags nestedFlags
                |> Query.has [ Selector.text unreadableCopy ]


corruptReasonSurvivesToThePage : Test
corruptReasonSurvivesToThePage =
    test "corrupt_reason_survives: the decoder's account of the failure is not discarded" <|
        \() ->
            cardForFlags nestedFlags
                |> Query.has
                    [ Selector.attribute
                        (Html.Attributes.attribute "data-testid" "stored-session-unreadable-notice")
                    ]


{-| The paired negative: an ordinary signed-out boot must NOT accuse the browser
of anything. With `corruptBlobReachesTheReader` above as its control, this
cannot pass by the notice having been deleted.
-}
cleanBootSaysNothing : Test
cleanBootSaysNothing =
    test "clean_boot_says_nothing: a first-time visitor is not told their session broke" <|
        \() ->
            cardForFlags emptyFlags
                |> Query.hasNot [ Selector.text unreadableCopy ]
