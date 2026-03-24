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

    %{
      id: book.id,
      title: book.title,
      description: book.description,
      language: book.language,
      subjects: book.subjects,
      bisac_codes: book.bisac_codes,
      visibility_tier: book.visibility_tier,
      author: author(book.author),
      editions: editions,
      edition_count: length(editions),
      primary_edition: edition_or_nil(primary),
      community_read_count: community_read_count
    }
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

    %{
      id: book.id,
      title: book.title,
      author: author_slim(book.author),
      subjects: book.subjects,
      visibility_tier: book.visibility_tier,
      editions: editions,
      edition_count: length(editions),
      primary_edition: edition_or_nil(primary)
    }
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

    %{
      id: book.id,
      title: book.title,
      visibility_tier: book.visibility_tier,
      author: author_slim(book.author),
      editions: editions,
      edition_count: length(editions),
      primary_edition: edition_or_nil(primary)
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

    %{
      id: book.id,
      title: book.title,
      description: book.description,
      visibility_tier: book.visibility_tier,
      author: author_bookshelf(book.author),
      editions: editions,
      edition_count: length(editions),
      primary_edition: edition_or_nil(primary)
    }
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
    %{
      id: author_struct.id,
      name: author_struct.name,
      bio: author_struct.bio,
      website: author_struct.website_url
    }
  end

  @doc """
  Serializes an author as the slim `{id, name}` shape.

  Matches `SearchController.format_book/1` and `CatalogueController.format_author/1`.
  """
  @spec author_slim(map() | nil) :: map() | nil
  def author_slim(%Ecto.Association.NotLoaded{}), do: nil
  def author_slim(nil), do: nil
  def author_slim(author_struct), do: %{id: author_struct.id, name: author_struct.name}

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
    do: %{id: author_struct.id, name: author_struct.name, bio: nil}

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
    %{
      id: ed.id,
      isbn: ed.isbn,
      format_label: ed.format_label,
      cover_image_url: ed.cover_image_url,
      page_count: ed.page_count,
      publisher: ed.publisher,
      publication_year: ed.publication_year,
      is_primary: ed.is_primary
    }
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
    %{
      id: placement.id,
      position: placement.position,
      placed_at: placement.placed_at,
      formats: placement.formats,
      personal_rating: placement.personal_rating,
      notes: placement.notes,
      book: bookshelf_book(placement.book)
    }
  end

  @doc """
  Serializes a placement as the slim ref shape for create/move operations.

  Matches `BookshelfPlacementController.format_placement/1`.
  """
  @spec placement_ref(map()) :: map()
  def placement_ref(placement) do
    %{
      id: placement.id,
      book_id: placement.book_id,
      bookshelf_id: placement.bookshelf_id,
      position: placement.position,
      placed_at: placement.placed_at,
      removed_at: placement.removed_at
    }
  end

  @doc """
  Serializes a placement as the book-detail shape (user's placement for a book).

  Matches `BookController.format_placement_or_nil/1`. Returns `nil` when
  the placement is nil.
  """
  @spec book_placement(map() | nil) :: map() | nil
  def book_placement(nil), do: nil

  def book_placement(placement) do
    %{
      id: placement.id,
      book_id: placement.book_id,
      bookshelf_name: placement.bookshelf.name,
      formats: placement.formats || [],
      personal_rating: placement.personal_rating,
      notes: placement.notes
    }
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
    %{
      id: user_struct.id,
      email: user_struct.email,
      display_name: user_struct.display_name,
      role: user_struct.role,
      profile_visibility: user_struct.profile_visibility,
      age_verified: user_struct.age_verified,
      consent_analytics: user_struct.consent_analytics,
      country_code: user_struct.country_code,
      city: user_struct.city
    }
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
    %{
      id: post.id,
      user_id: post.user_id,
      title: post.title,
      body: post.body,
      visibility: post.visibility,
      published_at: post.published_at,
      created_at: post.created_at,
      updated_at: post.updated_at
    }
  end

  @doc """
  Serializes a blog post-book association.

  Matches `BlogController.serialize_association/2`. When `is_owner` is true,
  the `reasoning` field is included.
  """
  @spec blog_association(map(), boolean()) :: map()
  def blog_association(assoc, is_owner) do
    base = %{
      id: assoc.id,
      book_id: assoc.book_id,
      confidence: assoc.confidence,
      source: assoc.source,
      visible: assoc.visible
    }

    if is_owner, do: Map.put(base, :reasoning, assoc.reasoning), else: base
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
    %{
      id: l.id,
      status: l.status,
      pricing_mode: l.pricing_mode,
      price_cents: l.price_cents,
      currency: l.currency,
      condition: l.condition,
      description: l.description,
      contact_info: l.contact_info,
      photo_urls: l.photo_urls,
      listed_at: l.listed_at,
      expires_at: l.expires_at,
      sold_at: l.sold_at,
      created_at: l.created_at,
      updated_at: l.updated_at,
      book: listing_book(l.book),
      seller: listing_seller(l.seller)
    }
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
    %{
      id: book.id,
      title: book.title,
      description: book.description,
      language: book.language,
      subjects: book.subjects,
      bisac_codes: book.bisac_codes,
      visibility_tier: book.visibility_tier,
      created_at: book.created_at,
      updated_at: book.updated_at
    }
  end

  # Matches `User @derive {Jason.Encoder, only: [...]}` — the shape Jason
  # produces when ListingController passes the raw struct through `json/2`.
  @spec listing_seller(map() | struct() | nil) :: map() | nil
  defp listing_seller(%Ecto.Association.NotLoaded{}), do: nil
  defp listing_seller(nil), do: nil

  defp listing_seller(seller) do
    %{
      id: seller.id,
      email: seller.email,
      display_name: seller.display_name,
      role: seller.role,
      profile_visibility: seller.profile_visibility,
      age_verified: seller.age_verified,
      consent_analytics: seller.consent_analytics,
      created_at: seller.created_at,
      updated_at: seller.updated_at
    }
  end
end
