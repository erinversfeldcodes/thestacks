module Page.SessionExpiryPagesTest exposing (suite)

{-| Extends the global session-expiry 401 interceptor to the six remaining
authed pages (three Settings, three Admin). Page-seam contract: an
authenticated 401 bubbles the distinct `SessionExpired` OutMsg instead
of being rendered as a generic error; each page's every authed `Err`
branch is driven to prove no branch swallows it.
-}

import Api
import Expect
import Http
import Page.Admin.ScraperConfig as ScraperConfig
import Page.Admin.SourceApproval as SourceApproval
import Page.Blog.Editor as Editor
import Page.Blog.Post as Post
import Page.Catalogue as Catalogue
import Page.Marketplace.MyListings as MyListings
import Page.Search as Search
import Page.Settings.Consent as Consent
import Page.Settings.Notifications as Notifications
import Page.Settings.Password as Password
import Page.Settings.Privacy as Privacy
import Page.Settings.Profile as Profile
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Types.User exposing (User)


unauthorized : Http.Error
unauthorized =
    Http.BadStatus 401


nonAuth : Http.Error
nonAuth =
    Http.NetworkError


settingsUser : User
settingsUser =
    { id = "user-1"
    , email = "ada@example.com"
    , displayName = "Ada"
    , handle = "ada"
    , role = "user"
    , countryCode = Nothing
    , city = Nothing
    , consentAnalytics = False
    , consentWritingAssistant = False
    }


suite : Test
suite =
    describe "Phase 1 — 401 interceptor on the 6 remaining authed pages"
        [ describe "Settings.Consent"
            [ test "consent_401_bubbles: SaveCompleted 401 → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Consent.update
                                (Consent.SaveCompleted (Err unauthorized))
                                (Consent.init { analytics = False, writingAssistant = False })
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Consent.SessionExpired
            , test "consent_non401_stays_local: SaveCompleted network error → NoOut" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Consent.update
                                (Consent.SaveCompleted (Err nonAuth))
                                (Consent.init { analytics = False, writingAssistant = False })
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Consent.NoOut
            , test "consent_success_stays_local: SaveCompleted Ok → NoOut" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Consent.update
                                (Consent.SaveCompleted (Ok ()))
                                (Consent.init { analytics = False, writingAssistant = False })
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Consent.NoOut
            ]
        , describe "Settings.Privacy"
            [ test "privacy_profile_401_bubbles: SaveProfileVisibilityCompleted 401 → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Privacy.update
                                (Privacy.SaveProfileVisibilityCompleted (Err unauthorized))
                                Privacy.init
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Privacy.SessionExpired
            , test "privacy_shelf_401_bubbles: SaveShelfVisibilityCompleted 401 → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Privacy.update
                                (Privacy.SaveShelfVisibilityCompleted (Err unauthorized))
                                Privacy.init
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Privacy.SessionExpired
            , test "privacy_profile_non401_stays_local: SaveProfileVisibilityCompleted network error → NoOut" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Privacy.update
                                (Privacy.SaveProfileVisibilityCompleted (Err nonAuth))
                                Privacy.init
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Privacy.NoOut
            , test "privacy_shelf_success_stays_local: SaveShelfVisibilityCompleted Ok → NoOut" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Privacy.update
                                (Privacy.SaveShelfVisibilityCompleted (Ok ()))
                                Privacy.init
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Privacy.NoOut
            ]
        , describe "Admin.ScraperConfig"
            [ test "scraper_config_401_bubbles: SourceHealthReceived 401 → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            ScraperConfig.update
                                (ScraperConfig.SourceHealthReceived (Err unauthorized))
                                (Tuple.first (ScraperConfig.init (Just "tok")))
                    in
                    outMsg |> Expect.equal ScraperConfig.SessionExpired
            , test "scraper_config_non401_stays_local: SourceHealthReceived network error → NoOut" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            ScraperConfig.update
                                (ScraperConfig.SourceHealthReceived (Err nonAuth))
                                (Tuple.first (ScraperConfig.init (Just "tok")))
                    in
                    outMsg |> Expect.equal ScraperConfig.NoOut
            ]
        , describe "Admin.SourceApproval"
            [ test "source_approval_list_401_bubbles: SourcesReceived 401 → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            SourceApproval.update
                                (SourceApproval.SourcesReceived (Err unauthorized))
                                (Tuple.first (SourceApproval.init (Just "tok")))
                                (Just "tok")
                    in
                    outMsg |> Expect.equal SourceApproval.SessionExpired
            , test "source_approval_approve_401_bubbles: ApproveCompleted 401 → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            SourceApproval.update
                                (SourceApproval.ApproveCompleted "src-1" (Err unauthorized))
                                (Tuple.first (SourceApproval.init (Just "tok")))
                                (Just "tok")
                    in
                    outMsg |> Expect.equal SourceApproval.SessionExpired
            , test "source_approval_reject_401_bubbles: RejectCompleted 401 → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            SourceApproval.update
                                (SourceApproval.RejectCompleted "src-1" (Err unauthorized))
                                (Tuple.first (SourceApproval.init (Just "tok")))
                                (Just "tok")
                    in
                    outMsg |> Expect.equal SourceApproval.SessionExpired
            , test "source_approval_non401_stays_local: SourcesReceived network error → NoOut" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            SourceApproval.update
                                (SourceApproval.SourcesReceived (Err nonAuth))
                                (Tuple.first (SourceApproval.init (Just "tok")))
                                (Just "tok")
                    in
                    outMsg |> Expect.equal SourceApproval.NoOut
            , test "source_approval_approve_non401_stays_local: ApproveCompleted network error → NoOut" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            SourceApproval.update
                                (SourceApproval.ApproveCompleted "src-1" (Err nonAuth))
                                (Tuple.first (SourceApproval.init (Just "tok")))
                                (Just "tok")
                    in
                    outMsg |> Expect.equal SourceApproval.NoOut
            ]
        , describe "Phase 2 — Blog.Post"
            [ test "blog_post_load_401_bubbles: PostLoaded 401 → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Post.update
                                (Post.PostLoaded (Err unauthorized))
                                (Tuple.first (Post.init "post-1" (Just "tok") (Just "user-1") False "https://thestacks.test"))
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Post.SessionExpired
            , test "blog_post_comments_401_bubbles: CommentsLoaded 401 → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Post.update
                                (Post.CommentsLoaded (Err unauthorized))
                                (Tuple.first (Post.init "post-1" (Just "tok") (Just "user-1") False "https://thestacks.test"))
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Post.SessionExpired
            , test "blog_post_association_401_bubbles: AssociationActionCompleted 401 → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Post.update
                                (Post.AssociationActionCompleted (Err unauthorized))
                                (Tuple.first (Post.init "post-1" (Just "tok") (Just "user-1") False "https://thestacks.test"))
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Post.SessionExpired
            , test "blog_post_comment_submit_401_bubbles: CommentSubmitted 401 → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Post.update
                                (Post.CommentSubmitted (Err unauthorized))
                                (Tuple.first (Post.init "post-1" (Just "tok") (Just "user-1") False "https://thestacks.test"))
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Post.SessionExpired
            , test "blog_post_comment_delete_401_bubbles: CommentDeleted 401 → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Post.update
                                (Post.CommentDeleted (Err unauthorized))
                                (Tuple.first (Post.init "post-1" (Just "tok") (Just "user-1") False "https://thestacks.test"))
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Post.SessionExpired
            , test "blog_post_non401_stays_local: PostLoaded network error → NoOut" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Post.update
                                (Post.PostLoaded (Err nonAuth))
                                (Tuple.first (Post.init "post-1" (Just "tok") (Just "user-1") False "https://thestacks.test"))
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Post.NoOut
            ]
        , describe "Phase 2 — Blog.Editor"
            [ test "blog_editor_save_401_bubbles: SaveCompleted 401 → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Editor.update
                                (Editor.SaveCompleted (Err unauthorized))
                                (Tuple.first (Editor.init Editor.New (Just "tok")))
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Editor.SessionExpired
            , test "blog_editor_publish_401_bubbles: PublishCompleted 401 → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Editor.update
                                (Editor.PublishCompleted (Err unauthorized))
                                (Tuple.first (Editor.init Editor.New (Just "tok")))
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Editor.SessionExpired
            , test "blog_editor_load_401_bubbles: PostLoaded 401 → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Editor.update
                                (Editor.PostLoaded (Err unauthorized))
                                (Tuple.first (Editor.init (Editor.Edit "post-1") (Just "tok")))
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Editor.SessionExpired
            , test "blog_editor_non401_stays_local: SaveCompleted network error → NoOut" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Editor.update
                                (Editor.SaveCompleted (Err nonAuth))
                                (Tuple.first (Editor.init Editor.New (Just "tok")))
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Editor.NoOut
            ]
        , describe "Phase 2 — Marketplace.MyListings"
            [ test "my_listings_list_401_bubbles: ListingsReceived 401 → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            MyListings.update
                                (MyListings.ListingsReceived (Err unauthorized))
                                (Tuple.first (MyListings.init (Just "tok")))
                                (Just "tok")
                    in
                    outMsg |> Expect.equal MyListings.SessionExpired
            , test "my_listings_update_401_bubbles: ListingUpdated 401 → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            MyListings.update
                                (MyListings.ListingUpdated "listing-1" (Err unauthorized))
                                (Tuple.first (MyListings.init (Just "tok")))
                                (Just "tok")
                    in
                    outMsg |> Expect.equal MyListings.SessionExpired
            , test "my_listings_non401_stays_local: ListingsReceived network error → NoOut" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            MyListings.update
                                (MyListings.ListingsReceived (Err nonAuth))
                                (Tuple.first (MyListings.init (Just "tok")))
                                (Just "tok")
                    in
                    outMsg |> Expect.equal MyListings.NoOut
            ]
        , describe "Phase 2 — Catalogue"
            [ test "catalogue_placements_401_bubbles: UserPlacementsLoaded 401 → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Catalogue.update
                                (Catalogue.UserPlacementsLoaded (Err unauthorized))
                                (Tuple.first (Catalogue.init (Just "tok")))
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Catalogue.SessionExpired
            , test "catalogue_place_401_bubbles: PlaceBookCompleted 401 → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Catalogue.update
                                (Catalogue.PlaceBookCompleted "library" "book-1" (Err (Api.PlaceHttpError unauthorized)))
                                (Tuple.first (Catalogue.init (Just "tok")))
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Catalogue.SessionExpired
            , test "catalogue_placements_non401_stays_local: UserPlacementsLoaded network error → NoOut" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Catalogue.update
                                (Catalogue.UserPlacementsLoaded (Err nonAuth))
                                (Tuple.first (Catalogue.init (Just "tok")))
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Catalogue.NoOut
            , test "catalogue_public_list_401_stays_local: CatalogueReceived 401 → NoOut (public branch NOT routed)" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Catalogue.update
                                (Catalogue.CatalogueReceived (Err unauthorized))
                                (Tuple.first (Catalogue.init (Just "tok")))
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Catalogue.NoOut
            ]
        , describe "— Settings.Password (the three write-forms that lied)"
            [ test "password_401_bubbles: the wrapper's expiry signal → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Password.update
                                Password.SessionExpiryDetected
                                Password.init
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Password.SessionExpired
            , test "password_non401_stays_local: SaveCompleted network error → NoOut" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Password.update
                                (Password.SaveCompleted (Err nonAuth))
                                Password.init
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Password.NoOut
            , test "password_success_stays_local: SaveCompleted Ok → NoOut" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Password.update
                                (Password.SaveCompleted (Ok ()))
                                Password.init
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Password.NoOut
            , test "password_expiry_does_not_repaint_the_form_as_failed" <|
                \() ->
                    let
                        ( newModel, _, _ ) =
                            Password.update
                                Password.SessionExpiryDetected
                                Password.init
                                (Just "tok")
                    in
                    Password.view newModel
                        |> Query.fromHtml
                        |> Query.hasNot [ Selector.text "Could not change password. Please try again." ]
            , test "password_a_real_failure_still_says_try_again (positive control)" <|
                \() ->
                    let
                        ( newModel, _, _ ) =
                            Password.update
                                (Password.SaveCompleted (Err nonAuth))
                                Password.init
                                (Just "tok")
                    in
                    Password.view newModel
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "Could not change password. Please try again." ]
            ]
        , describe "— Settings.Profile"
            [ test "profile_save_401_bubbles: the wrapper's expiry signal → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Profile.update
                                Profile.SessionExpiryDetected
                                (Profile.seedFromSession settingsUser)
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Profile.SessionExpired
            , test "profile_hydration_401_bubbles: the account read's 401 → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Profile.update
                                (Profile.AccountReceived (Err unauthorized))
                                (Profile.seedFromSession settingsUser)
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Profile.SessionExpired
            , test "profile_hydration_non401_stays_local: the account read's network error → NoOut" <|
                \() ->
                    let
                        ( newModel, _, outMsg ) =
                            Profile.update
                                (Profile.AccountReceived (Err nonAuth))
                                (Profile.seedFromSession settingsUser)
                                (Just "tok")
                    in
                    Expect.all
                        [ \_ -> outMsg |> Expect.equal Profile.NoOut
                        , \_ ->
                            Profile.view newModel
                                |> Query.fromHtml
                                |> Query.has
                                    [ Selector.text "We could not read your saved profile from the library, so these fields may be out of date. Reload the page to try again." ]
                        ]
                        ()
            , test "profile_validation_failure_stays_local: a 422 → NoOut" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Profile.update
                                (Profile.SaveProfileCompleted
                                    (Err (Api.ProfileValidationFailed [ ( "handle", [ "has already been taken" ] ) ]))
                                )
                                (Profile.seedFromSession settingsUser)
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Profile.NoOut
            , test "profile_location_non401_stays_local: SaveLocationCompleted network error → NoOut" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Profile.update
                                (Profile.SaveLocationCompleted (Err nonAuth))
                                (Profile.seedFromSession settingsUser)
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Profile.NoOut
            , test "profile_expiry_keeps_the_typed_current_password_on_screen" <|
                \() ->
                    let
                        ( typed, _, _ ) =
                            Profile.update
                                (Profile.SetCurrentPassword "hunter2")
                                (Profile.seedFromSession settingsUser)
                                (Just "tok")

                        ( afterExpiry, _, _ ) =
                            Profile.update Profile.SessionExpiryDetected typed (Just "tok")
                    in
                    afterExpiry.currentPassword |> Expect.equal "hunter2"
            ]
        , describe "— Settings.Notifications"
            [ test "notifications_save_401_bubbles: the wrapper's expiry signal → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Notifications.update
                                Notifications.SessionExpiryDetected
                                (Tuple.first (Notifications.init (Just "tok")))
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Notifications.SessionExpired
            , test "notifications_load_non401_stays_local: Loaded network error → NoOut" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Notifications.update
                                (Notifications.Loaded (Err nonAuth))
                                (Tuple.first (Notifications.init (Just "tok")))
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Notifications.NoOut
            , test "notifications_save_non401_stays_local: SaveCompleted network error → NoOut" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Notifications.update
                                (Notifications.SaveCompleted (Err nonAuth))
                                (Tuple.first (Notifications.init (Just "tok")))
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Notifications.NoOut
            ]
        , describe "Phase 2 — Search"
            [ test "search_401_bubbles: SearchCompleted 401 → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Search.update
                                (Search.SearchCompleted (Err unauthorized))
                                Search.init
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Search.SessionExpired
            , test "search_non401_stays_local: SearchCompleted network error → NoOut" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Search.update
                                (Search.SearchCompleted (Err nonAuth))
                                Search.init
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Search.NoOut
            ]
        ]
