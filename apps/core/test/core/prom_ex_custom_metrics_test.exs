defmodule Core.PromExCustomMetricsTest do
  @moduledoc """
      Regression for 139: custom `stacks_*` telemetry must be exported via
      PromEx so the SLO gate sees real values at `/internal/metrics`. The
      parser expects exactly `stacks_upload_terminal_count_total`,
      `stacks_router_dispatch_stop_duration_milliseconds_{bucket,sum,count}`
      and `stacks_fuse_state_state` — fires each event and asserts the family
      appears in the exposition.
  """

  use ExUnit.Case, async: false

  setup do
    :ok
  end

  test "PromEx exports custom stacks_* metrics the SLO gate scraper reads" do
    :telemetry.execute(
      [:stacks, :upload, :terminal],
      %{count: 1},
      %{outcome: :resolved}
    )

    :telemetry.execute(
      [:stacks, :router_dispatch, :stop],
      %{duration: System.convert_time_unit(42, :millisecond, :native)},
      %{route: "/api/health", route_group: :health}
    )

    :telemetry.execute(
      [:stacks, :fuse, :state],
      %{state: 1},
      %{fuse_name: :vision_fuse}
    )

    Process.sleep(50)

    output = PromEx.get_metrics(Core.PromEx)

    refute output == :prom_ex_down, "Core.PromEx must be running for this test"

    assert output =~ "stacks_upload_terminal_count_total",
           "expected stacks_upload_terminal_count_total in PromEx output, got:\n#{output}"

    assert output =~ "stacks_router_dispatch_stop_duration_milliseconds",
           "expected stacks_router_dispatch_stop_duration_milliseconds_{bucket,sum,count} in PromEx output, got:\n#{output}"

    assert output =~ "stacks_fuse_state_state",
           "expected stacks_fuse_state_state in PromEx output, got:\n#{output}"
  end

  test "PromEx exports the auth refresh revoke-failure counter" do
    :telemetry.execute(
      [:stacks, :auth, :refresh, :revoke_failed],
      %{count: 1},
      %{}
    )

    Process.sleep(50)

    output = PromEx.get_metrics(Core.PromEx)

    refute output == :prom_ex_down, "Core.PromEx must be running for this test"

    assert output =~ "stacks_auth_refresh_revoke_failed_count_total",
           "expected stacks_auth_refresh_revoke_failed_count_total in PromEx output, got:\n#{output}"
  end

  defp scrape do
    Process.sleep(50)
    output = PromEx.get_metrics(Core.PromEx)
    refute output == :prom_ex_down, "Core.PromEx must be running for this test"
    output
  end

  defp assert_label(output, family, key, value) do
    re =
      ~r/#{Regex.escape(family)}\{[^}\n]*#{Regex.escape(key)}="#{Regex.escape(value)}"[^}\n]*\}/

    assert output =~ re,
           "expected #{family} exported with #{key}=\"#{value}\", got:\n#{output}"
  end

  describe "auth §12 operational counters fire + export with the right tag-set" do
    test "registration success/failure counter exports result label" do
      :telemetry.execute([:stacks, :auth, :registration], %{count: 1}, %{result: :ok})
      :telemetry.execute([:stacks, :auth, :registration], %{count: 1}, %{result: :error})

      output = scrape()

      assert_label(output, "stacks_auth_registration_count_total", "result", "ok")
      assert_label(output, "stacks_auth_registration_count_total", "result", "error")
    end

    test "JWT issuance counter exports context label (login + refresh)" do
      :telemetry.execute([:stacks, :auth, :jwt_issued], %{count: 1}, %{context: :login})
      :telemetry.execute([:stacks, :auth, :jwt_issued], %{count: 1}, %{context: :refresh})

      output = scrape()

      assert_label(output, "stacks_auth_jwt_issued_count_total", "context", "login")
      assert_label(output, "stacks_auth_jwt_issued_count_total", "context", "refresh")
    end

    test "login-failure-by-type counter exports type label for each status class" do
      for type <- [
            :invalid_credentials,
            :email_unconfirmed,
            :missing_params,
            :account_locked,
            :service_busy
          ] do
        :telemetry.execute([:stacks, :auth, :login_failure], %{count: 1}, %{type: type})
      end

      output = scrape()

      assert_label(output, "stacks_auth_login_failure_count_total", "type", "invalid_credentials")
      assert_label(output, "stacks_auth_login_failure_count_total", "type", "email_unconfirmed")
      assert_label(output, "stacks_auth_login_failure_count_total", "type", "missing_params")
      assert_label(output, "stacks_auth_login_failure_count_total", "type", "account_locked")
      assert_label(output, "stacks_auth_login_failure_count_total", "type", "service_busy")
    end

    test "429 login-failure-by-type: rate-limit rejection counter exports bucket label" do
      :telemetry.execute([:stacks, :rate_limit, :rejected], %{count: 1}, %{bucket: :auth})

      output = scrape()

      assert_label(output, "stacks_rate_limit_rejected_count_total", "bucket", "auth")
    end
  end

  describe "GDPR counters export with the right tag-set at the reporter level" do
    test "export outcome exports result label" do
      :telemetry.execute([:stacks, :gdpr, :export], %{count: 1}, %{result: :ok})
      :telemetry.execute([:stacks, :gdpr, :export], %{count: 1}, %{result: :error})

      output = scrape()

      assert_label(output, "stacks_gdpr_export_count_total", "result", "ok")
      assert_label(output, "stacks_gdpr_export_count_total", "result", "error")
    end

    test "deletion outcome exports both result and failed_step labels" do
      :telemetry.execute([:stacks, :gdpr, :deletion], %{count: 1}, %{
        result: :ok,
        failed_step: :none
      })

      :telemetry.execute([:stacks, :gdpr, :deletion], %{count: 1}, %{
        result: :error,
        failed_step: :delete_user
      })

      output = scrape()

      assert output =~
               ~r/stacks_gdpr_deletion_count_total\{[^}\n]*result="error"[^}\n]*failed_step="delete_user"[^}\n]*\}|stacks_gdpr_deletion_count_total\{[^}\n]*failed_step="delete_user"[^}\n]*result="error"[^}\n]*\}/,
             "expected stacks_gdpr_deletion_count_total with result=\"error\" AND failed_step=\"delete_user\", got:\n#{output}"

      assert_label(output, "stacks_gdpr_deletion_count_total", "result", "ok")
      assert_label(output, "stacks_gdpr_deletion_count_total", "failed_step", "none")
    end

    test "consent grant/revoke export the feature label" do
      :telemetry.execute([:stacks, :gdpr, :consent, :grant], %{count: 1}, %{feature: "analytics"})

      :telemetry.execute([:stacks, :gdpr, :consent, :revoke], %{count: 1}, %{
        feature: "analytics"
      })

      output = scrape()

      assert_label(output, "stacks_gdpr_consent_grant_count_total", "feature", "analytics")
      assert_label(output, "stacks_gdpr_consent_revoke_count_total", "feature", "analytics")
    end

    test "image expired/stuck export the reason label; orphan exports the untagged family" do
      :telemetry.execute([:stacks, :gdpr, :image, :expired], %{count: 1}, %{reason: "expired"})
      :telemetry.execute([:stacks, :gdpr, :image, :expired], %{count: 1}, %{reason: "stuck"})
      :telemetry.execute([:stacks, :gdpr, :image, :stuck], %{count: 1}, %{reason: "stuck"})
      :telemetry.execute([:stacks, :gdpr, :image, :orphan], %{count: 3}, %{})

      output = scrape()

      assert_label(output, "stacks_gdpr_image_expired_count_total", "reason", "expired")
      assert_label(output, "stacks_gdpr_image_expired_count_total", "reason", "stuck")
      assert_label(output, "stacks_gdpr_image_stuck_count_total", "reason", "stuck")

      assert output =~ "stacks_gdpr_image_orphan_count_total",
             "expected stacks_gdpr_image_orphan_count_total in PromEx output, got:\n#{output}"
    end

    test "audit write exports both action and resource_type labels" do
      :telemetry.execute([:stacks, :gdpr, :audit, :write], %{count: 1}, %{
        action: "test.telemetry_action",
        resource_type: "test"
      })

      output = scrape()

      assert_label(
        output,
        "stacks_gdpr_audit_write_count_total",
        "action",
        "test.telemetry_action"
      )

      assert_label(output, "stacks_gdpr_audit_write_count_total", "resource_type", "test")
    end
  end
end
