defmodule Stacks.Workers.PostBookAssociationWorker do
  @moduledoc """
      Oban worker that uses an LLM to discover which books from the catalogue
      are discussed in a newly published blog post.

      Triggered by `blog.post_published` via `BlogAssociationHandler`.

      The post's body is sent to a third party (Together AI), so the author's
      writing-assistant consent gates the whole run: without it the worker
      stops before a prompt is built and nothing reaches the client seam. The
      consent is the author's, not the reader's — the body is the author's
      writing.

      Associations derived before the author's consent was withdrawn are left
      standing. They are book links (`post_id`, `book_id`, a confidence and a
      short reasoning string), not copies of the body, so revocation has
      nothing here to erase; the writing-assistant data that IS derived from
      the author's own text is purged by `WritingAssistantDataPurgeWorker`.

      Every terminal path counts itself under `[:stacks, :blog, :association]`
      with an `:outcome` label, so a consent-blocked run is visible as a number
      rather than only as a line in the log.
  """

  use Stacks.Worker, scope: :system, queue: :default, max_attempts: 3

  require Logger

  import Ecto.Query

  alias Core.Repo
  alias Stacks.AI.Structured
  alias Stacks.Blog
  alias Stacks.Books.Book
  alias Stacks.Events
  alias Stacks.GDPR.Consent

  @impl true
  def perform(%Oban.Job{args: %{"post_id" => post_id}}) do
    case Blog.get_post(post_id) do
      nil ->
        Logger.warning("PostBookAssociationWorker: post #{post_id} not found")
        emit_outcome(:post_missing)
        :ok

      post ->
        run_association(post)
    end
  end

  @max_books 200
  @max_post_length 4000

  defp run_association(post) do
    if Consent.check_consent(post.user_id, "writing_assistant") do
      associate_with_catalogue(post)
    else
      Logger.info(
        "PostBookAssociationWorker: author of post #{post.id} has not granted " <>
          "writing-assistant consent, skipping"
      )

      emit_outcome(:no_consent)
      :ok
    end
  end

  defp associate_with_catalogue(post) do
    books =
      Repo.all(
        from(b in Book, order_by: [desc: b.created_at], limit: @max_books, preload: [:author])
      )

    if books == [] do
      Logger.info("PostBookAssociationWorker: no books in catalogue, skipping")
      emit_outcome(:no_catalogue)
      :ok
    else
      prompt = build_prompt(post.body, books)

      case together_client().complete(prompt, max_tokens: 1024, temperature: 0.2) do
        {:ok, response} ->
          handle_response(post, response)

        {:error, reason} ->
          Logger.warning(
            "PostBookAssociationWorker: LLM call failed for post #{post.id}: #{inspect(reason)}"
          )

          emit_outcome(:llm_error)
          {:error, reason}
      end
    end
  end

  defp emit_outcome(outcome) do
    :telemetry.execute([:stacks, :blog, :association], %{count: 1}, %{outcome: outcome})
  end

  defp build_prompt(post_body, books) when is_binary(post_body) do
    post_body = String.slice(post_body, 0, @max_post_length)

    book_list =
      Enum.map_join(books, "\n", fn book ->
        author_name = if book.author, do: book.author.name, else: "Unknown"
        "- #{book.id}: \"#{book.title}\" by #{author_name}"
      end)

    """
    You are analyzing a blog post to find which books from a catalogue are discussed.

    Post content:
    #{post_body}

    Books in catalogue:
    #{book_list}

    Return a JSON array of objects with keys: book_id, confidence (0.0-1.0), reasoning.
    Only include books that are clearly discussed or referenced in the post. Return [] if none.
    """
  end

  # ⛔ THROUGH `Stacks.AI.Structured`, NOT `Jason.decode/1` DIRECTLY. MEASURED
  # against the live model: 3 of 3 responses came back FENCED — ```json … ``` —
  # and `Jason.decode/1` fails on the first character of every one. The
  # associations were dropped, a warning was logged, and the text that would
  # have explained it was discarded.
  #
  # ⚖️ The two failures are kept apart on purpose. `:unparseable` is the model
  # answering in a shape nothing can read; `:unexpected_shape` is valid JSON
  # that is not a list, i.e. the model understood the format and not the task.
  # They want different fixes — a parsing change versus a prompt change — and
  # one outcome atom for both would hide which is happening.
  defp handle_response(post, response) do
    case Structured.decode(response) do
      {:ok, associations} ->
        persist_associations(post, associations)

      {:error, {:unexpected_shape, raw}} ->
        Logger.warning(
          "PostBookAssociationWorker: unexpected JSON shape for post #{post.id}: " <>
            String.slice(raw, 0, 200)
        )

        emit_outcome(:unreadable_response)
        :ok

      {:error, {:unparseable, raw}} ->
        # ⚠️ The raw text is logged, bounded, rather than thrown away. Until
        # `op.llm_call_log` lands this is the only record of what the model
        # actually said, and "failed to parse" without it is unactionable.
        Logger.warning(
          "PostBookAssociationWorker: could not read the LLM response for post #{post.id}: " <>
            String.slice(raw, 0, 200)
        )

        emit_outcome(:unreadable_response)
        :ok
    end
  end

  defp persist_associations(post, associations) do
    book_ids =
      associations
      |> Enum.reduce([], fn assoc, acc -> associate_single(post, assoc, acc) end)

    Events.emit_safe(%{
      event_type: "blog.associations_suggested",
      aggregate_type: "post",
      aggregate_id: post.id,
      payload: %{book_ids: book_ids, count: length(book_ids)}
    })

    emit_outcome(:associated)
    :ok
  end

  # ⚠️ Atom keys, because `Structured.decode/2` has already normalised them and
  # filtered the entries it could not read. The string-keyed `Map.get` that was
  # here trusted the model's spelling of its own field names.
  defp associate_single(post, assoc, acc) do
    %{book_id: book_id, confidence: confidence, reasoning: reasoning} = assoc
    attrs = %{source: "llm", confidence: confidence, reasoning: reasoning, visible: true}

    case Blog.associate_book(post, book_id, attrs) do
      {:ok, _} ->
        [book_id | acc]

      {:error, reason} ->
        Logger.warning(
          "PostBookAssociationWorker: failed to associate book #{book_id}: #{inspect(reason)}"
        )

        acc
    end
  end

  defp together_client do
    Application.get_env(:core, :together_client, Stacks.AI.TogetherClient)
  end
end
