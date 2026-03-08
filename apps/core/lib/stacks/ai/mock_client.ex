defmodule Stacks.AI.MockClient do
  @moduledoc """
  Mock implementation of the vision client for use in tests and development.
  Returns configurable responses via the process dictionary or defaults.
  """

  @behaviour Stacks.AI.ClientBehaviour

  @impl true
  def call_vision("is_book", _payload) do
    {:ok, %{"is_book" => true}}
  end

  def call_vision("extract_isbn", payload) do
    isbn = Map.get(payload, :isbn) || Map.get(payload, "isbn") || "9780743273565"
    {:ok, %{"isbn" => isbn}}
  end

  def call_vision("classify_subjects", _payload) do
    {:ok, %{"subjects" => ["fiction", "classic"], "bisac_codes" => ["FIC000000"]}}
  end

  def call_vision(_endpoint, _payload) do
    {:ok, %{}}
  end
end
