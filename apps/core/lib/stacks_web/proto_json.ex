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

  alias Stacks.Books
  alias StacksWeb.ProtoJSON.Gen

  # Shared user field lists — used by user/1 and listing_seller/1 for consistency.
  @user_core_fields [
    :id,
    :email,
    :display_name,
    :role,
    :profile_visibility,
    :age_verified,
    :consent_analytics
  ]
  @user_auth_fields @user_core_fields ++ [:country_code, :city, :onboarding_completed]
  @user_embed_fields @user_core_fields ++ [:created_at, :updated_at]

  # ---------------------------------------------------------------------------
  # Book (work)
  # ---------------------------------------------------------------------------

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

  # ---------------------------------------------------------------------------
  # Author
  # ---------------------------------------------------------------------------

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

  # ---------------------------------------------------------------------------
  # Edition
  # ---------------------------------------------------------------------------

  @doc """
  Serializes a book edition struct.

  Matches the `format_edition/1` used identically across BookController,
  BookshelfController, SearchController, and CatalogueController.
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
      :is_primary
    ])
  end

  # ---------------------------------------------------------------------------
  # SocialController — no ProtoJSON functions needed
  # ---------------------------------------------------------------------------
  #
  # SocialController responses are trivial inline maps:
  #   block/2   -> %{blocked: true}
  #   unblock/2 -> %{blocked: false}
  #   blocked_users/2 -> %{blocked_users: list, total: int, page: int}
  # These stay as inline maps in the controller — no serializer benefit.

  # ---------------------------------------------------------------------------
  # Placement variants
  # ---------------------------------------------------------------------------

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
      :finished_at
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
    |> Map.take([:id, :book_id, :bookshelf_id, :position, :placed_at, :removed_at])
  end

  @doc """
  Serializes a placement as the book-detail shape (user's placement for a book).

  Matches `BookController.format_placement_or_nil/1`. Returns `nil` when
  the placement is nil.
  """
  @spec book_placement(map() | nil) :: map() | nil
  def book_placement(nil), do: nil

  def book_placement(placement) do
    Gen.placement(placement)
    |> Map.take([:id, :book_id, :personal_rating, :notes])
    |> Map.merge(%{
      bookshelf_name: placement.bookshelf.name,
      formats: placement.formats || []
    })
  end

  # ---------------------------------------------------------------------------
  # User
  # ---------------------------------------------------------------------------

  @doc """
  Serializes a user struct for auth responses.

  Matches `AuthController.format_user/1`.
  """
  @spec user(map()) :: map()
  def user(user_struct) do
    base = Gen.user(user_struct) |> Map.take(@user_auth_fields)
    steps = user_struct.onboarding_steps || %{}
    step_order = ~w(profile age_verification privacy)

    next_step =
      Enum.find(step_order, fn step ->
        not (Map.get(steps, step, false) == true)
      end)

    Map.put(base, :next_onboarding_step, next_step)
  end

  # ---------------------------------------------------------------------------
  # Onboarding
  # ---------------------------------------------------------------------------

  @doc """
  Serializes the onboarding status map from `Accounts.onboarding_status/1`.

  Returns `%{steps: %{...}, completed: bool, next_step: step | nil}`.
  """
  @spec onboarding_status(map()) :: map()
  def onboarding_status(%{steps: steps, completed: completed, next_step: next_step}) do
    %{steps: steps, completed: completed, next_step: next_step}
  end

  # ---------------------------------------------------------------------------
  # Blog
  # ---------------------------------------------------------------------------

  @doc """
  Serializes a blog post struct.

  Matches `BlogController.format_post/1`.
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
      :updated_at
    ])
  end

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

  # ---------------------------------------------------------------------------
  # Comment
  # ---------------------------------------------------------------------------

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

  # ---------------------------------------------------------------------------
  # Upload / Poll
  # ---------------------------------------------------------------------------

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

  # ---------------------------------------------------------------------------
  # Listing (marketplace)
  # ---------------------------------------------------------------------------

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

  # ---------------------------------------------------------------------------
  # Placement formats
  # ---------------------------------------------------------------------------

  @doc """
  Serializes a placement's format update response.

  Matches the `%{id, formats}` shape returned by
  `BookshelfPlacementController.update_formats/2`.
  """
  @spec placement_formats(map()) :: map()
  def placement_formats(placement) do
    %{id: placement.id, formats: placement.formats}
  end

  # ---------------------------------------------------------------------------
  # Reading progress
  # ---------------------------------------------------------------------------

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

  # ---------------------------------------------------------------------------
  # Visibility update
  # ---------------------------------------------------------------------------

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

  # ---------------------------------------------------------------------------
  # Association action
  # ---------------------------------------------------------------------------

  @doc """
  Serializes a blog association confirm/dismiss response.

  Matches the `%{id, book_id, visible}` shape returned by
  `BlogController.confirm_association/2` and `BlogController.dismiss_association/2`.
  """
  @spec association_action(map()) :: map()
  def association_action(assoc) do
    %{id: assoc.id, book_id: assoc.book_id, visible: assoc.visible}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

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

  # Matches `Book @derive {Jason.Encoder, only: [...]}` — the shape Jason
  # produces when ListingController passes the raw struct through `json/2`.
  # No author, no editions — just the flat book fields plus timestamps.
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

  # Extracts the book title from a preloaded association, handling not-loaded and nil.
  @spec association_book_title(map()) :: String.t()
  defp association_book_title(%{book: %Ecto.Association.NotLoaded{}}), do: ""
  defp association_book_title(%{book: nil}), do: ""
  defp association_book_title(%{book: %{title: title}}), do: title || ""
  defp association_book_title(_), do: ""

  # Matches `User @derive {Jason.Encoder, only: [...]}` — the shape Jason
  # produces when ListingController passes the raw struct through `json/2`.
  @spec listing_seller(map() | struct() | nil) :: map() | nil
  defp listing_seller(%Ecto.Association.NotLoaded{}), do: nil
  defp listing_seller(nil), do: nil

  defp listing_seller(seller) do
    Gen.user(seller)
    |> Map.take(@user_embed_fields)
  end
end
