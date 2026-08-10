defmodule Stacks.Blog.SyndicationTest do
  use Core.DataCase, async: true

  import Ecto.Query
  import Stacks.Factory

  alias Stacks.Blog.PostSyndication
  alias Stacks.Blog.Syndication
  alias Stacks.Events.EventLog
  alias Stacks.GDPR.Deletion

  defp public_post(attrs \\ []) do
    insert(
      :post,
      Keyword.merge(
        [visibility: "public", syndicated: true, published_at: DateTime.utc_now()],
        attrs
      )
    )
  end

  describe "feed_posts/1 — the feed's visibility gate" do
    test "serves ONLY public + syndicated + published posts" do
      user = insert(:user)

      visible = public_post(user: user, title: "In the feed")

      _platform =
        insert(:post, user: user, visibility: "platform", published_at: DateTime.utc_now())

      _unsyndicated = public_post(user: user, syndicated: false, title: "Opted out")
      _draft = insert(:post, user: user, visibility: "public", syndicated: true)
      _someone_elses = public_post(title: "Not mine")

      assert [post] = Syndication.feed_posts(user.id)
      assert post.id == visible.id
    end
  end

  describe "feed_xml/1" do
    test "every entry carries the canonical link AND the visible originally-published line" do
      user = insert(:user)
      post = public_post(user: user, title: "The Anatomy of Melancholy")

      {xml, etag} = Syndication.feed_xml(user)

      canonical = Syndication.canonical_url(post)
      assert xml =~ ~s(<link rel="alternate" type="text/html" href="#{canonical}" />)
      # Inside <content>, escaped — a visible sentence survives any importer.
      assert xml =~ "Originally published on"
      assert xml =~ "The Anatomy of Melancholy"
      assert etag == Stacks.Feeds.compute_etag(xml)
    end

    test "a writer with no public posts gets a VALID empty feed, not an error" do
      user = insert(:user)
      {xml, _etag} = Syndication.feed_xml(user)

      assert xml =~ ~s(<feed xmlns="http://www.w3.org/2005/Atom">)
      refute xml =~ "<entry>"
    end

    test "post bodies are escaped — markup in a post cannot break the XML" do
      user = insert(:user)
      public_post(user: user, body: "One </feed> weird & trick")

      {xml, _} = Syndication.feed_xml(user)
      assert xml =~ "&lt;/feed&gt; weird &amp; trick"
      refute xml =~ "One </feed>"
    end
  end

  describe "export/2" do
    test "markdown export opens and closes with the canonical claim" do
      post = public_post()

      %{format: "markdown", canonical_url: canonical, body: body} =
        Syndication.export(post, "markdown")

      assert String.starts_with?(body, "*Originally published on [The Stacks](#{canonical}).*")
      assert String.ends_with?(body, "*Originally published on [The Stacks](#{canonical}).*")
      assert body =~ post.body
    end

    test "html export carries rel=canonical" do
      post = public_post()
      %{format: "html", canonical_url: canonical, body: body} = Syndication.export(post, "html")

      assert body =~ ~s(<link rel="canonical" href="#{canonical}" />)
      assert body =~ "Originally published on"
    end
  end

  describe "record/2 + set_syndicated_url/2" do
    test "records the canonical URL as it is NOW and emits a counts-only event" do
      post = public_post()

      assert {:ok, syndication} = Syndication.record(post, "export")
      assert syndication.target == "substack"
      assert syndication.canonical_url == Syndication.canonical_url(post)
      assert syndication.syndicated_url == nil

      event =
        Repo.one!(
          from e in EventLog,
            where: e.event_type == "post.syndicated" and e.aggregate_id == ^post.id
        )

      assert event.payload == %{"target" => "substack", "method" => "export"}
    end

    test "closing the loop stores the pasted URL; non-http(s) schemes are refused" do
      post = public_post()
      {:ok, syndication} = Syndication.record(post, "export")

      assert {:error, changeset} =
               Syndication.set_syndicated_url(syndication, "javascript:alert(1)")

      assert %{syndicated_url: [_]} = errors_on(changeset)

      assert {:ok, updated} =
               Syndication.set_syndicated_url(
                 syndication,
                 "https://erin.substack.com/p/melancholy"
               )

      assert updated.syndicated_url == "https://erin.substack.com/p/melancholy"
    end

    test "an unknown method is refused" do
      post = public_post()
      assert {:error, changeset} = Syndication.record(post, "oauth")
      assert %{method: [_]} = errors_on(changeset)
    end
  end

  describe "GDPR — erasure reaches syndication records" do
    test "deleting the post cascades its syndications (and user erasure cascades both hops)" do
      user = insert(:user)
      post = public_post(user: user)
      {:ok, syndication} = Syndication.record(post, "export")

      # The two-hop cascade the story warns about: true today, and this test is
      # what keeps it from going silently untrue if someone weakens an FK.
      assert {:ok, _} = Deletion.delete_user_data(user.id)
      assert nil == Repo.get(PostSyndication, syndication.id)
    end
  end
end
