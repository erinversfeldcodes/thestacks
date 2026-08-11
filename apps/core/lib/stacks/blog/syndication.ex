defmodule Stacks.Blog.Syndication do
  @moduledoc """
    POSSE: the post here is canonical; the Substack copy says so.
    Substack has no write API, so the only honest mechanisms are the two
    built here: the public blog Atom feed (`feed_xml/1`, polled by Substack's
    RSS import) and a canonical-tagged export (`export/2`, paste-ready
    HTML/Markdown with the canonical link baked in). Nothing here sends a
    request to Substack and the platform never holds a Substack credential.

    ⛔ The feed is anonymous-only by design: its consumer is a third-party
    fetcher that republishes whatever it reads, so it must only ever contain
    what an anonymous viewer could see.
  """

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Blog.Post
  alias Stacks.Blog.PostSyndication
  alias Stacks.Events
  alias Stacks.Feeds

  @atom_ns "http://www.w3.org/2005/Atom"
  @feed_limit 20
  @valid_methods ~w(rss export)
  @valid_url_schemes ~w(http https)

  @doc """
    The posts the syndication feed serves: public AND syndicated AND published,
    newest first, capped at #{@feed_limit}. Served by the partial index
    `blog_posts_user_public_published_idx`.
  """
  @spec feed_posts(binary()) :: [Post.t()]
  def feed_posts(user_id) do
    Post
    |> where(
      [p],
      p.user_id == ^user_id and p.visibility == "public" and p.syndicated and
        not is_nil(p.published_at)
    )
    |> order_by([p], desc: p.published_at)
    |> limit(@feed_limit)
    |> Repo.all()
  end

  @doc """
    Renders the writer's blog feed as Atom 1.0. Returns `{xml, etag}`.

    An empty feed is a valid, empty Atom document — HTTP 200, never 404, because
    a 404 makes Substack drop the subscription (story sad-paths).
  """
  @spec feed_xml(Stacks.Accounts.User.t()) :: {String.t(), String.t()}
  def feed_xml(user) do
    posts = feed_posts(user.id)
    display_name = user.display_name || user.handle || "A reader"

    updated =
      posts
      |> Enum.map(& &1.published_at)
      |> Enum.max(DateTime, fn -> DateTime.utc_now() end)
      |> DateTime.to_iso8601()

    entries = Enum.map_join(posts, "\n", &feed_entry/1)

    xml =
      """
      <?xml version="1.0" encoding="utf-8"?>
      <feed xmlns="#{@atom_ns}">
        <title>#{escape_xml(display_name)} — Writing on The Stacks</title>
        <id>urn:stacks:blogfeed:#{user.id}</id>
        <updated>#{updated}</updated>
        <author>
          <name>#{escape_xml(display_name)}</name>
        </author>
        <link rel="alternate" type="text/html" href="#{host_url()}/u/#{user.handle}" />
        <link rel="self" type="application/atom+xml" href="#{host_url()}/api/feeds/u/#{user.handle}/blog" />
      #{entries}
      </feed>
      """
      |> String.trim()

    {xml, Feeds.compute_etag(xml)}
  end

  defp feed_entry(post) do
    canonical = canonical_url(post)

    content =
      escape_xml(
        "<p><em>Originally published on <a href=\"#{canonical}\">The Stacks</a>.</em></p>\n" <>
          body_as_html(post.body)
      )

    """
      <entry>
        <title>#{escape_xml(post.title)}</title>
        <id>urn:stacks:post:#{post.id}</id>
        <updated>#{DateTime.to_iso8601(post.updated_at)}</updated>
        <published>#{DateTime.to_iso8601(post.published_at)}</published>
        <link rel="alternate" type="text/html" href="#{canonical}" />
        <content type="html">#{content}</content>
      </entry>\
    """
  end

  @doc """
    The paste-ready copy for Substack's editor: the post's body wrapped in the
    canonical framing. The opening and closing lines are the POSSE claim — they
    are the artefact, not decoration.
  """
  @spec export(Post.t(), String.t()) :: %{
          format: String.t(),
          canonical_url: String.t(),
          body: String.t()
        }
  def export(%Post{} = post, format) when format in ["html", "markdown"] do
    canonical = canonical_url(post)

    body =
      case format do
        "markdown" ->
          """
          *Originally published on [The Stacks](#{canonical}).*

          #{post.body}

          ---

          *Originally published on [The Stacks](#{canonical}).*
          """

        "html" ->
          """
          <link rel="canonical" href="#{canonical}" />
          <p><em>Originally published on <a href="#{canonical}">The Stacks</a>.</em></p>
          #{body_as_html(post.body)}
          <hr />
          <p><em>Originally published on <a href="#{canonical}">The Stacks</a>.</em></p>
          """
      end

    %{format: format, canonical_url: canonical, body: String.trim(body)}
  end

  @doc """
    Records one act of syndication, storing the canonical URL AS IT IS NOW —
    stored rather than derived, so a future host change cannot silently rewrite
    what the third-party copy actually says. Emits `post.syndicated` (no title,
    no body, no URL — a slug derived from a title is title data by another name).
  """
  @spec record(Post.t(), String.t()) ::
          {:ok, PostSyndication.t()} | {:error, Ecto.Changeset.t()}
  def record(%Post{} = post, method) do
    %PostSyndication{}
    |> syndication_changeset(%{
      post_id: post.id,
      target: "substack",
      method: method,
      canonical_url: canonical_url(post)
    })
    |> Repo.insert()
    |> case do
      {:ok, syndication} ->
        Events.emit_safe(%{
          event_type: "post.syndicated",
          aggregate_type: "post",
          aggregate_id: post.id,
          payload: %{target: syndication.target, method: syndication.method}
        })

        {:ok, syndication}

      error ->
        error
    end
  end

  @doc """
    Closes the POSSE loop: the writer pastes the live Substack URL back in
    ("Also published at"). Only `http`/`https` — the value is a user-supplied
    outbound link and is rendered with `rel="nofollow noopener"` client-side.
  """
  @spec set_syndicated_url(PostSyndication.t(), String.t()) ::
          {:ok, PostSyndication.t()} | {:error, Ecto.Changeset.t()}
  def set_syndicated_url(%PostSyndication{} = syndication, url) do
    syndication
    |> syndication_changeset(%{syndicated_url: url})
    |> Repo.update()
  end

  @doc "Fetches a syndication scoped to its post."
  @spec get_syndication(Post.t(), binary()) :: PostSyndication.t() | nil
  def get_syndication(%Post{id: post_id}, sid) do
    PostSyndication
    |> where([s], s.post_id == ^post_id and s.id == ^sid)
    |> Repo.one()
  rescue
    Ecto.Query.CastError -> nil
  end

  @doc "All syndications for a post, oldest first."
  @spec list_syndications(Post.t()) :: [PostSyndication.t()]
  def list_syndications(%Post{id: post_id}) do
    PostSyndication
    |> where([s], s.post_id == ^post_id)
    |> order_by([s], asc: s.created_at)
    |> Repo.all()
  end

  @doc "Changeset for a syndication record."
  def syndication_changeset(syndication, attrs) do
    syndication
    |> Ecto.Changeset.cast(attrs, [:post_id, :target, :method, :canonical_url, :syndicated_url])
    |> Ecto.Changeset.validate_required([:post_id, :target, :method, :canonical_url])
    |> Ecto.Changeset.validate_inclusion(:target, ["substack"])
    |> Ecto.Changeset.validate_inclusion(:method, @valid_methods)
    |> validate_url(:syndicated_url)
    |> Ecto.Changeset.foreign_key_constraint(:post_id)
  end

  defp validate_url(changeset, field) do
    Ecto.Changeset.validate_change(changeset, field, fn ^field, value ->
      case URI.new(value) do
        {:ok, %URI{scheme: scheme, host: host}}
        when scheme in @valid_url_schemes and is_binary(host) and host != "" ->
          []

        _ ->
          [{field, "must be an http or https address"}]
      end
    end)
  end

  @doc """
    The post's permanent address: `<host>/blog/<uuid>`. The UUID form is ugly
    and it is PERMANENT, which is the POSSE requirement — slugs are deferred
    deliberately (story §12: a slug adds a uniqueness surface, a redirect
    obligation, and a second address for the same post — three ways to break a
    canonical link).
  """
  @spec canonical_url(Post.t()) :: String.t()
  def canonical_url(%Post{id: id}), do: "#{host_url()}/blog/#{id}"

  defp host_url, do: CoreWeb.Endpoint.url()

  defp body_as_html(body) do
    body
    |> String.split(~r/\n{2,}/)
    |> Enum.map_join("\n", fn para -> "<p>#{String.trim(para)}</p>" end)
  end

  defp escape_xml(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
