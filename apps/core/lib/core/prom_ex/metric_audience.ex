defmodule Core.PromEx.MetricAudience do
  @moduledoc """
      Per-metric AUDIENCE classification — the fail-closed
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
    "stacks_ai_together_completion_count_total" => :public,
    "stacks_discovery_brave_search_count_total" => :public,
    "stacks_auth_jwt_issued_count_total" => :public,
    "stacks_auth_login_failure_count_total" => :public,
    "stacks_auth_mfa_verify_count_total" => :public,
    # Invite-gate outcomes. `:public` like its registration sibling: the counter is an
    # aggregate keyed only by a bounded result atom (ok / required / invalid / expired
    # / revoked / exhausted / email_mismatch) and names no invite, code or person.
    "stacks_auth_invite_count_total" => :public,
    "stacks_auth_refresh_reuse_detected_count_total" => :public,
    "stacks_auth_refresh_revoke_failed_count_total" => :public,
    "stacks_auth_registration_count_total" => :public,
    "stacks_auth_session_expired_count_total" => :public,
    "stacks_email_delivered_count_total" => :public,
    "stacks_events_dispatch_duration_milliseconds" => :public,
    "stacks_events_emitted_count_total" => :public,
    "stacks_events_handler_error_count_total" => :public,
    "stacks_events_handler_invoked_count_total" => :public,
    "stacks_fuse_state_state" => :public,
    # ── The six families that gained a reporter ──────────────────────────────
    # Classified consciously rather than inherited, since an unlisted metric is
    # :unclassified and reaches no public surface by default.
    #
    # The two circuit-breaker counters are :public for the same reason
    # `stacks_fuse_state_state` already is — a breaker name and a count say that
    # a dependency is unwell, which is exactly what a transparency page is for,
    # and they name no person.
    "stacks_fuse_blown_count_total" => :public,
    "stacks_fuse_melt_count_total" => :public,
    # robots.txt fetches: an aggregate count with no tags at all. Nothing to
    # attribute to anyone.
    "stacks_crawler_robots_fetch_count_total" => :public,
    # Platform operating cost by category and service. :public because the cost
    # page already publishes these figures by design — this is the metric behind
    # a surface that is deliberately open, and `service` is bounded to a
    # ten-name vocabulary the app itself writes.
    "stacks_costs_recorded_amount_cents" => :public,
    # ⚠️ The two AI-spend metrics, and the one classification here that was
    # genuinely arguable — recorded with the alternative so it can be overturned
    # without re-deriving the argument.
    #
    # AGAINST :public — live spend against a budget limit is an operational
    # control signal, not a published figure. Continuously exposed it tells an
    # observer how close the platform is to refusing AI work, which is an
    # invitation to push it there; the cost page reports spend in ARREARS, while
    # this reports headroom in REAL TIME. Those are different disclosures.
    #
    # FOR :public, which is what was chosen — this project's transparency
    # posture already publishes platform spend, and a reader discovering that
    # image identification has stopped working deserves to see the reason was a
    # budget ceiling rather than a fault. Hiding a refusal count makes a
    # degradation look like a bug. The amounts are aggregates by provider,
    # naming no person and no request.
    #
    # The DoS concern is real but weak here: the limit is a cost ceiling, not a
    # capacity one, and anyone can already infer it by watching identification
    # fail. If that changes — a per-user limit, say — revisit this first.
    "stacks_budget_cost_recorded_amount_cents" => :public,
    "stacks_budget_limit_exceeded_count_total" => :public,
    "stacks_gdpr_audit_read_count_total" => :public,
    "stacks_gdpr_audit_write_count_total" => :public,
    "stacks_gdpr_consent_grant_count_total" => :public,
    "stacks_gdpr_consent_revoke_count_total" => :public,
    "stacks_gdpr_deletion_count_total" => :public,
    "stacks_gdpr_deletion_duration_milliseconds" => :public,
    "stacks_gdpr_export_count_total" => :public,
    "stacks_gdpr_export_duration_milliseconds" => :public,
    "stacks_auth_confirmation_resend_count_total" => :public,
    "stacks_auth_email_change_count_total" => :public,
    "stacks_auth_password_reset_count_total" => :public,
    "stacks_accounts_email_change_lapsed_degraded" => :public,
    "stacks_blog_association_count_total" => :public,
    "stacks_gdpr_export_expired_count_total" => :public,
    "stacks_gdpr_export_orphan_count_total" => :public,
    "stacks_gdpr_export_undated_count_total" => :public,
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
