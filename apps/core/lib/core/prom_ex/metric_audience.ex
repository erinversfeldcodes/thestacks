defmodule Core.PromEx.MetricAudience do
  @moduledoc """
  Per-metric AUDIENCE classification (ADR-021 §4) — the fail-closed privacy
  boundary for observability.

  A metric is PUBLIC iff it is explicitly listed here as `:public`. Anything not
  listed is `:unclassified`, which is treated as **not public** everywhere
  (fail-closed): a newly-added metric family cannot reach the public transparency
  page (#241) or the anonymous public Grafana until it is consciously classified.
  This is the posture ADR-021 mandates precisely because PII-bearing metrics
  (e.g. blog engagement) are coming — a new metric must never leak by default.

  ## Audiences (ADR-021 §4)

    * `:public`      — everyone; aggregate, non-PII, non-de-anonymisable. Rendered
      on the public transparency page + the anonymous public Grafana.
    * `:own`         — the PRODUCING user only; the #242 personal-inference surface.
      A per-user axis, never an aggregate dashboard. (Route value; no per-user
      metric family exists yet.)
    * `:break_glass` — admin, rare/logged elevated access (#138); NOT a routine
      dashboard. For a future aggregate-but-de-anon-risky metric. (Route value.)

  ## Gating rule (ADR-021 §4)

  An operational metric is `:public` UNLESS it contains PII or can be
  de-anonymised. "Might reveal security posture" is NOT a reason to withhold.
  Every one of the current families is an aggregate keyed only on bounded
  whitelisted atoms (no user-id / handle / IP / email / free-text — see the #249
  metric audit), so **all current families are `:public`**.

  `Core.PromEx.MetricAudienceTest` enforces that EVERY registered family
  (`Core.PromEx.Plugins.Stacks`) is classified here: adding a metric without
  classifying it fails the build, so nothing is ever silently
  measured-but-undisplayed. Keys are the registered family name —
  `metric.name |> Enum.join("_")` — matching `DashboardDriftTest` /
  `DashboardLabelValidationTest`.
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
