defmodule StacksWeb.BlogController do
  @moduledoc """
      CRUD endpoints for blog posts.

      Public GET routes use optional auth so unauthenticated viewers see only
      public/published posts. Authenticated POST/PUT/DELETE routes enforce
      ownership and the visibility ceiling.
  """

  use CoreWeb, :controller

  action_fallback CoreWeb.FallbackController

  alias Stacks.Accounts.Guardian
  alias Stacks.Blog
  alias Stacks.Blog.Syndication
  alias StacksWeb.ProtoJSON

  @doc "GET /api/blog/posts — list published posts for a user (query param: user_id)."
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, %{"user_id" => user_id}) do
    viewer = build_viewer(conn)
    posts = Blog.list_user_posts(user_id, viewer)
    json(conn, %{posts: Enum.map(posts, &ProtoJSON.blog_post/1)})
  end

  def index(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{error: "user_id is required"})
  end

  @doc "GET /api/blog/posts/:id — show a single post."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    viewer = build_viewer(conn)

    case Blog.get_post_for_viewer(id, viewer) do
      nil ->
        {:error, :not_found}

      post ->
        user = Guardian.Plug.current_resource(conn)
        is_owner = user != nil && user.id == post.user_id

        associations =
          post.id
          |> Blog.list_associations()
          |> Enum.filter(fn a -> is_owner || a.visible end)
          |> Enum.map(&ProtoJSON.blog_association(&1, is_owner))

        json(conn, %{post: ProtoJSON.blog_post(post), associations: associations})
    end
  end

  @doc "POST /api/blog/posts — create a new draft post."
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    user = Guardian.Plug.current_resource(conn)

    attrs = %{
      title: params["title"],
      body: params["body"],
      visibility: params["visibility"] || "owner"
    }

    with {:ok, post} <- Blog.create_post(user, attrs) do
      conn
      |> put_status(201)
      |> json(%{post: ProtoJSON.blog_post(post)})
    end
  end

  @doc "PUT /api/blog/posts/:id — update a post."
  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, %{"id" => id} = params) do
    user = Guardian.Plug.current_resource(conn)

    attrs =
      params
      |> Map.take(["title", "body", "visibility", "syndicated"])
      |> atomize_keys()

    with {:ok, post} <- fetch_post(id),
         {:ok, updated_post} <- Blog.update_post(post, user, attrs) do
      json(conn, %{post: ProtoJSON.blog_post(updated_post)})
    end
  end

  @doc "DELETE /api/blog/posts/:id — delete a post."
  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    with {:ok, post} <- fetch_post(id),
         {:ok, _post} <- Blog.delete_post(post, user) do
      json(conn, %{deleted: true})
    end
  end

  @doc "POST /api/blog/posts/:id/publish — publish a draft post."
  @spec publish(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def publish(conn, %{"id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    with {:ok, post} <- fetch_post(id),
         {:ok, published_post} <- Blog.publish_post(post, user) do
      json(conn, %{post: ProtoJSON.blog_post(published_post)})
    end
  end

  @doc """
      GET /api/blog/posts/:id/syndication?format=html|markdown — the canonical-
      tagged, paste-ready copy for Substack.

      Author-only, and only for a PUBLIC published post: the export is an
      authoring tool, and syndicating a non-public post would carry it past its
      own audience. 422 `not_public` names that refusal distinctly from 404.
  """
  @spec syndication(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def syndication(conn, %{"id" => id} = params) do
    user = Guardian.Plug.current_resource(conn)
    format = params["format"] || "html"

    with {:ok, post} <- fetch_post(id),
         :ok <- check_ownership(post, user),
         :ok <- check_syndicable(post),
         :ok <- check_format(format) do
      json(conn, Syndication.export(post, format))
    end
  end

  @doc "POST /api/blog/posts/:id/syndications — record an act of syndication."
  @spec create_syndication(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_syndication(conn, %{"id" => id} = params) do
    user = Guardian.Plug.current_resource(conn)

    with {:ok, post} <- fetch_post(id),
         :ok <- check_ownership(post, user),
         :ok <- check_syndicable(post),
         {:ok, syndication} <- Syndication.record(post, params["method"] || "export") do
      conn
      |> put_status(201)
      |> json(%{syndication: format_syndication(syndication)})
    end
  end

  @doc """
      PUT /api/blog/posts/:id/syndications/:sid — the writer pastes the live
      Substack URL back in ("Also published at"), closing the POSSE loop.
  """
  @spec update_syndication(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_syndication(conn, %{"id" => id, "sid" => sid, "syndicated_url" => url}) do
    user = Guardian.Plug.current_resource(conn)

    with {:ok, post} <- fetch_post(id),
         :ok <- check_ownership(post, user),
         {:ok, syndication} <- fetch_syndication(post, sid) do
      case Syndication.set_syndicated_url(syndication, url) do
        {:ok, updated} ->
          json(conn, %{syndication: format_syndication(updated)})

        {:error, %Ecto.Changeset{}} ->
          conn
          |> put_status(422)
          |> json(%{error: "invalid_url"})
      end
    end
  end

  defp check_syndicable(post) do
    if post.visibility == "public" and not is_nil(post.published_at) do
      :ok
    else
      {:error, :not_public}
    end
  end

  defp check_format(format) when format in ["html", "markdown"], do: :ok
  defp check_format(_), do: {:error, :bad_format}

  defp fetch_syndication(post, sid) do
    case Syndication.get_syndication(post, sid) do
      nil -> {:error, :not_found}
      syndication -> {:ok, syndication}
    end
  end

  defp format_syndication(syndication) do
    %{
      id: syndication.id,
      post_id: syndication.post_id,
      target: syndication.target,
      method: syndication.method,
      canonical_url: syndication.canonical_url,
      syndicated_url: syndication.syndicated_url,
      created_at: DateTime.to_iso8601(syndication.created_at)
    }
  end

  @doc "PUT /api/blog/posts/:post_id/associations/:id/confirm — confirm a book association."
  @spec confirm_association(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def confirm_association(conn, %{"post_id" => post_id, "id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    with {:ok, post} <- fetch_post(post_id),
         :ok <- check_ownership(post, user),
         {:ok, association} <- Blog.confirm_association(post, id) do
      json(conn, %{association: ProtoJSON.association_action(association)})
    end
  end

  @doc "PUT /api/blog/posts/:post_id/associations/:id/dismiss — dismiss a book association."
  @spec dismiss_association(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def dismiss_association(conn, %{"post_id" => post_id, "id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    with {:ok, post} <- fetch_post(post_id),
         :ok <- check_ownership(post, user),
         {:ok, association} <- Blog.dismiss_association(post, id) do
      json(conn, %{association: ProtoJSON.association_action(association)})
    end
  end

  @doc """
      POST /api/blog/posts/:id/chat — writing-assistant chat for a post.

      Gated by `StacksWeb.Plugs.ConsentCheck, feature: "writing_assistant"` in the
      router pipeline: reaching this action means the user has granted consent (a
      403 is returned upstream otherwise). The assistant itself is not built yet —
      this is an honest "under construction" surface, NOT real AI.
  """
  @spec chat(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def chat(conn, %{"id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    with {:ok, post} <- fetch_post(id),
         :ok <- check_ownership(post, user) do
      json(conn, %{
        status: "under_construction",
        message: "The writing assistant is coming soon."
      })
    end
  end

  defp fetch_post(id) do
    case Blog.get_post(id) do
      nil -> {:error, :not_found}
      post -> {:ok, post}
    end
  end

  defp check_ownership(%{user_id: owner_id}, %{id: user_id}) when owner_id == user_id, do: :ok
  defp check_ownership(_post, _user), do: {:error, :unauthorized}

  defp build_viewer(conn) do
    case Guardian.Plug.current_resource(conn) do
      nil -> :unauthenticated
      %{id: id} -> {:platform_user, id}
    end
  end

  defp atomize_keys(map) do
    Map.new(map, fn {k, v} -> {String.to_existing_atom(k), v} end)
  end
end
