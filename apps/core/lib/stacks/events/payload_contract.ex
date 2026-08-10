defmodule Stacks.Events.PayloadContract do
  @moduledoc """
  The declared, versioned shape of every `op.event_log` payload — the schema that
  `buf` cannot provide.

  Event payloads are `google.protobuf.Struct` (opaque JSON), so `buf breaking`
  is blind to their internal shape, and `schema_version` + `Stacks.Events.Upcaster`
  were honour-system. This module makes the payload shape a **declared contract**
  that three guards enforce (see `Stacks.Events.PayloadContractTest`):

    1. **Shape drift** — `Stacks.Events.emit/1` validates each payload against this
       contract in non-prod envs (`validate/1`); the existing test suite drives most
       emitters, so a payload whose keys/version drift from the contract fails a test.
    2. **Version ↔ upcaster** — every entry with `version > 1` must have an
       `Upcaster` clause migrating older versions forward.
    3. **PII-lint** — every payload key must be non-personal-shaped, or listed in
       `free_text_allowlist/0` with a justification (the guard that would have caught
       the blog-title free-text leak at write time).

  ## Changing an event payload
  1. Update the emitter, and this contract entry (keys and, for a breaking change,
     `version`).
  2. If `version` changed, add a `Stacks.Events.Upcaster` clause for the old version.
  3. If a new key is personal-shaped but genuinely non-PII, add it to
     `free_text_allowlist/0` with a one-line justification.

  Each entry is `%{version:, keys:, optional: []}` — `keys` are always present;
  `optional` keys may be present or absent (a payload whose shape varies by branch,
  e.g. `image.rejected` carries `isbn` only on the mismatch path). Both `keys` and
  `optional` are PII-linted.

  Contract is the single reviewable diff for any event-shape change — like
  `proto/persisted.exs` is for the DB schema.
  """

  # event_type => %{version: current schema_version, keys: required payload keys,
  #                 optional: keys that may be absent (default [])}
  @contract %{
    # ── blog ──────────────────────────────────────────────────────────────────
    "blog.post_created" => %{version: 2, keys: ~w(user_id visibility)},
    "blog.post_updated" => %{version: 2, keys: ~w(user_id visibility)},
    "blog.post_published" => %{version: 2, keys: ~w(user_id)},
    "blog.post_deleted" => %{version: 1, keys: ~w(user_id)},
    "blog.association_confirmed" => %{version: 1, keys: ~w(book_id post_id)},
    "blog.association_dismissed" => %{version: 1, keys: ~w(book_id post_id)},
    "blog.associations_suggested" => %{version: 1, keys: ~w(book_ids count)},
    "post.comment_created" => %{version: 1, keys: ~w(author_id comment_id)},
    # ── books ─────────────────────────────────────────────────────────────────
    "book.created" => %{version: 1, keys: ~w(isbn title visibility_tier)},
    # `book_id` stays v1 rather than becoming v2: it was ADDED (#355), and an
    # upcaster cannot invent it for the historical rows that predate it — it
    # would have to query. So the contract states what every emit from this
    # codebase now carries, the one consumer degrades to the cache TTL when an
    # old row arrives without it, and no version pretends to a migration that
    # cannot be written.
    "book.cover_confirmed" => %{version: 1, keys: ~w(book_id cover_image_url)},
    # #357, the age-gate write. `book_id` is the WORK id (what the one subscriber
    # keys its cache by, not read off `aggregate_id` — see
    # CacheInvalidationHandler); `visibility_tier` is the closed two-value enum
    # `book.created` already carries. Who raised the gate is `metadata.actor`
    # ("user" | "owner") and never an id, so the payload says a BOOK changed,
    # not who changed it.
    "book.visibility_tier_changed" => %{version: 1, keys: ~w(book_id visibility_tier)},
    # #357. UUID-only by design: the work whose metadata EnrichBookJob just
    # rewrote. The enriched title is deliberately absent — `event_log` is
    # immutable, and the title is readable from the book row this event names.
    "book.enriched" => %{version: 1, keys: ~w(book_id)},
    "books.confirmed" => %{version: 1, keys: ~w(isbn shelf title)},
    "books.edition_merged" => %{version: 1, keys: ~w(isbn work_id)},
    "image.submitted" => %{version: 1, keys: ~w(storage_path)},
    # `isbn` present only when a candidate ISBN was found but mismatched; the
    # not-a-book / ISBN-not-extracted path emits `reason` alone (identify_book_job).
    "image.rejected" => %{version: 1, keys: ~w(reason), optional: ~w(isbn)},
    "image.resolved" => %{version: 1, keys: ~w(book_count)},
    # `reason` present only on the stuck-image cleanup path; the 30-day retention
    # path emits an empty payload (gdpr/image_retention.ex).
    "image.expired" => %{version: 1, keys: ~w(), optional: ~w(reason)},
    # ── shelving ──────────────────────────────────────────────────────────────
    # `source` (US-1.1.9): capture provenance — manual / upload / goodreads_import.
    # Optional because pre-import events lack it; readers default absent to
    # "manual". PlacementHandler uses it to coalesce an import's feed
    # regenerations (the import job enqueues one per bookshelf at finalize).
    "placement.created" => %{
      version: 1,
      keys: ~w(book_id bookshelf visibility_tier),
      optional: ~w(source)
    },
    "placement.moved" => %{version: 1, keys: ~w(from_bookshelf to_bookshelf)},
    "placement.reread" => %{version: 1, keys: ~w(book_id to_bookshelf)},
    "placement.removed" => %{version: 1, keys: ~w(book_id)},
    # The undo of a removal (#375). Carries `bookshelf` where `placement.removed`
    # does not, because the feed handler has to know which bookshelf's Atom feed
    # gained a book back — a removal only ever takes one away, so it can rebuild
    # from the placement alone.
    "placement.restored" => %{version: 1, keys: ~w(book_id bookshelf)},
    "placement.reading_started" => %{version: 1, keys: ~w(book_id)},
    "placement.reading_completed" => %{version: 1, keys: ~w(book_id)},
    # ── library imports (US-1.1.9) ────────────────────────────────────────────
    # Counts ONLY — never row content. A raw import row is the reader's own free
    # text (reviews, private notes) with a 30-day retention; an event payload is
    # immutable. Any row detail on these events would outlive its erasure path.
    "library_import.started" => %{version: 1, keys: ~w(user_id source row_count)},
    "library_import.completed" => %{
      version: 1,
      keys:
        ~w(user_id source status row_count shelved_count duplicate_count unverified_count unreadable_count)
    },
    # ── accounts / user ───────────────────────────────────────────────────────
    "user.registered" => %{version: 1, keys: ~w(role)},
    "user.profile_updated" => %{version: 1, keys: ~w()},
    "user.profile_visibility_changed" => %{version: 1, keys: ~w(visibility)},
    "user.location_updated" => %{version: 1, keys: ~w()},
    "user.password_changed" => %{version: 1, keys: ~w()},
    # US-14.1.3 — deliberately no code, no note, no invited address; a payload
    # carrying any of those would fail this contract in test.
    "invite.issued" => %{version: 1, keys: ~w(max_uses expires_at email_bound)},
    "invite.redeemed" => %{version: 1, keys: ~w(user_id use_count)},
    "invite.revoked" => %{version: 1, keys: ~w()},
    "user.notifications_updated" => %{version: 1, keys: ~w()},
    "user.visibility_recap_completed" => %{
      version: 1,
      keys: ~w(bookshelves_capped new_visibility placements_capped posts_capped)
    },
    # ── social ────────────────────────────────────────────────────────────────
    "social.user_blocked" => %{version: 1, keys: ~w(blocked_id)},
    "social.user_unblocked" => %{version: 1, keys: ~w(blocked_id)},
    "group.created" => %{version: 1, keys: ~w(owner_id)},
    "group.invitation_sent" => %{version: 1, keys: ~w(invited_by_id invited_user_id)},
    "group.member_joined" => %{version: 1, keys: ~w(user_id)},
    "group.member_left" => %{version: 1, keys: ~w(user_id)},
    "group.member_removed" => %{version: 1, keys: ~w(removed_by_id removed_user_id)},
    # ── marketplace ───────────────────────────────────────────────────────────
    "listing.created" => %{version: 1, keys: ~w(book_id seller_id)},
    "listing.activated" => %{version: 1, keys: ~w(book_id seller_id)},
    "listing.removed" => %{version: 1, keys: ~w(book_id seller_id)},
    "listing.sold" => %{version: 1, keys: ~w(book_id seller_id)},
    "listing.expired" => %{version: 1, keys: ~w(book_id seller_id)},
    # ── partners (business, not user) ─────────────────────────────────────────
    "partner.event_created" => %{version: 1, keys: ~w(space_id title)},
    "partner.event_deleted" => %{version: 1, keys: ~w(space_id)},
    "partner.inventory_synced" => %{version: 1, keys: ~w(synced unresolved_count)},
    # ── enrichment / discovery (system/operational) ───────────────────────────
    "source.approved" => %{version: 1, keys: ~w(status)},
    # `geocoded` is carried so an operator can see, from the event stream alone, how many
    # approvals produced a mappable space versus an unpositioned one — the difference
    # between a working geocoder and a silently degraded one.
    "third_space.created" => %{version: 1, keys: ~w(source_id geocoded)},
    # No payload at all: `aggregate_id` is the space's own id, which says everything the
    # event needs to. An earlier draft carried the business URL and the PII lint refused
    # it — `event_log` is immutable, so free text in it is permanent.
    "third_space.delisted" => %{version: 1, keys: ~w()},
    "source.rejected" => %{version: 1, keys: ~w(status)},
    "enrichment.sources_discovered" => %{version: 1, keys: ~w(count query source_ids)},
    "enrichment.author_sources_discovered" => %{version: 1, keys: ~w(rss_feed_url website_url)},
    "enrichment.author_updated" => %{version: 1, keys: ~w(author_id new_entries)},
    "enrichment.events_discovered" => %{version: 1, keys: ~w(events_count store_name)},
    "enrichment.prices_scraped" => %{version: 1, keys: ~w(book_ids count)},
    "enrichment.reviews_scraped" => %{version: 1, keys: ~w(book_count)},
    # ── ops / monitoring ──────────────────────────────────────────────────────
    "costs.refreshed" => %{version: 1, keys: ~w(item_count period vision_jobs)},
    "source_health.recorded" => %{
      version: 1,
      keys: ~w(consecutive_failures source_name source_type status)
    }
  }

  # Payload keys whose NAME looks personal/free-text but are verified NOT user PII —
  # each carries a justification (mirrors the erasure schema-guard's nilify allowlist).
  # The PII-lint fails on any personal-shaped key absent from this list.
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
    # US-14.1.3: a BOOLEAN — whether the invitation is bound to some address —
    # deliberately chosen so event_log never carries the address itself.
    "email_bound" => "boolean flag (bound-or-not), never the address itself"
  }

  # Substrings that mark a payload key as personal/free-text-shaped (PII-lint trigger).
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
