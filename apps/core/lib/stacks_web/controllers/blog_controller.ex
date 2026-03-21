defmodule StacksWeb.BlogController do
  @moduledoc """
  CRUD endpoints for blog posts.

  Public GET routes use optional auth so unauthenticated viewers see only
  public/published posts. Authenticated POST/PUT/DELETE routes enforce
  ownership and the visibility ceiling.
  """

  use CoreWeb, :controller

  alias Stacks.Accounts.Guardian
  alias Stacks.Blog

  @doc "GET /api/blog/posts — list published posts for a user (query param: user_id)."
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, %{"user_id" => user_id}) do
    viewer = build_viewer(conn)
    posts = Blog.list_user_posts(user_id, viewer)
    json(conn, %{posts: Enum.map(posts, &format_post/1)})
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
        conn |> put_status(404) |> json(%{error: "not_found"})

      post ->
        associations = Blog.list_associations(post.id)
        json(conn, %{post: format_post(post), associations: associations})
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

    case Blog.create_post(user, attrs) do
      {:ok, post} ->
        conn
        |> put_status(201)
        |> json(%{post: format_post(post)})

      {:error, :visibility_ceiling} ->
        conn
        |> put_status(422)
        |> json(%{error: "post visibility exceeds profile visibility ceiling"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(422)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  @doc "PUT /api/blog/posts/:id — update a post."
  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, %{"id" => id} = params) do
    user = Guardian.Plug.current_resource(conn)

    case Blog.get_post(id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      post ->
        attrs =
          params
          |> Map.take(["title", "body", "visibility"])
          |> atomize_keys()

        case Blog.update_post(post, user, attrs) do
          {:ok, updated_post} ->
            json(conn, %{post: format_post(updated_post)})

          {:error, :unauthorized} ->
            conn |> put_status(403) |> json(%{error: "forbidden"})

          {:error, :visibility_ceiling} ->
            conn
            |> put_status(422)
            |> json(%{error: "post visibility exceeds profile visibility ceiling"})

          {:error, %Ecto.Changeset{} = changeset} ->
            conn
            |> put_status(422)
            |> json(%{errors: format_errors(changeset)})
        end
    end
  end

  @doc "DELETE /api/blog/posts/:id — delete a post."
  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    case Blog.get_post(id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      post ->
        case Blog.delete_post(post, user) do
          {:ok, _post} ->
            json(conn, %{deleted: true})

          {:error, :unauthorized} ->
            conn |> put_status(403) |> json(%{error: "forbidden"})
        end
    end
  end

  @doc "POST /api/blog/posts/:id/publish — publish a draft post."
  @spec publish(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def publish(conn, %{"id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    case Blog.get_post(id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      post ->
        case Blog.publish_post(post, user) do
          {:ok, published_post} ->
            json(conn, %{post: format_post(published_post)})

          {:error, :unauthorized} ->
            conn |> put_status(403) |> json(%{error: "forbidden"})
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_viewer(conn) do
    case Guardian.Plug.current_resource(conn) do
      nil -> :unauthenticated
      %{id: id} -> {:platform_user, id}
    end
  end

  defp format_post(post) do
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

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp atomize_keys(map) do
    Map.new(map, fn {k, v} -> {String.to_existing_atom(k), v} end)
  end
end
