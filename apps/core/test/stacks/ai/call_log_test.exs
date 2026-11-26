defmodule Stacks.AI.CallLogTest do
  @moduledoc """
      What the call log keeps, what it refuses, and what erasure does to it.

      ⛔ THE ERASURE CASE IS THE ONE THAT MATTERS. This table holds a model's
      text about a reader's post, which is personal data. The GDPR epic's
      defining failure was a free-text column that survived seven reviews and a
      green schema-guard because nobody drove a deletion through it — so this
      file deletes a user and looks.
  """
  use Core.DataCase, async: false

  import Ecto.Query
  import Stacks.Factory

  alias Core.Repo
  alias Stacks.AI.CallLog

  defp a_logged_call(attrs \\ %{}) do
    user = insert(:user)
    post = insert(:post, user: user)

    {:ok, entry} =
      %CallLog{}
      |> CallLog.changeset(
        Map.merge(
          %{
            post_id: post.id,
            model: "meta-llama/Llama-3.3-70B-Instruct-Turbo",
            prompt_sha256: CallLog.hash_prompt("the prompt"),
            outcome: "associated",
            raw_response: "[]"
          },
          attrs
        )
      )
      |> Repo.insert()

    {user, post, entry}
  end

  describe "erasure reaches it" do
    test "deleting the reader deletes what the model said about their post" do
      {user, _post, entry} = a_logged_call()

      # ⛔ ANTI-VACUITY, and the half the GDPR epic's defect slipped through:
      # the row must exist FIRST. Without this the assertion below passes
      # against a table that never held anything.
      assert Repo.get(CallLog, entry.id)

      Repo.delete!(user)

      refute Repo.get(CallLog, entry.id),
             "the model's text about a deleted reader's post is still here — a cascade " <>
               "that removes the reference while keeping the content is the defect this " <>
               "table was designed against"
    end
  end

  describe "what it refuses to keep" do
    # ⚠️ The prompt embeds the post body. Storing it would make this diagnostic
    # table an undeclared second archive of a reader's writing.
    test "there is nowhere to put a prompt, only its hash" do
      columns =
        Repo.query!("""
        SELECT column_name FROM information_schema.columns
        WHERE table_schema = 'op' AND table_name = 'llm_call_log'
        """).rows
        |> List.flatten()

      assert "prompt_sha256" in columns

      refute "prompt" in columns,
             "a column for the prompt text would hold the post body a second time"
    end

    test "the hash is stable and does not reveal its input" do
      hash = CallLog.hash_prompt("a post about lighthouses")

      assert hash == CallLog.hash_prompt("a post about lighthouses")
      refute hash =~ "lighthouse"
      assert String.length(hash) == 64
    end

    # ⛔ TRUNCATES RATHER THAN REJECTING — losing the row would lose the
    # outcome, latency and token counts along with the oversized field.
    test "an oversized response is cut to the bound, and the row survives" do
      {_user, _post, entry} = a_logged_call(%{raw_response: String.duplicate("x", 20_000)})

      assert byte_size(entry.raw_response) == 8_192
    end

    # ⚖️ Bytes, not characters: the database CHECK is `octet_length`, so a
    # character-based slice of multi-byte text would pass the changeset and
    # fail at the database — a disagreement that only shows up in production.
    test "the bound is bytes, so multi-byte text does not slip past it" do
      {_user, _post, entry} = a_logged_call(%{raw_response: String.duplicate("é", 9_000)})

      assert byte_size(entry.raw_response) <= 8_192
    end

    test "an unknown outcome is refused" do
      user = insert(:user)
      post = insert(:post, user: user)

      changeset =
        CallLog.changeset(%CallLog{}, %{
          post_id: post.id,
          model: "m",
          prompt_sha256: CallLog.hash_prompt("p"),
          outcome: "something_new"
        })

      refute changeset.valid?,
             "the outcome vocabulary is closed — a typo in a new call site must fail " <>
               "rather than quietly split the metric"
    end
  end

  describe "what it keeps" do
    test "a transport error records no response, rather than an empty one" do
      {_user, _post, entry} = a_logged_call(%{outcome: "llm_error", raw_response: nil})

      assert entry.outcome == "llm_error"

      assert is_nil(entry.raw_response),
             "NULL and \"\" must stay distinguishable: one is 'never reached', the " <>
               "other is 'answered with nothing'"
    end

    test "a successful call is recorded too, not only the failures" do
      {_user, post, _entry} = a_logged_call(%{outcome: "associated"})

      rows =
        Repo.all(from c in CallLog, where: c.post_id == ^post.id, select: c.outcome)

      assert rows == ["associated"],
             "an eval harness needs what the model usually does, which a failures-only " <>
               "log cannot answer"
    end
  end

  describe "truncating a response that is not plain ASCII" do
    # ⛔ A BYTE SLICE PRODUCED INVALID UTF-8, POSTGRES REFUSED IT, AND THE ROW
    # WAS SILENTLY LOST — for precisely the longest responses, which are the
    # ones this table exists to capture.
    #
    # `binary_part/3` can cut inside a multi-byte codepoint. Measured before
    # the fix: 8,191 ASCII bytes followed by "é" yielded an 8,192-byte value
    # ending `<<97, 97, 195>>`, and `Repo.insert` raised
    # `ERROR 22021 (character_not_in_repertoire) invalid byte sequence for
    # encoding "UTF8": 0xc3`. The worker's `record_call/5` rescues, so nothing
    # crashed and nothing was recorded.
    #
    # ⚠️ The comment above `truncate_raw/1` argued that byte-slicing existed to
    # avoid "a changeset that passes and a database that fails". It was what
    # created one. Model output about books carries curly quotes, em-dashes and
    # accented author names as a matter of course.
    test "a cut that would sever a codepoint is backed off until it is valid" do
      raw = String.duplicate("a", 8_191) <> "é"

      changeset = CallLog.changeset(%CallLog{}, valid_attrs(raw_response: raw))
      stored = Ecto.Changeset.get_field(changeset, :raw_response)

      assert String.valid?(stored),
             "the stored value is not valid UTF-8 — byte_size=#{byte_size(stored)}, " <>
               "tail=#{inspect(binary_part(stored, byte_size(stored) - 3, 3))}"

      assert byte_size(stored) <= 8_192
    end

    # ⬛ AND IT REACHES THE DATABASE, which is the claim that matters: the
    # changeset being valid was never the problem.
    test "the truncated value is accepted by the database" do
      raw = String.duplicate("a", 8_191) <> "é"
      post = insert(:post, user: insert(:user))

      assert {:ok, log} =
               %CallLog{}
               |> CallLog.changeset(valid_attrs(post_id: post.id, raw_response: raw))
               |> Repo.insert()

      assert String.valid?(log.raw_response)
    end

    # ⚠️ A multi-byte response that needs MORE than one byte backed off — a
    # three-byte codepoint severed at its first byte needs two.
    test "a three-byte codepoint is backed off correctly" do
      raw = String.duplicate("a", 8_190) <> "—" <> "tail"

      changeset = CallLog.changeset(%CallLog{}, valid_attrs(raw_response: raw))
      stored = Ecto.Changeset.get_field(changeset, :raw_response)

      assert String.valid?(stored)
      assert byte_size(stored) <= 8_192
    end

    # ⬛ ANTI-VACUITY: a value already under the bound must be stored UNCUT, or
    # a truncator that returned "" would satisfy every case above.
    test "a short response is not touched" do
      raw = ~s([{"book_id": "abc", "reasoning": "an em—dash and a curly ’quote’"}])

      changeset = CallLog.changeset(%CallLog{}, valid_attrs(raw_response: raw))

      assert Ecto.Changeset.get_field(changeset, :raw_response) == raw
    end
  end

  # ⚖️ The required fields, so each case above states only the one thing it is
  # about. `post_id` defaults to a generated UUID because most of these cases
  # never reach the database and do not need a real post.
  defp valid_attrs(overrides) do
    Map.merge(
      %{
        post_id: Ecto.UUID.generate(),
        model: "m",
        prompt_sha256: CallLog.hash_prompt("p"),
        outcome: "associated"
      },
      Map.new(overrides)
    )
  end
end
