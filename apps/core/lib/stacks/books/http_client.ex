defmodule Stacks.Books.HttpClient do
  @moduledoc "Real HTTP client for ISBN resolver — uses Finch."

  @behaviour Stacks.Books.HttpClientBehaviour

  require Logger

  # The query parameters safe to put in a log line. Everything else is redacted.
  #
  # This is an ALLOWLIST on purpose. The first version denied a list of known
  # credential names — `key`, `token`, `secret` and friends — which is a bet that
  # no provider ever invents a new one; `client_secret` walked straight through
  # it. A function whose job is "no credential reaches the log" has to fail
  # closed, which is the same argument `scripts/check-idor-response.sh` makes for
  # an unexpected status code.
  #
  # The resolver's URLs are worth logging — what identifies the request is what
  # makes a failure diagnosable — so the parameters that carry that are named
  # here and everything else is replaced rather than the whole URL dropped.
  # `isbn_resolver.ex` builds four shapes: Open Library books (`bibkeys`,
  # `format`, `jscmd`), Google Books (`q`, `maxResults`), Open Library works
  # editions (`limit`), and the title search (`title`, `fields`, `limit`,
  # optionally `author`).
  #
  # ⚠️ `title` and `author` belong here for a specific reason: the title search is
  # the one path with NO ISBN to identify the request, so redacting them would
  # leave a log line that says a request failed without saying which book — the
  # exact loss this redaction exists to avoid. They are not new exposure either:
  # `isbn_resolver.ex:186`, `:564` and `:570` already log both in the clear.
  #
  # ⚠️ This module has TWO entry points with different trust properties, and the
  # list has to serve both. `get/1` fetches URLs we construct, one shape of which
  # carries our API key — an allowlist is exactly right there. `get_binary/1`
  # fetches a cover URL a third party handed us (`imageLinks.thumbnail`), whose
  # parameters are theirs and cannot be enumerated in advance; `id` is there
  # because it is the only thing naming which cover failed, and it is an opaque
  # public volume identifier rather than a credential. Open Library covers are
  # path-based and never reach this list at all.
  #
  # Names are compared downcased, which is why `maxresults` and `langrestrict`
  # appear in that form.
  @loggable_params ~w(q isbn bibkeys jscmd format fields maxresults langrestrict
                      country title author limit id)

  @impl true
  def get(url) do
    req = Finch.build(:get, url)

    case Finch.request(req, Stacks.Finch, receive_timeout: 15_000, request_timeout: 15_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        decode_body(body, url)

      {:ok, %Finch.Response{status: status}} ->
        warn("ISBNResolver: unexpected status #{status}", url)
        {:error, :unexpected_status}

      {:error, error} ->
        map_error(error, url)
    end
  end

  @impl true
  def get_binary(url) do
    req = Finch.build(:get, url)

    case Finch.request(req, Stacks.Finch, receive_timeout: 10_000, request_timeout: 10_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Finch.Response{status: status}} ->
        warn("Books.get_binary: unexpected status #{status}", url)
        {:error, :unexpected_status}

      {:error, error} ->
        map_error(error, url)
    end
  end

  @doc false
  @spec map_error(term(), String.t()) ::
          {:error, Stacks.Books.HttpClientBehaviour.error_reason()}
  def map_error(%Finch.TransportError{reason: :timeout} = error, url) do
    warn("ISBNResolver: request timed out", url, error)
    {:error, :timeout}
  end

  def map_error(%Finch.Error{reason: reason} = error, url)
      when reason in [:timeout, :request_timeout] do
    warn("ISBNResolver: request timed out", url, error)
    {:error, :timeout}
  end

  def map_error(%Finch.TransportError{} = error, url) do
    warn("ISBNResolver: transport error", url, error)
    {:error, :transport_error}
  end

  def map_error(error, url) do
    warn("ISBNResolver: request failed", url, error)
    {:error, :transport_error}
  end

  defp decode_body(body, url) do
    case Jason.decode(body) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, %Jason.DecodeError{} = reason} ->
        warn("ISBNResolver: malformed JSON body", url, reason)

        {:error, :malformed_response}
    end
  end

  # The module's ONLY logging path, so that redacting is not something a future
  # call site can forget. Six of the seven sites were unguarded by any test when
  # this was seven separate `Logger.warning` calls — the next one added would
  # have been unguarded too. One choke point makes the omission unrepresentable
  # rather than merely unlikely.
  defp warn(prefix, url, detail \\ nil) do
    suffix = if detail, do: ": #{inspect(detail)}", else: ""
    Logger.warning("#{prefix} for #{redact(url)}#{suffix}")
  end

  @doc """
      A URL safe to log: only the parameters on the loggable allowlist keep their
      values, so the line still says which provider and which ISBN failed while
      anything that might carry a credential is replaced.
  """
  # Specced to `String.t()` rather than `term()`, and with no catch-all clause:
  # every caller reaches this through `warn/3`, and every entry point specs its
  # url as `String.t()` (`http_client_behaviour.ex:19, :28`). A permissive clause
  # bought nothing — a `%URI{}` would still raise on interpolation and a `nil`
  # would interpolate as a blank URL, so it converted a loud failure into either
  # the same failure or a silent one — while the widened spec suppressed the
  # Dialyzer check that catches a non-binary caller before it ever runs.
  @spec redact(String.t()) :: String.t()
  def redact(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{query: nil} -> url
      %URI{query: query} = uri -> URI.to_string(%{uri | query: redact_query(query)})
    end
  end

  defp redact_query(query) do
    query
    |> URI.decode_query()
    |> Enum.map(&redact_param/1)
    |> URI.encode_query()
  end

  # A plain word, not a bracketed marker: `URI.encode_query/1` percent-encodes
  # the brackets, so `[REDACTED]` reaches the log as `key=%5BREDACTED%5D` — which
  # reads like a value rather than like a redaction.
  defp redact_param({name, value}) do
    if String.downcase(name) in @loggable_params do
      {name, value}
    else
      {name, "REDACTED"}
    end
  end
end
