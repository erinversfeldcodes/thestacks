defmodule StacksWeb.ProtoJSON do
  @moduledoc """
  Shared proto-shaped JSON serializers for all controllers.

  "Proto" here means that every function produces the exact map shape
  defined by the corresponding `.proto` message in `proto/stacks/common/v1/`.
  The maps are not Protobuf-encoded — they are plain Elixir maps that
  Phoenix's `json/2` encodes to JSON matching the proto field names.

  Each function converts an Ecto struct (or plain map) into the map shape
  that Phoenix's `json/2` will encode.

  ## Design

  Controllers currently duplicate `format_book`, `format_edition`, etc.
  This module provides a single source of truth so that #131e can replace
  every inline `format_*` helper with a delegation to `ProtoJSON`.

  Enum values are lowercase strings (`"public"`, `"age_gated"`) matching
  current API output and Elm decoder expectations — NOT proto-convention
  `SCREAMING_SNAKE_CASE`.
  """

  require Logger

  alias Stacks.Books
  alias Stacks.Feeds
  alias StacksWeb.ProtoJSON.Gen

  @user_core_fields [
    :id,
    :email,
    :display_name,
    :role,
    :profile_visibility,
    :age_verified,
    :consent_analytics
  ]
  @user_auth_fields @user_core_fields ++ [:handle, :country_code, :city, :onboarding_completed]
  @user_embed_fields @user_core_fields ++ [:created_at, :updated_at]

  @doc """
  Serializes a book (work) struct into the proto `Book` message shape.

  Matches `BookController.format_book/2` — the richest book representation,
  including all fields (description, language, subjects, bisac_codes,
  community_read_count).

  ## Options

    * `:community_read_count` — integer, defaults to `0`.
  """
  @spec book(map(), keyword()) :: map()
  def book(book, opts \\ []) do
    community_read_count = Keyword.get(opts, :community_read_count, 0)
    editions = editions_list(book)
    primary = Books.primary_edition(book)

    Gen.book(book)
    |> Map.take([
      :id,
      :title,
      :description,
      :language,
      :subjects,
      :bisac_codes,
      :visibility_tier
    ])
    |> Map.merge(%{
      author: author(book.author),
      editions: editions,
      edition_count: length(editions),
      primary_edition: edition_or_nil(primary),
      community_read_count: community_read_count
    })
  end

  @doc """
  Serializes a book for catalogue listing.

  Matches `CatalogueController.format_catalogue_book/1` — includes
  subjects but omits description, language, bisac_codes, and
  community_read_count. Author is the slim `{id, name}` shape.
  """
  @spec catalogue_book(map()) :: map()
  def catalogue_book(book) do
    editions = editions_list(book)
    primary = Books.primary_edition(book)

    Gen.book(book)
    |> Map.take([:id, :title, :subjects, :visibility_tier])
    |> Map.merge(%{
      author: author_slim(book.author),
      editions: editions,
      edition_count: length(editions),
      primary_edition: edition_or_nil(primary)
    })
  end

  @doc """
  Serializes a book for search results.

  Matches `SearchController.format_book/1` — omits description, language,
  subjects, bisac_codes, and community_read_count. Author is the slim
  `{id, name}` shape.
  """
  @spec search_book(map()) :: map()
  def search_book(book) do
    editions = editions_list(book)
    primary = Books.primary_edition(book)

    Gen.book(book)
    |> Map.take([:id, :title, :visibility_tier])
    |> Map.merge(%{
      author: author_slim(book.author),
      editions: editions,
      edition_count: length(editions),
      primary_edition: edition_or_nil(primary)
    })
  end

  @doc """
  Serializes a search result into the proto `SearchHit` shape (#285).

  Wraps a book (via `search_book/1`) with optional discovery-source provenance.
  `label` is a map that may carry `:source`, `:owner_handle`, `:price`, and
  `:bookshelf_name`; each defaults to the empty string (proto3 string default)
  when absent. The provenance labels (`:source`/`:owner_handle`/`:price`) are set
  ONLY for discoverable-by-design platform hits (an always-visible
  `looking_for_home` placement or an active marketplace listing).
  `:bookshelf_name` is set ONLY for the viewer's own collection hits (the shelf
  the book sits on) — platform hits leave it empty. `:snippet` is a
  `ts_headline`-highlighted description excerpt set ONLY for a scope=deep hit
  whose description matched (#284); every title-only hit leaves it empty. A plain
  platform book passes `%{}` and carries none of them.
  """
  @spec search_hit(map(), map()) :: map()
  def search_hit(book, label \\ %{}) do
    %{
      book: search_book(book),
      source: Map.get(label, :source, ""),
      owner_handle: Map.get(label, :owner_handle, ""),
      price: Map.get(label, :price, ""),
      bookshelf_name: Map.get(label, :bookshelf_name, ""),
      bookshelf_names: Map.get(label, :bookshelf_names, []),
      snippet: Map.get(label, :snippet, "")
    }
  end

  @doc """
  Serializes the embedded book inside a bookshelf placement.

  Matches the inline book map in `BookshelfController.format_placement/1` —
  includes description and visibility_tier but omits language, subjects,
  bisac_codes, and community_read_count. Author uses the bookshelf shape
  `{id, name, bio: nil}`.
  """
  @spec bookshelf_book(map()) :: map() | nil
  def bookshelf_book(%Ecto.Association.NotLoaded{}), do: nil
  def bookshelf_book(nil), do: nil

  def bookshelf_book(book) do
    editions = editions_list(book)
    primary = Books.primary_edition(book)

    Gen.book(book)
    |> Map.take([:id, :title, :description, :visibility_tier])
    |> Map.merge(%{
      author: author_bookshelf(book.author),
      editions: editions,
      edition_count: length(editions),
      primary_edition: edition_or_nil(primary)
    })
  end

  @doc """
  Serializes an author struct — the full shape with `{id, name, bio, website}`.

  Matches `BookController.format_author/1`.
  """
  @spec author(map() | nil) :: map() | nil
  def author(%Ecto.Association.NotLoaded{}), do: nil
  def author(nil), do: nil

  def author(author_struct) do
    Gen.author(author_struct) |> Map.take([:id, :name, :bio, :website])
  end

  @doc """
  Serializes an author as the slim `{id, name}` shape.

  Matches `SearchController.format_book/1` and `CatalogueController.format_author/1`.
  """
  @spec author_slim(map() | nil) :: map() | nil
  def author_slim(%Ecto.Association.NotLoaded{}), do: nil
  def author_slim(nil), do: nil
  def author_slim(author_struct), do: Gen.author(author_struct) |> Map.take([:id, :name])

  @doc """
  Serializes an author as the bookshelf shape `{id, name, bio: nil}`.

  The `bio` field is intentionally hardcoded to `nil` to match the
  `BookshelfController.format_author/1` contract — bookshelf views never
  expose author bios, regardless of whether one exists on the struct.
  """
  @spec author_bookshelf(map() | nil) :: map() | nil
  def author_bookshelf(%Ecto.Association.NotLoaded{}), do: nil
  def author_bookshelf(nil), do: nil

  def author_bookshelf(author_struct),
    do: Gen.author(author_struct) |> Map.take([:id, :name]) |> Map.put(:bio, nil)

  @doc """
  Serializes a book edition struct.

  Matches the `format_edition/1` used identically across BookController,
  BookshelfController, SearchController, and CatalogueController.

  `verification_source` is on the wire as of #344. It was DB-only when #335
  added it, because nothing outside the platform needed the provenance; the SPA
  now does. A book whose ISBN nothing external has confirmed carries an
  `"ISBN 978…"` placeholder title, and the reader has to be able to tell that
  from a book actually called that — which the client can only do if it is told
  which one it has. Deriving it there from `title` starting with `"ISBN "` is the
  guess this field exists to replace: it is wrong for a real title of that shape
  and, worse, stops working the moment enrichment succeeds.

  It is provenance, not personal data — which of two public catalogues answered
  a public ISBN lookup — so serialising it exposes nothing about a reader.
  """
  @spec edition(map()) :: map()
  def edition(ed) do
    Gen.edition(ed)
    |> Map.take([
      :id,
      :isbn,
      :format_label,
      :cover_image_url,
      :page_count,
      :publisher,
      :publication_year,
      :is_primary,
      :verification_source
    ])
  end

  @doc """
  Serializes a placement with embedded book — the rich shape for bookshelf views.

  Matches `BookshelfController.format_placement/1`.
  """
  @spec placement_detail(map()) :: map()
  def placement_detail(placement) do
    Gen.placement(placement)
    |> Map.take([
      :id,
      :position,
      :placed_at,
      :formats,
      :personal_rating,
      :notes,
      :reading_status,
      :current_page,
      :started_at,
      :finished_at,
      :visibility
    ])
    |> Map.put(:book, bookshelf_book(placement.book))
  end

  @doc """
  Serializes a placement as the slim ref shape for create/move operations.

  Matches `BookshelfPlacementController.format_placement/1`.
  """
  @spec placement_ref(map()) :: map()
  def placement_ref(placement) do
    Gen.placement(placement)
    |> Map.take([:id, :book_id, :bookshelf_id, :shelf_id, :position, :placed_at, :removed_at])
  end

  @doc """
  Serializes a placement as the book-detail shape (user's placement for a book).

  Matches `BookController.format_placement_or_nil/1`. Returns `nil` when
  the placement is nil.

  Emits `visibility` (the placement's own visibility) and `bookshelf_visibility`
  (the parent bookshelf's visibility — the ceiling the #194 frontend greys
  options against). When the bookshelf association is not loaded, both the
  name and the ceiling default to `nil` rather than crashing.
  """
  @spec book_placement(map() | nil) :: map() | nil
  def book_placement(nil), do: nil

  def book_placement(placement) do
    bookshelf = loaded_bookshelf(placement.bookshelf)

    Gen.placement(placement)
    |> Map.take([:id, :book_id, :personal_rating, :notes])
    |> Map.merge(%{
      bookshelf_name: bookshelf && bookshelf.name,
      formats: placement.formats || [],
      visibility: placement.visibility,
      bookshelf_visibility: bookshelf && bookshelf.visibility
    })
  end

  @spec loaded_bookshelf(term()) :: map() | nil
  defp loaded_bookshelf(%Ecto.Association.NotLoaded{}) do
    Logger.warning(
      "ProtoJSON.book_placement/1: placement.bookshelf not preloaded — bookshelf_visibility " <>
        "will be nil and the client cannot grey ceiling-exceeding options. Preload :bookshelf."
    )

    nil
  end

  defp loaded_bookshelf(nil), do: nil
  defp loaded_bookshelf(bookshelf), do: bookshelf

  @doc """
  Serializes a user struct for auth responses.

  Matches `AuthController.format_user/1`.
  """
  @spec user(map()) :: map()
  def user(user_struct) do
    base = Gen.user(user_struct) |> Map.take(@user_auth_fields)
    steps = user_struct.onboarding_steps || %{}
    step_order = Stacks.Accounts.onboarding_step_order()

    next_step =
      Enum.find(step_order, fn step ->
        not (Map.get(steps, step, false) == true)
      end)

    Map.put(base, :next_onboarding_step, next_step)
  end

  @doc """
  Serializes the onboarding status map from `Accounts.onboarding_status/1`.

  Returns `%{steps: %{...}, completed: bool, next_step: step | nil}`.
  """
  @spec onboarding_status(map()) :: map()
  def onboarding_status(%{steps: steps, completed: completed, next_step: next_step}) do
    %{steps: steps, completed: completed, next_step: next_step}
  end

  @doc """
  Serializes a blog post struct.

  Matches `BlogController.format_post/1`.

  Emits `author_display_name` — a denormalised projection of the author's
  `op.users.display_name` — so the block-user confirmation can name the person
  ("Block <name>?"). When the `:user` association is not loaded, the field is
  `nil` and the frontend falls back to a generic "the author" label.
  """
  @spec blog_post(map()) :: map()
  def blog_post(post) do
    Gen.blog_post(post)
    |> Map.take([
      :id,
      :user_id,
      :title,
      :body,
      :visibility,
      :published_at,
      :created_at,
      :updated_at,
      :syndicated
    ])
    |> Map.put(:author_display_name, author_display_name(post))
    |> Map.put(:author_handle, author_handle(post))
  end

  @spec author_display_name(map()) :: String.t() | nil
  defp author_display_name(%{user: %{display_name: name}}), do: name
  defp author_display_name(_post), do: nil

  @spec author_handle(map()) :: String.t() | nil
  defp author_handle(%{user: %{handle: handle}}), do: handle
  defp author_handle(_post), do: nil

  @doc """
  Serializes a blog post-book association.

  Matches `BlogController.serialize_association/2`. When `is_owner` is true,
  the `reasoning` field is included.
  """
  @spec blog_association(map(), boolean()) :: map()
  def blog_association(assoc, is_owner) do
    base =
      Gen.book_association(assoc)
      |> Map.merge(%{
        book_title: association_book_title(assoc),
        status: if(assoc.visible, do: "confirmed", else: "dismissed")
      })

    if is_owner, do: base, else: Map.delete(base, :reasoning)
  end

  @doc """
  Serializes a blog post comment.

  Handles the virtual `:replies` key added by `Blog.list_comments/2`.
  """
  @spec comment(map()) :: map()
  def comment(comment) do
    %{
      id: comment.id,
      post_id: comment.post_id,
      author_id: comment.author_id,
      parent_id: comment.parent_id,
      body: comment.body,
      created_at: comment.created_at,
      replies: Map.get(comment, :replies, []) |> Enum.map(&comment/1)
    }
  end

  @doc """
  Serializes a group struct.
  """
  @spec group(map()) :: map()
  def group(g) do
    %{
      id: g.id,
      owner_id: g.owner_id,
      name: g.name,
      type: g.type,
      visibility: g.visibility,
      created_at: g.created_at,
      updated_at: g.updated_at
    }
  end

  @doc """
  Serializes a group invitation struct.
  """
  @spec group_invitation(map()) :: map()
  def group_invitation(invitation) do
    %{
      id: invitation.id,
      group_id: invitation.group_id,
      invited_by_id: invitation.invited_by_id,
      invited_user_id: invitation.invited_user_id,
      status: invitation.status,
      responded_at: invitation.responded_at,
      created_at: invitation.created_at
    }
  end

  @doc """
  Serializes a visibility grant struct.
  """
  @spec visibility_grant(map()) :: map()
  def visibility_grant(grant) do
    %{
      id: grant.id,
      resource_type: grant.resource_type,
      resource_id: grant.resource_id,
      granted_to_id: grant.granted_to_id,
      granted_by_id: grant.granted_by_id,
      created_at: grant.created_at
    }
  end

  @doc """
  Builds the poll response map for upload status polling.

  Matches `UploadController.render_status/3` output shape. Accepts a map
  with string or atom keys for the required fields.
  """
  @spec poll_response(map()) :: map()
  def poll_response(attrs) do
    %{
      image_id: get_field(attrs, :image_id),
      status: get_field(attrs, :status),
      book_id: get_field(attrs, :book_id),
      book_ids: get_field(attrs, :book_ids, []),
      rejection_reason: get_field(attrs, :rejection_reason),
      is_duplicate: get_field(attrs, :is_duplicate, false)
    }
  end

  @doc """
  Builds the upload-inbox response — `stacks.common.v1.UploadInbox` (#351).

  There is no count field, and that is the point: the navigation badge counts
  the `awaiting_confirmation` entries of this same list, so the number and the
  surface it points at cannot drift apart. A second, separately-derived count
  on the wire would be one more thing that can be wrong.
  """
  @spec upload_inbox([map()]) :: map()
  def upload_inbox(items) when is_list(items) do
    %{items: Enum.map(items, &upload_inbox_item/1)}
  end

  @doc """
  Serializes one `stacks.common.v1.UploadInboxItem`.
  """
  @spec upload_inbox_item(map()) :: map()
  def upload_inbox_item(item) do
    %{
      image_id: get_field(item, :image_id),
      kind: get_field(item, :kind),
      book_ids: get_field(item, :book_ids, []),
      rejection_reason: get_field(item, :rejection_reason),
      uploaded_at: get_field(item, :uploaded_at)
    }
  end

  @doc """
  Serializes a marketplace listing struct.

  The ListingController passes the Listing struct directly to `json/2`,
  which uses the `Jason.Encoder` derive on `Stacks.Marketplace.Listing`.
  This function produces the identical shape for explicit serialization.

  Derived fields: `book` is serialized via the Book `Jason.Encoder` derive
  shape (id, title, description, language, subjects, bisac_codes,
  visibility_tier, created_at, updated_at — no author/editions); `seller`
  is serialized via the User `Jason.Encoder` derive shape (id, email,
  display_name, role, profile_visibility, age_verified, consent_analytics,
  created_at, updated_at).
  """
  @spec listing(map()) :: map()
  def listing(l) do
    Gen.listing(l)
    |> Map.take([
      :id,
      :status,
      :pricing_mode,
      :price_cents,
      :currency,
      :condition,
      :description,
      :contact_info,
      :photo_urls,
      :listed_at,
      :expires_at,
      :sold_at,
      :created_at,
      :updated_at
    ])
    |> Map.merge(%{
      book: listing_book(l.book),
      seller: listing_seller(l.seller)
    })
  end

  @doc """
  Serializes a shelf with its placements, filtering by visibility.

  Used by BookshelfController to build the `shelves` response shape.
  Each shelf includes its position and the placements visible to the viewer.
  `writing_book_ids` is any enumerable of book ids the owner has written about
  (#287); it is normalised to a set internally, so the caller may pass a MapSet
  (returned unchanged by `MapSet.new/1`) or a plain list. The default `[]` keeps
  the ribbon flag off for callers that don't compute writing.
  """
  @spec shelf_with_placements(map(), term(), Enumerable.t()) :: map()
  def shelf_with_placements(shelf, viewer, writing_book_ids \\ []) do
    writing_set = MapSet.new(writing_book_ids)

    visible_placements =
      shelf.placements
      |> Enum.filter(&(Stacks.Visibility.resolve_visibility(&1, viewer) == :visible))
      |> Enum.map(fn placement ->
        placement
        |> placement_detail()
        |> Map.put(:has_user_writing, MapSet.member?(writing_set, placement.book_id))
      end)

    %{id: shelf.id, position: shelf.position, placements: visible_placements}
  end

  @doc """
  Serializes a user's PUBLIC profile for `/u/:handle` (#213). Deliberately
  REDACTED — only the fields a stranger may see (handle, display_name, website,
  location) plus the viewer-visible bookshelf summaries. NEVER emit email,
  consent flags, notification prefs, role, or any other account/PII field
  (`ProtoJson.user/1` leaks all of those and MUST NOT be used here).

  `shelves` is the already visibility-filtered list from
  `Stacks.Visibility.viewable_shelves/2`.
  """
  @spec public_profile(map(), [map()]) :: map()
  def public_profile(user, shelves) do
    %{
      handle: user.handle,
      display_name: user.display_name || "",
      website_url: user.website_url,
      city: user.city,
      country_code: user.country_code,
      bookshelves:
        Enum.map(shelves, &%{name: &1.name, has_feed: Feeds.feed_eligible?(&1.visibility)})
    }
  end

  @doc """
  Slim, shelf-less variant of `public_profile/2` for people-search result cards
  (#217). Same REDACTED contract — only handle, display_name, and location; NEVER
  email, consent, role, or any account/PII field. No bookshelves (search results
  don't render shelf summaries).

  Exclusion of ghost/blocked users is enforced upstream in
  `Accounts.search_users/2` (SQL), never here — this serializer only shapes the
  already-permitted rows.
  """
  @spec public_profile_summary(map()) :: map()
  def public_profile_summary(user) do
    %{
      handle: user.handle,
      display_name: user.display_name || "",
      city: user.city,
      country_code: user.country_code
    }
  end

  @doc """
  Serializes a placement's format update response.

  Matches the `%{id, formats}` shape returned by
  `BookshelfPlacementController.update_formats/2`.
  """
  @spec placement_formats(map()) :: map()
  def placement_formats(placement) do
    %{id: placement.id, formats: placement.formats}
  end

  @doc """
  Serializes a placement's reading progress update response.

  Matches the shape returned by
  `BookshelfPlacementController.update_progress/2`.
  """
  @spec reading_progress(map()) :: map()
  def reading_progress(placement) do
    %{
      id: placement.id,
      reading_status: placement.reading_status,
      current_page: placement.current_page,
      started_at: placement.started_at,
      finished_at: placement.finished_at
    }
  end

  @doc """
  Serializes a visibility update response for a bookshelf or placement.

  Matches the `%{id, visibility}` shape returned by
  `BookshelfController.update_visibility/2` and
  `BookshelfPlacementController.update_visibility/2`.
  """
  @spec visibility_update(map()) :: map()
  def visibility_update(entity) do
    %{id: entity.id, visibility: entity.visibility}
  end

  @doc """
  Serializes a blog association confirm/dismiss response.

  Matches the `%{id, book_id, visible}` shape returned by
  `BlogController.confirm_association/2` and `BlogController.dismiss_association/2`.
  """
  @spec association_action(map()) :: map()
  def association_action(assoc) do
    %{id: assoc.id, book_id: assoc.book_id, visible: assoc.visible}
  end

  @doc """
  Serializes a feed item (placement or blog post) for the group content feed.
  """
  @spec feed_item(map()) :: map()
  def feed_item(%{type: :placement_created} = item) do
    %{
      type: "placement_created",
      placement_id: item.placement_id,
      book_id: item.book_id,
      book_title: item.book_title,
      book_cover_url: nil,
      user_id: item.user_id,
      user_display_name: item.user_display_name,
      occurred_at: DateTime.to_iso8601(item.occurred_at)
    }
  end

  def feed_item(%{type: :blog_post} = item) do
    %{
      type: "blog_post",
      post_id: item.post_id,
      post_title: item.post_title,
      post_visibility: item.post_visibility,
      user_id: item.user_id,
      user_display_name: item.user_display_name,
      occurred_at: DateTime.to_iso8601(item.occurred_at)
    }
  end

  @doc """
  Serializes a partner struct for API responses.
  Omits hmac_secret — security-sensitive, never serialized.
  """
  @spec partner(map()) :: map()
  def partner(p) do
    %{
      id: p.id,
      name: p.name,
      business_type: p.business_type,
      contact_email: p.contact_email,
      website_url: p.website_url,
      status: p.status,
      api_key_prefix: p.api_key_prefix,
      approved_by_id: p.approved_by_id,
      created_at: p.created_at && DateTime.to_iso8601(p.created_at)
    }
  end

  @spec editions_list(map()) :: [map()]
  defp editions_list(%{editions: %Ecto.Association.NotLoaded{}}), do: []

  defp editions_list(%{editions: editions}) when is_list(editions) do
    Enum.map(editions, &edition/1)
  end

  defp editions_list(_), do: []

  @spec edition_or_nil(map() | nil) :: map() | nil
  defp edition_or_nil(nil), do: nil
  defp edition_or_nil(ed), do: edition(ed)

  @spec get_field(map(), atom(), term()) :: term()
  defp get_field(attrs, key, default \\ nil) do
    cond do
      Map.has_key?(attrs, key) ->
        Map.get(attrs, key)

      Map.has_key?(attrs, to_string(key)) ->
        Map.get(attrs, to_string(key))

      true ->
        default
    end
  end

  @spec listing_book(map() | struct() | nil) :: map() | nil
  defp listing_book(%Ecto.Association.NotLoaded{}), do: nil
  defp listing_book(nil), do: nil

  defp listing_book(book) do
    Gen.book(book)
    |> Map.take([
      :id,
      :title,
      :description,
      :language,
      :subjects,
      :bisac_codes,
      :visibility_tier,
      :created_at,
      :updated_at
    ])
  end

  @spec association_book_title(map()) :: String.t()
  defp association_book_title(%{book: %Ecto.Association.NotLoaded{}}), do: ""
  defp association_book_title(%{book: nil}), do: ""
  defp association_book_title(%{book: %{title: title}}), do: title || ""
  defp association_book_title(_), do: ""

  @spec listing_seller(map() | struct() | nil) :: map() | nil
  defp listing_seller(%Ecto.Association.NotLoaded{}), do: nil
  defp listing_seller(nil), do: nil

  defp listing_seller(seller) do
    Gen.user(seller)
    |> Map.take(@user_embed_fields)
  end
end
