defmodule Stacks.AI.VisionError do
  @moduledoc """
    The closed set of vision-service failures, answering the two questions
    every caller has: retry? and what do we tell the reader? A
    `:deterministic` error is a conclusion about the INPUT — repeating the
    request repeats the conclusion; `:transient` is a statement about the
    SERVICE — the next attempt may succeed. (Pre-split, `IdentifyBookJob`
    retried undecodable images on a GPU three times.) Mirrors
    `TriggerPriceScrapeJob.interpret/2`.
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
        written verbatim to `uploaded_images.rejection_reason`. The constructor is
        named for the common case; it carries every determination the service
        makes about an input it will not accept, including the two that are about
        the request rather than the pixels (`no_image_supplied`,
        `malformed_request`). What unites them is the only thing a caller acts on:
        the service has already decided, and asking again changes nothing.
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
    Whether repeating the identical request could produce a different answer:
    `:deterministic` → cancel, `:transient` → retry. Decided by the LABELLED
    error code, never the raw HTTP status — an unlabelled 4xx could be deploy
    skew between core and the sidecar, and permanently rejecting an upload on
    that is worse than three cheap retries (deterministic rejections happen in
    the sidecar's validation layer, before any GPU is allocated).
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

  def message({:undecodable_image, "malformed_request"}),
    do: "vision rejected the request shape (core sent a combination it does not accept)"

  def message({:undecodable_image, token}), do: "vision rejected the image: #{token}"
  def message(:circuit_open), do: "vision service circuit is open"
  def message(:budget_exceeded), do: "vision service budget exhausted"
  def message({:upstream_status, status}), do: "vision service returned HTTP #{status}"
  def message({:transport, reason}), do: "vision service unreachable: #{inspect(reason)}"

  @doc """
    Interpret a non-200 from the vision service. A body carrying a
    `VisionError` is a determination about the input; anything else is a fault.
    The catch-all cannot swallow quietly: a new `VisionErrorCode` fails the
    build (`scripts/check-enum-coverage.py`), an unrecognised code (sidecar
    deployed ahead of core) is logged + counted on `[:stacks,:vision,:error]`,
    and the result is still terminal for the reader via `IdentifyBookJob`'s
    final-attempt wrapper — slower failure, never an eternal spinner.
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

  defp from_code("VISION_ERROR_CODE_MALFORMED_REQUEST", _status),
    do: emit(:malformed_request, {:undecodable_image, "malformed_request"})

  defp from_code(other, status) do
    Logger.warning(
      "Stacks.AI.VisionError: vision service returned HTTP #{status} with unrecognised " <>
        "error code #{inspect(other)} — treating as a service fault (retryable). " <>
        "A sidecar deployed ahead of core will look exactly like this."
    )

    emit(:unrecognised, {:upstream_status, status})
  end

  defp emit(code, error) do
    :telemetry.execute(
      [:stacks, :vision, :error],
      %{count: 1},
      %{code: code, determination: determination(error)}
    )

    error
  end

  defp decode_error_code(body) do
    case Jason.decode(body) do
      {:ok, %{"code" => code}} when is_binary(code) -> {:ok, code}
      _ -> :error
    end
  end
end
