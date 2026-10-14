defmodule Stacks.Books.HttpClientTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Stacks.Books.HttpClient

  @url "http://example.test/api"

  describe "map_error/2 with Finch >= 0.23 error structs" do
    test "HTTP/1 pool timeout (%Finch.TransportError{reason: :timeout}) maps to :timeout" do
      error = %Finch.TransportError{
        reason: :timeout,
        source: %Mint.TransportError{reason: :timeout}
      }

      log =
        capture_log(fn ->
          assert HttpClient.map_error(error, @url) == {:error, :timeout}
        end)

      assert log =~ "request timed out"
    end

    test "HTTP/2 pool timeout (%Finch.Error{reason: :timeout}) maps to :timeout" do
      log =
        capture_log(fn ->
          assert HttpClient.map_error(%Finch.Error{reason: :timeout}, @url) ==
                   {:error, :timeout}
        end)

      assert log =~ "request timed out"
    end

    test "%Finch.Error{reason: :request_timeout} maps to :timeout" do
      assert capture_log(fn ->
               assert HttpClient.map_error(%Finch.Error{reason: :request_timeout}, @url) ==
                        {:error, :timeout}
             end) =~ "request timed out"
    end

    test "non-timeout transport error maps to :transport_error" do
      error = %Finch.TransportError{
        reason: :econnrefused,
        source: %Mint.TransportError{reason: :econnrefused}
      }

      log =
        capture_log(fn ->
          assert HttpClient.map_error(error, @url) == {:error, :transport_error}
        end)

      assert log =~ "transport error"
    end

    test "HTTP protocol error falls through to :transport_error" do
      error = %Finch.HTTPError{reason: :invalid_status_line, module: Mint.HTTP1, source: nil}

      log =
        capture_log(fn ->
          assert HttpClient.map_error(error, @url) == {:error, :transport_error}
        end)

      assert log =~ "request failed"
    end

    test "unknown error term falls through to :transport_error" do
      log =
        capture_log(fn ->
          assert HttpClient.map_error(:some_future_error, @url) == {:error, :transport_error}
        end)

      assert log =~ "request failed"
    end
  end

  describe "get/1" do
    test "connection refused returns {:error, :transport_error}" do
      {:ok, socket} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(socket)
      :ok = :gen_tcp.close(socket)

      capture_log(fn ->
        assert HttpClient.get("http://127.0.0.1:#{port}/") == {:error, :transport_error}
      end)
    end
  end

  describe "credentials never reach the log" do
    @google "https://www.googleapis.com/books/v1/volumes?q=isbn:9780156001311&key=SECRET-KEY-VALUE"

    test "a failing request logs the URL without its key" do
      log =
        capture_log(fn ->
          HttpClient.map_error(%Finch.TransportError{reason: :timeout}, @google)
        end)

      refute log =~ "SECRET-KEY-VALUE"
      assert log =~ "key=REDACTED"
      # The diagnosable part survives: which provider, and which ISBN.
      assert log =~ "googleapis.com"
      assert log =~ "9780156001311"
    end

    test "redact/1 replaces every credential-bearing parameter" do
      for name <- ~w(key api_key apikey access_token token secret password) do
        redacted = HttpClient.redact("https://example.test/x?#{name}=hunter2&q=keepme")

        refute redacted =~ "hunter2", "#{name} was left in the URL"
        assert redacted =~ "#{name}=REDACTED"
        assert redacted =~ "keepme"
      end
    end

    test "an unknown parameter is redacted by default, not passed through" do
      # The denylist this replaced let `client_secret` through, because it was a
      # bet that no provider invents a credential name nobody listed. These are
      # the names that bet lost on.
      for name <- ~w(client_secret signature sig auth refresh_token api-key pwd
                     oauth_token session_id private_key) do
        redacted = HttpClient.redact("https://example.test/x?#{name}=hunter2")

        refute redacted =~ "hunter2", "#{name} leaked — the allowlist let it through"
        assert redacted =~ "REDACTED"
      end
    end

    test "the parameters that make a failure diagnosable survive" do
      # Open Library's shape and Google Books' shape; if these were redacted the
      # log would say a request failed without saying which book or which query.
      ol =
        HttpClient.redact(
          "https://openlibrary.org/api/books?bibkeys=ISBN:9780156001311&format=json&jscmd=data"
        )

      assert ol =~ "bibkeys=ISBN%3A9780156001311"
      assert ol =~ "format=json"
      assert ol =~ "jscmd=data"
      refute ol =~ "REDACTED"

      gb =
        HttpClient.redact(
          "https://www.googleapis.com/books/v1/volumes?q=isbn:9780156001311&key=SECRET&maxResults=5"
        )

      assert gb =~ "q=isbn%3A9780156001311"
      assert gb =~ "maxResults=5"
      assert gb =~ "key=REDACTED"
      refute gb =~ "SECRET"
    end

    test "every map_error/2 clause redacts, not just the one a probe happened to hit" do
      # Six of the seven log sites were unguarded when this module had seven
      # separate Logger calls. These cover the four public ones.
      errors = [
        %Finch.TransportError{reason: :timeout},
        %Finch.Error{reason: :request_timeout},
        %Finch.TransportError{reason: :econnrefused},
        :some_future_error
      ]

      for error <- errors do
        log = capture_log(fn -> HttpClient.map_error(error, @google) end)

        refute log =~ "SECRET-KEY-VALUE", "#{inspect(error)}'s branch leaked the key"
        assert log =~ "key=REDACTED"
      end
    end

    test "the title search keeps what identifies it — the path with no ISBN" do
      # The one resolver path where title and author ARE the identifier. An
      # allowlist that redacted them would leave a line saying a request failed
      # without saying which book, which is the loss this redaction exists to
      # avoid. Not new exposure: isbn_resolver.ex:186, :564 and :570 already log
      # both in the clear.
      search =
        HttpClient.redact(
          "https://openlibrary.org/search.json?title=The+Name+of+the+Rose&author=Umberto+Eco" <>
            "&fields=key,title&limit=5"
        )

      assert search =~ "title=The+Name+of+the+Rose"
      assert search =~ "author=Umberto+Eco"
      assert search =~ "limit=5"
      refute search =~ "REDACTED"
    end

    test "a cover download keeps the id that says which cover failed" do
      # `get_binary/1` is the module's second entry point and fetches a URL a
      # THIRD PARTY gave us (`imageLinks.thumbnail`), so its parameters are not
      # ours to enumerate. `id` is the only one that names the cover; without it
      # the log says a cover download failed and nothing more.
      cover =
        HttpClient.redact(
          "http://books.google.com/books/content?id=hLZXDwAAQBAJ&printsec=frontcover" <>
            "&img=1&zoom=1&edge=curl&source=gbs_api"
        )

      assert cover =~ "id=hLZXDwAAQBAJ"
    end

    test "an Open Library cover URL has no query to redact" do
      path_based = "https://covers.openlibrary.org/b/id/8739161-L.jpg"

      assert HttpClient.redact(path_based) == path_based
    end

    test "a URL with no query string is returned unchanged" do
      assert HttpClient.redact("https://openlibrary.org/isbn/9780156001311.json") ==
               "https://openlibrary.org/isbn/9780156001311.json"
    end
  end
end
