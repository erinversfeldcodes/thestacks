defmodule Stacks.AI.VisionError do
  @moduledoc """
  The closed set of ways a call to the vision service can fail, and the two
  questions every caller asks about one: *should this be tried again?* and
  *what do we tell the reader?*

  Before this module a vision failure was an open-ended term. `{:error, reason}`
  could be `:circuit_open`, a `%Finch.Error{}`, or `%{status: 422, body: "..."}`,
  and `Stacks.Workers.IdentifyBookJob` treated all three identically: retry on a
  GPU, three times. An image the service had already proved it cannot decode was
  re-sent twice more to be un-decoded again, and the reader waited out the whole
  backoff schedule to be told the same thing.

  The split mirrors `Stacks.Workers.TriggerPriceScrapeJob.interpret/2`, which
  separates what the scraper *concluded* from whether it *worked*. Here:
  a `:deterministic` error is a conclusion about the input, and repeating the
  request repeats the conclusion. A `:transient` error is a statement about the
  service, and the next attempt may well succeed.
  """

  require Logger

  @typedoc """
  Closed set of reasons `Stacks.AI.Client.call_vision/2` returns on failure.
  Mirrors the convention `Stacks.Books.ISBNResolver.error_reason/0` documents.

  Adding a constructor here requires adding a clause to `determination/1`,
  `reason_token/1` and `message/1` — each is written without a catch-all, so
  dialyzer and the compiler's missing-clause warning enforce exhaustiveness
  rather than a silent default.

    * `:circuit_open` — the `:vision_fuse` breaker is blown. No request left.
    * `:budget_exceeded` — the Modal spend cap is reached. No request left.
    * `{:undecodable_image, token}` — the service looked at the input and
      concluded it cannot be processed. `token` is a stable snake_case string,
      written verbatim to `uploaded_images.rejection_reason`.
    * `{:upstream_status, status}` — a non-200 the service did not label with a
      `VisionErrorCode`. Deliberately NOT deterministic: see `determination/1`.
    * `{:transport, term}` — no usable answer arrived. Covers a refused socket,
      a timeout, and a 200 whose body we could not read.
  """
  @type t ::
          :circuit_open
          | :budget_exceeded
          | {:undecodable_image, String.t()}
          | {:upstream_status, non_neg_integer()}
          | {:transport, term()}

  @doc """
  True when `reason` is a member of `t/0`.

  Callers that receive failures from more than one source (the worker also sees
  storage presign errors and raised exceptions) use this to decide whether the
  vocabulary in this module applies, instead of assuming it does.
  """
  @spec vision_error?(term()) :: boolean()
  def vision_error?(:circuit_open), do: true
  def vision_error?(:budget_exceeded), do: true
  def vision_error?({:undecodable_image, token}) when is_binary(token), do: true
  def vision_error?({:upstream_status, status}) when is_integer(status), do: true
  def vision_error?({:transport, _reason}), do: true
  def vision_error?(_other), do: false

  @doc """
  Whether repeating the identical request could plausibly produce a different
  answer.

  `:deterministic` means it could not, so the caller cancels. `:transient` means
  it could, so the caller retries.

  Note what decides this: **the labelled error code, never the HTTP status
  number.** A 4xx the service did not label could be a deploy skew between core
  and the sidecar, and permanently rejecting a reader's upload on the strength
  of an unlabelled status is a worse failure than three cheap retries — cheap
  because every deterministic rejection the sidecar makes happens in its
  validation layer, before any GPU is allocated. So the GPU-cost argument that
  motivates the split only applies to the codes, and the codes are the only
  thing that gets to cancel.
  """
  @spec determination(t()) :: :deterministic | :transient
  def determination({:undecodable_image, _token}), do: :deterministic
  def determination(:circuit_open), do: :transient
  def determination(:budget_exceeded), do: :transient
  def determination({:upstream_status, _status}), do: :transient
  def determination({:transport, _reason}), do: :transient

  @doc """
  The stable token written to `uploaded_images.rejection_reason` when this error
  ends the upload.

  These strings are a wire contract with the SPA (`Page.Upload` matches
  `"not_a_book"` by name and renders everything else as a generic failure), so
  they are snake_case identifiers rather than prose, and they do not change.
  """
  @spec reason_token(t()) :: String.t()
  def reason_token({:undecodable_image, token}), do: token
  def reason_token(:circuit_open), do: "vision_unavailable"
  def reason_token(:budget_exceeded), do: "vision_budget_exceeded"
  def reason_token({:upstream_status, _status}), do: "vision_unavailable"
  def reason_token({:transport, _reason}), do: "vision_unavailable"

  @doc """
  A sentence for the operator: the `{:cancel, reason}` Oban records, and the log
  line. Not shown to readers — the SPA renders its own copy off `reason_token/1`.
  """
  @spec message(t()) :: String.t()
  def message({:undecodable_image, "undecodable_image"}),
    do: "vision could not read the image (not a decodable image)"

  def message({:undecodable_image, "image_too_large"}),
    do: "vision rejected the image: larger than the service accepts"

  def message({:undecodable_image, "image_unreachable"}),
    do: "vision could not fetch the stored image"

  def message({:undecodable_image, "no_image_supplied"}),
    do: "vision received a request carrying no image"

  def message({:undecodable_image, token}), do: "vision rejected the image: #{token}"
  def message(:circuit_open), do: "vision service circuit is open"
  def message(:budget_exceeded), do: "vision service budget exhausted"
  def message({:upstream_status, status}), do: "vision service returned HTTP #{status}"
  def message({:transport, reason}), do: "vision service unreachable: #{inspect(reason)}"

  @doc """
  Interpret a non-200 from the vision service.

  A body carrying a `VisionError` is a determination the service made about the
  input. Anything else is a fault, and is reported as one.

  The catch-all cannot swallow quietly, by construction:

    * a **new** `VisionErrorCode` cannot reach it at all —
      `scripts/check-enum-coverage.py` fails the build the moment this file
      stops matching one of the enum's values;
    * an **unrecognised** code (a sidecar deployed ahead of core) is logged at
      warning and counted on `[:stacks, :vision, :error]` with `code:
      :unrecognised`, so it shows up as a rate rather than as silence;
    * whatever it returns is still terminal for the reader — the final-attempt
      wrapper in `Stacks.Workers.IdentifyBookJob` marks the row rejected when
      the retries run out, so "unrecognised" costs a slower failure, never an
      eternal spinner.
  """
  @spec from_http_error(non_neg_integer(), binary()) :: t()
  def from_http_error(status, body) when is_integer(status) and is_binary(body) do
    case decode_error_code(body) do
      {:ok, code} -> from_code(code, status)
      :error -> emit(:unlabelled, {:upstream_status, status})
    end
  end

  @doc """
  Interpret a transport-level failure (no usable answer arrived).
  """
  @spec from_transport(term()) :: t()
  def from_transport(reason), do: emit(:transport, {:transport, reason})

  # One clause per VisionErrorCode wire value. `scripts/check-enum-coverage.py`
  # discovers this file as a consumer (it matches on the literals) and fails the
  # build if the enum grows a value this function does not name — which is the
  # point: a new deterministic failure mode must be given a reader-facing token
  # here before it can ship, rather than defaulting into "something went wrong".
  #
  # proto-enum-coverage: VisionErrorCode ignore VISION_ERROR_CODE_UNSPECIFIED —
  #   proto3 unset sentinel; a body carrying it named no determination, so it is
  #   handled as an unrecognised code (retryable + counted), not as a decision.
  defp from_code("VISION_ERROR_CODE_UNDECODABLE_IMAGE", _status),
    do: emit(:undecodable_image, {:undecodable_image, "undecodable_image"})

  defp from_code("VISION_ERROR_CODE_IMAGE_TOO_LARGE", _status),
    do: emit(:image_too_large, {:undecodable_image, "image_too_large"})

  defp from_code("VISION_ERROR_CODE_IMAGE_UNREACHABLE", _status),
    do: emit(:image_unreachable, {:undecodable_image, "image_unreachable"})

  defp from_code("VISION_ERROR_CODE_NO_IMAGE_SUPPLIED", _status),
    do: emit(:no_image_supplied, {:undecodable_image, "no_image_supplied"})

  defp from_code(other, status) do
    Logger.warning(
      "Stacks.AI.VisionError: vision service returned HTTP #{status} with unrecognised " <>
        "error code #{inspect(other)} — treating as a service fault (retryable). " <>
        "A sidecar deployed ahead of core will look exactly like this."
    )

    emit(:unrecognised, {:upstream_status, status})
  end

  # Funnel counter for vision failures. `code` is a whitelisted atom — never a
  # message, URL, or anything else the service echoed back (GDPR: telemetry is a
  # warehouse-adjacent sink). `determination` lets a dashboard show the split
  # this module exists to create.
  defp emit(code, error) do
    :telemetry.execute(
      [:stacks, :vision, :error],
      %{count: 1},
      %{code: code, determination: determination(error)}
    )

    error
  end

  # The body is the JSON encoding of a `VisionError` message. A body that is not
  # JSON, or is JSON without a string `code`, is not a determination — say so by
  # returning :error rather than inventing one.
  defp decode_error_code(body) do
    case Jason.decode(body) do
      {:ok, %{"code" => code}} when is_binary(code) -> {:ok, code}
      _ -> :error
    end
  end
end
