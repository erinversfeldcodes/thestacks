defmodule Stacks.SocialFeedTest do
  use Core.DataCase, async: true

  import Ecto.Query
  import Stacks.Factory

  alias Stacks.Social
  alias Stacks.Social.GroupMember

  setup do
    owner = insert(:user)
    viewer = insert(:user)
    {:ok, group} = Social.create_group(owner.id, %{name: "Test Group", type: "close_friends"})
    insert(:group_member, group: group, user: viewer)
    %{owner: owner, viewer: viewer, group: group}
  end

  describe "feed_for_group/3" do
    test "returns group-visible placement in feed", %{owner: owner, group: group, viewer: viewer} do
      bookshelf = insert(:bookshelf, user: owner)
      book = insert(:book)

      insert(:placement,
        bookshelf: bookshelf,
        book: book,
        visibility: "group",
        placed_at: DateTime.utc_now()
      )

      assert {:ok, items} = Social.feed_for_group(group.id, viewer.id)
      assert length(items) == 1
      assert hd(items).type == :placement_created
      assert hd(items).book_title == book.title
    end

    test "excludes owner-only placements", %{owner: owner, group: group, viewer: viewer} do
      bookshelf = insert(:bookshelf, user: owner)
      book = insert(:book)

      insert(:placement,
        bookshelf: bookshelf,
        book: book,
        visibility: "owner",
        placed_at: DateTime.utc_now()
      )

      assert {:ok, []} = Social.feed_for_group(group.id, viewer.id)
    end

    test "includes published blog post with platform visibility", %{
      owner: owner,
      group: group,
      viewer: viewer
    } do
      post =
        insert(:post,
          user: owner,
          visibility: "platform",
          published_at: DateTime.utc_now(),
          title: "My Post"
        )

      assert {:ok, items} = Social.feed_for_group(group.id, viewer.id)
      assert length(items) == 1
      assert hd(items).type == :blog_post
      assert hd(items).post_title == post.title
    end

    test "excludes unpublished blog posts", %{owner: owner, group: group, viewer: viewer} do
      insert(:post,
        user: owner,
        visibility: "group",
        published_at: nil
      )

      assert {:ok, []} = Social.feed_for_group(group.id, viewer.id)
    end

    test "returns :unauthorized for non-member", %{group: group} do
      outsider = insert(:user)
      assert {:error, :unauthorized} = Social.feed_for_group(group.id, outsider.id)
    end

    test "returns :not_found for bad group_id", %{viewer: viewer} do
      assert {:error, :not_found} = Social.feed_for_group(Ecto.UUID.generate(), viewer.id)
    end

    test "before cursor excludes newer items", %{owner: owner, group: group, viewer: viewer} do
      bookshelf = insert(:bookshelf, user: owner)
      book = insert(:book)

      old_time = DateTime.add(DateTime.utc_now(), -3600, :second)
      new_time = DateTime.utc_now()

      insert(:placement,
        bookshelf: bookshelf,
        book: book,
        visibility: "group",
        placed_at: old_time
      )

      insert(:placement,
        bookshelf: bookshelf,
        book: insert(:book),
        visibility: "group",
        placed_at: new_time
      )

      cursor = DateTime.add(old_time, 1800, :second)
      assert {:ok, items} = Social.feed_for_group(group.id, viewer.id, before: cursor)
      assert length(items) == 1
      assert hd(items).book_title == book.title
    end

    test "former member content excluded after removal", %{group: group, viewer: viewer} do
      former = insert(:user)
      insert(:group_member, group: group, user: former)

      bookshelf = insert(:bookshelf, user: former)

      insert(:placement,
        bookshelf: bookshelf,
        book: insert(:book),
        visibility: "group",
        placed_at: DateTime.utc_now()
      )

      assert {:ok, items_before} = Social.feed_for_group(group.id, viewer.id)
      assert Enum.any?(items_before, &(&1.user_id == former.id))

      Repo.delete_all(
        from(m in GroupMember, where: m.group_id == ^group.id and m.user_id == ^former.id)
      )

      assert {:ok, items_after} = Social.feed_for_group(group.id, viewer.id)
      refute Enum.any?(items_after, &(&1.user_id == former.id))
    end
  end
end
