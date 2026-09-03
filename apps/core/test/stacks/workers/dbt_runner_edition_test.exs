defmodule Stacks.Workers.DbtRunnerEditionTest do
  use ExUnit.Case, async: true

  alias Stacks.Workers.DbtRunner

  @moduletag :unit

  # There are two programs called `dbt`. dbt-core runs this repository's models
  # against the configured profile; the dbt Cloud CLI forwards the invocation to
  # a dbt Cloud account and takes a different argv. `System.cmd("dbt", …)` runs
  # whichever answers on PATH, and picking the wrong one does not announce
  # itself — it surfaces as a puzzling argument error, or as a run that appears
  # to succeed against something that is not this database.

  describe "core_edition?/1" do
    test "recognises dbt-core by its installed Core version and adapter plugins" do
      assert DbtRunner.core_edition?("""
             Core:
               - installed: 1.12.2
               - latest:    1.12.2 - Up to date!

             Plugins:
               - postgres: 1.11.0 - Up to date!
             """)
    end

    test "refuses the Cloud CLI, which names itself and has no local adapter" do
      refute DbtRunner.core_edition?("dbt Cloud CLI - 0.38.19 (a1b2c3d 2026-08-01T00:00:00Z)")
    end

    test "refuses output that mentions Core but is still the Cloud CLI" do
      refute DbtRunner.core_edition?("""
             dbt Cloud CLI - 0.38.19
             Core:
               - installed: 1.12.2
             """)
    end

    test "refuses empty or unrecognisable output rather than assuming the good case" do
      refute DbtRunner.core_edition?("")
      refute DbtRunner.core_edition?("dbt: command not found")
    end
  end
end
