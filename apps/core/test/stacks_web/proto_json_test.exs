defmodule StacksWeb.ProtoJSONTest do
  @moduledoc "Golden snapshot tests verifying ProtoJSON output matches controller format_* helpers."

  use Core.DataCase, async: true

  import Stacks.Factory

  alias StacksWeb.ProtoJSON

  # ---------------------------------------------------------------------------
  # book/2
  # ---------------------------------------------------------------------------

  describe "book/2" do
    test "produces identical output to BookController.format_book/2 with all fields" do
      author = insert(:author, bio: "Great writer.", website_url: "https://example.com")
      book = insert(:book, author: author, subjects: ["fiction", "philosophy"])

      edition =
        insert(:book_edition,
          book: book,
          isbn: "9780140449136",
          format_label: "Paperback",
          cover_image_url: "https://covers.example.com/1.jpg",
          page_count: 320,
          publisher: "Penguin",
          publication_year: 2003,
          is_primary: true
        )

      book = %{book | editions: [edition]}

      result = ProtoJSON.book(book, community_read_count: 42)

      assert result == %{
               id: book.id,
               title: book.title,
               description: book.description,
               language: book.language,
               subjects: ["fiction", "philosophy"],
               bisac_codes: book.bisac_codes,
               visibility_tier: "public",
               author: %{
                 id: author.id,
                 name: author.name,
                 bio: "Great writer.",
                 website: "https://example.com"
               },
               editions: [
                 %{
                   id: edition.id,
                   isbn: "9780140449136",
                   format_label: "Paperback",
                   cover_image_url: "https://covers.example.com/1.jpg",
                   page_count: 320,
                   publisher: "Penguin",
                   publication_year: 2003,
                   is_primary: true
                 }
               ],
               edition_count: 1,
               primary_edition: %{
                 id: edition.id,
                 isbn: "9780140449136",
                 format_label: "Paperback",
                 cover_image_url: "https://covers.example.com/1.jpg",
                 page_count: 320,
                 publisher: "Penguin",
                 publication_year: 2003,
                 is_primary: true
               },
               community_read_count: 42
             }
    end

    test "defaults community_read_count to 0" do
      book = insert(:book, author: nil)
      book = %{book | editions: []}

      result = ProtoJSON.book(book)

      assert result.community_read_count == 0
    end

    test "handles nil author" do
      book = insert(:book, author: nil)
      book = %{book | editions: []}

      result = ProtoJSON.book(book)

      assert result.author == nil
    end

    test "handles not-loaded author" do
      book = insert(:book)
      # Simulate Ecto.Association.NotLoaded
      book = %{
        book
        | author: %Ecto.Association.NotLoaded{
            __field__: :author,
            __owner__: Stacks.Books.Book,
            __cardinality__: :one
          }
      }

      result = ProtoJSON.book(book)

      assert result.author == nil
    end

    test "handles empty editions" do
      book = insert(:book, author: nil)
      book = %{book | editions: []}

      result = ProtoJSON.book(book)

      assert result.editions == []
      assert result.edition_count == 0
      assert result.primary_edition == nil
    end

    test "handles not-loaded editions" do
      book = insert(:book, author: nil)

      book = %{
        book
        | editions: %Ecto.Association.NotLoaded{
            __field__: :editions,
            __owner__: Stacks.Books.Book,
            __cardinality__: :many
          }
      }

      result = ProtoJSON.book(book)

      assert result.editions == []
      assert result.edition_count == 0
    end
  end

  # ---------------------------------------------------------------------------
  # catalogue_book/1
  # ---------------------------------------------------------------------------

  describe "catalogue_book/1" do
    test "includes subjects but omits description, language, bisac_codes, community_read_count" do
      author = insert(:author)
      book = insert(:book, author: author, subjects: ["history"])

      edition =
        insert(:book_edition, book: book, is_primary: true)

      book = %{book | editions: [edition]}

      result = ProtoJSON.catalogue_book(book)

      assert result.subjects == ["history"]
      assert result.author == %{id: author.id, name: author.name}
      refute Map.has_key?(result, :description)
      refute Map.has_key?(result, :language)
      refute Map.has_key?(result, :bisac_codes)
      refute Map.has_key?(result, :community_read_count)
    end

    test "handles nil author" do
      book = insert(:book, author: nil)
      book = %{book | editions: []}

      result = ProtoJSON.catalogue_book(book)

      assert result.author == nil
    end
  end

  # ---------------------------------------------------------------------------
  # search_book/1
  # ---------------------------------------------------------------------------

  describe "search_book/1" do
    test "includes visibility_tier but omits description, subjects, language, bisac_codes" do
      author = insert(:author)
      book = insert(:book, author: author, visibility_tier: "age_gated")

      edition = insert(:book_edition, book: book, is_primary: true)
      book = %{book | editions: [edition]}

      result = ProtoJSON.search_book(book)

      assert result.visibility_tier == "age_gated"
      assert result.author == %{id: author.id, name: author.name}
      refute Map.has_key?(result, :description)
      refute Map.has_key?(result, :subjects)
      refute Map.has_key?(result, :language)
      refute Map.has_key?(result, :bisac_codes)
      refute Map.has_key?(result, :community_read_count)
    end
  end

  # ---------------------------------------------------------------------------
  # bookshelf_book/1
  # ---------------------------------------------------------------------------

  describe "bookshelf_book/1" do
    test "includes description and visibility_tier, author with bio: nil" do
      author = insert(:author, bio: "Great writer.", website_url: "https://example.com")
      book = insert(:book, author: author, description: "A fine book.")

      edition = insert(:book_edition, book: book, is_primary: true)
      book = %{book | editions: [edition]}

      result = ProtoJSON.bookshelf_book(book)

      assert result.description == "A fine book."
      assert result.visibility_tier == book.visibility_tier
      assert result.author == %{id: author.id, name: author.name, bio: nil}
      refute Map.has_key?(result, :language)
      refute Map.has_key?(result, :subjects)
      refute Map.has_key?(result, :bisac_codes)
      refute Map.has_key?(result, :community_read_count)
    end

    test "returns nil for not-loaded book association" do
      assert ProtoJSON.bookshelf_book(%Ecto.Association.NotLoaded{
               __field__: :book,
               __owner__: Stacks.Shelving.Placement,
               __cardinality__: :one
             }) == nil
    end

    test "returns nil for nil" do
      assert ProtoJSON.bookshelf_book(nil) == nil
    end

    test "returns empty editions when editions are not loaded" do
      author = insert(:author)
      book = insert(:book, author: author)

      book = %{
        book
        | editions: %Ecto.Association.NotLoaded{
            __field__: :editions,
            __owner__: Stacks.Books.Book,
            __cardinality__: :many
          }
      }

      result = ProtoJSON.bookshelf_book(book)

      assert result.editions == []
      assert result.edition_count == 0
      assert result.primary_edition == nil
    end
  end

  # ---------------------------------------------------------------------------
  # author/1
  # ---------------------------------------------------------------------------

  describe "author/1" do
    test "full shape with id, name, bio, website" do
      a = insert(:author, bio: "Bio text.", website_url: "https://site.com")

      assert ProtoJSON.author(a) == %{
               id: a.id,
               name: a.name,
               bio: "Bio text.",
               website: "https://site.com"
             }
    end

    test "nil website_url renders as nil" do
      a = insert(:author, website_url: nil)

      assert ProtoJSON.author(a).website == nil
    end

    test "returns nil for nil" do
      assert ProtoJSON.author(nil) == nil
    end

    test "returns nil for not-loaded" do
      assert ProtoJSON.author(%Ecto.Association.NotLoaded{
               __field__: :author,
               __owner__: Stacks.Books.Book,
               __cardinality__: :one
             }) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # author_slim/1
  # ---------------------------------------------------------------------------

  describe "author_slim/1" do
    test "only id and name" do
      a = insert(:author, bio: "Should be excluded.")

      result = ProtoJSON.author_slim(a)

      assert result == %{id: a.id, name: a.name}
      refute Map.has_key?(result, :bio)
      refute Map.has_key?(result, :website)
    end

    test "returns nil for nil" do
      assert ProtoJSON.author_slim(nil) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # author_bookshelf/1
  # ---------------------------------------------------------------------------

  describe "author_bookshelf/1" do
    test "includes id, name, and bio: nil" do
      a = insert(:author, bio: "Has a bio.")

      assert ProtoJSON.author_bookshelf(a) == %{id: a.id, name: a.name, bio: nil}
    end

    test "returns nil for nil" do
      assert ProtoJSON.author_bookshelf(nil) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # edition/1
  # ---------------------------------------------------------------------------

  describe "edition/1" do
    test "all fields serialized" do
      book = insert(:book)

      ed =
        insert(:book_edition,
          book: book,
          isbn: "9781234567890",
          format_label: "Hardcover",
          cover_image_url: "https://covers.example.com/2.jpg",
          page_count: 450,
          publisher: "HarperCollins",
          publication_year: 2021,
          is_primary: false
        )

      assert ProtoJSON.edition(ed) == %{
               id: ed.id,
               isbn: "9781234567890",
               format_label: "Hardcover",
               cover_image_url: "https://covers.example.com/2.jpg",
               page_count: 450,
               publisher: "HarperCollins",
               publication_year: 2021,
               is_primary: false
             }
    end

    test "nil optional fields" do
      book = insert(:book)

      ed =
        insert(:book_edition,
          book: book,
          cover_image_url: nil,
          page_count: nil,
          publisher: nil,
          publication_year: nil
        )

      result = ProtoJSON.edition(ed)

      assert result.cover_image_url == nil
      assert result.page_count == nil
      assert result.publisher == nil
      assert result.publication_year == nil
    end
  end

  # ---------------------------------------------------------------------------
  # placement_detail/1
  # ---------------------------------------------------------------------------

  describe "placement_detail/1" do
    test "matches BookshelfController.format_placement/1 shape" do
      user = insert(:user)
      author = insert(:author)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      book = insert(:book, author: author)
      edition = insert(:book_edition, book: book, is_primary: true)
      book = %{book | editions: [edition]}

      placement =
        insert(:placement,
          bookshelf: bookshelf,
          book: book,
          position: 3,
          formats: ["physical"],
          personal_rating: 5
        )

      result = ProtoJSON.placement_detail(placement)

      assert result.id == placement.id
      assert result.position == 3
      assert result.placed_at == placement.placed_at
      assert result.formats == ["physical"]
      assert result.personal_rating == 5
      assert result.notes == placement.notes
      assert result.book != nil
      assert result.book.id == book.id
      assert result.book.author == %{id: author.id, name: author.name, bio: nil}
    end

    test "book is nil when not loaded" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user)

      placement =
        insert(:placement,
          bookshelf: bookshelf,
          book: build(:book)
        )

      placement = %{
        placement
        | book: %Ecto.Association.NotLoaded{
            __field__: :book,
            __owner__: Stacks.Shelving.Placement,
            __cardinality__: :one
          }
      }

      result = ProtoJSON.placement_detail(placement)

      assert result.book == nil
    end
  end

  # ---------------------------------------------------------------------------
  # placement_ref/1
  # ---------------------------------------------------------------------------

  describe "placement_ref/1" do
    test "matches BookshelfPlacementController.format_placement/1 shape" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user)
      book = insert(:book)

      placement =
        insert(:placement,
          bookshelf: bookshelf,
          book: book,
          position: 1
        )

      result = ProtoJSON.placement_ref(placement)

      assert result == %{
               id: placement.id,
               book_id: placement.book_id,
               bookshelf_id: placement.bookshelf_id,
               position: placement.position,
               placed_at: placement.placed_at,
               removed_at: placement.removed_at
             }
    end

    test "removed_at is nil for active placement" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user)
      placement = insert(:placement, bookshelf: bookshelf, book: build(:book))

      result = ProtoJSON.placement_ref(placement)

      assert result.removed_at == nil
    end
  end

  # ---------------------------------------------------------------------------
  # book_placement/1
  # ---------------------------------------------------------------------------

  describe "book_placement/1" do
    test "matches BookController.format_placement_or_nil/1 shape" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "antilibrary")
      book = insert(:book)

      placement =
        insert(:placement,
          bookshelf: bookshelf,
          book: book,
          formats: ["physical", "ebook"],
          personal_rating: 4
        )

      # Preload bookshelf so .bookshelf.name is available
      placement = Core.Repo.preload(placement, :bookshelf)

      result = ProtoJSON.book_placement(placement)

      assert result == %{
               id: placement.id,
               book_id: placement.book_id,
               bookshelf_name: "antilibrary",
               formats: ["physical", "ebook"],
               personal_rating: 4,
               notes: placement.notes
             }
    end

    test "returns nil for nil" do
      assert ProtoJSON.book_placement(nil) == nil
    end

    test "defaults formats to empty list when nil" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, name: "library")
      book = insert(:book)

      placement =
        insert(:placement,
          bookshelf: bookshelf,
          book: book,
          formats: nil
        )

      placement = Core.Repo.preload(placement, :bookshelf)

      result = ProtoJSON.book_placement(placement)

      assert result.formats == []
    end
  end

  # ---------------------------------------------------------------------------
  # user/1
  # ---------------------------------------------------------------------------

  describe "user/1" do
    test "matches AuthController.format_user/1 shape" do
      u =
        insert(:user,
          display_name: "Alice",
          role: "user",
          profile_visibility: "platform",
          age_verified: true,
          consent_analytics: true,
          country_code: "ZA",
          city: "Cape Town"
        )

      result = ProtoJSON.user(u)

      assert result == %{
               id: u.id,
               email: u.email,
               display_name: "Alice",
               role: "user",
               profile_visibility: "platform",
               age_verified: true,
               consent_analytics: true,
               country_code: "ZA",
               city: "Cape Town"
             }
    end

    test "handles nil optional fields" do
      u = insert(:user, country_code: nil, city: nil)

      result = ProtoJSON.user(u)

      assert result.country_code == nil
      assert result.city == nil
    end
  end

  # ---------------------------------------------------------------------------
  # blog_post/1
  # ---------------------------------------------------------------------------

  describe "blog_post/1" do
    test "matches BlogController.format_post/1 shape" do
      user = insert(:user)
      post = insert(:post, user: user, visibility: "platform")

      result = ProtoJSON.blog_post(post)

      assert result == %{
               id: post.id,
               user_id: post.user_id,
               title: post.title,
               body: post.body,
               visibility: "platform",
               published_at: post.published_at,
               created_at: post.created_at,
               updated_at: post.updated_at
             }
    end

    test "published_at is nil for unpublished post" do
      user = insert(:user)
      post = insert(:post, user: user, published_at: nil)

      result = ProtoJSON.blog_post(post)

      assert result.published_at == nil
    end
  end

  # ---------------------------------------------------------------------------
  # blog_association/2
  # ---------------------------------------------------------------------------

  describe "blog_association/2" do
    test "non-owner shape excludes reasoning" do
      assoc = insert(:post_book_association)

      result = ProtoJSON.blog_association(assoc, false)

      assert result.id == assoc.id
      assert result.book_id == assoc.book_id
      assert result.confidence == assoc.confidence
      assert result.source == assoc.source
      assert result.visible == assoc.visible
      assert is_binary(result.book_title)
      assert result.status in ["confirmed", "dismissed"]
      refute Map.has_key?(result, :reasoning)
    end

    test "owner shape includes reasoning" do
      assoc = insert(:post_book_association, reasoning: "Thematic overlap.")

      result = ProtoJSON.blog_association(assoc, true)

      assert result.reasoning == "Thematic overlap."
      assert Map.has_key?(result, :reasoning)
      assert is_binary(result.book_title)
      assert result.status in ["confirmed", "dismissed"]
    end
  end

  # ---------------------------------------------------------------------------
  # poll_response/1
  # ---------------------------------------------------------------------------

  describe "poll_response/1" do
    test "matches UploadController render_status output" do
      attrs = %{
        image_id: "abc-123",
        status: "resolved",
        book_id: "book-uuid",
        book_ids: ["book-uuid"],
        rejection_reason: nil,
        is_duplicate: false
      }

      result = ProtoJSON.poll_response(attrs)

      assert result == %{
               image_id: "abc-123",
               status: "resolved",
               book_id: "book-uuid",
               book_ids: ["book-uuid"],
               rejection_reason: nil,
               is_duplicate: false
             }
    end

    test "defaults book_ids to empty list and is_duplicate to false" do
      attrs = %{image_id: "img-1", status: "pending", book_id: nil, rejection_reason: nil}

      result = ProtoJSON.poll_response(attrs)

      assert result.book_ids == []
      assert result.is_duplicate == false
    end

    test "works with string keys" do
      attrs = %{
        "image_id" => "img-2",
        "status" => "rejected",
        "book_id" => nil,
        "book_ids" => [],
        "rejection_reason" => "not_a_book",
        "is_duplicate" => false
      }

      result = ProtoJSON.poll_response(attrs)

      assert result.image_id == "img-2"
      assert result.status == "rejected"
      assert result.rejection_reason == "not_a_book"
    end

    test "preserves explicit false for is_duplicate (no falsiness bug)" do
      attrs = %{
        is_duplicate: false,
        image_id: "i",
        status: "s",
        book_id: nil,
        rejection_reason: nil
      }

      result = ProtoJSON.poll_response(attrs)

      assert result.is_duplicate == false
    end

    test "preserves explicit nil for book_id when is_duplicate is false" do
      attrs = %{
        "image_id" => "i",
        "status" => "pending",
        "book_id" => nil,
        "book_ids" => [],
        "rejection_reason" => nil,
        "is_duplicate" => false
      }

      result = ProtoJSON.poll_response(attrs)

      assert result.book_id == nil
      assert result.is_duplicate == false
    end
  end

  # ---------------------------------------------------------------------------
  # listing/1
  # ---------------------------------------------------------------------------

  describe "listing/1" do
    test "matches the Jason.Encoder derive shape" do
      listing = insert(:listing)

      result = ProtoJSON.listing(listing)

      assert result.id == listing.id
      assert result.status == "draft"
      assert result.pricing_mode == listing.pricing_mode
      assert result.price_cents == listing.price_cents
      assert result.currency == "ZAR"
      assert result.condition == listing.condition
      assert result.description == listing.description
      assert result.photo_urls == []
      assert result.listed_at == nil
      assert result.expires_at == nil
      assert result.sold_at == nil
    end

    test "serializes nested book and seller matching Jason.Encoder derive shapes" do
      author = insert(:author)
      book = insert(:book, author: author, subjects: ["fiction"])
      _edition = insert(:book_edition, book: book, is_primary: true)
      seller = insert(:user, display_name: "Alice")

      listing = insert(:listing, book: book, seller: seller)

      result = ProtoJSON.listing(listing)

      # Book matches Book @derive {Jason.Encoder, only: [...]} — no author, no editions
      assert result.book == %{
               id: book.id,
               title: book.title,
               description: book.description,
               language: book.language,
               subjects: ["fiction"],
               bisac_codes: book.bisac_codes,
               visibility_tier: book.visibility_tier,
               created_at: book.created_at,
               updated_at: book.updated_at
             }

      refute Map.has_key?(result.book, :author)
      refute Map.has_key?(result.book, :editions)

      # Seller matches User @derive {Jason.Encoder, only: [...]} — full user shape
      assert result.seller.id == seller.id
      assert result.seller.email == seller.email
      assert result.seller.display_name == "Alice"
      assert result.seller.role == seller.role
      assert Map.has_key?(result.seller, :created_at)
      assert Map.has_key?(result.seller, :updated_at)
    end

    test "listing/1 produces identical output to Jason.encode! on a raw Listing struct" do
      book = insert(:book, author: nil)
      seller = insert(:user, display_name: "Bob")
      listing = insert(:listing, book: book, seller: seller)

      jason_output =
        listing
        |> Jason.encode!()
        |> Jason.decode!()

      proto_output =
        listing
        |> ProtoJSON.listing()
        |> Jason.encode!()
        |> Jason.decode!()

      assert proto_output == jason_output
    end

    test "handles not-loaded book and seller" do
      listing = insert(:listing)

      listing = %{
        listing
        | book: %Ecto.Association.NotLoaded{
            __field__: :book,
            __owner__: Stacks.Marketplace.Listing,
            __cardinality__: :one
          },
          seller: %Ecto.Association.NotLoaded{
            __field__: :seller,
            __owner__: Stacks.Marketplace.Listing,
            __cardinality__: :one
          }
      }

      result = ProtoJSON.listing(listing)

      assert result.book == nil
      assert result.seller == nil
    end
  end

  # ---------------------------------------------------------------------------
  # placement_formats/1
  # ---------------------------------------------------------------------------

  describe "placement_formats/1" do
    test "returns id and formats" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user)

      placement =
        insert(:placement,
          bookshelf: bookshelf,
          book: build(:book),
          formats: ["physical", "ebook"]
        )

      result = ProtoJSON.placement_formats(placement)

      assert result == %{id: placement.id, formats: ["physical", "ebook"]}
    end

    test "preserves nil formats (matches controller — no nil guard)" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user)
      placement = insert(:placement, bookshelf: bookshelf, book: build(:book), formats: nil)

      result = ProtoJSON.placement_formats(placement)

      assert result.formats == nil
    end
  end

  # ---------------------------------------------------------------------------
  # visibility_update/1
  # ---------------------------------------------------------------------------

  describe "visibility_update/1" do
    test "returns id and visibility for a bookshelf" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, visibility: "platform")

      result = ProtoJSON.visibility_update(bookshelf)

      assert result == %{id: bookshelf.id, visibility: "platform"}
    end

    test "returns id and visibility for a placement" do
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user)
      placement = insert(:placement, bookshelf: bookshelf, book: build(:book))

      result = ProtoJSON.visibility_update(placement)

      assert result == %{id: placement.id, visibility: placement.visibility}
    end
  end

  # ---------------------------------------------------------------------------
  # association_action/1
  # ---------------------------------------------------------------------------

  describe "association_action/1" do
    test "returns id, book_id, and visible" do
      assoc = insert(:post_book_association, visible: true)

      result = ProtoJSON.association_action(assoc)

      assert result == %{id: assoc.id, book_id: assoc.book_id, visible: true}
    end

    test "returns visible: false for dismissed association" do
      assoc = insert(:post_book_association, visible: false)

      result = ProtoJSON.association_action(assoc)

      assert result.visible == false
    end
  end
end
