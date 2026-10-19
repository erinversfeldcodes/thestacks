defmodule Stacks.BlogTest do
  @moduledoc "Tests for the Stacks.Blog context."

  use Core.DataCase, async: true
  use Oban.Testing, repo: Core.Repo

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.Blog

  defp event_count(event_type) do
    Repo.aggregate(
      from(e in "event_log", prefix: "op", where: e.event_type == ^event_type),
      :count
    )
  end

  defp latest_event_payload(event_type, aggregate_id) do
    Repo.one(
      from(e in "event_log",
        prefix: "op",
        where: e.event_type == ^event_type and e.aggregate_id == ^aggregate_id,
        order_by: [desc: e.occurred_at],
        limit: 1,
        select: e.payload
      )
    )
  end

  describe "create_post/2" do
    test "creates a post with valid attrs" do
      user = insert(:user)
      attrs = %{title: "My First Post", body: "Hello world.", visibility: "owner"}

      assert {:ok, post} = Blog.create_post(user, attrs)
      assert post.title == "My First Post"
      assert post.body == "Hello world."
      assert post.visibility == "owner"
      assert post.user_id == user.id
      assert post.published_at == nil
    end

    test "defaults to draft (visibility: owner) when visibility not supplied" do
      user = insert(:user)
      attrs = %{title: "Draft Post", body: "Some body."}

      assert {:ok, post} = Blog.create_post(user, attrs)
      assert post.visibility == "owner"
    end

    test "enforces visibility ceiling — rejects visibility less restrictive than profile" do
      user = insert(:user, profile_visibility: "owner")
      attrs = %{title: "Public Post", body: "Body.", visibility: "platform"}

      assert {:error, :visibility_ceiling} = Blog.create_post(user, attrs)
    end

    test "allows visibility equal to profile_visibility" do
      user = insert(:user, profile_visibility: "platform")
      attrs = %{title: "Platform Post", body: "Body.", visibility: "platform"}

      assert {:ok, post} = Blog.create_post(user, attrs)
      assert post.visibility == "platform"
    end

    test "allows visibility more restrictive than profile_visibility" do
      user = insert(:user, profile_visibility: "platform")
      attrs = %{title: "Owner Post", body: "Body.", visibility: "owner"}

      assert {:ok, post} = Blog.create_post(user, attrs)
      assert post.visibility == "owner"
    end

    test "returns changeset error when required fields are missing" do
      user = insert(:user)
      attrs = %{title: nil, body: nil}

      assert {:error, %Ecto.Changeset{}} = Blog.create_post(user, attrs)
    end

    test "emits blog.post_created event on success" do
      user = insert(:user)
      before_count = event_count("blog.post_created")

      Blog.create_post(user, %{title: "Event Post", body: "Body."})

      assert event_count("blog.post_created") == before_count + 1
    end

    test "blog.post_created event payload is UUID-only (user_id + visibility, no free-text title)" do
      user = insert(:user, profile_visibility: "platform")

      {:ok, post} =
        Blog.create_post(user, %{
          title: "Payload Post",
          body: "Body.",
          visibility: "platform"
        })

      payload = latest_event_payload("blog.post_created", post.id)

      assert payload["user_id"] == user.id
      assert payload["visibility"] == "platform"
      refute Map.has_key?(payload, "title")
    end
  end

  describe "update_post/3" do
    test "updates a post when called by the owner" do
      user = insert(:user)
      post = insert(:post, user: user)

      assert {:ok, updated} = Blog.update_post(post, user, %{title: "Updated Title"})
      assert updated.title == "Updated Title"
    end

    test "returns :unauthorized when called by a non-owner" do
      owner = insert(:user)
      other = insert(:user)
      post = insert(:post, user: owner)

      assert {:error, :unauthorized} = Blog.update_post(post, other, %{title: "Hacked"})
    end

    test "enforces visibility ceiling on update" do
      user = insert(:user, profile_visibility: "owner")
      post = insert(:post, user: user, visibility: "owner")

      assert {:error, :visibility_ceiling} =
               Blog.update_post(post, user, %{visibility: "platform"})
    end

    test "emits blog.post_updated event on success" do
      user = insert(:user)
      post = insert(:post, user: user)
      before_count = event_count("blog.post_updated")

      Blog.update_post(post, user, %{title: "New Title"})

      assert event_count("blog.post_updated") == before_count + 1
    end

    test "blog.post_updated event payload is UUID-only (user_id + visibility, no free-text title)" do
      user = insert(:user, profile_visibility: "platform")
      post = insert(:post, user: user, visibility: "platform", title: "Original")

      {:ok, _updated} =
        Blog.update_post(post, user, %{title: "Updated Title", visibility: "owner"})

      payload = latest_event_payload("blog.post_updated", post.id)

      assert payload["user_id"] == user.id
      assert payload["visibility"] == "owner"
      refute Map.has_key?(payload, "title")
    end
  end

  describe "publish_post/2" do
    test "sets published_at timestamp" do
      user = insert(:user)
      post = insert(:post, user: user, published_at: nil)

      assert {:ok, published} = Blog.publish_post(post, user)
      assert published.published_at != nil
    end

    test "returns :unauthorized when called by non-owner" do
      owner = insert(:user)
      other = insert(:user)
      post = insert(:post, user: owner, published_at: nil)

      assert {:error, :unauthorized} = Blog.publish_post(post, other)
    end

    test "emits blog.post_published event" do
      user = insert(:user)
      post = insert(:post, user: user, published_at: nil)
      before_count = event_count("blog.post_published")

      Blog.publish_post(post, user)

      assert event_count("blog.post_published") == before_count + 1
    end
  end

  describe "delete_post/2" do
    test "deletes a post when called by the owner" do
      user = insert(:user)
      post = insert(:post, user: user)

      assert {:ok, _deleted} = Blog.delete_post(post, user)
      assert Blog.get_post(post.id) == nil
    end

    test "returns :unauthorized when called by a non-owner" do
      owner = insert(:user)
      other = insert(:user)
      post = insert(:post, user: owner)

      assert {:error, :unauthorized} = Blog.delete_post(post, other)
      assert Blog.get_post(post.id) != nil
    end

    test "emits blog.post_deleted event on success" do
      user = insert(:user)
      post = insert(:post, user: user)
      before_count = event_count("blog.post_deleted")

      Blog.delete_post(post, user)

      assert event_count("blog.post_deleted") == before_count + 1
    end
  end

  describe "get_post/1" do
    test "returns a post by ID" do
      user = insert(:user)
      post = insert(:post, user: user)

      fetched = Blog.get_post(post.id)
      assert fetched.id == post.id
      assert fetched.title == post.title
    end

    test "returns nil for nonexistent ID" do
      assert Blog.get_post(Ecto.UUID.generate()) == nil
    end
  end

  describe "list_user_posts/2" do
    test "owner sees all posts including unpublished drafts" do
      user = insert(:user, profile_visibility: "platform")
      _draft = insert(:post, user: user, visibility: "owner", published_at: nil)

      _published =
        insert(:post, user: user, visibility: "platform", published_at: DateTime.utc_now())

      posts = Blog.list_user_posts(user.id, {:platform_user, user.id})
      assert length(posts) == 2
    end

    test "non-owner sees only published posts" do
      user = insert(:user, profile_visibility: "platform")
      viewer = insert(:user)
      _draft = insert(:post, user: user, visibility: "platform", published_at: nil)

      _published =
        insert(:post, user: user, visibility: "platform", published_at: DateTime.utc_now())

      posts = Blog.list_user_posts(user.id, {:platform_user, viewer.id})
      assert length(posts) == 1
    end

    test "unauthenticated viewer sees only published public posts" do
      user = insert(:user, profile_visibility: "public")
      _draft = insert(:post, user: user, visibility: "public", published_at: nil)

      _published =
        insert(:post, user: user, visibility: "public", published_at: DateTime.utc_now())

      posts = Blog.list_user_posts(user.id, :unauthenticated)
      assert length(posts) == 1
    end

    test "non-owner cannot see owner-only posts even if published" do
      user = insert(:user, profile_visibility: "platform")
      viewer = insert(:user)

      _owner_only =
        insert(:post, user: user, visibility: "owner", published_at: DateTime.utc_now())

      posts = Blog.list_user_posts(user.id, {:platform_user, viewer.id})
      assert posts == []
    end
  end

  describe "list_user_posts/2 public visibility" do
    test "unauthenticated sees only published + public-visible posts" do
      user = insert(:user, profile_visibility: "public")

      _public_published =
        insert(:post, user: user, visibility: "public", published_at: DateTime.utc_now())

      _owner_only_published =
        insert(:post, user: user, visibility: "owner", published_at: DateTime.utc_now())

      _public_draft = insert(:post, user: user, visibility: "public", published_at: nil)

      _platform_published =
        insert(:post, user: user, visibility: "platform", published_at: DateTime.utc_now())

      posts = Blog.list_user_posts(user.id, :unauthenticated)
      assert length(posts) == 1
    end
  end

  describe "tighten_posts_to_ceiling/2" do
    test "tightens posts more visible than the new ceiling" do
      user = insert(:user, profile_visibility: "platform")
      post = insert(:post, user: user, visibility: "platform")

      assert {:ok, count} = Blog.tighten_posts_to_ceiling(user.id, "owner")
      assert count == 1

      reloaded = Repo.get!(Blog.Post, post.id)
      assert reloaded.visibility == "owner"
    end

    test "leaves posts already at or below the ceiling unchanged" do
      user = insert(:user, profile_visibility: "platform")
      owner_post = insert(:post, user: user, visibility: "owner")
      platform_post = insert(:post, user: user, visibility: "platform")

      assert {:ok, count} = Blog.tighten_posts_to_ceiling(user.id, "platform")
      assert count == 0

      assert Repo.get!(Blog.Post, owner_post.id).visibility == "owner"
      assert Repo.get!(Blog.Post, platform_post.id).visibility == "platform"
    end

    test "returns the count of tightened posts" do
      user = insert(:user, profile_visibility: "platform")
      _p1 = insert(:post, user: user, visibility: "platform")
      _p2 = insert(:post, user: user, visibility: "platform")
      _p3 = insert(:post, user: user, visibility: "owner")

      assert {:ok, 2} = Blog.tighten_posts_to_ceiling(user.id, "owner")
    end

    test "runs in a transaction (all or nothing)" do
      user = insert(:user, profile_visibility: "platform")
      _p1 = insert(:post, user: user, visibility: "platform")
      _p2 = insert(:post, user: user, visibility: "platform")

      assert {:ok, 2} = Blog.tighten_posts_to_ceiling(user.id, "owner")

      posts =
        from(p in Blog.Post, where: p.user_id == ^user.id)
        |> Repo.all()

      assert Enum.all?(posts, &(&1.visibility == "owner"))
    end

    test "does not affect another user's posts" do
      user = insert(:user, profile_visibility: "platform")
      other = insert(:user, profile_visibility: "platform")
      _user_post = insert(:post, user: user, visibility: "platform")
      other_post = insert(:post, user: other, visibility: "platform")

      Blog.tighten_posts_to_ceiling(user.id, "owner")

      assert Repo.get!(Blog.Post, other_post.id).visibility == "platform"
    end
  end

  describe "book_ids_with_user_writing/2" do
    test "returns the ids of books the user has written a visible association about" do
      user = insert(:user)
      written = insert(:book)
      unwritten = insert(:book)
      post = insert(:post, user: user)
      insert(:post_book_association, post: post, book: written, visible: true)

      result = Blog.book_ids_with_user_writing(user.id, [written.id, unwritten.id])

      assert written.id in result
      refute unwritten.id in result
    end

    test "excludes invisible (unconfirmed) associations" do
      user = insert(:user)
      book = insert(:book)
      post = insert(:post, user: user)
      insert(:post_book_association, post: post, book: book, visible: false)

      assert Blog.book_ids_with_user_writing(user.id, [book.id]) == []
    end

    test "excludes another user's writing about the same book" do
      user = insert(:user)
      other = insert(:user)
      book = insert(:book)
      other_post = insert(:post, user: other)
      insert(:post_book_association, post: other_post, book: book, visible: true)

      assert Blog.book_ids_with_user_writing(user.id, [book.id]) == []
    end

    test "empty book_ids short-circuits to an empty list" do
      user = insert(:user)
      assert Blog.book_ids_with_user_writing(user.id, []) == []
    end
  end

  describe "public post listing — paging past what the reader cannot see" do
    # ⛔ The feed read the newest window and stopped there, with no cursor of any
    # kind. A short page is fine and deliberate — the window is read before the
    # visibility filter runs — but a short page nobody can page past means the
    # corpus has an unreachable tail. A reader excluded from the newest window saw
    # an EMPTY feed while older posts they were welcome to read sat behind it, and
    # no request they could make would reach them.
    #
    # ⚠️ These tests drive the window at `limit: 2` rather than the production 50.
    # Seeding 51 posts to exercise the real default would be slow and would prove
    # the same thing; what matters is that more than one window exists.

    defp author_with_public_profile do
      insert(:user, profile_visibility: "public")
    end

    defp published_post(author, visibility, seconds_ago) do
      insert(:post,
        user: author,
        visibility: visibility,
        published_at: DateTime.add(DateTime.utc_now(), -seconds_ago, :second)
      )
    end

    test "a reader invisible to the whole first window still reaches the posts behind it" do
      # This is the defect, in the smallest shape that holds it. The two newest
      # posts are `platform`, which an anonymous reader may not see; the third is
      # `public` and is theirs to read. With a window of two, the first page
      # therefore returns NOTHING — and before the cursor existed, nothing was
      # also the final answer.
      author = author_with_public_profile()
      _newest = published_post(author, "platform", 30)
      _second = published_post(author, "platform", 60)
      oldest = published_post(author, "public", 90)

      assert {:ok, %{posts: [], next_cursor: cursor}} =
               Blog.page_public_posts(:unauthenticated, limit: 2)

      # ⚠️ The cursor has to come from the last row SCANNED, not the last row
      # returned. There is no last returned row here, so a cursor derived from the
      # visible posts could not exist — and a feed that stopped on an empty page
      # would be the same dead end one window further in.
      assert is_binary(cursor),
             "an empty page with more corpus behind it must still carry a cursor, or the " <>
               "reader is stuck on a window they can see none of"

      assert {:ok, %{posts: [found], next_cursor: nil}} =
               Blog.page_public_posts(:unauthenticated, limit: 2, after: cursor)

      assert found.id == oldest.id
    end

    test "walking the cursor to the end yields every visible post exactly once" do
      # Guards the two ways a keyset goes wrong even when each page looks right:
      # a boundary that re-reads its own last row (duplicates) or skips past it
      # (a post nobody can ever see).
      author = author_with_public_profile()
      posts = for n <- 1..7, do: published_post(author, "public", n * 10)

      collected = walk_feed(:unauthenticated, nil, [], 0)

      assert Enum.sort(collected) == Enum.sort(Enum.map(posts, & &1.id))
      assert length(Enum.uniq(collected)) == length(collected), "a post was returned twice"
    end

    test "posts sharing a published_at to the microsecond are both reachable" do
      # `published_at` alone is not a total order — two posts published in one
      # transaction collide — so the keyset carries `id` as a tie-break. Without
      # it the boundary row is either repeated forever or dropped.
      author = author_with_public_profile()
      at = DateTime.utc_now()

      a = insert(:post, user: author, visibility: "public", published_at: at)
      b = insert(:post, user: author, visibility: "public", published_at: at)

      # ⚠️ A window of ONE, so the page boundary falls INSIDE the tie. At two the
      # pair fits in one window and a keyset that compared only `published_at`
      # would look correct; the row it loses is the one it hands the cursor over.
      collected = walk_feed(:unauthenticated, nil, [], 0, 1)

      assert Enum.sort(collected) == Enum.sort([a.id, b.id]),
             "a post sharing its published_at with the page's last row was lost at the " <>
               "boundary, so it is reachable by no request at all"
    end

    test "the last page says it is the last one" do
      author = author_with_public_profile()
      published_post(author, "public", 10)

      assert {:ok, %{posts: [_], next_cursor: nil}} =
               Blog.page_public_posts(:unauthenticated, limit: 2)
    end

    test "a cursor the client could not have produced is refused, not silently restarted" do
      author = author_with_public_profile()
      published_post(author, "public", 10)

      for bad <- ["not-base64!!", Base.url_encode64("nonsense", padding: false)] do
        assert {:error, :invalid_cursor} =
                 Blog.page_public_posts(:unauthenticated, after: bad),
               "#{inspect(bad)} was accepted — a client looping on a cursor it cannot form " <>
                 "would re-read the first window forever and see a feed that never advances"
      end
    end

    test "a caller cannot ask for an unbounded window" do
      # Seeds past the ceiling on purpose. A handful of posts would satisfy any
      # limit at all, so the assertion would hold against no clamp whatsoever —
      # the corpus has to be larger than the cap for the cap to be visible.
      author = author_with_public_profile()
      at = DateTime.utc_now()

      for n <- 1..101 do
        insert(:post,
          user: author,
          visibility: "public",
          published_at: DateTime.add(at, -n, :second)
        )
      end

      assert {:ok, %{posts: posts, next_cursor: cursor}} =
               Blog.page_public_posts(:unauthenticated, limit: 1_000_000)

      assert length(posts) == 100,
             "asked for a million rows and got #{length(posts)} — the window is whatever the " <>
               "caller says it is, so one request can read the whole corpus"

      assert is_binary(cursor), "the 101st post must still be reachable"

      # The floor, too: a window of zero reads nothing and would page forever.
      assert {:ok, %{posts: [_]}} = Blog.page_public_posts(:unauthenticated, limit: 0)
    end

    # Pages the whole feed, with a hard stop so a boundary bug becomes a failing
    # assertion rather than a test that never returns.
    defp walk_feed(viewer, cursor, acc, depth, limit \\ 2)

    defp walk_feed(_viewer, _cursor, _acc, depth, _limit) when depth > 20 do
      flunk("the cursor did not reach the end of the feed in 20 pages — it is not advancing")
    end

    defp walk_feed(viewer, cursor, acc, depth, limit) do
      {:ok, %{posts: posts, next_cursor: next}} =
        Blog.page_public_posts(viewer, limit: limit, after: cursor)

      acc = acc ++ Enum.map(posts, & &1.id)

      case next do
        nil -> acc
        _ -> walk_feed(viewer, next, acc, depth + 1, limit)
      end
    end
  end

  describe "public post listing — cost per request" do
    # The public archive is anonymous and the list is capped at 50, so the
    # per-request query count is the whole cost story. Filtering visibility one
    # post at a time issues a block lookup PER POST for a signed-in viewer;
    # Visibility already has a batch context that collapses those to one lookup
    # per distinct author, and this pins that it is actually used.
    test "issues a bounded number of queries regardless of how many posts there are" do
      viewer = insert(:user)

      authors = for _ <- 1..10, do: insert(:user, profile_visibility: "public")

      for author <- authors, _ <- 1..2 do
        insert(:post,
          user: author,
          visibility: "public",
          published_at: DateTime.utc_now() |> DateTime.truncate(:second)
        )
      end

      count = count_queries(fn -> Blog.page_public_posts({:platform_user, viewer.id}) end)

      # 20 posts by 10 authors. One post query, one preload, and block lookups
      # that must be per-author at worst — not per-post.
      assert count <= 13,
             "#{count} queries for 20 posts by 10 authors — visibility is being " <>
               "resolved per post rather than per author"
    end

    defp count_queries(fun) do
      ref = make_ref()
      test_pid = self()

      # Count only the queries this process issues. A telemetry handler runs in
      # the process that emitted the event, so comparing against the test pid
      # filters out every other async test's queries — without this the count
      # was 119 in a full run and 12 in a single-file run, i.e. it was measuring
      # the suite rather than the function.
      :telemetry.attach(
        "query-counter-#{inspect(ref)}",
        [:core, :repo, :query],
        fn _, _, _, _ ->
          if self() == test_pid, do: send(test_pid, {ref, :query})
        end,
        nil
      )

      fun.()
      :telemetry.detach("query-counter-#{inspect(ref)}")
      drain(ref, 0)
    end

    defp drain(ref, n) do
      receive do
        {^ref, :query} -> drain(ref, n + 1)
      after
        0 -> n
      end
    end
  end
end
