defmodule Stacks.Blog do
  @moduledoc """
  Context for blog features: posts and their book associations.

  All writes enforce a visibility ceiling — a post's visibility cannot be
  less restrictive than the author's `profile_visibility`.
  """

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Blog.{Post, PostBookAssociation}
  alias Stacks.Events
  alias Stacks.Visibility

  # ---------------------------------------------------------------------------
  # Post CRUD
  # ---------------------------------------------------------------------------

  @doc """
  Creates a blog post for the given user.

  The post defaults to `visibility: "owner"` (draft mode). If the caller
  supplies a visibility that is less restrictive than the user's
  `profile_visibility`, creation fails with `{:error, :visibility_ceiling}`.
  """
  @spec create_post(Stacks.Accounts.User.t(), map()) ::
          {:ok, Post.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_post(user, attrs) do
    attrs = Map.put(attrs, :user_id, user.id)
    requested_visibility = Map.get(attrs, :visibility, "owner")

    with :ok <- validate_ceiling(requested_visibility, user.profile_visibility) do
      %Post{}
      |> Post.changeset(attrs)
      |> Repo.insert()
      |> tap_ok(fn post ->
        Events.emit_safe(%{
          event_type: "blog.post_created",
          aggregate_type: "post",
          aggregate_id: post.id,
          payload: %{user_id: user.id, title: post.title, visibility: post.visibility}
        })
      end)
    end
  end

  @doc """
  Updates a blog post. Only the post owner may update.

  Returns `{:error, :not_found}` if the post does not exist,
  `{:error, :unauthorized}` if the caller is not the owner, or
  `{:error, :visibility_ceiling}` if the new visibility exceeds the ceiling.
  """
  @spec update_post(Post.t(), Stacks.Accounts.User.t(), map()) ::
          {:ok, Post.t()} | {:error, Ecto.Changeset.t() | atom()}
  def update_post(%Post{} = post, user, attrs) do
    requested_visibility = Map.get(attrs, :visibility, post.visibility)

    with :ok <- check_ownership(post, user),
         :ok <- validate_ceiling(requested_visibility, user.profile_visibility) do
      post
      |> Post.changeset(attrs)
      |> Repo.update()
      |> tap_ok(fn updated_post ->
        Events.emit_safe(%{
          event_type: "blog.post_updated",
          aggregate_type: "post",
          aggregate_id: updated_post.id,
          payload: %{
            user_id: user.id,
            title: updated_post.title,
            visibility: updated_post.visibility
          }
        })
      end)
    end
  end

  @doc """
  Publishes a draft post by setting `published_at` to now.

  Only the post owner may publish. Emits `blog.post_published`.
  """
  @spec publish_post(Post.t(), Stacks.Accounts.User.t()) ::
          {:ok, Post.t()} | {:error, atom()}
  def publish_post(%Post{} = post, user) do
    with :ok <- check_ownership(post, user) do
      post
      |> Post.changeset(%{published_at: DateTime.utc_now()})
      |> Repo.update()
      |> tap_ok(fn published_post ->
        Events.emit_safe(%{
          event_type: "blog.post_published",
          aggregate_type: "post",
          aggregate_id: published_post.id,
          payload: %{user_id: user.id, title: published_post.title}
        })
      end)
    end
  end

  @doc """
  Unpublishes a post by clearing `published_at`.

  Only the post owner may unpublish.
  """
  @spec unpublish_post(Post.t(), Stacks.Accounts.User.t()) ::
          {:ok, Post.t()} | {:error, atom()}
  def unpublish_post(%Post{} = post, user) do
    with :ok <- check_ownership(post, user) do
      post
      |> Post.changeset(%{published_at: nil})
      |> Repo.update()
    end
  end

  @doc """
  Deletes a blog post. Only the post owner may delete.
  """
  @spec delete_post(Post.t(), Stacks.Accounts.User.t()) ::
          {:ok, Post.t()} | {:error, atom()}
  def delete_post(%Post{} = post, user) do
    with :ok <- check_ownership(post, user) do
      Repo.delete(post)
      |> tap_ok(fn deleted_post ->
        Events.emit_safe(%{
          event_type: "blog.post_deleted",
          aggregate_type: "post",
          aggregate_id: deleted_post.id,
          payload: %{user_id: user.id}
        })
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Reads
  # ---------------------------------------------------------------------------

  @doc """
  Fetches a single post by ID.

  Returns `nil` if the post does not exist.
  """
  @spec get_post(String.t()) :: Post.t() | nil
  def get_post(id), do: Repo.get(Post, id)

  @doc """
  Fetches a single post by ID, applying visibility filtering for the viewer.

  Returns `nil` if the post does not exist or is not visible to the viewer.
  The viewer is either `:unauthenticated` or `{:platform_user, user_id}`.
  """
  @spec get_post_for_viewer(String.t(), term()) :: Post.t() | nil
  def get_post_for_viewer(id, viewer) do
    case Repo.get(Post, id) do
      nil ->
        nil

      post ->
        if Visibility.can_view?(post, viewer), do: post, else: nil
    end
  end

  @doc """
  Lists all posts by a given user, filtered by viewer visibility.

  Returns only published posts that the viewer is allowed to see.
  The owner always sees all their own posts (including drafts).
  """
  @spec list_user_posts(String.t(), term()) :: [Post.t()]
  def list_user_posts(user_id, viewer) do
    query =
      case viewer do
        {:platform_user, ^user_id} ->
          # Owner sees everything, including unpublished drafts
          from(p in Post,
            where: p.user_id == ^user_id,
            order_by: [desc: p.created_at]
          )

        _ ->
          # Non-owners only see published posts
          from(p in Post,
            where: p.user_id == ^user_id and not is_nil(p.published_at),
            order_by: [desc: p.published_at]
          )
      end

    query
    |> Repo.all()
    |> Enum.filter(&Visibility.can_view?(&1, viewer))
  end

  @doc """
  Lists posts associated with a given book (by book_id), visible to the viewer.

  Only returns published posts with visible associations.
  """
  @spec list_posts_for_book(String.t(), term()) :: [Post.t()]
  def list_posts_for_book(book_id, viewer) do
    from(p in Post,
      join: a in PostBookAssociation,
      on: a.post_id == p.id,
      where: a.book_id == ^book_id and a.visible == true and not is_nil(p.published_at),
      order_by: [desc: p.published_at],
      distinct: true
    )
    |> Repo.all()
    |> Enum.filter(&Visibility.can_view?(&1, viewer))
  end

  @doc """
  Re-evaluates all of a user's published posts against a new profile visibility ceiling.

  Any post whose visibility is less restrictive than the new ceiling is tightened
  to match the ceiling. Returns the count of posts that were tightened.
  """
  @spec tighten_posts_to_ceiling(String.t(), String.t()) :: {:ok, non_neg_integer()}
  def tighten_posts_to_ceiling(user_id, new_profile_visibility) do
    posts_to_tighten =
      from(p in Post,
        where: p.user_id == ^user_id
      )
      |> Repo.all()
      |> Enum.filter(fn post ->
        Visibility.validate_visibility_ceiling(post.visibility, new_profile_visibility, :post) !=
          :ok
      end)

    Repo.transaction(fn ->
      Enum.each(posts_to_tighten, fn post ->
        post
        |> Post.changeset(%{visibility: new_profile_visibility})
        |> Repo.update!()
      end)
    end)

    {:ok, length(posts_to_tighten)}
  end

  # ---------------------------------------------------------------------------
  # Book associations
  # ---------------------------------------------------------------------------

  @doc """
  Manually associates a book with a post.
  """
  @spec associate_book(Post.t(), String.t(), map()) ::
          {:ok, PostBookAssociation.t()} | {:error, Ecto.Changeset.t()}
  def associate_book(%Post{} = post, book_id, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          post_id: post.id,
          book_id: book_id,
          source: "manual",
          confidence: 1.0,
          visible: true
        },
        attrs
      )

    %PostBookAssociation{}
    |> PostBookAssociation.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists book associations for a post.
  """
  @spec list_associations(String.t()) :: [PostBookAssociation.t()]
  def list_associations(post_id) do
    from(a in PostBookAssociation,
      where: a.post_id == ^post_id,
      order_by: [desc: a.confidence],
      preload: [:book]
    )
    |> Repo.all()
  end

  @doc """
  Confirms a book association by setting `visible: true`.

  The caller must own the post. Returns `{:error, :not_found}` if the
  association does not exist or does not belong to the post.
  """
  @spec confirm_association(Post.t(), String.t()) ::
          {:ok, PostBookAssociation.t()} | {:error, atom()}
  def confirm_association(%Post{} = post, association_id) do
    case get_association_for_post(post.id, association_id) do
      nil ->
        {:error, :not_found}

      association ->
        association
        |> PostBookAssociation.changeset(%{visible: true})
        |> Repo.update()
        |> tap_ok(fn assoc ->
          Events.emit_safe(%{
            event_type: "blog.association_confirmed",
            aggregate_type: "post_book_association",
            aggregate_id: assoc.id,
            payload: %{post_id: post.id, book_id: assoc.book_id}
          })
        end)
    end
  end

  @doc """
  Dismisses a book association by setting `visible: false`.

  The caller must own the post. Returns `{:error, :not_found}` if the
  association does not exist or does not belong to the post.
  """
  @spec dismiss_association(Post.t(), String.t()) ::
          {:ok, PostBookAssociation.t()} | {:error, atom()}
  def dismiss_association(%Post{} = post, association_id) do
    case get_association_for_post(post.id, association_id) do
      nil ->
        {:error, :not_found}

      association ->
        association
        |> PostBookAssociation.changeset(%{visible: false})
        |> Repo.update()
        |> tap_ok(fn assoc ->
          Events.emit_safe(%{
            event_type: "blog.association_dismissed",
            aggregate_type: "post_book_association",
            aggregate_id: assoc.id,
            payload: %{post_id: post.id, book_id: assoc.book_id}
          })
        end)
    end
  end

  defp get_association_for_post(post_id, association_id) do
    Repo.get_by(PostBookAssociation, id: association_id, post_id: post_id)
  end

  @doc """
  Lists posts written by a user that are associated with a given book.

  Only returns posts with visible associations. Ordered by `published_at` descending.
  """
  @spec list_posts_for_book_by_user(String.t(), String.t()) :: [Post.t()]
  def list_posts_for_book_by_user(book_id, user_id) do
    from(p in Post,
      join: a in PostBookAssociation,
      on: a.post_id == p.id,
      where: a.book_id == ^book_id and a.visible == true and p.user_id == ^user_id,
      order_by: [desc: p.published_at],
      distinct: true
    )
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp check_ownership(%Post{user_id: owner_id}, %{id: user_id})
       when owner_id == user_id,
       do: :ok

  defp check_ownership(_post, _user), do: {:error, :unauthorized}

  defp validate_ceiling(child_visibility, parent_visibility) do
    case Visibility.validate_visibility_ceiling(child_visibility, parent_visibility, :post) do
      :ok -> :ok
      {:error, _reason} -> {:error, :visibility_ceiling}
    end
  end

  defp tap_ok({:ok, record}, fun) do
    fun.(record)
    {:ok, record}
  end

  defp tap_ok(error, _fun), do: error
end
