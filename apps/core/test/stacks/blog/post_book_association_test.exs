defmodule Stacks.Blog.PostBookAssociationTest do
  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Blog
  alias Stacks.Blog.PostBookAssociation

  describe "post_book_association_changeset/2" do
    test "is valid with post, book, confidence, and source" do
      post = insert(:post)
      book = insert(:book)

      changeset =
        Blog.post_book_association_changeset(%PostBookAssociation{}, %{
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
        Blog.post_book_association_changeset(%PostBookAssociation{}, %{
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
        Blog.post_book_association_changeset(%PostBookAssociation{}, %{
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
        Blog.post_book_association_changeset(%PostBookAssociation{}, %{
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
        Blog.post_book_association_changeset(%PostBookAssociation{}, %{
          post_id: post.id,
          book_id: book.id,
          confidence: 0.9,
          source: "manual"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :visible) == true
    end

    # ⛔ A CONFIDENCE OF 12.0 WOULD HAVE BEEN STORED AND SHOWN TO THE AUTHOR.
    # The only bound was a clamp inside the JSON parser — correct for the
    # model's answer, silent about every other writer of this column.
    test "a confidence above one is refused" do
      post = insert(:post, user: insert(:user))
      book = insert(:book)

      changeset =
        Blog.post_book_association_changeset(%PostBookAssociation{}, %{
          post_id: post.id,
          book_id: book.id,
          confidence: 12.0,
          source: "llm"
        })

      refute changeset.valid?
      assert "must be less than or equal to 1.0" in errors_on(changeset).confidence
    end

    test "a negative confidence is refused" do
      post = insert(:post, user: insert(:user))
      book = insert(:book)

      changeset =
        Blog.post_book_association_changeset(%PostBookAssociation{}, %{
          post_id: post.id,
          book_id: book.id,
          confidence: -0.5,
          source: "llm"
        })

      refute changeset.valid?
      assert "must be greater than or equal to 0.0" in errors_on(changeset).confidence
    end

    # ⬛ ANTI-VACUITY: the bounds themselves are VALID, or a changeset that
    # rejected everything would satisfy both cases above.
    test "the bounds themselves are accepted" do
      post = insert(:post, user: insert(:user))
      book = insert(:book)

      for value <- [0.0, 1.0] do
        changeset =
          Blog.post_book_association_changeset(%PostBookAssociation{}, %{
            post_id: post.id,
            book_id: book.id,
            confidence: value,
            source: "llm"
          })

        assert changeset.valid?, "#{value} is in range and must be accepted"
      end
    end

    # ⚖️ AND THE DATABASE REFUSES IT TOO, which is the claim that matters: the
    # changeset is one writer's path, the CHECK holds for all of them. Driven
    # by bypassing the changeset the way a backfill or a raw insert would.
    test "the database refuses an out-of-range confidence even without the changeset" do
      post = insert(:post, user: insert(:user))
      book = insert(:book)

      assert_raise Postgrex.Error, ~r/post_book_associations_confidence_in_range/, fn ->
        Core.Repo.query!(
          """
          INSERT INTO op.post_book_associations
            (id, post_id, book_id, confidence, source, visible, created_at)
          VALUES (gen_random_uuid(), $1, $2, 12.0, 'llm', true, now())
          """,
          [Ecto.UUID.dump!(post.id), Ecto.UUID.dump!(book.id)]
        )
      end
    end
  end

  describe "what a reader sees when two suggestions tie" do
    # ⛔ THE ORDER WAS UNDETERMINED ON EQUAL CONFIDENCE, and the clamp made
    # that the normal case: `Structured.clamp/1` maps every out-of-range value
    # to exactly `1.0`, so a model answering `1.4` and `2.5` for one book
    # produces an exact tie rather than two distinct scores.
    #
    # ⚖️ A live suggestion must outrank a dismissed one — the same keys the
    # dedup migration uses, so the row that survives a collapse is the row that
    # was on top before it.
    test "a live suggestion outranks a dismissed one at equal confidence" do
      post = insert(:post, user: insert(:user))
      dismissed_book = insert(:book)
      live_book = insert(:book)

      insert(:post_book_association,
        post: post,
        book: dismissed_book,
        confidence: 1.0,
        visible: false
      )

      insert(:post_book_association,
        post: post,
        book: live_book,
        confidence: 1.0,
        visible: true
      )

      ordered = Blog.list_associations(post.id)

      assert length(ordered) == 2,
             "anti-vacuity: both rows must be present, or the ordering claim is empty"

      assert hd(ordered).book_id == live_book.id,
             "a dismissed suggestion came first at equal confidence — the reader's top " <>
               "row is decided by the plan rather than by a rule"
    end

    # ⬛ AND CONFIDENCE STILL WINS, or an ordering that sorted on `visible`
    # first would satisfy the case above while burying a better match.
    test "confidence still outranks visibility" do
      post = insert(:post, user: insert(:user))
      strong_dismissed = insert(:book)
      weak_live = insert(:book)

      insert(:post_book_association,
        post: post,
        book: strong_dismissed,
        confidence: 0.95,
        visible: false
      )

      insert(:post_book_association,
        post: post,
        book: weak_live,
        confidence: 0.40,
        visible: true
      )

      assert hd(Blog.list_associations(post.id)).book_id == strong_dismissed.id,
             "visibility outranked confidence — a weaker match is now shown first"
    end
  end
end
