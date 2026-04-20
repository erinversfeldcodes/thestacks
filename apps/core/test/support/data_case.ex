defmodule Core.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Core.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Core.DataCase
    end
  end

  setup tags do
    Core.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    alias Ecto.Adapters.SQL.Sandbox
    # Tests point Oban at Core.Repo (test.exs overrides the production
    # Core.ObanRepo — see test.exs comments), so only one sandbox owner
    # is needed. In prod the two repos use separate pools for HTTP /
    # background isolation; in test that isolation isn't exercised.
    pid = Sandbox.start_owner!(Core.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
