defmodule Stacks.AI.VisionFixtures do
  @moduledoc """
    Canonical `/analyze` response shapes for steering `Stacks.AI.MockClient`.

    Before every test file that needed a non-default vision answer
    defined its own `@behaviour Stacks.AI.ClientBehaviour` module and swapped it
    in with `Application.put_env(:core,:vision_client, …)`. Each of those was a
    hand-written mirror of the production response shape, free to drift from it
    independently — and at least one had already drifted. This module is the one
    place the shape is written down; `Stacks.AI.MockClient` is the one place it is
    served from.

    ## Usage

        import Stacks.AI.VisionFixtures

        steer_vision(not_a_book)
        assert {:error,:not_a_book} = Moderation.run_pipeline(context)

        steer_vision(books_with_isbns(["9780743273565"]))
        steer_vision(service_error)

        with_vision(no_isbn, fn -> perform_job(IdentifyBookJob, args) end)

    Steering is process-local (`Stacks.AI.MockClient` keeps registrations in the
    process dictionary and looks them up through `$callers`), so it reaches Tasks
    the pipeline spawns and jobs run inline by `perform_job/2` or
    `Oban.drain_queue/1`, without mutating any global.
  """

  alias Stacks.AI.MockClient

  @book "CLASSIFICATION_RESULT_BOOK"
  @not_book "CLASSIFICATION_RESULT_NOT_BOOK"
  @ambiguous "CLASSIFICATION_RESULT_AMBIGUOUS"

  @doc """
    Register `response` as the answer to `endpoint` for the current process.

    Defaults to `"analyze"`, the only endpoint the post-consolidation Moderation
    pipeline calls. Pass `:any` to steer every endpoint.
  """
  def steer_vision(response, endpoint \\ "analyze"),
    do: MockClient.put_response(endpoint, response)

  @doc """
    Steer the vision seam for the duration of `fun`, then clear the registration.

    Use when a single test needs two different vision answers in sequence, or when
    work continues in the same process after the steered call and must see the
    default again. A test that steers once does not need this — the process
    dictionary dies with the test process.
  """
  def with_vision(response, fun), do: with_vision("analyze", response, fun)

  def with_vision(endpoint, response, fun) do
    steer_vision(response, endpoint)

    try do
      fun.()
    after
      MockClient.clear()
    end
  end

  @doc """
    Build an `/analyze` success response.

    Options: `:confidence` (image-level, default `0.9`) and `:model_used`
    (default `"mock"` — set it to `"local_ocr"` or a VLM name when the test
    asserts on extraction provenance).
  """
  def analyze_response(classification, books, opts \\ []) do
    {:ok,
     %{
       "classification" => classification,
       "confidence" => Keyword.get(opts, :confidence, 0.9),
       "books" => books,
       "model_used" => Keyword.get(opts, :model_used, "mock")
     }}
  end

  @doc """
    Build one entry of the `"books"` list.

    The base candidate carries `title`, `author`, `potential_isbns` and `raw_text`
    but **no** `confidence` key — pre-prompt-v2 payloads genuinely omit it, and
    the threshold gate treats absent and present-nil differently. Pass
    `confidence:` explicitly whenever the candidate should carry one.
  """
  def book_candidate(overrides \\ []) do
    base = %{
      "title" => nil,
      "author" => nil,
      "potential_isbns" => [],
      "raw_text" => nil
    }

    Enum.reduce(overrides, base, fn {key, value}, acc ->
      Map.put(acc, Atom.to_string(key), value)
    end)
  end

  @doc "BOOK classification carrying `books`."
  def book_response(books, opts \\ []), do: analyze_response(@book, books, opts)

  @doc """
    BOOK classification with one plain candidate per ISBN. The common case.

    `:candidate_confidence` (default `0.9`) sets each candidate's confidence — the
    one the threshold gate reads. `:confidence` keeps its
    `analyze_response/3` meaning: the image-level classification confidence.
  """
  def books_with_isbns(isbns, opts \\ []) do
    {candidate_confidence, response_opts} = Keyword.pop(opts, :candidate_confidence, 0.9)

    isbns
    |> Enum.map(&book_candidate(potential_isbns: [&1], confidence: candidate_confidence))
    |> book_response(response_opts)
  end

  @doc "NOT_BOOK — Moderation rejects with `:not_a_book`."
  def not_a_book(opts \\ []),
    do: analyze_response(@not_book, [], Keyword.put_new(opts, :confidence, 0.95))

  @doc """
    AMBIGUOUS — treated as not-a-book by Moderation (only BOOK short-circuits
    into extraction), so `books` stays empty.
  """
  def ambiguous(opts \\ []),
    do: analyze_response(@ambiguous, [], Keyword.put_new(opts, :confidence, 0.5))

  @doc "BOOK classification with an empty candidate list — rejects with `:isbn_not_found`."
  def no_isbn(opts \\ []), do: book_response([], opts)

  @doc """
    A steerable response that sends the outgoing `/analyze` payload to `pid` and
    then short-circuits with an empty candidate list, so the pipeline returns
    without doing resolution work.

    Use it to assert on what the caller *sent*, rather than on what the mock
    answered — that is the only thing a payload-forwarding test is really about.
    `pid` is normally `self`; the closure runs in whichever process calls the
    seam, so the message still lands in the test process.
  """
  def capture_payload(pid, response \\ nil) do
    fn payload ->
      send(pid, {:vision_payload, payload})
      response || no_isbn(confidence: 0.95)
    end
  end

  @doc "The vision service is down."
  def service_error, do: {:error, :service_unavailable}

  @doc "The circuit breaker is open, so no request left the node."
  def circuit_open, do: {:error, :circuit_open}
end
