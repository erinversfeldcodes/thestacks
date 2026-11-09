defmodule Stacks.AI.CallLog do
  @moduledoc """
      What we asked a model, what it answered, and whether we could read it.

      ⛔ HAND-WRITTEN RATHER THAN GENERATED, DELIBERATELY. The schemas under
      `Stacks.Gen.*` are produced from `.proto` files because they describe data
      that crosses a wire. This describes data that must never cross one: it is
      a diagnostic and eval-capture record, and giving it a proto contract would
      invite a consumer it should not have.

      ⚖️ **PERSONAL DATA.** `raw_response` is a model's text about a reader's
      post. The row is reachable by erasure through `blog_posts` → `users`, both
      cascading — see the migration for why `nilify_all` would have been the
      wrong choice twice over.

      ⚠️ THE PROMPT IS NEVER STORED. It embeds the post body, and a diagnostic
      table holding a second copy of a reader's writing is an undeclared archive
      of personal data. `prompt_sha256` answers the only question the prompt is
      needed for here — "was this the same prompt as that one?" — without
      keeping the text.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]
  @type t :: %__MODULE__{}

  # ⛔ MIRRORS THE DATABASE CONSTRAINT, and does not replace it. A changeset
  # validation catches the ordinary path with a usable error; the CHECK catches
  # every other writer. Having only the changeset would leave a backfill or a
  # console session free to write an unbounded row, and the thing being bounded
  # is a remote model's output.
  @max_raw_bytes 8_192

  # ⚠️ `no_books_found` is a SUCCESS, not a failure: the pass ran and the
  # model found nothing. It is separate from `associated` because the two used
  # to share a label, which made a working pass over a post with no books
  # indistinguishable from one that linked three — to the dashboard and to the
  # author alike.
  @outcomes ~w(associated no_books_found unreadable_response unexpected_shape llm_error)

  schema "llm_call_log" do
    field :post_id, :binary_id
    field :model, :string
    field :prompt_sha256, :string
    field :outcome, :string
    field :latency_ms, :integer
    field :raw_response, :string

    timestamps()
  end

  @doc "The bounded record of one call."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :post_id,
      :model,
      :prompt_sha256,
      :outcome,
      :latency_ms,
      :raw_response
    ])
    |> validate_required([:post_id, :model, :prompt_sha256, :outcome])
    |> validate_inclusion(:outcome, @outcomes)
    |> truncate_raw()
    |> foreign_key_constraint(:post_id)
    |> check_constraint(:raw_response, name: :raw_response_is_bounded)
  end

  @doc """
      The hash a prompt is stored as.

      ⚖️ Public because the caller computes it — the prompt should not travel
      into this module just to be hashed and dropped, which would put a reader's
      post body in one more place for no benefit.
  """
  @spec hash_prompt(String.t()) :: String.t()
  def hash_prompt(prompt) when is_binary(prompt) do
    :crypto.hash(:sha256, prompt) |> Base.encode16(case: :lower)
  end

  # ⚠️ TRUNCATES RATHER THAN REJECTING. A response too long to store is still
  # evidence about what happened, and refusing the row would lose the outcome,
  # the latency and the token counts along with it — trading all the diagnostic
  # value for strictness about the one field that has a bound.
  #
  # ⛔ Bytes, not characters: the CHECK is `octet_length`, and an 8_192-CHARACTER
  # slice of multi-byte text is larger than 8_192 bytes. Slicing by characters
  # would pass the changeset and fail at the database, which is the kind of
  # disagreement that only shows up in production.
  #
  # ⛔ BUT A BYTE SLICE ALONE CREATED THE VERY DISAGREEMENT THE LINE ABOVE
  # CLAIMS TO PREVENT, and it was measured: `binary_part/3` can cut inside a
  # multi-byte codepoint, and Postgres then refuses the value outright —
  # `ERROR 22021 (character_not_in_repertoire) invalid byte sequence for
  # encoding "UTF8": 0xc3`. 8,191 ASCII bytes followed by "é" produced a
  # valid-looking 8,192-byte changeset ending `<<97, 97, 195>>`.
  #
  # ⚠️ And it failed INVISIBLY, which is worse than crashing: the worker's
  # `record_call/5` rescues, so the row is simply dropped — for precisely the
  # longest responses, which are the ones this table exists to capture. Model
  # output about books carries curly quotes, em-dashes and accented author
  # names as a matter of course.
  #
  # ⚖️ So trailing bytes come off until the result is valid UTF-8: at most three
  # iterations, since no codepoint is longer than four bytes. Under the bound in
  # bytes AND decodable, which is what the column actually requires.
  defp truncate_raw(changeset) do
    case get_change(changeset, :raw_response) do
      raw when is_binary(raw) and byte_size(raw) > @max_raw_bytes ->
        put_change(changeset, :raw_response, trim_to_valid_utf8(raw, @max_raw_bytes))

      _ ->
        changeset
    end
  end

  defp trim_to_valid_utf8(_raw, size) when size <= 0, do: ""

  defp trim_to_valid_utf8(raw, size) do
    candidate = binary_part(raw, 0, size)

    if String.valid?(candidate) do
      candidate
    else
      trim_to_valid_utf8(raw, size - 1)
    end
  end
end
