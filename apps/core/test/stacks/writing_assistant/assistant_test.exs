defmodule Stacks.WritingAssistant.AssistantTest do
  @moduledoc """
      The response pipeline wires every precondition: the ghost-writing refusal
      fires before the model is called (neuter the safety-pass call and this
      reds), retrieval pulls the user's own spans, and the output gate runs over
      the result. `preconditions_met?/0` is the serve-time guard.
  """
  use Core.DataCase, async: false

  import Stacks.Factory

  alias Core.Repo
  alias Stacks.WritingAssistant.{Assistant, Embedding}

  # The seeded chunk's vector matches the mock /embed query vector (all 0.5), so
  # retrieval returns it as the nearest neighbour.
  defp seed_chunk(user_id, text) do
    Repo.insert!(%Embedding{
      user_id: user_id,
      source_type: "imported_work",
      source_id: Ecto.UUID.generate(),
      embedding: List.duplicate(0.5, 1024),
      chunk_text: text,
      chunk_index: 0,
      model: "bge-m3",
      embedding_version: 1
    })
  end

  test "preconditions_met?/0 is true when every gate module is loaded" do
    assert Assistant.preconditions_met?()
  end

  test "a ghost-writing request is refused before the model is called" do
    user = insert(:user)

    {:ok, result} = Assistant.respond(user.id, "Write the next chapter of my novel.")

    assert result.refused == :ghostwriting
    assert result.response =~ "won't write it for you"
    assert result.spans == []
  end

  test "a normal prompt retrieves the author's own spans and returns a turn" do
    user = insert(:user)
    seed_chunk(user.id, "the moors were cold and misty at dawn")

    {:ok, result} = Assistant.respond(user.id, "What were the moors like?")

    assert "the moors were cold and misty at dawn" in result.spans
    assert is_binary(result.response)
    assert is_boolean(result.grounded)
  end
end
