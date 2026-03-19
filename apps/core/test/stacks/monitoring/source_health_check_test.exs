defmodule Stacks.Monitoring.SourceHealthCheckTest do
  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Monitoring.SourceHealthCheck

  describe "changeset/2" do
    test "is valid with source_name, source_type, and status" do
      changeset =
        SourceHealthCheck.changeset(%SourceHealthCheck{}, %{
          source_name: "my-scraper",
          source_type: "scraper_config",
          status: "healthy",
          consecutive_failures: 0,
          total_successes: 10,
          total_failures: 0
        })

      assert changeset.valid?
    end

    test "is invalid without source_name" do
      changeset =
        SourceHealthCheck.changeset(%SourceHealthCheck{}, %{
          source_type: "scraper_config",
          status: "healthy"
        })

      refute changeset.valid?
      assert %{source_name: [_ | _]} = errors_on(changeset)
    end

    test "is invalid with an unknown source_type" do
      changeset =
        SourceHealthCheck.changeset(%SourceHealthCheck{}, %{
          source_name: "my-scraper",
          source_type: "carrier_pigeon",
          status: "healthy"
        })

      refute changeset.valid?
      assert %{source_type: [_ | _]} = errors_on(changeset)
    end

    test "is invalid with an unknown status" do
      changeset =
        SourceHealthCheck.changeset(%SourceHealthCheck{}, %{
          source_name: "my-scraper",
          source_type: "scraper_config",
          status: "vibing"
        })

      refute changeset.valid?
      assert %{status: [_ | _]} = errors_on(changeset)
    end
  end

  describe "DB constraint smoke test" do
    test "persists a valid source health check" do
      check = insert(:source_health_check)
      assert check.id
      assert check.status == "healthy"
    end

    test "enforces unique constraint on source_name" do
      insert(:source_health_check, source_name: "my-scraper")

      assert {:error, changeset} =
               %SourceHealthCheck{}
               |> SourceHealthCheck.changeset(%{
                 source_name: "my-scraper",
                 source_type: "scraper_config",
                 status: "healthy"
               })
               |> Core.Repo.insert()

      assert %{source_name: [_ | _]} = errors_on(changeset)
    end
  end
end
