defmodule Stacks.Events.PayloadContract do
  @moduledoc """
      The declared, versioned shape of every `op.event_log` payload — the
      schema `buf` cannot provide, since payloads are opaque
      `google.protobuf.Struct` JSON. Three guards enforce it
      (`PayloadContractTest`): shape drift (`emit/1` validates in non-prod
      envs, so drifting emitters fail tests), version ↔ upcaster (every
      `version > 1` entry needs an `Upcaster` clause), and PII-lint (every
      payload key must be non-personal-shaped or explicitly allowlisted with a
      justification — UUID-only is the rule).
  """

  @contract %{
    "blog.post_created" => %{version: 2, keys: ~w(user_id visibility)},
    "blog.post_updated" => %{version: 2, keys: ~w(user_id visibility)},
    "blog.post_published" => %{version: 2, keys: ~w(user_id)},
    "blog.post_deleted" => %{version: 1, keys: ~w(user_id)},
    "blog.association_confirmed" => %{version: 1, keys: ~w(book_id post_id)},
    "blog.association_dismissed" => %{version: 1, keys: ~w(book_id post_id)},
    "blog.associations_suggested" => %{version: 1, keys: ~w(book_ids count)},
    "post.comment_created" => %{version: 1, keys: ~w(author_id comment_id)},
    "post.syndicated" => %{version: 1, keys: ~w(target method)},
    "book.created" => %{version: 1, keys: ~w(isbn title visibility_tier)},
    "book.cover_confirmed" => %{version: 1, keys: ~w(book_id cover_image_url)},
    "book.visibility_tier_changed" => %{version: 1, keys: ~w(book_id visibility_tier)},
    "book.enriched" => %{version: 1, keys: ~w(book_id)},
    "books.confirmed" => %{version: 1, keys: ~w(isbn shelf title)},
    "books.edition_merged" => %{version: 1, keys: ~w(isbn work_id)},
    "image.submitted" => %{version: 1, keys: ~w(storage_path)},
    "image.rejected" => %{version: 1, keys: ~w(reason), optional: ~w(isbn)},
    "image.resolved" => %{version: 1, keys: ~w(book_count)},
    "image.expired" => %{version: 1, keys: ~w(), optional: ~w(reason)},
    "placement.created" => %{
      version: 1,
      keys: ~w(book_id bookshelf visibility_tier),
      optional: ~w(source)
    },
    "placement.moved" => %{version: 1, keys: ~w(from_bookshelf to_bookshelf)},
    "placement.reread" => %{version: 1, keys: ~w(book_id to_bookshelf)},
    "placement.removed" => %{version: 1, keys: ~w(book_id)},
    "placement.restored" => %{version: 1, keys: ~w(book_id bookshelf)},
    "placement.reading_started" => %{version: 1, keys: ~w(book_id)},
    "placement.reading_completed" => %{version: 1, keys: ~w(book_id)},
    "library_import.started" => %{version: 1, keys: ~w(user_id source row_count)},
    "library_import.completed" => %{
      version: 1,
      keys:
        ~w(user_id source status row_count shelved_count duplicate_count unverified_count unreadable_count)
    },
    "user.registered" => %{version: 1, keys: ~w(role)},
    "user.profile_updated" => %{version: 1, keys: ~w()},
    "user.profile_visibility_changed" => %{version: 1, keys: ~w(visibility)},
    "user.location_updated" => %{version: 1, keys: ~w()},
    "user.password_changed" => %{version: 1, keys: ~w()},
    # Empty by construction, not by omission: the only facts these events could
    # carry beyond the aggregate id are two email addresses, and event_log is
    # append-only — erasure blanks a payload where it can delete a row.
    "user.email_change_requested" => %{version: 1, keys: ~w()},
    "user.email_change_confirmed" => %{version: 1, keys: ~w()},
    "user.email_change_reverted" => %{version: 1, keys: ~w()},
    "user.email_change_expired" => %{version: 1, keys: ~w()},
    "invite.issued" => %{version: 1, keys: ~w(max_uses expires_at email_bound)},
    "invite.redeemed" => %{version: 1, keys: ~w(user_id use_count)},
    "invite.revoked" => %{version: 1, keys: ~w()},
    "user.notifications_updated" => %{version: 1, keys: ~w()},
    "user.visibility_recap_completed" => %{
      version: 1,
      keys: ~w(bookshelves_capped new_visibility placements_capped posts_capped)
    },
    "social.user_blocked" => %{version: 1, keys: ~w(blocked_id)},
    "social.user_unblocked" => %{version: 1, keys: ~w(blocked_id)},
    "group.created" => %{version: 1, keys: ~w(owner_id)},
    "group.invitation_sent" => %{version: 1, keys: ~w(invited_by_id invited_user_id)},
    "group.member_joined" => %{version: 1, keys: ~w(user_id)},
    "group.member_left" => %{version: 1, keys: ~w(user_id)},
    "group.member_removed" => %{version: 1, keys: ~w(removed_by_id removed_user_id)},
    "listing.created" => %{version: 1, keys: ~w(book_id seller_id)},
    "listing.activated" => %{version: 1, keys: ~w(book_id seller_id)},
    "listing.removed" => %{version: 1, keys: ~w(book_id seller_id)},
    "listing.sold" => %{version: 1, keys: ~w(book_id seller_id)},
    "listing.expired" => %{version: 1, keys: ~w(book_id seller_id)},
    "partner.event_created" => %{version: 1, keys: ~w(space_id title)},
    "partner.event_deleted" => %{version: 1, keys: ~w(space_id)},
    "partner.inventory_synced" => %{version: 1, keys: ~w(synced unresolved_count)},
    "source.approved" => %{version: 1, keys: ~w(status)},
    "third_space.created" => %{version: 1, keys: ~w(source_id geocoded)},
    "third_space.delisted" => %{version: 1, keys: ~w()},
    "source.rejected" => %{version: 1, keys: ~w(status)},
    "enrichment.sources_discovered" => %{version: 1, keys: ~w(count query source_ids)},
    "enrichment.author_sources_discovered" => %{version: 1, keys: ~w(rss_feed_url website_url)},
    "enrichment.author_updated" => %{version: 1, keys: ~w(author_id new_entries)},
    "enrichment.events_discovered" => %{version: 1, keys: ~w(events_count store_name)},
    "enrichment.prices_scraped" => %{version: 1, keys: ~w(book_ids count)},
    "enrichment.reviews_scraped" => %{version: 1, keys: ~w(book_count)},
    "costs.refreshed" => %{version: 1, keys: ~w(item_count period vision_jobs)},
    # No body, deliberately. op.event_log is immutable outside GDPR redaction,
    # so a reader's words written here would outlive every erasure request.
    "feedback.submitted" => %{version: 1, keys: ~w(user_id character_count)},
    "source_health.recorded" => %{
      version: 1,
      keys: ~w(consecutive_failures source_name source_type status)
    }
  }

  @free_text_allowlist %{
    "title" => "bibliographic book title / partner-event title — public metadata, not user PII",
    "query" =>
      "system source-discovery query (book/author terms), not user-entered personal input",
    "reason" => "image-rejection reason (bounded string), non-personal",
    "store_name" => "bookstore business name (partner entity), not user PII",
    "source_name" => "monitoring source identifier, non-personal",
    "rss_feed_url" => "external author RSS URL, not user PII",
    "website_url" => "external author website URL, not user PII",
    "cover_image_url" => "book cover image URL, not user PII",
    "storage_path" => "opaque object-storage key, not free-text personal data",
    "email_bound" => "boolean flag (bound-or-not), never the address itself"
  }

  @pii_shaped ~w(title body name comment note query email city address phone handle display description message content url path reason store)

  @doc "The full contract: event_type => %{version, keys, optional}."
  @spec contract() :: %{
          optional(String.t()) => %{
            :version => pos_integer(),
            :keys => [String.t()],
            optional(:optional) => [String.t()]
          }
        }
  def contract, do: @contract

  @doc "Free-text-shaped keys explicitly cleared as non-PII, with justification."
  @spec free_text_allowlist() :: %{optional(String.t()) => String.t()}
  def free_text_allowlist, do: @free_text_allowlist

  @doc "Substrings that flag a key as personal/free-text-shaped."
  @spec pii_shaped() :: [String.t()]
  def pii_shaped, do: @pii_shaped

  @doc """
      Validate an emitted event map against the contract.

      Returns `:ok` when the payload keys and `schema_version` match the declared
      contract for that `event_type`, or when the event_type is not in the contract
      (unknown types are the coverage test's concern, not a runtime crash). Returns
      `{:error, reason}` on a shape/version mismatch for a known type.
  """
  @spec validate(map()) :: :ok | {:error, String.t()}
  def validate(%{event_type: type} = event) do
    case Map.fetch(@contract, type) do
      :error ->
        :ok

      {:ok, %{version: version, keys: keys} = entry} ->
        optional = Map.get(entry, :optional, [])
        allowed = MapSet.new(keys ++ optional)
        required = MapSet.new(keys)

        actual =
          event |> Map.get(:payload, %{}) |> Map.keys() |> Enum.map(&to_string/1) |> MapSet.new()

        undeclared = MapSet.difference(actual, allowed)
        missing = MapSet.difference(required, actual)
        actual_version = Map.get(event, :schema_version, 1)

        cond do
          not Enum.empty?(undeclared) ->
            {:error,
             "#{type}: undeclared payload keys #{inspect(Enum.sort(undeclared))} " <>
               "(allowed: #{inspect(Enum.sort(allowed))}). If intentional, bump schema_version, " <>
               "add an Upcaster clause, and update PayloadContract."}

          not Enum.empty?(missing) ->
            {:error,
             "#{type}: missing required payload keys #{inspect(Enum.sort(missing))} " <>
               "(required: #{inspect(Enum.sort(required))}). Emit them, mark them optional in " <>
               "PayloadContract, or update the emitter."}

          actual_version != version ->
            {:error,
             "#{type}: schema_version #{actual_version} != contract v#{version} (update the emitter or PayloadContract)."}

          true ->
            :ok
        end
    end
  end

  def validate(_), do: :ok

  @doc """
      Like `validate/1` but raises `Stacks.Events.PayloadContract.Violation` on a
      mismatch. Called from `Stacks.Events.emit/1` in non-prod envs so a contract
      drift fails the test that emitted it.
  """
  @spec validate!(map()) :: :ok
  def validate!(event) do
    case validate(event) do
      :ok -> :ok
      {:error, message} -> raise __MODULE__.Violation, message
    end
  end
end

defmodule Stacks.Events.PayloadContract.Violation do
  @moduledoc "Raised when an emitted event payload drifts from the declared contract."
  defexception [:message]
end
