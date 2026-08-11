defmodule Stacks.Workers.ScoreSourceJob do
  @moduledoc """
  Oban worker that scores a discovered source's confidence (0.0–1.0)
  using the Together AI LLM.

  Accepts `%{"source_id" => id}`. Fetches the source, builds a prompt
  asking the LLM to evaluate whether it is a legitimate bookshop/community,
  parses the numeric confidence from the response, and updates the record.

  Sources scoring above 0.8 are logged for platform owner review.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Stacks.Discovery

  @impl true
  def perform(%Oban.Job{args: %{"source_id" => source_id}}) do
    case Discovery.get_source(source_id) do
      nil ->
        Logger.warning("ScoreSourceJob: source #{source_id} not found")
        {:cancel, "source not found"}

      source ->
        score_source(source)
    end
  end

  defp score_source(source) do
    client = together_client()

    prompt = build_scoring_prompt(source)

    case client.complete(prompt, max_tokens: 64, temperature: 0.1) do
      {:ok, response} ->
        confidence = parse_confidence(response)
        persist_confidence(source, confidence)

      {:error, reason} ->
        Logger.warning("ScoreSourceJob: LLM scoring failed for #{source.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_scoring_prompt(source) do
    """
    Evaluate whether this is a legitimate #{source.type} based on its name and URL.
    Rate your confidence from 0.0 to 1.0 that this is a real, active #{source.type}.
    Respond with ONLY a number between 0.0 and 1.0.

    Name: #{source.name}
    URL: #{source.url}
    Type: #{source.type}
    """
  end

  defp parse_confidence(response) do
    case Float.parse(String.trim(response)) do
      {value, _} when value >= 0.0 and value <= 1.0 ->
        value

      {value, _} when value > 1.0 ->
        1.0

      {value, _} when value < 0.0 ->
        0.0

      _ ->
        0.5
    end
  end

  defp persist_confidence(source, confidence) do
    case Discovery.update_confidence(source, confidence) do
      {:ok, updated} ->
        if confidence > 0.8 do
          Logger.info(
            "ScoreSourceJob: high-confidence source #{updated.id} (#{confidence}) — flagged for review"
          )
        end

        :ok

      {:error, reason} ->
        Logger.warning(
          "ScoreSourceJob: failed to update confidence for #{source.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp together_client do
    Application.get_env(:core, :together_client, Stacks.AI.TogetherClient)
  end
end
