defmodule Stacks.FeatureFlags do
  @moduledoc """
  Central read-side for The Stacks' runtime feature flags (ADR-020).

  Flags are plain `Application` env values set from `config/runtime.exs` (via an
  env var) so they can be flipped per-deployment with no code change — the same
  self-hosted, in-repo kill-switch pattern as the AI kill-switch,
  `STACKS_E2E_TEST_HELPERS`, and `ALLOW_SEEDS`. Deliberately NOT a SaaS flag
  service (no phone-home, no per-eval cost).

  Read every flag through a helper here so there is a single, greppable source of
  truth and every call site is uniform.
  """

  @doc """
  Whether age-gating enforcement is active.

  When `false` (the **production default**), all three enforcement points —
  `StacksWeb.Plugs.AgeGate.enforce/2`, `Stacks.Books.maybe_exclude_age_gated/2`,
  and `Stacks.Visibility.check_age_gate/3` — are no-ops: age-gated books behave
  exactly like public ones. Shipped dark until a real age-verification provider
  is integrated (ADR-020). The test env sets this to `true` so the full
  enforcement suite keeps exercising the gate.
  """
  @spec age_gating_enabled?() :: boolean()
  def age_gating_enabled? do
    Application.get_env(:core, :age_gating_enabled, false)
  end

  @doc """
  Whether registration is gated behind an invitation (US-14.1.3, closed beta).

  When `true`, `POST /api/auth/register` refuses any request whose
  `invite_code` is missing or not redeemable, and the SPA (told via
  `GET /api/config`) replaces the Register form with the invite-only panel.
  Flipping it off restores open registration with no code change. The SPA
  fails CLOSED on a config decode failure — a config blip must not reopen
  public registration.
  """
  @spec invite_only_registration?() :: boolean()
  def invite_only_registration? do
    Application.get_env(:core, :invite_only_registration, false)
  end
end
