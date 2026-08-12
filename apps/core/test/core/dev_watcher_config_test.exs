defmodule Core.DevWatcherConfigTest do
  @moduledoc """
      Drift guard for the dev asset watcher's cwd: a doubled
      `Path.expand` once pointed it at `apps/core/apps/core/assets`,
      crash-looping the watcher and silently killing hot-rebuild. Dev config
      never loads in:test, so this reads `config/dev.exs` via
      `Config.Reader.read!/1` and asserts the watcher `cd` exists.
  """

  use ExUnit.Case, async: true

  @dev_config_path Path.expand("../../config/dev.exs", __DIR__)

  test "every dev endpoint watcher cd is an existing directory containing build.js" do
    watchers =
      @dev_config_path
      |> Config.Reader.read!()
      |> get_in([:core, CoreWeb.Endpoint, :watchers])

    assert is_list(watchers) and watchers != [],
           "expected at least one watcher in #{@dev_config_path}"

    for {command, args} <- watchers do
      cd = args |> Enum.filter(&match?({:cd, _}, &1)) |> Keyword.get(:cd)

      assert is_binary(cd),
             "watcher #{inspect(command)} has no :cd option in #{@dev_config_path}"

      assert File.dir?(cd),
             "watcher #{inspect(command)} cd does not exist: #{cd} " <>
               "(regression: doubled apps/core path?)"

      assert File.exists?(Path.join(cd, "build.js")),
             "watcher #{inspect(command)} cd exists but has no build.js: #{cd}"
    end
  end
end
