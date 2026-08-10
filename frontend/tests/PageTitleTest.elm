module PageTitleTest exposing (suite)

{-| Issue #360 — the document title is derived from the page, not from the route.


## The defect

`view` called `pageTitle model.route`. A route is what the reader ASKED for; a
`Page` is what the shell BUILT. They differ by design at six sites — every one
of them a place where the shell deliberately shows something other than the
route's page — so the tab, the browser history entry and the screen reader's
navigation announcement all named a page the reader was not looking at.

Six drift sites, one per test below:

1.  the protected-route bounce (the URL is deliberately left alone),
2.  the `/admin/*` MFA gate,
3.  an owner-guard refusal (`PageNotFound`),
4.  the ADR-020 age-gating refusal (`PageNotFound`),
5.  sign-out, which swaps the page before the URL,
6.  `handleAdminSessionExpiry`, which re-gates **without touching the URL at
    all** — so its title stayed wrong for as long as the operator stayed.


## Why these assertions are not vacuous

Each drift test asserts BOTH what the title now says AND that it no longer says
the thing that was wrong — a negative assertion always paired with its positive
control, because `expectViewHasNot`-shaped checks pass just as happily when the
subject does not exist at all.


## Mutation probe

Changing `PageAdminGate`'s branch to name the gated route — the pre-#360
behaviour — reddens `drift_2_admin_gate` and `drift_6_admin_reauth`.

-}

import Expect
import Http
import Main exposing (Page(..))
import Navigation.Route as Route exposing (ConfirmStatus(..), Route(..))
import Page.Admin.Session as AdminSession
import Page.Blog.Editor as BlogEditor
import Page.BookDetail as BookDetail
import Page.Bookshelf as Bookshelf
import Page.Home as Home
import Page.Login as Login
import Page.Profile as ProfilePage
import Test exposing (Test, describe, test)
import Types.Book exposing (Book, VisibilityTier(..))
import Types.RemoteData
import Types.User exposing (User)


suite : Test
suite =
    describe "Page title (Issue #360)"
        [ describe "the six sites where the route named a page nobody was looking at"
            [ driftBounce
            , driftAdminGate
            , driftOwnerRefusal
            , driftAgeGatingRefusal
            , driftSignOut
            , driftAdminReauth
            ]
        , describe "what a route could not know"
            [ bookshelfNamesItsShelf
            , profileShelfNamesWhoseShelf
            , bookDetailNamesTheBook
            , bookDetailBeforeItLoads
            , blogEditorDistinguishesNewFromEdit
            , publicProfileNamesTheReader
            ]
        , describe "shape"
            [ everyTitleCarriesTheProductName
            , homeIsJustTheProductName
            ]
        ]



-- FIXTURES


ownerUser : User
ownerUser =
    { id = "u1"
    , email = "owner@stacks.dev"
    , displayName = "The Owner"
    , handle = "the_owner"
    , role = "owner"
    , countryCode = Nothing
    , city = Nothing
    , consentAnalytics = False
    , consentWritingAssistant = False
    }


readerUser : User
readerUser =
    { ownerUser | id = "u2", displayName = "A Reader", handle = "a_reader", role = "user" }


ownerAuth : Main.Auth
ownerAuth =
    { user = ownerUser, token = "tok" }


readerAuth : Main.Auth
readerAuth =
    { user = readerUser, token = "tok" }


ageGatingOff : Main.AppConfig
ageGatingOff =
    { ageGatingEnabled = False, inviteOnly = False }


ageGatingOn : Main.AppConfig
ageGatingOn =
    { ageGatingEnabled = True, inviteOnly = False }


{-| Build a page exactly the way the shell does, so a test cannot assert about a
page arrangement production never produces.
-}
pageFor : Main.AppConfig -> Route -> Maybe Main.Auth -> Maybe String -> Page
pageFor config route maybeAuth adminToken =
    Main.initPage config route "https://thestacks.test" maybeAuth adminToken Nothing Login.Fresh
        |> Tuple.first



-- 1..6 — THE DRIFT SITES


driftBounce : Test
driftBounce =
    test "drift_1_bounce: a signed-out reader deep-linking to /upload is titled for the card they can see" <|
        \() ->
            let
                title =
                    pageTitleOf (pageFor ageGatingOff Upload Nothing Nothing)
            in
            Expect.all
                [ \t -> Expect.equal "Sign In — The Stacks" t
                , \t -> Expect.notEqual "Add a Book — The Stacks" t
                ]
                title


driftAdminGate : Test
driftAdminGate =
    test "drift_2_admin_gate: the MFA challenge is not titled with the surface behind it" <|
        \() ->
            let
                title =
                    pageTitleOf (pageFor ageGatingOff Route.AdminSourceApproval (Just ownerAuth) Nothing)
            in
            Expect.all
                [ \t -> Expect.equal "Admin Sign-In — The Stacks" t
                , \t -> Expect.notEqual "Source Approval — The Stacks" t
                ]
                title


driftOwnerRefusal : Test
driftOwnerRefusal =
    test "drift_3_owner_refusal: a refused admin route is titled Not Found, not with what it refused" <|
        \() ->
            let
                title =
                    pageTitleOf (pageFor ageGatingOff Route.AdminRemovalRequests (Just readerAuth) (Just "admin-tok"))
            in
            Expect.all
                [ \t -> Expect.equal "Not Found — The Stacks" t
                , \t -> Expect.notEqual "Removal Requests — The Stacks" t
                ]
                title


{-| The positive control for the test above: with an owner and an admin token
the very same route DOES render its surface and DOES get its title. Without
this, `drift_3` would pass just as well if every admin route were broken.
-}
driftAgeGatingRefusal : Test
driftAgeGatingRefusal =
    test "drift_4_age_gating: Book Moderation is Not Found while the flag is dark, and itself when lit" <|
        \() ->
            Expect.all
                [ \() ->
                    pageTitleOf (pageFor ageGatingOff Route.AdminBookModeration (Just ownerAuth) (Just "admin-tok"))
                        |> Expect.equal "Not Found — The Stacks"
                , \() ->
                    pageTitleOf (pageFor ageGatingOn Route.AdminBookModeration (Just ownerAuth) (Just "admin-tok"))
                        |> Expect.equal "Book Moderation — The Stacks"
                ]
                ()


{-| Sign-out replaces the page immediately and pushes `/login` afterwards, so
for one render the card wore the title of the page signed out from. The title
can no longer reach a route to be wrong about — and, newly, it follows the card
as the reader switches tabs, which a route-derived title structurally could not
do because the URL does not change when the mode does.
-}
driftSignOut : Test
driftSignOut =
    test "drift_5_sign_out: the login card is titled by its own mode, and retitles when the mode changes" <|
        \() ->
            let
                signedOutCard =
                    Login.init Login.Fresh

                ( registering, _, _ ) =
                    Login.update (Login.ModeSwitched Login.RegisterMode) signedOutCard
            in
            Expect.all
                [ \() ->
                    pageTitleOf (PageLogin signedOutCard)
                        |> Expect.equal "Sign In — The Stacks"
                , \() ->
                    pageTitleOf (PageLogin registering)
                        |> Expect.equal "Create Account — The Stacks"
                ]
                ()


{-| `handleAdminSessionExpiry` puts the gate back on whatever route the operator
was on and never touches the URL, so a route-derived title could not recover.
Asserting the title is the SAME for two different gated routes proves the
carried route cannot leak into it — which is exactly the claim that was false.
-}
driftAdminReauth : Test
driftAdminReauth =
    test "drift_6_admin_reauth: re-gating mid-session cannot inherit the gated route's title" <|
        \() ->
            let
                onSources =
                    pageTitleOf (PageAdminGate Route.AdminSourceApproval AdminSession.init)

                onScrapers =
                    pageTitleOf (PageAdminGate Route.AdminScraperConfig AdminSession.init)
            in
            Expect.all
                [ \() -> Expect.equal onSources onScrapers
                , \() -> Expect.equal "Admin Sign-In — The Stacks" onSources
                , \() -> Expect.notEqual "Scraper Health — The Stacks" onScrapers
                ]
                ()



-- WHAT A ROUTE COULD NOT KNOW


bookshelfPage : Bookshelf.Config -> Page
bookshelfPage config =
    Bookshelf.init config (Just "tok") "u1"
        |> Tuple.first
        |> PageBookshelf


bookshelfNamesItsShelf : Test
bookshelfNamesItsShelf =
    test "bookshelf_names_its_shelf: three shelves share one Page constructor and still get three titles" <|
        \() ->
            Expect.equalLists
                [ pageTitleOf (bookshelfPage Bookshelf.libraryConfig)
                , pageTitleOf (bookshelfPage Bookshelf.antiLibraryConfig)
                , pageTitleOf (bookshelfPage Bookshelf.wishListConfig)
                ]
                [ "Library — The Stacks"
                , "Antilibrary — The Stacks"
                , "Wish List — The Stacks"
                ]


bookshelfProfileNamesWhose : String
bookshelfProfileNamesWhose =
    "Antilibrary — @ada — The Stacks"


profileShelfNamesWhoseShelf : Test
profileShelfNamesWhoseShelf =
    test "profile_shelf_names_whose: browsing another reader's shelf says which shelf and whose" <|
        \() ->
            let
                title =
                    pageTitleOf (bookshelfPage (Bookshelf.profileConfig "ada" "antilibrary"))
            in
            Expect.all
                [ \t -> Expect.equal bookshelfProfileNamesWhose t

                -- The route could only ever answer "Reader", for every shelf of
                -- every reader.
                , \t -> Expect.notEqual "Reader — The Stacks" t
                ]
                title


aBook : Book
aBook =
    { id = "b1"
    , title = "The Uncommon Reader"
    , author = Nothing
    , description = Nothing
    , editions = []
    , primaryEdition = Nothing
    , editionCount = 0
    , subjects = []
    , visibilityTier = Public
    }


bookDetailModel : Types.RemoteData.RemoteData Http.Error Book -> BookDetail.Model
bookDetailModel bookState =
    let
        base =
            BookDetail.init "b1" (Just "tok") Nothing |> Tuple.first
    in
    { base | book = bookState }


bookDetailNamesTheBook : Test
bookDetailNamesTheBook =
    test "book_detail_names_the_book: a loaded book detail is titled with that book" <|
        \() ->
            let
                title =
                    pageTitleOf (PageBookDetail (bookDetailModel (Types.RemoteData.Success aBook)))
            in
            Expect.all
                [ \t -> Expect.equal "The Uncommon Reader — The Stacks" t
                , \t -> Expect.notEqual "Book — The Stacks" t
                ]
                title


bookDetailBeforeItLoads : Test
bookDetailBeforeItLoads =
    test "book_detail_before_load: an unloaded book detail falls back to a neutral title" <|
        \() ->
            pageTitleOf (PageBookDetail (bookDetailModel Types.RemoteData.Loading))
                |> Expect.equal "Book — The Stacks"


blogEditorDistinguishesNewFromEdit : Test
blogEditorDistinguishesNewFromEdit =
    test "blog_editor_new_vs_edit: two routes share one editor page and still get two titles" <|
        \() ->
            let
                editorFor mode =
                    BlogEditor.init mode (Just "tok")
                        |> Tuple.first
                        |> PageBlogEditor
                        |> pageTitleOf
            in
            Expect.equalLists
                [ editorFor BlogEditor.New, editorFor (BlogEditor.Edit "p1") ]
                [ "New Post — The Stacks", "Edit Post — The Stacks" ]


publicProfileNamesTheReader : Test
publicProfileNamesTheReader =
    test "public_profile_names_the_reader: a profile is titled with the handle it is showing" <|
        \() ->
            let
                title =
                    ProfilePage.init (Just "tok") "ada"
                        |> Tuple.first
                        |> PageProfile
                        |> pageTitleOf
            in
            Expect.all
                [ \t -> Expect.equal "@ada — The Stacks" t
                , \t -> Expect.notEqual "Reader — The Stacks" t
                ]
                title



-- SHAPE


{-| A representative page from every family. The suffix is written once, in
`titled`; this is what stops a hand-written branch from dropping it.
-}
representativePages : List Page
representativePages =
    [ PageLogin (Login.init Login.Fresh)
    , bookshelfPage Bookshelf.libraryConfig
    , PageBookDetail (bookDetailModel Types.RemoteData.Loading)
    , PageAbout
    , PageAdminGate Route.AdminSourceApproval AdminSession.init
    , PageConfirmEmail EmailConfirmed
    , PageConfirmEmail EmailConfirmFailed
    , PageNotFound
    ]


everyTitleCarriesTheProductName : Test
everyTitleCarriesTheProductName =
    test "title_suffix: every page but Home ends with the product name" <|
        \() ->
            representativePages
                |> List.map pageTitleOf
                |> List.filter (\t -> not (String.endsWith " — The Stacks" t))
                |> Expect.equalLists []


homeIsJustTheProductName : Test
homeIsJustTheProductName =
    test "home_title: the home page is the product, not a page within it" <|
        \() ->
            pageTitleOf (PageHome Home.Landing) |> Expect.equal "The Stacks"



-- HELPERS


pageTitleOf : Page -> String
pageTitleOf =
    Main.pageTitle
