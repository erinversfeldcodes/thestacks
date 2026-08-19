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
  alias Stacks.Feedback.Entry, as: FeedbackEntry
  alias Stacks.Marketplace.{Listing, OfferMessage, OfferThread, Transaction}
  alias Stacks.Shelving.{Bookshelf, Placement, PlacementHistory}
  alias Stacks.Social.{Group, GroupInvitation, GroupMember, UserBlock, VisibilityGrant}
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

    uploaded_images =
      UploadedImage
      |> where([i], i.user_id == ^user_id)
      |> select([i], %{id: i.id, uploaded_at: i.uploaded_at, status: i.status})
      |> Repo.all()

    blog_posts =
      Post
      |> where([p], p.user_id == ^user_id)
      |> Repo.all()

    blog_comments =
      PostComment
      |> where([c], c.author_id == ^user_id)
      |> Repo.all()

    blog_syndications =
      Stacks.Blog.PostSyndication
      |> join(:inner, [s], p in Post, on: s.post_id == p.id)
      |> where([_s, p], p.user_id == ^user_id)
      |> Repo.all()
      |> Enum.map(
        &%{
          post_id: &1.post_id,
          target: &1.target,
          method: &1.method,
          canonical_url: &1.canonical_url,
          syndicated_url: &1.syndicated_url,
          created_at: &1.created_at
        }
      )

    invitations =
      Stacks.Accounts.InviteCode
      |> where([i], i.redeemed_by_id == ^user_id)
      |> select([i], %{
        code_prefix: i.code_prefix,
        redeemed_at: i.redeemed_at,
        expires_at: i.expires_at
      })
      |> Repo.all()

    # The reader's own words are theirs, so the body goes out in full.
    feedback_entries =
      FeedbackEntry
      |> where([f], f.user_id == ^user_id)
      |> order_by([f], desc: f.created_at)
      |> select([f], %{body: f.body, page_context: f.page_context, created_at: f.created_at})
      |> Repo.all()

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
      #     pending_email_token, pending_email_revert_token,
      #     password (virtual, never persisted).
      #   Account-security mechanics — internal auth state, not user-provided
      #     personal data:
      #     email_confirmed, password_reset_sent_at, failed_login_count,
      #     failed_login_first_at, locked_until, lockout_duration_seconds.
      #   Internal UX progress flags — app state, not personal data:
      #     onboarding_completed, onboarding_steps.
      user: %{
        id: user.id,
        email: user.email,
        # An address the reader typed, and the moment they typed it. Personal data
        # even though the account does not answer on it (yet, or ever) — a change
        # in flight is a fact about the reader that the platform is holding.
        pending_email: user.pending_email,
        pending_email_sent_at: user.pending_email_sent_at,
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
        syndication_default: user.syndication_default,
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
      library_imports: library_imports,
      blog_syndications: blog_syndications,
      feedback: feedback_entries,
      marketplace_listings: marketplace_listings(user_id),
      marketplace_offer_threads: marketplace_offer_threads(user_id),
      marketplace_offer_messages: marketplace_offer_messages(user_id),
      marketplace_transactions: marketplace_transactions(user_id),
      reading_groups: reading_groups(user_id),
      reading_group_memberships: reading_group_memberships(user_id),
      reading_group_invitations: reading_group_invitations(user_id),
      blocked_users: blocked_users(user_id),
      visibility_grants: visibility_grants(user_id)
    }

    {:ok, export}
  rescue
    error -> {:error, error}
  end

  defp marketplace_listings(user_id) do
    Listing
    |> where([l], l.seller_id == ^user_id)
    |> order_by([l], desc: l.created_at)
    |> select([l], %{
      id: l.id,
      book_id: l.book_id,
      status: l.status,
      pricing_mode: l.pricing_mode,
      price_cents: l.price_cents,
      currency: l.currency,
      condition: l.condition,
      description: l.description,
      contact_info: l.contact_info,
      photo_urls: l.photo_urls,
      listed_at: l.listed_at,
      expires_at: l.expires_at,
      sold_at: l.sold_at,
      created_at: l.created_at
    })
    |> Repo.all()
  end

  defp marketplace_offer_threads(user_id) do
    OfferThread
    |> where([t], t.buyer_id == ^user_id)
    |> order_by([t], desc: t.created_at)
    |> select([t], %{
      id: t.id,
      placement_id: t.placement_id,
      status: t.status,
      created_at: t.created_at
    })
    |> Repo.all()
  end

  # Only the messages this user WROTE. The counterparty's words on the same
  # thread are their personal data, not the subject's, and a portability export
  # is not a licence to walk off with someone else's half of the conversation.
  defp marketplace_offer_messages(user_id) do
    OfferMessage
    |> where([m], m.sender_id == ^user_id)
    |> order_by([m], asc: m.created_at)
    |> select([m], %{
      id: m.id,
      thread_id: m.thread_id,
      type: m.type,
      body: m.body,
      amount_cents: m.amount_cents,
      created_at: m.created_at
    })
    |> Repo.all()
  end

  # `payment_provider_ref` / `shipping_provider_ref` are deliberately absent:
  # they are integration handles into third-party systems, and putting them in
  # a file the user downloads adds lookup risk without portability value.
  defp marketplace_transactions(user_id) do
    Transaction
    |> where([t], t.buyer_id == ^user_id or t.seller_id == ^user_id)
    |> order_by([t], desc: t.created_at)
    |> Repo.all()
    |> Enum.map(
      &%{
        id: &1.id,
        listing_id: &1.listing_id,
        role: if(&1.buyer_id == user_id, do: "buyer", else: "seller"),
        amount_cents: &1.amount_cents,
        currency: &1.currency,
        payment_status: &1.payment_status,
        shipping_status: &1.shipping_status,
        shipping_cost_cents: &1.shipping_cost_cents,
        completed_at: &1.completed_at,
        created_at: &1.created_at
      }
    )
  end

  # Groups the user OWNS. The member roster is not exported with them — who
  # else is in a reading group is those readers' data.
  defp reading_groups(user_id) do
    Group
    |> where([g], g.owner_id == ^user_id)
    |> order_by([g], desc: g.created_at)
    |> select([g], %{
      id: g.id,
      name: g.name,
      type: g.type,
      visibility: g.visibility,
      created_at: g.created_at
    })
    |> Repo.all()
  end

  defp reading_group_memberships(user_id) do
    GroupMember
    |> where([m], m.user_id == ^user_id)
    |> order_by([m], desc: m.created_at)
    |> select([m], %{
      id: m.id,
      group_id: m.group_id,
      role: m.role,
      joined_at: m.joined_at
    })
    |> Repo.all()
  end

  defp reading_group_invitations(user_id) do
    GroupInvitation
    |> where([i], i.invited_user_id == ^user_id or i.invited_by_id == ^user_id)
    |> order_by([i], desc: i.created_at)
    |> Repo.all()
    |> Enum.map(
      &%{
        id: &1.id,
        group_id: &1.group_id,
        direction: if(&1.invited_by_id == user_id, do: "sent", else: "received"),
        status: &1.status,
        responded_at: &1.responded_at,
        created_at: &1.created_at
      }
    )
  end

  # The user's own block list only. Rows where they are the BLOCKED party are
  # someone else's decision about them — exporting those would hand the subject
  # a list of who has blocked them.
  defp blocked_users(user_id) do
    UserBlock
    |> where([b], b.blocker_id == ^user_id)
    |> order_by([b], desc: b.created_at)
    |> select([b], %{id: b.id, blocked_id: b.blocked_id, created_at: b.created_at})
    |> Repo.all()
  end

  defp visibility_grants(user_id) do
    VisibilityGrant
    |> where([g], g.granted_by_id == ^user_id or g.granted_to_id == ^user_id)
    |> order_by([g], desc: g.created_at)
    |> Repo.all()
    |> Enum.map(
      &%{
        id: &1.id,
        direction: if(&1.granted_by_id == user_id, do: "granted", else: "received"),
        resource_type: &1.resource_type,
        resource_id: &1.resource_id,
        granted_to_id: &1.granted_to_id,
        granted_by_id: &1.granted_by_id,
        created_at: &1.created_at
      }
    )
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
