defmodule Stacks.BlogCommentTest do
  @moduledoc "Tests for Blog comment functions."

  use Core.DataCase, async: true

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Blog

  defp published_post(user) do
    insert(:post, user: user, published_at: DateTime.utc_now())
  end

  describe "list_comments/2" do
    test "returns top-level comments with nested replies" do
      user = insert(:user)
      post = published_post(user)
      commenter = insert(:user)

      parent = insert(:post_comment, post: post, author: commenter, body: "Top level")

      insert(:post_comment,
        post: post,
        author: commenter,
        parent_id: parent.id,
        body: "Reply"
      )

      [top] = Blog.list_comments(post.id, nil)
      assert top.body == "Top level"
      assert length(top.replies) == 1
      assert hd(top.replies).body == "Reply"
    end

    test "excludes comments from blocked users" do
      viewer = insert(:user)
      blocked = insert(:user)
      post = published_post(insert(:user))

      insert(:post_comment, post: post, author: blocked, body: "Hidden")
      insert(:post_comment, post: post, author: viewer, body: "Visible")

      insert(:user_block, blocker: viewer, blocked: blocked)

      comments = Blog.list_comments(post.id, viewer.id)
      assert length(comments) == 1
      assert hd(comments).body == "Visible"
    end

    test "does not filter comments when viewer_id is nil" do
      blocker = insert(:user)
      blocked = insert(:user)
      post = published_post(insert(:user))

      insert(:user_block, blocker: blocker, blocked: blocked)

      insert(:post_comment, post: post, author: blocked, body: "Should be visible anonymously")

      comments = Blog.list_comments(post.id, nil)
      assert length(comments) == 1
      assert hd(comments).body == "Should be visible anonymously"
    end

    test "returns empty list when post has no comments" do
      user = insert(:user)
      post = published_post(user)

      assert [] = Blog.list_comments(post.id, nil)
    end
  end

  describe "create_comment/3" do
    test "creates a comment on a published post" do
      user = insert(:user)
      post = published_post(user)
      commenter = insert(:user)

      assert {:ok, comment} =
               Blog.create_comment(post.id, commenter.id, %{body: "Nice post!"})

      assert comment.body == "Nice post!"
      assert comment.post_id == post.id
      assert comment.author_id == commenter.id
    end

    test "the returned comment carries its timestamp, because the caller serialises it" do
      user = insert(:user)
      post = published_post(user)
      commenter = insert(:user)

      assert {:ok, comment} =
               Blog.create_comment(post.id, commenter.id, %{body: "Timestamped?"})

      # The column's NOW() default fills the ROW, not the struct. `create/2`
      # serialises exactly this struct into its 201, so a nil here is a comment
      # that reaches its own author without a timestamp while everyone who
      # reloads the thread sees one.
      assert comment.created_at, "the struct handed to the serialiser must carry created_at"

      reloaded = Repo.get(Stacks.Blog.PostComment, comment.id)
      assert reloaded.created_at == comment.created_at, "and it must be the value actually stored"
    end

    test "returns :post_not_found for unpublished post" do
      user = insert(:user)
      post = insert(:post, user: user, published_at: nil)

      assert {:error, :post_not_found} =
               Blog.create_comment(post.id, user.id, %{body: "Hello"})
    end

    test "returns :post_not_found for non-existent post" do
      user = insert(:user)
      fake_id = Ecto.UUID.generate()

      assert {:error, :post_not_found} =
               Blog.create_comment(fake_id, user.id, %{body: "Hello"})
    end

    test "returns :parent_not_found for invalid parent_id" do
      user = insert(:user)
      post = published_post(user)
      fake_id = Ecto.UUID.generate()

      assert {:error, :parent_not_found} =
               Blog.create_comment(post.id, user.id, %{body: "Reply", parent_id: fake_id})
    end

    test "returns changeset error for empty body" do
      user = insert(:user)
      post = published_post(user)

      assert {:error, %Ecto.Changeset{}} =
               Blog.create_comment(post.id, user.id, %{body: ""})
    end

    test "emits post.comment_created event" do
      user = insert(:user)
      post = published_post(user)
      commenter = insert(:user)

      assert {:ok, comment} =
               Blog.create_comment(post.id, commenter.id, %{body: "Nice post!"})

      events =
        Repo.all(
          from e in "event_log",
            prefix: "op",
            where: e.event_type == "post.comment_created" and e.aggregate_id == ^post.id,
            select: e.payload
        )

      assert length(events) == 1
      payload = hd(events)
      assert payload["comment_id"] == comment.id
      assert payload["author_id"] == commenter.id
    end

    test "creates a reply with valid parent_id" do
      user = insert(:user)
      post = published_post(user)
      commenter = insert(:user)

      parent = insert(:post_comment, post: post, author: commenter, body: "Top level")

      assert {:ok, reply} =
               Blog.create_comment(post.id, commenter.id, %{
                 body: "A reply",
                 parent_id: parent.id
               })

      assert reply.parent_id == parent.id
      assert reply.body == "A reply"
    end
  end

  describe "delete_comment/2" do
    test "comment author can delete their own comment" do
      user = insert(:user)
      post = published_post(user)
      commenter = insert(:user)
      comment = insert(:post_comment, post: post, author: commenter)

      assert :ok = Blog.delete_comment(comment.id, commenter.id)
    end

    test "post author can delete any comment on their post" do
      post_author = insert(:user)
      post = published_post(post_author)
      commenter = insert(:user)
      comment = insert(:post_comment, post: post, author: commenter)

      assert :ok = Blog.delete_comment(comment.id, post_author.id)
    end

    test "unrelated user cannot delete comment" do
      user = insert(:user)
      post = published_post(user)
      commenter = insert(:user)
      other = insert(:user)
      comment = insert(:post_comment, post: post, author: commenter)

      assert {:error, :unauthorized} = Blog.delete_comment(comment.id, other.id)
    end

    test "returns :not_found for non-existent comment" do
      user = insert(:user)
      fake_id = Ecto.UUID.generate()

      assert {:error, :not_found} = Blog.delete_comment(fake_id, user.id)
    end
  end
end
