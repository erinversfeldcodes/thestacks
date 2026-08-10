defmodule Stacks.GDPR.Export do
  @moduledoc """
  GDPR data export. Collects all user-owned data from the operational schema
  and formats it for download (right to data portability).
  """

  import Ecto.Query

  alias Core.Repo
  alias Stacks.Accounts
  alias Stacks.Blog.{Post, PostComment}
  alias Stacks.Books.UploadedImage
  alias Stacks.Shelving.{Bookshelf, Placement, PlacementHistory}
  alias Stacks.WritingAssistant.{Embedding, Session, TurnFeedback}

  @doc """
  Exports all data for a user. Returns a JSON-serialisable map.
  The `_opts` parameter is reserved for future filtering options.
  """
  @spec export_user_data(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def export_user_data(user_id, _opts \\ []) do
    user = Accounts.get_user!(user_id)

    bookshelves =
      Bookshelf
      |> where([bs], bs.user_id == ^user_id)
      |> Repo.all()

    bookshelf_ids = Enum.map(bookshelves, & &1.id)

    placements =
      Placement
      |> where([p], p.bookshelf_id in ^bookshelf_ids)
      |> preload([:book_edition, book: :editions])
      |> Repo.all()

    histories =
      PlacementHistory
      |> where([h], h.from_bookshelf in ^bookshelf_ids or h.to_bookshelf in ^bookshelf_ids)
      |> Repo.all()

    sessions =
      Session
      |> where([s], s.user_id == ^user_id)
      |> Repo.all()

    feedback =
      TurnFeedback
      |> join(:inner, [f], s in Session, on: f.session_id == s.id)
      |> where([_f, s], s.user_id == ^user_id)
      |> Repo.all()

    # Summary only — the `embedding` vector column is deliberately NOT selected,
    # so the raw vector never leaves the database. Vectors are not human-readable
    # and carry no portability value; exporting them would be a data-leak risk.
    embeddings_summary =
      Embedding
      |> where([e], e.user_id == ^user_id)
      |> select([e], %{
        source_type: e.source_type,
        source_title: e.title,
        shelf: e.shelf,
        date_embedded: e.content_date
      })
      |> Repo.all()

    # DECISION (#353): the user's uploaded images ARE included in the export
    # (right to data portability — the reader can see which uploads the system
    # holds for them and their status). We export ONLY id + uploaded_at + status.
    # We deliberately export NEITHER the image bytes NOR the storage_path / a
    # presigned URL: the bytes are not portable structured data, and emitting a
    # usable storage key/URL from a plain export endpoint would leak a fetchable
    # pointer to the raw image. The bytes are erased on request via
    # delete_user_data/1 and by the 30-day retention sweep.
    uploaded_images =
      UploadedImage
      |> where([i], i.user_id == ^user_id)
      |> select([i], %{id: i.id, uploaded_at: i.uploaded_at, status: i.status})
      |> Repo.all()

    # The reader's own writing (#392). `blog_posts.body` and `post_comments.body`
    # are the user's own free text and squarely within the right to portability,
    # so they are exported in full. Posts are keyed by `user_id`, comments by
    # `author_id`. We deliberately do NOT export `post_book_associations` — its
    # `reasoning` is LLM-derived, not the reader's own writing.
    blog_posts =
      Post
      |> where([p], p.user_id == ^user_id)
      |> Repo.all()

    blog_comments =
      PostComment
      |> where([c], c.author_id == ^user_id)
      |> Repo.all()

    # US-14.1.3: invitations the user REDEEMED — their entry into the beta is
    # part of their record. Deliberately excluded: `code_hash` (a credential),
    # `note` (the OWNER's private writing about them, not their own data), and
    # anything they merely issued as owner (platform-operations data, on the
    # admin surface).
    invitations =
      Stacks.Accounts.InviteCode
      |> where([i], i.redeemed_by_id == ^user_id)
      |> select([i], %{
        code_prefix: i.code_prefix,
        redeemed_at: i.redeemed_at,
        expires_at: i.expires_at
      })
      |> Repo.all()

    # US-1.1.9: the user's library imports — the durable summary (filename,
    # status, counts) AND any raw rows still inside their 30-day retention
    # window. The raw rows are the reader's own Goodreads free text (reviews,
    # private notes) — squarely portable while they exist; after the sweep the
    # summary alone remains and the export says so via the counts.
    library_imports =
      Stacks.Imports.LibraryImport
      |> where([li], li.user_id == ^user_id)
      |> order_by([li], desc: li.created_at)
      |> Repo.all()
      |> Enum.map(&library_import_to_map/1)

    export = %{
      exported_at: DateTime.utc_now(),
      # Every personal / user-provided column on op.users is exported here.
      # Columns deliberately EXCLUDED (see the schema-sweep guard in
      # test/stacks/gdpr_test.exs, whose exclusion list mirrors this rationale):
      #   Secrets — exporting them would defeat their purpose / leak credentials:
      #     password_hash, email_confirmation_token, password_reset_token,
      #     password (virtual, never persisted).
      #   Account-security mechanics — internal auth state, not user-provided
      #     personal data:
      #     email_confirmed, password_reset_sent_at, failed_login_count,
      #     failed_login_first_at, locked_until.
      #   Internal UX progress flags — app state, not personal data:
      #     onboarding_completed, onboarding_steps.
      user: %{
        id: user.id,
        email: user.email,
        display_name: user.display_name,
        handle: user.handle,
        role: user.role,
        profile_visibility: user.profile_visibility,
        website_url: user.website_url,
        country_code: user.country_code,
        city: user.city,
        notify_wishlist_availability: user.notify_wishlist_availability,
        notify_marketplace: user.notify_marketplace,
        notify_group_invitations: user.notify_group_invitations,
        notify_event_matches: user.notify_event_matches,
        age_verified: user.age_verified,
        age_verified_at: user.age_verified_at,
        age_verification_provider: user.age_verification_provider,
        consent_analytics: user.consent_analytics,
        consent_analytics_at: user.consent_analytics_at,
        consent_writing_assistant: user.consent_writing_assistant,
        consent_writing_assistant_at: user.consent_writing_assistant_at,
        created_at: user.created_at,
        updated_at: user.updated_at
      },
      bookshelves: Enum.map(bookshelves, &bookshelf_to_map/1),
      placements: Enum.map(placements, &placement_to_map/1),
      placement_history: Enum.map(histories, &history_to_map/1),
      writing_assistant_sessions: Enum.map(sessions, &session_to_map/1),
      writing_assistant_feedback: Enum.map(feedback, &feedback_to_map/1),
      embeddings_summary: embeddings_summary,
      uploaded_images: uploaded_images,
      blog_posts: Enum.map(blog_posts, &blog_post_to_map/1),
      blog_comments: Enum.map(blog_comments, &blog_comment_to_map/1),
      invitations: invitations,
      library_imports: library_imports
    }

    {:ok, export}
  rescue
    error -> {:error, error}
  end

  defp library_import_to_map(import) do
    rows =
      Stacks.Imports.LibraryImportRow
      |> where([r], r.import_id == ^import.id)
      |> order_by([r], asc: r.row_number)
      |> Repo.all()
      |> Enum.map(
        &%{
          row_number: &1.row_number,
          title: &1.raw_title,
          author: &1.raw_author,
          isbn13: &1.raw_isbn13,
          goodreads_shelf: &1.goodreads_shelf,
          rating: &1.raw_rating,
          review: &1.raw_review,
          private_notes: &1.raw_notes,
          outcome: &1.outcome,
          reason: &1.reason
        }
      )

    %{
      id: import.id,
      source: import.source,
      filename: import.filename,
      status: import.status,
      row_count: import.row_count,
      shelved_count: import.shelved_count,
      duplicate_count: import.duplicate_count,
      unverified_count: import.unverified_count,
      unreadable_count: import.unreadable_count,
      created_at: import.created_at,
      finished_at: import.finished_at,
      rows: rows
    }
  end

  defp bookshelf_to_map(bookshelf) do
    %{
      id: bookshelf.id,
      name: bookshelf.name,
      visibility: bookshelf.visibility,
      created_at: bookshelf.created_at
    }
  end

  defp blog_post_to_map(post) do
    %{
      id: post.id,
      title: post.title,
      body: post.body,
      visibility: post.visibility,
      published_at: post.published_at,
      created_at: post.created_at
    }
  end

  defp blog_comment_to_map(comment) do
    %{
      id: comment.id,
      post_id: comment.post_id,
      body: comment.body,
      created_at: comment.created_at
    }
  end

  defp placement_to_map(placement) do
    %{
      id: placement.id,
      book_isbn: placement_isbn(placement),
      book_title: placement.book && placement.book.title,
      bookshelf_id: placement.bookshelf_id,
      position: placement.position,
      placed_at: placement.placed_at,
      removed_at: placement.removed_at,
      formats: placement.formats,
      personal_rating: placement.personal_rating,
      notes: placement.notes
    }
  end

  # Which ISBN this placement is OF. Since #335 D2 a placement names its own
  # edition, so the export reports the copy the person actually shelved rather
  # than whichever edition the work currently displays as primary — a work can
  # gain a new primary edition long after they shelved theirs, and an export
  # that silently re-pointed at it would be reporting someone else's book.
  # Falls back to the work's primary for placements made before the column
  # existed and for a work with no edition at all.
  defp placement_isbn(%{book_edition: %{isbn: isbn}}) when is_binary(isbn), do: isbn

  defp placement_isbn(%{book: nil}), do: nil

  defp placement_isbn(%{book: book}) do
    case Stacks.Books.primary_edition(book) do
      nil -> nil
      edition -> edition.isbn
    end
  end

  defp placement_isbn(_placement), do: nil

  defp history_to_map(history) do
    %{
      id: history.id,
      book_id: history.book_id,
      from_bookshelf: history.from_bookshelf,
      to_bookshelf: history.to_bookshelf,
      moved_at: history.moved_at
    }
  end

  defp session_to_map(session) do
    %{
      id: session.id,
      status: session.status,
      topic: session.topic,
      model: session.model,
      started_at: session.started_at,
      created_at: session.created_at
    }
  end

  defp feedback_to_map(feedback) do
    %{
      id: feedback.id,
      session_id: feedback.session_id,
      turn_index: feedback.turn_index,
      rating: feedback.rating,
      comment: feedback.comment,
      created_at: feedback.created_at
    }
  end
end
