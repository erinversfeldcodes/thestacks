defmodule Stacks.AI.VisionErrorTest do
  @moduledoc """
  The closed error set, and the half of the sidecar contract that lives in
  Elixir.

  The point of the type is that a caller can ask "should I try this again?" and
  get an answer that is about the failure's *kind*, not its shape. So the tests
  that matter are the ones that would catch the set quietly reopening: a code the
  sidecar can send that this module does not name, or a catch-all that turns an
  unrecognised answer into silence.
  """

  use ExUnit.Case, async: true

  alias Stacks.AI.VisionError
  alias Stacks.Proto.Enums.VisionErrorCode

  @wire_codes VisionErrorCode.values() -- ["VISION_ERROR_CODE_UNSPECIFIED"]

  describe "sidecar contract — every wire code is a named determination" do
    test "each non-zero VisionErrorCode maps to a deterministic error with a distinct token" do
      results =
        for code <- @wire_codes do
          body = Jason.encode!(%{"code" => code, "message" => "detail for #{code}"})
          {code, VisionError.from_http_error(422, body)}
        end

      unhandled =
        for {code, error} <- results,
            VisionError.determination(error) != :deterministic,
            do: code

      assert unhandled == [],
             """
             These VisionErrorCode values did not map to a deterministic error.
             The sidecar can send them; a value that falls into the catch-all is
             retried three times on a GPU to be told the same thing.

               #{inspect(unhandled)}
             """

      tokens = for {_code, error} <- results, do: VisionError.reason_token(error)

      assert length(Enum.uniq(tokens)) == length(tokens),
             "two codes share a rejection_reason token, so the reader cannot be " <>
               "told which happened: #{inspect(tokens)}"
    end

    test "the enum is fully consumed — no code is handled only by accident" do
      for code <- @wire_codes do
        body = Jason.encode!(%{"code" => code, "message" => "x"})
        assert {:undecodable_image, _token} = VisionError.from_http_error(422, body)
      end
    end
  end

  describe "the catch-all cannot swallow" do
    test "an unrecognised code is retryable and counted, not treated as a determination" do
      attach_error_telemetry()

      body = Jason.encode!(%{"code" => "VISION_ERROR_CODE_FROM_THE_FUTURE", "message" => "?"})
      error = VisionError.from_http_error(422, body)

      assert error == {:upstream_status, 422}
      assert VisionError.determination(error) == :transient

      assert_receive {:vision_error, %{code: :unrecognised, determination: :transient}}
    end

    test "the proto3 zero value is handled as unrecognised rather than as a decision" do
      attach_error_telemetry()

      body = Jason.encode!(%{"code" => "VISION_ERROR_CODE_UNSPECIFIED", "message" => "?"})

      assert {:upstream_status, 422} = VisionError.from_http_error(422, body)
      assert_receive {:vision_error, %{code: :unrecognised}}
    end

    test "a non-JSON body is a fault, not a determination, and is counted" do
      attach_error_telemetry()

      assert {:upstream_status, 500} =
               VisionError.from_http_error(500, "<html>gateway is unwell</html>")

      assert_receive {:vision_error, %{code: :unlabelled, determination: :transient}}
    end

    test "JSON without a string code is not a determination" do
      assert {:upstream_status, 422} = VisionError.from_http_error(422, ~s({"detail":"nope"}))
      assert {:upstream_status, 422} = VisionError.from_http_error(422, ~s({"code":7}))
    end

    test "every path out of from_http_error emits exactly one counter" do
      attach_error_telemetry()

      VisionError.from_http_error(422, ~s({"code":"VISION_ERROR_CODE_UNDECODABLE_IMAGE"}))
      VisionError.from_http_error(422, ~s({"code":"VISION_ERROR_CODE_FROM_THE_FUTURE"}))
      VisionError.from_http_error(503, "unlabelled")
      VisionError.from_transport(:closed)

      assert_receive {:vision_error, %{code: :undecodable_image}}
      assert_receive {:vision_error, %{code: :unrecognised}}
      assert_receive {:vision_error, %{code: :unlabelled}}
      assert_receive {:vision_error, %{code: :transport}}
      refute_receive {:vision_error, _}, 50
    end

    test "the counter's metadata carries no service-supplied text" do
      attach_error_telemetry()

      VisionError.from_http_error(
        422,
        Jason.encode!(%{
          "code" => "VISION_ERROR_CODE_UNDECODABLE_IMAGE",
          "message" => "user@example.com uploaded /private/path.jpg"
        })
      )

      assert_receive {:vision_error, metadata}
      assert Map.keys(metadata) |> Enum.sort() == [:code, :determination]
      assert is_atom(metadata.code)
      assert is_atom(metadata.determination)
    end
  end

  describe "vision_error?/1 — the boundary of the vocabulary" do
    test "recognises every constructor of the set" do
      for error <- [
            :circuit_open,
            :budget_exceeded,
            {:undecodable_image, "undecodable_image"},
            {:upstream_status, 503},
            {:transport, :closed}
          ] do
        assert VisionError.vision_error?(error), "#{inspect(error)} should be in the set"
        assert VisionError.determination(error) in [:deterministic, :transient]
        assert is_binary(VisionError.reason_token(error))
        assert is_binary(VisionError.message(error))
      end
    end

    test "rejects reasons from elsewhere, so callers do not read them as vision verdicts" do
      for other <- [
            :signing_key_unavailable,
            :not_a_book,
            {:undecodable_image, :not_a_binary},
            {:upstream_status, "503"},
            %RuntimeError{message: "boom"},
            nil
          ] do
        refute VisionError.vision_error?(other), "#{inspect(other)} should NOT be in the set"
      end
    end
  end

  describe "determination/1 — what may be retried" do
    test "only a labelled determination about the input cancels" do
      assert VisionError.determination({:undecodable_image, "anything"}) == :deterministic

      for transient <- [
            :circuit_open,
            :budget_exceeded,
            {:upstream_status, 400},
            {:upstream_status, 422},
            {:upstream_status, 500},
            {:transport, :timeout}
          ] do
        assert VisionError.determination(transient) == :transient,
               "#{inspect(transient)} must stay retryable — an unlabelled status could be " <>
                 "a deploy skew, and permanently rejecting a reader's upload over one is " <>
                 "worse than three cheap retries"
      end
    end
  end

  defp attach_error_telemetry do
    test_pid = self()
    handler_id = {__MODULE__, System.unique_integer()}

    :telemetry.attach(
      handler_id,
      [:stacks, :vision, :error],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:vision_error, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
