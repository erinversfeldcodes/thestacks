module Page.SessionExpiryPagesTest exposing (suite)

{-| Tests for Issue #178 Phase 1 — extend the global session-expiry 401
interceptor to the six remaining authed pages (three Settings pages, three
Admin pages).

Page-seam contract (mirrors `SessionExpiryTest` Scenario 1):

  - An authenticated 401 from any authed-request `Err` branch must bubble the
    distinct `SessionExpired` `OutMsg` to `Main` instead of being swallowed
    locally.
  - A non-401 error (network failure) and a success must stay LOCAL (`NoOut`)
    so the interceptor never over-captures.

Before the conversion these modules return 2-tuples with no `OutMsg` type, so
this suite fails to compile (RED). After the conversion each page returns a
`( Model, Cmd Msg, OutMsg )` and these assertions pass (GREEN).

-}

import Expect
import Http
import Page.Admin.Metrics as Metrics
import Page.Admin.ScraperConfig as ScraperConfig
import Page.Admin.SourceApproval as SourceApproval
import Page.Blog.Editor as Editor
import Page.Blog.Post as Post
import Page.Catalogue as Catalogue
import Page.Marketplace.MyListings as MyListings
import Page.Search as Search
import Page.Settings.AgeVerification as AgeVerification
import Page.Settings.Consent as Consent
import Page.Settings.Privacy as Privacy
import Test exposing (Test, describe, test)


unauthorized : Http.Error
unauthorized =
    Http.BadStatus 401


nonAuth : Http.Error
nonAuth =
    Http.NetworkError


suite : Test
suite =
    describe "Issue #178 Phase 1 — 401 interceptor on the 6 remaining authed pages"
        [ describe "Settings.AgeVerification"
            [ test "age_verification_401_bubbles: SaveCompleted 401 → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            AgeVerification.update
                                (AgeVerification.SaveCompleted (Err unauthorized))
                                AgeVerification.init
                                (Just "tok")
                    in
                    outMsg |> Expect.equal AgeVerification.SessionExpired
            , test "age_verification_non401_stays_local: SaveCompleted network error → NoOut" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            AgeVerification.update
                                (AgeVerification.SaveCompleted (Err nonAuth))
                                AgeVerification.init
                                (Just "tok")
                    in
                    outMsg |> Expect.equal AgeVerification.NoOut
            , test "age_verification_success_stays_local: SaveCompleted Ok → NoOut" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            AgeVerification.update
                                (AgeVerification.SaveCompleted (Ok ()))
                                AgeVerification.init
                                (Just "tok")
                    in
                    outMsg |> Expect.equal AgeVerification.NoOut
            ]
        , describe "Settings.Consent"
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
        , describe "Admin.Metrics"
            [ test "metrics_dashboard_401_bubbles: DashboardReceived 401 → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Metrics.update
                                (Metrics.DashboardReceived (Err unauthorized))
                                (Tuple.first (Metrics.init (Just "tok")))
                    in
                    outMsg |> Expect.equal Metrics.SessionExpired
            , test "metrics_quality_401_bubbles: QualityTrendsReceived 401 → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Metrics.update
                                (Metrics.QualityTrendsReceived (Err unauthorized))
                                (Tuple.first (Metrics.init (Just "tok")))
                    in
                    outMsg |> Expect.equal Metrics.SessionExpired
            , test "metrics_source_health_401_bubbles: SourceHealthReceived 401 → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Metrics.update
                                (Metrics.SourceHealthReceived (Err unauthorized))
                                (Tuple.first (Metrics.init (Just "tok")))
                    in
                    outMsg |> Expect.equal Metrics.SessionExpired
            , test "metrics_enrichment_401_bubbles: EnrichmentGapsReceived 401 → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Metrics.update
                                (Metrics.EnrichmentGapsReceived (Err unauthorized))
                                (Tuple.first (Metrics.init (Just "tok")))
                    in
                    outMsg |> Expect.equal Metrics.SessionExpired
            , test "metrics_non401_stays_local: DashboardReceived network error → NoOut" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Metrics.update
                                (Metrics.DashboardReceived (Err nonAuth))
                                (Tuple.first (Metrics.init (Just "tok")))
                    in
                    outMsg |> Expect.equal Metrics.NoOut
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
                                (Tuple.first (Post.init "post-1" (Just "tok") (Just "user-1") False))
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Post.SessionExpired
            , test "blog_post_comments_401_bubbles: CommentsLoaded 401 → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Post.update
                                (Post.CommentsLoaded (Err unauthorized))
                                (Tuple.first (Post.init "post-1" (Just "tok") (Just "user-1") False))
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Post.SessionExpired
            , test "blog_post_association_401_bubbles: AssociationActionCompleted 401 → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Post.update
                                (Post.AssociationActionCompleted (Err unauthorized))
                                (Tuple.first (Post.init "post-1" (Just "tok") (Just "user-1") False))
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Post.SessionExpired
            , test "blog_post_comment_submit_401_bubbles: CommentSubmitted 401 → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Post.update
                                (Post.CommentSubmitted (Err unauthorized))
                                (Tuple.first (Post.init "post-1" (Just "tok") (Just "user-1") False))
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Post.SessionExpired
            , test "blog_post_comment_delete_401_bubbles: CommentDeleted 401 → SessionExpired" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Post.update
                                (Post.CommentDeleted (Err unauthorized))
                                (Tuple.first (Post.init "post-1" (Just "tok") (Just "user-1") False))
                                (Just "tok")
                    in
                    outMsg |> Expect.equal Post.SessionExpired
            , test "blog_post_non401_stays_local: PostLoaded network error → NoOut" <|
                \() ->
                    let
                        ( _, _, outMsg ) =
                            Post.update
                                (Post.PostLoaded (Err nonAuth))
                                (Tuple.first (Post.init "post-1" (Just "tok") (Just "user-1") False))
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
                                (Catalogue.PlaceBookCompleted "library" "book-1" (Err unauthorized))
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
