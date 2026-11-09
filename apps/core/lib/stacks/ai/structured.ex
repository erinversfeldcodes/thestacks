defmodule Stacks.AI.Structured do
  @moduledoc """
      Reading a model's answer as data, and keeping the answer when it cannot be.

      ⛔ THE BOUNDARY HAD NO CONTRACT, AND THE FAILURE WAS SILENT. The worker
      asked for JSON in prose and ran `Jason.decode/1` on whatever came back.
      MEASURED against the live model (`Llama-3.3-70B-Instruct-Turbo`, the
      worker's own prompt, three calls): **3 of 3 responses were fenced** — they
      begin ` ```json ` and end ` ``` ` — and `Jason.decode/1` fails on the first
      character of every one of them. The associations were dropped, a warning
      was logged, and the text that would have explained it was thrown away.

      ⚖️ TWO THINGS FIX THAT, AND THEY ARE DIFFERENT THINGS. Asking the provider
      for `response_format: json_schema` makes a fenced answer unlikely; this
      module makes one survivable. Neither replaces the other — a schema is a
      request, not a guarantee, and a model that ignores it must not take the
      association chain down with it.

      ⚠️ ON FAILURE THE RAW TEXT TRAVELS WITH THE ERROR. `{:error, {:unparseable,
      raw}}` rather than `{:error, :unparseable}`, because the question anyone
      asks next is "what did it actually say?" and the old code's answer was
      "gone". The caller bounds it before storing; this module does not truncate,
      having just been written to survive a truncation.
  """

  @typedoc "One association the model proposes: which book, how sure, and why."
  @type association :: %{
          book_id: String.t(),
          confidence: float(),
          reasoning: String.t()
        }

  @type failure :: {:unparseable, String.t()} | {:unexpected_shape, String.t()}

  @doc """
      The output schema for a book-association answer.

      ⚖️ Lives beside the decoder deliberately. The schema describes what we ask
      for and the decoder describes what we accept, and the two drifting apart
      is how a boundary stops having a contract — asking for `confidence` while
      reading `score` would be invisible until a model obeyed the schema.

      ⚠️ `additionalProperties: false` because a model that volunteers extra
      fields is answering a different question, and `required` names only
      `book_id`: a missing confidence is still a usable answer, which is the
      same judgement `normalise/1` makes one layer down.
  """
  @spec association_schema() :: map()
  def association_schema do
    %{
      name: "book_associations",
      strict: true,
      schema: %{
        # ⛔ AN OBJECT AT THE ROOT, WRAPPING THE ARRAY, AND THE REASON IS A
        # DOCUMENTED LIMIT RATHER THAN A PREFERENCE.
        #
        # Together's API reference defines `json_schema` without stating a root
        # restriction, but every example it gives uses an object; OpenAI's
        # equivalent states the root "must be an object". An array root is
        # therefore somewhere between unsupported and undocumented, which is not
        # a difference worth betting the boundary on.
        #
        # ⚖️ `decode/2` accepts BOTH this wrapped shape and the bare array the
        # model sends when nothing constrains it, so the two can never disagree
        # about which is correct — and a provider that ignores the schema
        # entirely still lands somewhere the decoder understands.
        type: "object",
        additionalProperties: false,
        required: ["associations"],
        properties: %{
          associations: %{
            type: "array",
            items: %{
              type: "object",
              additionalProperties: false,
              # ⛔ EVERY KEY IS REQUIRED, AND THE OPTIONAL ONES ARE NULLABLE
              # INSTEAD. This said `required: ["book_id"]`, which reads more
              # honestly — a missing confidence is still a usable answer — and
              # may be invalid: OpenAI's structured-output rules state that with
              # `strict: true` ALL fields must be listed as required, with
              # optionality expressed as a null union. Together's reference is
              # SILENT on the point; it says only "Only a subset of JSON Schema
              # is supported when `strict` is `true`".
              #
              # ⚠️ So the stricter reading is the one that cannot be wrong: a
              # schema valid under both interpretations is accepted by both. The
              # cost is a model that answers `"confidence": null`, which
              # `normalise/1` already handles — it defaults a missing or null
              # confidence to 0.0 and keeps the association.
              required: ["book_id", "confidence", "reasoning"],
              properties: %{
                book_id: %{type: "string"},
                confidence: %{type: ["number", "null"], minimum: 0.0, maximum: 1.0},
                reasoning: %{type: ["string", "null"]}
              }
            }
          }
        }
      }
    }
  end

  @doc """
      Decode a completion into associations.

      Accepts a bare JSON array and a fenced one — ` ```json `, ` ``` `, with or
      without a trailing newline — because the model sends all of these and the
      difference is not meaningful.
  """
  @spec decode(String.t(), keyword()) :: {:ok, [association()]} | {:error, failure()}
  def decode(raw, _opts \\ []) when is_binary(raw) do
    case raw |> strip_fence() |> Jason.decode() do
      {:ok, items} when is_list(items) ->
        {:ok, Enum.flat_map(items, &normalise/1)}

      # ⚖️ THE SHAPE THE SCHEMA ASKS FOR. `association_schema/0` wraps the array
      # in an object because an array root is undocumented on this provider —
      # so a model that OBEYS the schema sends `{"associations": [...]}` while
      # one that ignores it sends the bare array. Both are the same answer, and
      # refusing one of them would make the schema's own success look like a
      # parse failure.
      {:ok, %{"associations" => items}} when is_list(items) ->
        {:ok, Enum.flat_map(items, &normalise/1)}

      # ⚠️ A DIFFERENT FAILURE FROM UNPARSEABLE, and worth its own name. Valid
      # JSON that is not a list means the model understood the format and not
      # the task — a prose object, or a single association where an array was
      # asked for. Collapsing the two would hide which one is happening, and
      # they want different fixes: one is a prompt problem, the other a parsing
      # problem.
      {:ok, _other} ->
        {:error, {:unexpected_shape, raw}}

      {:error, _} ->
        {:error, {:unparseable, raw}}
    end
  end

  # ⛔ THE FENCE IS STRIPPED, NOT MATCHED EXACTLY. The model varies the opening
  # (` ```json `, ` ```JSON `, bare ` ``` `), the line endings, and whether a
  # newline follows at all — and pinning one spelling re-creates the defect one
  # variant along. This regex has been wrong twice in two different directions,
  # so the reasoning is written out rather than assumed:
  #
  # ⚠️ **It is FOUND, not required to be the whole answer.** It used to be
  # anchored `\A…\z`, so "Here are the associations I found:" before the fence —
  # or "hope that helps" after it — defeated the strip entirely and the response
  # came back `:unparseable`. Chatty models do that constantly, and 16 tests in
  # this module's suite did not see it; the association corpus found it.
  #
  # ⛔ **THE OPENING ANCHOR IS THE WHOLE OF THE SAFETY, and it has to be,
  # because the first fix got this wrong.** Unanchoring without it matched ```
  # INSIDE a JSON string — a `reasoning` field quoting a code block — and
  # strip-then-parse turned a good response into garbage. `(?:\A|\r?\n)` requires
  # the fence to sit at the start or after a RAW newline, and no input
  # `Jason.decode/1` accepts can satisfy that inside itself: a raw newline is
  # invalid inside a JSON string, and no line of valid JSON begins with three
  # backticks. That is a proof rather than a probe, which matters because the
  # alternative — a runtime guard that re-parses and falls back — makes this
  # pattern's quality unobservable and is how the first fix went unnoticed.
  #
  # ⚠️ **The newlines around the content are OPTIONAL, and `\r` is matched
  # everywhere whitespace is.** The second fix narrowed `\s` to `[ \t]` and made
  # the inner newline mandatory, which cost three shapes that had worked:
  # **CRLF line endings** (transport-level, so it would arrive as a blanket
  # failure rather than an occasional one), a single-line
  # ` ```json [...] ``` `, and prose on the same line as the closing fence.
  # None of them weaken the anchor above.
  #
  # ⚖️ The content is GREEDY and there is no end anchor, which decides one case:
  # a response carrying TWO fenced blocks spans both and fails as unparseable
  # rather than silently returning the first. Two blocks is two answers, and
  # picking one would be a guess presented as a result — `:unparseable` tells
  # the author honestly and leaves the raw text in the call log.
  defp strip_fence(raw) do
    trimmed = String.trim(raw)

    case Regex.run(~r/(?:\A|\r?\n)```[a-zA-Z]*[ \t\r]*\r?\n?(.*)\r?\n?[ \t\r]*```/s, trimmed) do
      [_, inner] -> String.trim(inner)
      _ -> trimmed
    end
  end

  # ⚠️ DROPS AN ITEM IT CANNOT READ RATHER THAN FAILING THE WHOLE ANSWER. One
  # malformed entry among five should not cost the other four — the worker's
  # old behaviour was all-or-nothing in the other direction, and losing every
  # association to one bad row is the same defect wearing a different face.
  #
  # ⚖️ `book_id` is the only required field. A missing confidence is a model
  # that did not answer the question asked; it is still telling us which book,
  # and the caller decides what an unscored association is worth.
  defp normalise(%{"book_id" => book_id} = item) when is_binary(book_id) do
    [
      %{
        book_id: book_id,
        confidence: as_float(Map.get(item, "confidence")),
        reasoning: as_string(Map.get(item, "reasoning"))
      }
    ]
  end

  defp normalise(_), do: []

  # ⛔ CLAMPED TO [0, 1], AND THE PAGE IS WHY.
  #
  # Nothing guarded the range: no `validate_number`, no CHECK constraint, a
  # plain `:float` column — so a model answering `1.4` had it persisted, and
  # `Blog.list_associations/1` orders by `confidence desc`. **A hallucinated 1.4
  # therefore sorted above a legitimate 1.0 on the author's own page**: the
  # least trustworthy answer presented first, because it was the most confident.
  #
  # ⚖️ Clamped rather than dropped. The ASSOCIATION is still information — the
  # model named a book the post discusses — and only the number is out of
  # range, so discarding the row would throw away the useful half to punish the
  # useless one. Clamping is the smallest edit that restores the ordering's
  # meaning.
  #
  # ⚠️ Done at the BOUNDARY rather than in the changeset, because this is where
  # the provider's answer becomes ours: a changeset rule would leave every
  # other reader of `decode/2` holding an unclamped number.
  defp as_float(value) when is_float(value), do: clamp(value)
  defp as_float(value) when is_integer(value), do: clamp(value * 1.0)

  defp as_float(value) when is_binary(value) do
    case Float.parse(value) do
      # ⚠️ Clamped here too. `as_float/1` has three branches and a clamp on two
      # of them is a clamp with a hole — a model sending `"2.5"` as a string
      # went straight through, which a case caught the moment the number became
      # observable.
      {float, _} -> clamp(float)
      :error -> 0.0
    end
  end

  defp as_float(_), do: 0.0

  defp clamp(value) when value < 0.0, do: 0.0
  defp clamp(value) when value > 1.0, do: 1.0
  defp clamp(value), do: value
  defp as_string(value) when is_binary(value), do: value
  defp as_string(nil), do: ""
  defp as_string(value), do: to_string(value)
end
