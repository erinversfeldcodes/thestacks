defmodule Core.PromEx.MetricAudience do
  @moduledoc """
  Per-metric AUDIENCE classification (ADR-021 §4) — the fail-closed
  privacy boundary for observability. A metric is public iff explicitly
  listed `:public` here; anything unlisted is `:unclassified` and treated as
  NOT public everywhere, so a new metric family can never reach the public
  transparency page or anonymous Grafana by default. Other audiences:
  `:own` (producing user only), `:break_glass` (admin, logged), `:internal`
  (operators). Classify consciously; PII-bearing metrics are coming.
  """

  @audience %{
    "stacks_age_gate_enforce_count_total" => :public,
    "stacks_age_verification_count_total" => :public,
    "stacks_auth_jwt_issued_count_total" => :public,
    "stacks_auth_login_failure_count_total" => :public,
    "stacks_auth_mfa_verify_count_total" => :public,
    "stacks_auth_refresh_reuse_detected_count_total" => :public,
    "stacks_auth_refresh_revoke_failed_count_total" => :public,
    "stacks_auth_registration_count_total" => :public,
    "stacks_auth_session_expired_count_total" => :public,
    "stacks_events_dispatch_duration_milliseconds" => :public,
    "stacks_events_emitted_count_total" => :public,
    "stacks_events_handler_error_count_total" => :public,
    "stacks_events_handler_invoked_count_total" => :public,
    "stacks_fuse_state_state" => :public,
    "stacks_gdpr_audit_read_count_total" => :public,
    "stacks_gdpr_audit_write_count_total" => :public,
    "stacks_gdpr_consent_grant_count_total" => :public,
    "stacks_gdpr_consent_revoke_count_total" => :public,
    "stacks_gdpr_deletion_count_total" => :public,
    "stacks_gdpr_deletion_duration_milliseconds" => :public,
    "stacks_gdpr_export_count_total" => :public,
    "stacks_gdpr_export_duration_milliseconds" => :public,
    "stacks_gdpr_image_expired_count_total" => :public,
    "stacks_gdpr_image_orphan_count_total" => :public,
    "stacks_gdpr_image_stuck_count_total" => :public,
    "stacks_handle_claimed_count_total" => :public,
    "stacks_moderation_classification_count_total" => :public,
    "stacks_moderation_compound_expansion_count_total" => :public,
    "stacks_moderation_isbn_resolution_count_total" => :public,
    "stacks_moderation_tiering_count_total" => :public,
    "stacks_profile_view_count_total" => :public,
    "stacks_rate_limit_client_ip_count_total" => :public,
    "stacks_rate_limit_rejected_count_total" => :public,
    "stacks_repo_query_duration_milliseconds" => :public,
    "stacks_router_dispatch_stop_duration_milliseconds" => :public,
    "stacks_search_people_count_total" => :public,
    "stacks_shelf_browse_capped_count_total" => :public,
    "stacks_social_block_count_total" => :public,
    "stacks_social_block_error_count_total" => :public,
    "stacks_social_unblock_count_total" => :public,
    "stacks_upload_terminal_count_total" => :public,
    "stacks_view_as_error_count_total" => :public,
    "stacks_view_as_usage_count_total" => :public,
    "stacks_visibility_ceiling_rejection_count_total" => :public,
    "stacks_visibility_profile_change_count_total" => :public,
    "stacks_visibility_recap_bookshelves_capped_total" => :public,
    "stacks_visibility_recap_count_total" => :public,
    "stacks_visibility_recap_placements_capped_total" => :public,
    "stacks_visibility_recap_posts_capped_total" => :public,
    "stacks_vision_request_stop_duration_milliseconds" => :public,
    "stacks_vision_request_exception_count_total" => :public
  }

  @type audience :: :public | :own | :break_glass

  @doc """
  Audience for a registered family name, or `:unclassified` (fail-closed) when the
  family is not listed. `:unclassified` is never treated as public.
  """
  @spec audience(String.t()) :: audience() | :unclassified
  def audience(family) when is_binary(family), do: Map.get(@audience, family, :unclassified)

  @doc "True iff the family is explicitly `:public`. Fail-closed: unknown → false."
  @spec public?(String.t()) :: boolean()
  def public?(family) when is_binary(family), do: Map.get(@audience, family) == :public

  @doc "The full classification map (family → audience)."
  @spec all() :: %{optional(String.t()) => audience()}
  def all, do: @audience

  @doc "All families classified `:public`."
  @spec public_families() :: [String.t()]
  def public_families, do: for({family, :public} <- @audience, do: family)
end
