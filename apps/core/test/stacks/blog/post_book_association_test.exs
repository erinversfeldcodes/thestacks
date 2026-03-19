defmodule Stacks.Blog.PostBookAssociationTest do
  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Blog.PostBookAssociation

  describe "changeset/2" do
    test "is valid with post, book, confidence, and source" do
      post = insert(:post)
      book = insert(:book)

      changeset =
        PostBookAssociation.changeset(%PostBookAssociation{}, %{
          post_id: post.id,
          book_id: book.id,
          confidence: 0.9,
          reasoning: "Thematic overlap.",
          source: "llm",
          visible: true
        })

      assert changeset.valid?
    end

    test "is invalid without post_id" do
      book = insert(:book)

      changeset =
        PostBookAssociation.changeset(%PostBookAssociation{}, %{
          book_id: book.id,
          confidence: 0.9,
          source: "llm"
        })

      refute changeset.valid?
      assert %{post_id: [_ | _]} = errors_on(changeset)
    end

    test "is invalid without book_id" do
      post = insert(:post)

      changeset =
        PostBookAssociation.changeset(%PostBookAssociation{}, %{
          post_id: post.id,
          confidence: 0.9,
          source: "llm"
        })

      refute changeset.valid?
      assert %{book_id: [_ | _]} = errors_on(changeset)
    end

    test "is invalid with source not in allowed values" do
      post = insert(:post)
      book = insert(:book)

      changeset =
        PostBookAssociation.changeset(%PostBookAssociation{}, %{
          post_id: post.id,
          book_id: book.id,
          confidence: 0.9,
          source: "genie"
        })

      refute changeset.valid?
      assert %{source: [_ | _]} = errors_on(changeset)
    end

    test "visible defaults to true in changeset" do
      post = insert(:post)
      book = insert(:book)

      changeset =
        PostBookAssociation.changeset(%PostBookAssociation{}, %{
          post_id: post.id,
          book_id: book.id,
          confidence: 0.9,
          source: "manual"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :visible) == true
    end
  end
end
